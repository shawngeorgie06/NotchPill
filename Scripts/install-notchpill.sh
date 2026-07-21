#!/usr/bin/env bash
# One-line install (paste in Terminal — bypasses Finder Gatekeeper):
#   curl -fsSL https://raw.githubusercontent.com/shawngeorgie06/NotchPill/main/Scripts/install-notchpill.sh | bash
set -euo pipefail

REPO="shawngeorgie06/NotchPill"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading latest NotchPill release…"
ZIP_URL="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for asset in data.get('assets', []):
    name = asset.get('name', '')
    if name.endswith('macOS-arm64.zip'):
        print(asset['browser_download_url'])
        break
")"
[[ -n "$ZIP_URL" ]] || { echo "Could not find release ZIP." >&2; exit 1; }

curl -fsSL -o "$TMP/NotchPill.zip" "$ZIP_URL"
unzip -q "$TMP/NotchPill.zip" -d "$TMP"

STAGE="$(find "$TMP" -maxdepth 1 -type d -name 'NotchPill-*-macOS-arm64' | head -1)"
APP="$STAGE/NotchPill.app"
DEST="/Applications/NotchPill.app"

[[ -d "$APP" ]] || { echo "NotchPill.app missing in ZIP." >&2; exit 1; }

echo "==> Installing to Applications…"
pkill -x NotchPill 2>/dev/null || true
xattr -cr "$STAGE"
rm -rf "$DEST"
ditto "$APP" "$DEST"

# Strip the Gatekeeper quarantine flag so the app launches. The release build
# already carries a valid signature (self-signed or ad-hoc), so we do NOT
# re-sign here — re-signing would change the code identity and macOS would drop
# any Accessibility/Calendar permissions the user has granted. Only re-sign as a
# last resort if the shipped signature is somehow broken on this machine.
xattr -cr "$DEST"
if ! codesign --verify --deep --strict "$DEST" 2>/dev/null; then
  echo "==> Shipped signature invalid on this machine; re-signing ad-hoc…"
  FRAMEWORK="$DEST/Contents/Resources/MediaRemoteAdapter.framework"
  [[ -d "$FRAMEWORK" ]] && codesign --force --sign - "$FRAMEWORK" 2>/dev/null || true
  codesign --force --sign - "$DEST/Contents/MacOS/NotchPill" 2>/dev/null || true
  codesign --force --sign - "$DEST" 2>/dev/null || true
  xattr -cr "$DEST"
fi

echo "==> Launching NotchPill…"
open "$DEST"

echo ""
echo "Done! Look for the notch icon in your menu bar (top right)."
echo "Enable Launch at Login from the menu bar icon."
