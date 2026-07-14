#!/usr/bin/env bash
# trimmi-base devcontainer Feature.
# Installs the shared tooling (rtk + rtk-mcp) at the image level and ships the
# shared post-create / post-start lifecycle scripts that every trimmi-de repo's
# devcontainer.json calls. Repo-specific provisioning stays in each repo's own
# post-create.sh (which calls the shared one first).
set -euo pipefail

# Feature options arrive as UPPERCASED env vars.
INSTALL_RTK="${INSTALLRTK:-true}"
INSTALL_AIDER="${INSTALLAIDER:-true}"

SHARE=/usr/local/share/trimmi
# Determine the remote user's home directory dynamically
if [ -n "${_REMOTE_USER:-}" ]; then
    USER_HOME=$(getent passwd "$_REMOTE_USER" 2>/dev/null | cut -d: -f6) || USER_HOME="$HOME"
else
    USER_HOME="$HOME"
fi
mkdir -p "$SHARE"

echo "[trimmi-base] installing (installRtk=${INSTALL_RTK})"

# --- rtk + rtk-mcp -----------------------------------------------------------
# rtk ships prebuilt static release binaries, so we download one instead of
# compiling (the cargo build of rtk's icu/zerovec dependency tree takes minutes).
# rtk-mcp has NO prebuilt binaries, so it still builds from source with cargo
# (small/fast) — that's the only reason the rust feature is needed for tooling.
# Everything lands in /usr/local/bin so it's on PATH for every user, not just root.
RTK_VERSION="${RTKVERSION:-latest}"
if [ "$INSTALL_RTK" = "true" ]; then
    case "$(uname -m)" in
        x86_64)  rtk_target="x86_64-unknown-linux-musl" ;;
        aarch64) rtk_target="aarch64-unknown-linux-gnu" ;;
        *)       rtk_target="" ;;
    esac

    rtk_tag="$RTK_VERSION"
    if [ "$rtk_tag" = "latest" ]; then
        rtk_tag="$(curl -fsSL https://api.github.com/repos/rtk-ai/rtk/releases/latest \
            | grep -oP '"tag_name"\s*:\s*"\K[^"]+' || true)"
    fi

    rtk_installed=false
    if [ -n "$rtk_target" ] && [ -n "$rtk_tag" ]; then
        rtk_url="https://github.com/rtk-ai/rtk/releases/download/${rtk_tag}/rtk-${rtk_target}.tar.gz"
        echo "[trimmi-base] downloading prebuilt rtk ${rtk_tag} (${rtk_target})"
        if curl -fsSL --retry 3 --retry-delay 5 "$rtk_url" | tar -xz -C /usr/local/bin rtk; then
            chmod 0755 /usr/local/bin/rtk
            rtk_installed=true
        else
            echo "[trimmi-base] WARNING: prebuilt rtk download failed; will try cargo"
        fi
    fi

    export PATH="/usr/local/cargo/bin:${CARGO_HOME:-/usr/local/cargo}/bin:${PATH}"
    if command -v cargo >/dev/null 2>&1; then
        if [ "$rtk_installed" != "true" ]; then
            for i in 1 2 3; do
                cargo install --locked --root /usr/local --git https://github.com/rtk-ai/rtk && break
                sleep 1
            done || echo "[trimmi-base] WARNING: rtk install failed after 3 attempts (skipping)"
        fi
        # rtk-mcp: no prebuilt binaries published — build from source.
        for i in 1 2 3; do
            cargo install --locked --root /usr/local --git https://github.com/ousamabenyounes/rtk-mcp && break
            sleep 1
        done || echo "[trimmi-base] WARNING: rtk-mcp install failed after 3 attempts (skipping)"
    else
        echo "[trimmi-base] WARNING: cargo not found — ensure the rust feature is present; skipping rtk-mcp"
    fi
fi

# --- uv (provides uvx, used to run the serena MCP server; see each repo's .mcp.json) ---
if ! command -v uv >/dev/null 2>&1; then
    # Install uv + uvx into /usr/local/bin so they're on PATH for every user at
    # runtime (same as rtk/rtk-mcp/aider). The installer otherwise defaults to
    # ~/.local/bin, which isn't on the global PATH and is root-owned during the
    # image build, so `uv` wouldn't be found later.
    curl -fsSL --retry 3 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
        || echo "[trimmi-base] WARNING: uv install failed"
fi

# --- aider (AI pair programming; DeepSeek default, OpenRouter available) -------
# aider is a Python CLI with a heavy dep tree; install it isolated via uv tool
# (uv installed above). Pin to Python 3.12: aider's transitive scipy dependency
# has no wheel for the default Python 3.14 yet and fails to build from source.
# uv fetches a managed 3.12 interpreter into UV_PYTHON_INSTALL_DIR. All install
# dirs live under /usr/local so the binary, venv, and interpreter are baked in
# and on PATH for every user.
if [ "$INSTALL_AIDER" = "true" ] && ! command -v aider >/dev/null 2>&1; then
    if command -v uv >/dev/null 2>&1; then
        export UV_TOOL_BIN_DIR=/usr/local/bin
        export UV_TOOL_DIR=/usr/local/share/uv/tools
        export UV_PYTHON_INSTALL_DIR=/usr/local/share/uv/python
        uv tool install --python 3.12 aider-chat \
            || echo "[trimmi-base] WARNING: aider install failed (ensure uv + network)"
    else
        echo "[trimmi-base] WARNING: uv not available; skipping aider install"
    fi
fi

# --- shared Claude Code credential + login isolation --------------------------
# Factored into its own script so BOTH post-create (before `claude mcp add`) and
# post-start (credential refresh on every start) can call it. Ordering is the
# whole point: devcontainer runs postCreate before postStart, and post-create's
# `claude mcp add` writes $CLAUDE_CONFIG_DIR/.claude.json. If that fresh file is
# created before the host's logged-in .claude.json is seeded, the container comes
# up with MCP servers but no oauthAccount -> "not logged in". So this runs first.
install -m 0755 /dev/stdin "$SHARE/claude-isolate.sh" <<'ISOLATE'
#!/usr/bin/env bash
# Claude Code per-container credential + login isolation. Idempotent; safe to run
# repeatedly and from multiple lifecycle hooks.
#
# Every trimmi repo bind-mounts the host ~/.claude at /home/vscode/.claude, so the
# host and all containers historically shared ONE ~/.claude/.credentials.json.
# Claude Code refreshes its short-lived OAuth token in the background and rewrites
# that file; with several containers running in parallel those refreshes clobber
# each other and you get kicked back to `/login`.
#
# Fix: CLAUDE_CONFIG_DIR points at a container-local dir (see the feature's
# containerEnv). We mirror every entry from the shared mount into it as a symlink
# -- so all config stays shared (CLAUDE.md, RTK.md, settings.json, plugins/, and
# projects/ which holds the auto-memory) -- EXCEPT the two files that carry
# per-container identity, handled as real seeded copies below:
#   .credentials.json  short-lived OAuth token (refreshed when the host's is newer)
#   .claude.json       login account (oauthAccount/userID) + evolving MCP/project state
set -u
SHARED="$HOME/.claude"
LOCAL="${CLAUDE_CONFIG_DIR:-$HOME/.claude-local}"
[ -d "$SHARED" ] || exit 0
[ "$LOCAL" = "$SHARED" ] && exit 0        # isolation off (config dir IS the mount)
mkdir -p "$LOCAL"

# Link entries not already present locally: never clobber something already there,
# but pick up new shared entries over time. The two identity files are skipped here
# and seeded as real copies below.
for src in "$SHARED"/* "$SHARED"/.[!.]*; do
    [ -e "$src" ] || continue                       # guard unmatched globs
    name="$(basename "$src")"
    case "$name" in .credentials.json|.claude.json) continue ;; esac
    if [ -e "$LOCAL/$name" ] || [ -L "$LOCAL/$name" ]; then continue; fi
    ln -s "$src" "$LOCAL/$name"
done

# .claude.json holds the login account. Seed it ONCE (when the local copy is
# missing) from the shared master so a fresh container inherits the host login;
# after that it's container-local and never re-clobbered, so `claude mcp add` and
# any evolving state stay put. Must be a real file, never a symlink back to the
# shared mount (that would send every container's writes host-globally).
[ -L "$LOCAL/.claude.json" ] && rm -f "$LOCAL/.claude.json"
if [ -f "$SHARED/.claude.json" ] && [ ! -f "$LOCAL/.claude.json" ]; then
    cp -p "$SHARED/.claude.json" "$LOCAL/.claude.json"
    chmod 600 "$LOCAL/.claude.json"
fi

# .credentials.json: real per-container copy (never a symlink, or background token
# refreshes would hit the shared copy again). Seed/refresh when the local copy is
# missing or the host's is newer (e.g. you just logged in on the host).
[ -L "$LOCAL/.credentials.json" ] && rm -f "$LOCAL/.credentials.json"
if [ -f "$SHARED/.credentials.json" ] && \
   { [ ! -f "$LOCAL/.credentials.json" ] || [ "$SHARED/.credentials.json" -nt "$LOCAL/.credentials.json" ]; }; then
    cp -p "$SHARED/.credentials.json" "$LOCAL/.credentials.json"
    chmod 600 "$LOCAL/.credentials.json"
fi
ISOLATE

# --- shared postStart: git identity + gh auth from the mounted token ----------
install -m 0755 /dev/stdin "$SHARE/post-start.sh" <<'POSTSTART'
#!/usr/bin/env bash
# Shared postStartCommand for trimmi-de repos. Runs on every start; never blocks.
set -u

# --- Claude Code per-container credential + login isolation -------------------
# Seed the container-local CLAUDE_CONFIG_DIR from the shared ~/.claude mount and
# refresh the OAuth token when the host's is newer. post-create already ran this
# once (before `claude mcp add`) so login lands first; here it keeps credentials
# fresh across restarts. See claude-isolate.sh for the full rationale.
bash /usr/local/share/trimmi/claude-isolate.sh || true

if [ -n "${HOST_GIT_USER:-}" ]; then
    git config --global user.name "$HOST_GIT_USER"
    git config --global user.email "${HOST_GIT_EMAIL:-}"
fi
git config --global push.autoSetupRemote true
# shellcheck source=/dev/null
if [ -f "$HOME/.gh_token_env" ] && . "$HOME/.gh_token_env" && [ -n "${GH_TOKEN:-}" ]; then
    if printf '%s' "$GH_TOKEN" | gh auth login --with-token >/dev/null 2>&1; then
        echo "gh authenticated from .gh_token_env"
    fi
fi
exit 0
POSTSTART

# --- shared postCreate: safe.directory + rtk hook + gh_token shell wiring -----
# Repo-specific steps (pip install, migrate, …) go in the repo's own post-create
# after sourcing/calling this one.
install -m 0755 /dev/stdin "$SHARE/post-create.sh" <<'POSTCREATE'
#!/usr/bin/env bash
# Shared postCreateCommand for trimmi-de repos. Runs once, as the remote user.
set -euo pipefail
echo "=== [trimmi] git safe.directory ==="
git config --global --add safe.directory "$(pwd)" || true

echo "=== [trimmi] rtk global hook (telemetry left disabled) ==="
# rtk init prompts once for telemetry consent ([y/N], default N). In a container
# build that prompt would block, so answer it non-interactively with N. The
# RTK_TELEMETRY_DISABLED=1 containerEnv (see devcontainer-feature.json) is the
# hard kill-switch: it blocks all telemetry pings regardless of consent state.
if command -v rtk >/dev/null 2>&1; then
    # rtk init prompts once for telemetry consent ([y/N], default N). In a container
    # build that prompt would block, so answer it non-interactively with N.
    printf "n\n" | rtk init -g 2>/dev/null || echo "WARNING: rtk init failed"
    rtk telemetry disable >/dev/null 2>&1 || true
else
    echo "WARNING: rtk init skipped (rtk not installed)"
fi

echo "=== [trimmi] wiring GH_TOKEN into interactive shells ==="
# The mounted ~/.gh_token_env is the single source of truth for gh auth; source it
# from ~/.bashrc so interactive shells get a clean GH_TOKEN. Idempotent via marker.
MARKER="# gh_token_env (devcontainer)"
if ! grep -qF "$MARKER" "$HOME/.bashrc" 2>/dev/null; then
    {
        echo ""
        echo "$MARKER"
        # shellcheck disable=SC2016  # $HOME must stay literal: it expands when .bashrc is sourced
        echo '[ -f "$HOME/.gh_token_env" ] && . "$HOME/.gh_token_env"'
    } >> "$HOME/.bashrc"
fi

# aider gets its keys + default model without any wiring here: the feature's
# containerEnv sets AIDER_ENV_FILE=/home/vscode/.aider_env (aider loads that
# host-mounted dotenv itself) and AIDER_MODEL=deepseek. Same idea as Claude Code
# reading its creds from the bind-mounted ~/.claude — nothing to source or write.

# Seed the isolated CLAUDE_CONFIG_DIR (login + credentials) BEFORE any claude
# command writes a fresh .claude.json. Without this, the `claude mcp add` below
# creates a .claude.json with MCP servers but no oauthAccount, and post-start's
# later seed is skipped (file already exists) -> the container is "not logged in".
bash /usr/local/share/trimmi/claude-isolate.sh || true

echo "=== [trimmi] user-scope MCP servers (serena, rtk) ==="
# Shared MCP servers live at USER scope so every trimmi repo gets them without
# hardcoding them into each repo's project-scope .mcp.json (which stays app-owned).
# Claude Code merges user + project scopes, so both are active at once. This writes
# to $CLAUDE_CONFIG_DIR/.claude.json, which is the container-local isolated dir
# (seeded from the host just above), so it does NOT leak host-globally. remove-then-add
# is idempotent across rebuilds and also picks up any change to a server's definition here.
if command -v claude >/dev/null 2>&1; then
    claude mcp remove --scope user serena >/dev/null 2>&1 || true
    # Kill the dashboard entirely, not just its browser pop-up:
    #   --enable-web-dashboard False   don't run the dashboard web server at all
    #                                  (nothing to serve at localhost:24282 → nothing to open)
    #   --open-web-dashboard   False   belt-and-suspenders: never auto-open a browser
    #   --enable-gui-log-window False  never spawn the tkinter GUI log window
    # (Booleans take an explicit value in serena's CLI.)
    claude mcp add --scope user serena -- uvx --from git+https://github.com/oraios/serena \
        serena start-mcp-server --context claude-code --project-from-cwd \
        --enable-web-dashboard False --open-web-dashboard False --enable-gui-log-window False \
        || echo "WARNING: serena mcp add failed"
    claude mcp remove --scope user rtk >/dev/null 2>&1 || true
    claude mcp add --scope user rtk -- rtk-mcp || echo "WARNING: rtk mcp add failed"
else
    echo "WARNING: claude not found; skipping user-scope MCP setup"
fi

echo "=== [trimmi] base post-create complete ==="
POSTCREATE

echo "[trimmi-base] done — shared lifecycle scripts in $SHARE"
