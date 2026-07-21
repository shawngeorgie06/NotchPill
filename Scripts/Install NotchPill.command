#!/bin/bash
# Install NotchPill from the folder next to this script.
# If double-click is blocked, open Terminal and run:
#   bash "/path/to/Install NotchPill.command"
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/NotchPill.app"
DEST="/Applications/NotchPill.app"

if [[ ! -d "$APP" ]]; then
  osascript -e 'display alert "NotchPill.app not found next to this installer." as critical'
  exit 1
fi

echo "Removing download quarantine from entire folder…"
xattr -cr "$DIR"

echo "Copying to Applications…"
pkill -x NotchPill 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Re-signing app…"
FRAMEWORK="$DEST/Contents/Resources/MediaRemoteAdapter.framework"
if [[ -d "$FRAMEWORK" ]]; then
  codesign --force --sign - "$FRAMEWORK" 2>/dev/null || true
fi
codesign --force --sign - "$DEST/Contents/MacOS/NotchPill"
codesign --force --sign - "$DEST"
xattr -cr "$DEST"

echo "Launching NotchPill…"
open "$DEST"

osascript -e 'display notification "Look for the notch icon in your menu bar." with title "NotchPill installed"'

echo ""
echo "Done! Enable Launch at Login from the menu bar icon."
read -r -p "Press Enter to close…"
