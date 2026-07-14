#!/bin/bash
# Validates the trimmi-base feature. Run with: devcontainer features test -f trimmi-base ...
# NOTE: no `set -e` — the test lib's `check` returns non-zero on failure by design
# and accumulates into FAILED[]; `reportResults` exits 1 at the end. With `set -e`
# the suite aborts at the first failing check and hides the rest.

source dev-container-features-test-lib

check "rtk on PATH"            bash -c "command -v rtk"
check "rtk works"              bash -c "rtk --version"
check "rtk-mcp on PATH"        bash -c "command -v rtk-mcp"
# rtk-mcp has no --help/--version; it just starts the stdio server (banner to
# stderr) and exits non-zero on EOF stdin. Smoke-test by confirming that banner.
check "rtk-mcp works"          bash -c "timeout 15 rtk-mcp </dev/null 2>&1 | grep -q 'Starting RTK-MCP server'"
check "uv on PATH"             bash -c "command -v uv || command -v uvx"
check "aider on PATH"          bash -c "command -v aider"
check "aider works"            bash -c "aider --version"
check "AIDER_MODEL set"        bash -c '[ "$AIDER_MODEL" = "deepseek" ]'
check "AIDER_ENV_FILE set"     bash -c '[ "$AIDER_ENV_FILE" = "/home/vscode/.aider_env" ]'
check "AIDER_READ set"         bash -c '[ "$AIDER_READ" = "/home/vscode/.claude/CLAUDE.md" ]'
check "AIDER_AUTO_COMMITS off" bash -c '[ "$AIDER_AUTO_COMMITS" = "false" ]'
check "AIDER_MODEL_WARN off"   bash -c '[ "$AIDER_SHOW_MODEL_WARNINGS" = "false" ]'
# No interactive startup prompts: analytics opt-in (the "see the docs?" one),
# the .gitignore prompt, and the update-check nag are all disabled up front.
check "AIDER_ANALYTICS off"    bash -c '[ "$AIDER_ANALYTICS_DISABLE" = "true" ]'
check "AIDER_GITIGNORE off"    bash -c '[ "$AIDER_GITIGNORE" = "false" ]'
check "AIDER_CHECK_UPDATE off" bash -c '[ "$AIDER_CHECK_UPDATE" = "false" ]'
check "AIDER_RELEASE_NOTES off" bash -c '[ "$AIDER_SHOW_RELEASE_NOTES" = "false" ]'
check "shared post-start.sh"   bash -c "test -x /usr/local/share/trimmi/post-start.sh"
check "shared post-create.sh"  bash -c "test -x /usr/local/share/trimmi/post-create.sh"
check "shared claude-isolate"  bash -c "test -x /usr/local/share/trimmi/claude-isolate.sh"
check "claude-isolate runs"    bash -c "bash /usr/local/share/trimmi/claude-isolate.sh"
check "post-create runs"       bash -c "bash /usr/local/share/trimmi/post-create.sh"
check "post-start runs"        bash -c "bash /usr/local/share/trimmi/post-start.sh"
check "CLAUDE_CONFIG_DIR set"  bash -c '[ "$CLAUDE_CONFIG_DIR" = "/home/vscode/.claude-local" ]'
check "EDITOR set"             bash -c '[ "$EDITOR" = "nano" ]'
check "rtk telemetry off"      bash -c '[ "$RTK_TELEMETRY_DISABLED" = "1" ]'
check "gh from dependency"     bash -c "command -v gh"
check "cargo from dependency"  bash -c "command -v cargo || test -x /usr/local/cargo/bin/cargo"
check "python 3.14 from dep"   bash -c "(python --version 2>&1 || true; python3 --version 2>&1 || true) | grep -q 'Python 3\.14'"

# --- login + mount-consumption tests -----------------------------------------
# The feature-test harness has no real host bind-mounts, so these simulate the
# *contents* each mount delivers and assert the tool actually consumes them —
# i.e. the exact chains that broke: Claude login surviving per-container
# isolation (~/.claude), aider reading its DeepSeek key (~/.aider_env), and gh
# reading its token (~/.gh_token_env). "all mounts declared" is covered
# statically by test/validate-metadata.sh (run in the pre-push hook + CI).

