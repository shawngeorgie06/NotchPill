#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# If macOS blocked this file, open Terminal and paste ONE of these instead:
#
#   curl -fsSL https://raw.githubusercontent.com/shawngeorgie06/NotchPill/main/Scripts/install-notchpill.sh | bash
#
#   xattr -cr ~/Downloads/NotchPill-*-macOS-arm64 && bash ~/Downloads/NotchPill-*-macOS-arm64/Install\ NotchPill.command
# ─────────────────────────────────────────────────────────────────────────────
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

# There is exactly one NotchPill. Anything else in /Applications whose name
# starts with "NotchPill" is a leftover: a versioned copy, a ".previous-*" or
# ".backup" rename from a hand-rolled install, or an unpacked release folder.
# Sweeping them here means an upgrade cleans up after every earlier one instead
# of adding to the pile. "NotchPill Dev.app" is spared — it is a separate app
# someone may be running on purpose, not a stale version of this one. The match
# is anchored to "NotchPill." or "NotchPill-" rather than a bare NotchPill*
# prefix, so an unrelated app that merely starts with those letters
# (NotchPillow.app) is not swept up with them.
shopt -s nullglob
for stale in /Applications/NotchPill.* /Applications/NotchPill-*; do
  [[ "$stale" == "$DEST" ]] && continue
  echo "Removing leftover $(basename "$stale")…"
  rm -rf "$stale"
done
shopt -u nullglob

# The release build is already validly signed; just clear quarantine so it can
# launch. We avoid re-signing so the code identity stays stable and macOS keeps
# any Accessibility/Calendar permissions. Re-sign only if the signature is broken.
xattr -cr "$DEST"
if ! codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  echo "Shipped signature invalid on this machine; re-signing ad-hoc…"
  FRAMEWORK="$DEST/Contents/Resources/MediaRemoteAdapter.framework"
  [[ -d "$FRAMEWORK" ]] && codesign --force --sign - "$FRAMEWORK" 2>/dev/null || true
  codesign --force --sign - "$DEST/Contents/MacOS/NotchPill" 2>/dev/null || true
  codesign --force --sign - "$DEST" 2>/dev/null || true
  xattr -cr "$DEST"
fi

echo "Launching NotchPill…"
open "$DEST"

osascript -e 'display notification "Look for the notch icon in your menu bar." with title "NotchPill installed"'

echo ""
echo "Done! Enable Launch at Login from the menu bar icon."
read -r -p "Press Enter to close…"
