#!/usr/bin/env bash
# Static validation of the trimmi-base feature metadata. Runs on the HOST (no
# container, no Docker), so it's fast enough for the pre-push hook and CI. It
# catches the config regressions the in-container tests can't see: a dropped or
# renamed mount, the mount string-vs-object schema bug (#26), or a wrong
# containerEnv value (e.g. CLAUDE_CONFIG_DIR not pointing at the isolated dir).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root = test/..
feat="$here/src/trimmi-base/devcontainer-feature.json"
[ -f "$feat" ] || { echo "FAIL: $feat not found"; exit 1; }

python3 - "$feat" <<'PY'
import json, sys
feat = json.load(open(sys.argv[1]))
errors = []

# --- all four host bind-mounts declared, as Mount OBJECTS (not string short-form) ---
want_targets = {
    "/home/vscode/.claude", "/home/vscode/.serena",
    "/home/vscode/.gh_token_env", "/home/vscode/.aider_env",
}
got_targets = set()
for m in feat.get("mounts", []):
    if not isinstance(m, dict):
        errors.append(f"mount must be an object, not string short-form: {m!r}")
        continue
    if m.get("type") != "bind":
        errors.append(f"mount {m.get('target')!r}: type must be 'bind', got {m.get('type')!r}")
    if "${localEnv:HOME}" not in m.get("source", ""):
        errors.append(f"mount {m.get('target')!r}: source must bind from ${{localEnv:HOME}}, got {m.get('source')!r}")
    got_targets.add(m.get("target"))
missing = want_targets - got_targets
if missing:
    errors.append(f"missing mount targets: {sorted(missing)}")

# --- containerEnv the tooling depends on ---
env = feat.get("containerEnv", {})
expect_env = {
    "CLAUDE_CONFIG_DIR": "/home/vscode/.claude-local",   # per-container login isolation
    "AIDER_MODEL": "deepseek",
    "AIDER_ENV_FILE": "/home/vscode/.aider_env",
    "AIDER_READ": "/home/vscode/.claude/CLAUDE.md",
}
for k, v in expect_env.items():
    if env.get(k) != v:
        errors.append(f"containerEnv[{k!r}] expected {v!r}, got {env.get(k)!r}")

if errors:
    print("FAIL: trimmi-base feature metadata:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print(f"OK: 4 host mounts declared {sorted(got_targets)}; containerEnv verified")
PY
