#!/usr/bin/env bash
# Runtime proof that serena's web dashboard stays OFF with the flags trimmi-base
# registers it with. Heavier than the config assertion in test/trimmi-base/test.sh
# (it fetches + launches serena over the network and waits for startup), so it's a
# standalone on-demand check — NOT part of the push gate.
#
#   Usage:  bash test/serena-dashboard-check.sh
#
# It runs a positive control first (dashboard ENABLED must open port 24282, proving
# the probe actually detects a live dashboard), then the real check (trimmi-base's
# flags must keep the port closed). Exit 0 = dashboard stays off.
set -uo pipefail

PORT=24282
SERENA=(uvx --from git+https://github.com/oraios/serena serena start-mcp-server --context claude-code)
PROJ="$(mktemp -d)"; git -C "$PROJ" init -q 2>/dev/null || true
trap 'pkill -9 -f "serena start-mcp-server --context claude-code --project $PROJ" 2>/dev/null; rm -rf "$PROJ"' EXIT

port_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; }

launch() { # args: dashboard flags. Keeps stdin open (sleep) so the stdio server stays up.
  sleep 90 | "${SERENA[@]}" --project "$PROJ" "$@" >"$PROJ/serena.log" 2>&1 &
}

stop() {
  pkill -9 -f "serena start-mcp-server --context claude-code --project $PROJ" 2>/dev/null
  # wait for the port to be released before the next phase
  for _ in $(seq 1 10); do port_open || break; sleep 1; done
}

fail=0

echo "[serena-check] positive control: dashboard ENABLED should open port $PORT…"
launch --enable-web-dashboard True --open-web-dashboard False --enable-gui-log-window False
opened=0
for _ in $(seq 1 45); do if port_open; then opened=1; break; fi; sleep 1; done
stop
if [ "$opened" = 1 ]; then
  echo "[serena-check]   ✅ control passed (probe detects a live dashboard)"
else
  echo "[serena-check]   ❌ control FAILED — serena never bound the port here; cannot trust the result"
  echo "[serena-check]      (network/startup issue? see $PROJ/serena.log)"; fail=1
fi

echo "[serena-check] real check: trimmi-base flags must keep port $PORT CLOSED…"
launch --enable-web-dashboard False --open-web-dashboard False --enable-gui-log-window False
bad=0
for _ in $(seq 1 25); do if port_open; then bad=1; break; fi; sleep 1; done
stop
if [ "$bad" = 0 ]; then
  echo "[serena-check]   ✅ dashboard stayed OFF — no server on $PORT, no browser to open"
else
  echo "[serena-check]   ❌ dashboard came up despite the disable flags"; fail=1
fi

[ "$fail" = 0 ] && echo "[serena-check] PASS" || echo "[serena-check] FAIL"
exit "$fail"
