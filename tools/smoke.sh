#!/bin/zsh
# Pre-release check: starts the built app in a sandbox (own data folder, Clawd home and
# instance lock - a running widget is not touched) with the fake `claude`, waits for it to
# come up and take its first /usage answer, then checks nothing landed in the error log.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Clawd Usage.app"
[[ -d "$APP" ]] || scripts/build-app.sh
BOX=$(mktemp -d)
FAKE="$PWD/Tests/Fixtures/fake-claude.sh"
cat > "$BOX/config.json" <<JSON
{ "claudePath": "$FAKE", "clawdHome": "$BOX/home", "showAdvisor": false, "showSky": false, "showStatus": false,
  "expanded": true, "showHistory": true }
JSON
CLAWD_SMOKE=1 CLAWD_DATA_DIR="$BOX" CLAWD_READY_FILE="$BOX/ready" "$APP/Contents/MacOS/ClawdUsage" &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$BOX"' EXIT
for i in {1..30}; do [[ -f "$BOX/ready" ]] && break; sleep 1; done
[[ -f "$BOX/ready" ]] || { echo "FAIL: no ready file after 30 s"; exit 1; }
echo "up: $(cat "$BOX/ready")"
for i in {1..15}; do [[ -f "$BOX/usage-history.json" ]] && break; sleep 1; done
grep -q '"samples"' "$BOX/usage-history.json" 2>/dev/null || { echo "FAIL: no /usage sample"; exit 1; }
kill -0 $PID || { echo "FAIL: the app exited"; exit 1; }
if [[ -s "$BOX/widget-error.log" ]]; then echo "FAIL: errors:"; cat "$BOX/widget-error.log"; exit 1; fi
echo "smoke OK"
