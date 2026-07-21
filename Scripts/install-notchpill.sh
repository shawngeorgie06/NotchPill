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

# Re-sign after copy so macOS accepts the app bundle.
FRAMEWORK="$DEST/Contents/Resources/MediaRemoteAdapter.framework"
if [[ -d "$FRAMEWORK" ]]; then
  codesign --force --sign - "$FRAMEWORK" 2>/dev/null || true
fi
codesign --force --sign - "$DEST/Contents/MacOS/NotchPill"
codesign --force --sign - "$DEST"
xattr -cr "$DEST"

echo "==> Launching NotchPill…"
open "$DEST"

echo ""
echo "Done! Look for the notch icon in your menu bar (top right)."
echo "Enable Launch at Login from the menu bar icon."
