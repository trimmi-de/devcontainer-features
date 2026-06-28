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
# Built with cargo from the rust feature (installsAfter: rust). Install into
# /usr/local (--root) so the binaries land on PATH for every user, not just root.
if [ "$INSTALL_RTK" = "true" ]; then
    export PATH="/usr/local/cargo/bin:${CARGO_HOME:-/usr/local/cargo}/bin:${PATH}"
    if command -v cargo >/dev/null 2>&1; then
        cargo install --locked --root /usr/local --git https://github.com/rtk-ai/rtk \
            || echo "[trimmi-base] WARNING: rtk install failed (skipping)"
        cargo install --locked --root /usr/local --git https://github.com/ousamabenyounes/rtk-mcp \
            || echo "[trimmi-base] WARNING: rtk-mcp install failed (skipping)"
    else
        echo "[trimmi-base] WARNING: cargo not found — ensure the rust feature is present; skipping rtk"
    fi
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

echo "=== [trimmi] rtk global hook ==="
command -v rtk >/dev/null 2>&1 && rtk init -g || echo "WARNING: rtk init skipped (rtk not installed)"

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
echo "=== [trimmi] base post-create complete ==="
POSTCREATE

echo "[trimmi-base] done — shared lifecycle scripts in $SHARE"
