#!/bin/bash
# Validates the trimmi-base feature. Run with: devcontainer features test -f trimmi-base ...
set -e

source dev-container-features-test-lib

check "rtk on PATH"            bash -c "command -v rtk"
check "rtk works"              bash -c "rtk --version"
check "rtk-mcp on PATH"        bash -c "command -v rtk-mcp"
check "rtk-mcp works"          bash -c "rtk-mcp --help"
check "uv on PATH"             bash -c "command -v uv || command -v uvx"
check "aider on PATH"          bash -c "command -v aider"
check "aider works"            bash -c "aider --help 2>&1 | head -5"
check "AIDER_MODEL set"        bash -c '[ "$AIDER_MODEL" = "deepseek" ]'
check "AIDER_ENV_FILE set"     bash -c '[ "$AIDER_ENV_FILE" = "/home/vscode/.aider_env" ]'
check "AIDER_READ set"         bash -c '[ "$AIDER_READ" = "CLAUDE.md" ]'
check "AIDER_AUTO_COMMITS off" bash -c '[ "$AIDER_AUTO_COMMITS" = "false" ]'
check "shared post-start.sh"   bash -c "test -x /usr/local/share/trimmi/post-start.sh"
check "shared post-create.sh"  bash -c "test -x /usr/local/share/trimmi/post-create.sh"
check "post-create runs"       bash -c "bash /usr/local/share/trimmi/post-create.sh"
check "post-start runs"        bash -c "bash /usr/local/share/trimmi/post-start.sh"
check "CLAUDE_CONFIG_DIR set"  bash -c '[ "$CLAUDE_CONFIG_DIR" = "/home/vscode/.claude" ]'
check "EDITOR set"             bash -c '[ "$EDITOR" = "nano" ]'
check "rtk telemetry off"      bash -c '[ "$RTK_TELEMETRY_DISABLED" = "1" ]'
check "gh from dependency"     bash -c "command -v gh"
check "cargo from dependency"  bash -c "command -v cargo || test -x /usr/local/cargo/bin/cargo"
check "python 3.14 from dep"   bash -c "(python --version 2>&1 || true; python3 --version 2>&1 || true) | grep -q 'Python 3\.14'"

reportResults