# Claude login (~/.claude): claude-isolate.sh must seed the isolated
# CLAUDE_CONFIG_DIR with the host login (.claude.json oauthAccount) and a REAL
# .credentials.json copy (never a symlink), and symlink shared config (CLAUDE.md).
check "claude login: isolation seeds oauthAccount + real creds copy" bash -c '
  set -e
  t=$(mktemp -d); export HOME=$t CLAUDE_CONFIG_DIR=$t/.claude-local
  mkdir -p "$t/.claude"
  printf "%s" "{\"oauthAccount\":{\"emailAddress\":\"t@e.com\"},\"mcpServers\":{}}" > "$t/.claude/.claude.json"
  printf "%s" "{\"tok\":1}" > "$t/.claude/.credentials.json"
  printf "shared" > "$t/.claude/CLAUDE.md"
  bash /usr/local/share/trimmi/claude-isolate.sh
  grep -q oauthAccount "$CLAUDE_CONFIG_DIR/.claude.json"
  [ -L "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]
  [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ] && [ ! -L "$CLAUDE_CONFIG_DIR/.credentials.json" ]
'

# Guards the postCreate-before-postStart ordering fix: a re-run (post-start)
# must NOT clobber the container-local login or the serena entry mcp add wrote.
check "claude login: re-run keeps container-local login + mcp" bash -c '
  set -e
  t=$(mktemp -d); export HOME=$t CLAUDE_CONFIG_DIR=$t/.claude-local
  mkdir -p "$t/.claude"; printf "%s" "{\"oauthAccount\":{\"e\":1}}" > "$t/.claude/.claude.json"
  bash /usr/local/share/trimmi/claude-isolate.sh
  printf "%s" "{\"oauthAccount\":{\"e\":1},\"mcpServers\":{\"serena\":{}}}" > "$CLAUDE_CONFIG_DIR/.claude.json"
  bash /usr/local/share/trimmi/claude-isolate.sh
  grep -q oauthAccount "$CLAUDE_CONFIG_DIR/.claude.json" && grep -q serena "$CLAUDE_CONFIG_DIR/.claude.json"
'

# aider login (~/.aider_env): aider must load DEEPSEEK_API_KEY from AIDER_ENV_FILE.
# The "DEEPSEEK_API_KEY: Not set" warning appears only when the key is absent.
check "aider login: loads DEEPSEEK_API_KEY from AIDER_ENV_FILE" bash -c '
  set -e
  t=$(mktemp -d); printf "DEEPSEEK_API_KEY=sk-test-abc\n" > "$t/aider_env"
  out=$(env -i HOME="$t" PATH="$PATH" AIDER_ENV_FILE="$t/aider_env" AIDER_SHOW_MODEL_WARNINGS=true \
        aider --model deepseek --no-git --exit --yes 2>&1)
  ! printf "%s" "$out" | grep -q "DEEPSEEK_API_KEY: Not set"
'

# Negative control: proves the assertion above is real (a missing key IS detected).
check "aider login: flags a missing key (negative control)" bash -c '
  set -e
  t=$(mktemp -d); printf "AIDER_MODEL=deepseek\n" > "$t/aider_env"
  out=$(env -i HOME="$t" PATH="$PATH" AIDER_ENV_FILE="$t/aider_env" AIDER_SHOW_MODEL_WARNINGS=true \
        aider --model deepseek --no-git --exit --yes 2>&1)
  printf "%s" "$out" | grep -q "DEEPSEEK_API_KEY: Not set"
'

# aider startup: no interactive questions. The .gitignore prompt is the one that
# actually mutates the repo, so test it behaviourally: with AIDER_GITIGNORE=false
# aider must NOT add .aider* to .gitignore (with it on, it does — see /tmp control).
# The analytics opt-in ("see the docs?"), update-check and release-notes prompts
# are asserted via their env vars above (they only fire on a TTY, not reproducible here).
check "aider startup: AIDER_GITIGNORE=false leaves .gitignore untouched" bash -c '
  set -e
  t=$(mktemp -d); cd "$t"; git init -q; git config user.email t@e.com; git config user.name t
  printf "DEEPSEEK_API_KEY=sk-x\n" > envf
  env -i HOME="$t" PATH="$PATH" AIDER_ENV_FILE="$t/envf" AIDER_MODEL=deepseek AIDER_GITIGNORE=false \
    aider --model deepseek --exit --yes </dev/null >/dev/null 2>&1 || true
  ! { [ -f .gitignore ] && grep -q "[.]aider" .gitignore; }
'

# gh login (~/.gh_token_env): the mounted dotenv must export GH_TOKEN when
# sourced — exactly how post-start.sh and ~/.bashrc consume it.
check "gh login: gh_token_env sources GH_TOKEN" bash -c '
  set -e
  t=$(mktemp -d); printf "export GH_TOKEN=ghp_test123\n" > "$t/.gh_token_env"
  ( . "$t/.gh_token_env"; [ "$GH_TOKEN" = "ghp_test123" ] )
'

# serena dashboard: post-create registered serena at user scope with the
# dashboard/browser/GUI fully disabled. Assert the stored command carries all
# three kill-switches (post-create ran above, writing $CLAUDE_CONFIG_DIR/.claude.json).
# A runtime proof (serena launched, port 24282 stays closed) lives in the heavier,
# on-demand test/serena-dashboard-check.sh.
check "serena: dashboard/browser/gui disabled in registration" bash -c '
  f="${CLAUDE_CONFIG_DIR:-$HOME/.claude-local}/.claude.json"
  grep -q -- "--enable-web-dashboard" "$f" \
    && grep -q -- "--open-web-dashboard" "$f" \
    && grep -q -- "--enable-gui-log-window" "$f"
'

reportResults
