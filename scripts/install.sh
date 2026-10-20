#!/bin/zsh
# Builds the app and puts it in /Applications (where "Open at login" belongs), replacing an older copy.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
pkill -f "Clawd Usage.app/Contents/MacOS/ClawdUsage" 2>/dev/null || true
rm -rf "/Applications/Clawd Usage.app"
cp -R "dist/Clawd Usage.app" /Applications/
echo "installed /Applications/Clawd Usage.app - open it with: open -a 'Clawd Usage'"
