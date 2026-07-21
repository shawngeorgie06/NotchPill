#!/bin/bash
# Double-click this file in Finder to install NotchPill (bypasses Gatekeeper quarantine).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/NotchPill.app"
DEST="/Applications/NotchPill.app"

if [[ ! -d "$APP" ]]; then
  osascript -e 'display alert "NotchPill.app not found next to this installer." as critical'
  exit 1
fi

echo "Removing download quarantine…"
xattr -cr "$APP"

echo "Copying to Applications…"
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -cr "$DEST"

echo "Launching NotchPill…"
open "$DEST"

osascript -e 'display notification "Look for the notch icon in your menu bar." with title "NotchPill installed"'

echo ""
echo "Done! Enable Launch at Login from the menu bar icon."
read -r -p "Press Enter to close…"
