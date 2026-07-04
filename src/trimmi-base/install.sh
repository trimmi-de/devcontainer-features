#!/usr/bin/env bash
# trimmi-base devcontainer Feature.
# Installs the shared tooling (rtk + rtk-mcp) at the image level and ships the
# shared post-create / post-start lifecycle scripts that every trimmi-de repo's
# devcontainer.json calls. Repo-specific provisioning stays in each repo's own
# post-create.sh (which calls the shared one first).
set -euo pipefail

# Feature options arrive as UPPERCASED env vars.
INSTALL_RTK="${INSTALLRTK:-true}"

SHARE=/usr/local/share/trimmi
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
        if curl -fsSL "$rtk_url" | tar -xz -C /usr/local/bin rtk; then
            chmod 0755 /usr/local/bin/rtk
            rtk_installed=true
        else
            echo "[trimmi-base] WARNING: prebuilt rtk download failed; will try cargo"
        fi
    fi

    export PATH="/usr/local/cargo/bin:${CARGO_HOME:-/usr/local/cargo}/bin:${PATH}"
    if command -v cargo >/dev/null 2>&1; then
        if [ "$rtk_installed" != "true" ]; then
            cargo install --locked --root /usr/local --git https://github.com/rtk-ai/rtk \
                || echo "[trimmi-base] WARNING: rtk install failed (skipping)"
        fi
        # rtk-mcp: no prebuilt binaries published — build from source.
        cargo install --locked --root /usr/local --git https://github.com/ousamabenyounes/rtk-mcp \
            || echo "[trimmi-base] WARNING: rtk-mcp install failed (skipping)"
    else
        echo "[trimmi-base] WARNING: cargo not found — ensure the rust feature is present; skipping rtk-mcp"
    fi
fi

# --- uv (provides uvx, used to run the serena MCP server; see each repo's .mcp.json) ---
if ! command -v uv >/dev/null 2>&1; then
    python3 -m pip install --no-cache-dir uv \
        || echo "[trimmi-base] WARNING: uv install failed (ensure the python feature is present)"
fi

# --- shared postStart: git identity + gh auth from the mounted token ----------
install -m 0755 /dev/stdin "$SHARE/post-start.sh" <<'POSTSTART'
#!/usr/bin/env bash
# Shared postStartCommand for trimmi-de repos. Runs on every start; never blocks.
set -u
if [ -n "${HOST_GIT_USER:-}" ]; then
    git config --global user.name "$HOST_GIT_USER"
    git config --global user.email "${HOST_GIT_EMAIL:-}"
fi
git config --global push.autoSetupRemote true
# shellcheck source=/dev/null
if [ -f "$HOME/.gh_token_env" ] && . "$HOME/.gh_token_env" && [ -n "${GH_TOKEN:-}" ]; then
    if printf '%s' "$GH_TOKEN" | env -u GH_TOKEN gh auth login --with-token >/dev/null 2>&1; then
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
    printf 'n\n' | rtk init -g || echo "WARNING: rtk init failed"
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

echo "=== [trimmi] user-scope MCP servers (serena, rtk) ==="
# Shared MCP servers live at USER scope so every trimmi repo gets them without
# hardcoding them into each repo's project-scope .mcp.json (which stays app-owned).
# Claude Code merges user + project scopes, so both are active at once. The config
# dir (~/.claude) is bind-mounted from the host, so this writes host-globally —
# accepted trade-off. remove-then-add is idempotent across rebuilds and also picks
# up any change to a server's definition here.
if command -v claude >/dev/null 2>&1; then
    claude mcp remove --scope user serena >/dev/null 2>&1 || true
    claude mcp add --scope user serena -- uvx --from git+https://github.com/oraios/serena \
        serena start-mcp-server --context claude-code --project-from-cwd \
        || echo "WARNING: serena mcp add failed"
    claude mcp remove --scope user rtk >/dev/null 2>&1 || true
    claude mcp add --scope user rtk -- rtk-mcp || echo "WARNING: rtk mcp add failed"
else
    echo "WARNING: claude not found; skipping user-scope MCP setup"
fi

echo "=== [trimmi] base post-create complete ==="
POSTCREATE

echo "[trimmi-base] done — shared lifecycle scripts in $SHARE"
