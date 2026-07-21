#!/usr/bin/env bash
# End-to-end dev-ready test — run while NotchPill is open on another screen/Space.
set -euo pipefail

NOTIFY="${NOTCHPILL_NOTIFY:-/Users/shawngeorgie/Projects/NotchPill/Scripts/notify-notchpill.sh}"
CURSOR_BUNDLE="com.todesktop.230313mzl4w4u92"
TERMINAL_BUNDLE="com.apple.Terminal"

echo "Firing 4 agent pings (staggered like real finishes)..."
echo "Switch to another Space now if you want the full effect."
sleep 2

"$NOTIFY" "Refactor complete" "12 files changed" Cursor "$CURSOR_BUNDLE" Composer &
sleep 0.05
"$NOTIFY" "Tests passed" "142 passed, 0 failed" Terminal "$TERMINAL_BUNDLE" claude-code &
sleep 0.05
"$NOTIFY" "Build finished" "Debug build OK" Cursor "$CURSOR_BUNDLE" "GPT-5" &
sleep 0.05
"$NOTIFY" "Review ready" "Security scan clean" Cursor "$CURSOR_BUNDLE" "Bugbot" &

wait
echo "Done — check the notch (scroll if needed)."
