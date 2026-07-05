#!/bin/bash
# Validates the trimmi-base feature. Run with: devcontainer features test -f trimmi-base ...
set -e

source dev-container-features-test-lib

check "rtk on PATH"            bash -c "command -v rtk"
check "rtk-mcp on PATH"        bash -c "command -v rtk-mcp"
check "uv on PATH"             bash -c "command -v uv || command -v uvx"
check "aider on PATH"          bash -c "command -v aider"
check "shared post-start.sh"   bash -c "test -x /usr/local/share/trimmi/post-start.sh"
check "shared post-create.sh"  bash -c "test -x /usr/local/share/trimmi/post-create.sh"
check "CLAUDE_CONFIG_DIR set"  bash -c '[ "$CLAUDE_CONFIG_DIR" = "/home/vscode/.claude" ]'
check "EDITOR set"             bash -c '[ "$EDITOR" = "nano" ]'
check "rtk telemetry off"      bash -c '[ "$RTK_TELEMETRY_DISABLED" = "1" ]'
check "gh from dependency"     bash -c "command -v gh"
check "cargo from dependency"  bash -c "command -v cargo || test -x /usr/local/cargo/bin/cargo"
check "python 3.14 from dep"   bash -c "(python --version 2>&1; python3 --version 2>&1) | grep -q 'Python 3\.14'"

reportResults
