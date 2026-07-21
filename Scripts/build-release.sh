#!/bin/bash
# Builds a distributable NotchPill.app and packages it as a ZIP in dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building MediaRemote adapter…"
./Scripts/setup-vendor.sh

SIGN_IDENTITY="${NOTCHPILL_SIGN_IDENTITY:-${DEVELOPER_ID_SIGNING_IDENTITY:-}}"
XCODE_SIGN_ARGS=(
  CODE_SIGNING_ALLOWED=YES
)
if [[ -n "$SIGN_IDENTITY" ]]; then
  XCODE_SIGN_ARGS+=(
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"
    ENABLE_HARDENED_RUNTIME=YES
    CODE_SIGN_ENTITLEMENTS=NotchPill/NotchPill.entitlements
  )
else
  XCODE_SIGN_ARGS+=(
    CODE_SIGN_IDENTITY="-"
    ENABLE_HARDENED_RUNTIME=NO
  )
fi

echo "==> Building NotchPill (Release, arm64)…"
xcodebuild \
  -project NotchPill.xcodeproj \
  -scheme NotchPill \
  -configuration Release \
  -derivedDataPath build \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  "${XCODE_SIGN_ARGS[@]}" \
  build

APP="build/Build/Products/Release/NotchPill.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "==> Signing for distribution…"
./Scripts/sign-and-notarize.sh "$APP"

mkdir -p dist
STAGE="dist/NotchPill-${VERSION}-macOS-arm64"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp RELEASE_INSTALL.txt "$STAGE/READ ME FIRST.txt"
cp "Scripts/Install NotchPill.command" "$STAGE/Install NotchPill.command"
chmod +x "$STAGE/Install NotchPill.command"
ZIP="dist/NotchPill-${VERSION}-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$STAGE" "$ZIP"
shasum -a 256 "$ZIP" | tee dist/SHA256SUMS.txt

echo ""
echo "Done: $ZIP"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "Note: ad-hoc build — unzip and double-click Install NotchPill.command"
else
  echo "Ready to upload to GitHub Releases."
fi
