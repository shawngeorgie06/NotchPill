#!/bin/bash
# Builds a distributable NotchPill.app and packages it as a ZIP in dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building MediaRemote adapter…"
./Scripts/setup-vendor.sh

echo "==> Building NotchPill (Release, arm64)…"
xcodebuild \
  -project NotchPill.xcodeproj \
  -scheme NotchPill \
  -configuration Release \
  -derivedDataPath build \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="build/Build/Products/Release/NotchPill.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "==> Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

mkdir -p dist
ZIP="dist/NotchPill-${VERSION}-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee dist/SHA256SUMS.txt

echo ""
echo "Done: $ZIP"
echo "Share this ZIP or upload it to GitHub Releases."
