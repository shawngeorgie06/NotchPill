#!/bin/bash
# Builds "NotchPill Dev.app" — a side-by-side build for testing changes without
# touching the copy you actually use.
#
# It differs from the release build in exactly two ways that matter:
#
#   * bundle id  com.local.notchpill.dev   (not …notchpill)
#   * app name   NotchPill Dev.app
#
# The bundle id is the whole point. macOS keys the Accessibility (TCC) grant on
# it, so the dev build asks for its own permission and cannot disturb the grant
# on your installed NotchPill. Both can run at once — quit the release one first
# unless you want two pills fighting over the same notch.
#
# Signed with the same stable self-signed identity for the same reason the
# release is: ad-hoc signing changes identity on every build, and macOS silently
# drops the Accessibility grant each time.
#
# Usage:
#   ./Scripts/build-dev.sh              # build + install to /Applications
#   ./Scripts/build-dev.sh --no-install # just build
#   ./Scripts/build-dev.sh --uninstall  # remove the dev build entirely
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEV_BUNDLE_ID="com.local.notchpill.dev"
DEV_NAME="NotchPill Dev"
DEST="/Applications/${DEV_NAME}.app"

# The executable inside the bundle is still called `NotchPill`, so matching on
# the process name would hit the installed release too — or, with -x, nothing at
# all. Match the bundle path instead: it is the only thing that tells the two
# apart in `ps`.
quit_dev() {
  pkill -f "${DEST}/Contents/MacOS/" 2>/dev/null || true
  sleep 1
}

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> Removing ${DEST}…"
  quit_dev
  rm -rf "$DEST"
  defaults delete "$DEV_BUNDLE_ID" 2>/dev/null || true
  echo "Removed. Your installed NotchPill is untouched."
  echo "Note: macOS keeps the stale Accessibility entry — remove '${DEV_NAME}'"
  echo "under System Settings → Privacy & Security → Accessibility by hand."
  exit 0
fi

echo "==> Building MediaRemote adapter…"
./Scripts/setup-vendor.sh

SIGN_IDENTITY="${NOTCHPILL_SIGN_IDENTITY:-NotchPill Self-Signed}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "!! Signing identity '$SIGN_IDENTITY' not found."
  echo "   Falling back to ad-hoc — macOS will drop the dev build's"
  echo "   Accessibility grant on every rebuild. See docs/NOTARIZATION.md."
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
else
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    CODE_SIGN_STYLE=Manual
    ENABLE_HARDENED_RUNTIME=YES
    CODE_SIGN_ENTITLEMENTS=NotchPill/NotchPill.entitlements
  )
fi

echo "==> Building ${DEV_NAME} (Debug, arm64)…"
xcodebuild \
  -project NotchPill.xcodeproj \
  -scheme NotchPill \
  -configuration Debug \
  -derivedDataPath build-dev \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=YES \
  PRODUCT_BUNDLE_IDENTIFIER="$DEV_BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=YES \
  "${SIGN_ARGS[@]}" \
  build >/dev/null

BUILT="build-dev/Build/Products/Debug/NotchPill.app"
[[ -d "$BUILT" ]] || { echo "!! Build produced no app at $BUILT"; exit 1; }

STAGE="build-dev/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$BUILT" "$STAGE/${DEV_NAME}.app"
APP="$STAGE/${DEV_NAME}.app"

# Rename the visible app too, so the menu bar and Force Quit list say which one
# you are looking at. CFBundleName drives both.
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${DEV_NAME}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${DEV_NAME}" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${DEV_NAME}" "$APP/Contents/Info.plist"

# Re-sign after editing Info.plist — any edit invalidates the signature, and an
# invalidly signed app is refused outright rather than merely warned about.
codesign --force --deep --options runtime \
  --entitlements NotchPill/NotchPill.entitlements \
  --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"

echo "==> Verifying…"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^Identifier|^Authority" || true

if [[ "${1:-}" == "--no-install" ]]; then
  echo
  echo "Built: $APP"
  exit 0
fi

echo "==> Installing to ${DEST}…"
quit_dev
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open -a "$DEST"

echo
echo "Running: ${DEV_NAME}"
echo "Your installed NotchPill is untouched (different bundle id)."
echo "Grant Accessibility to '${DEV_NAME}' separately if you need hover shortcuts."
echo "Remove it later with: ./Scripts/build-dev.sh --uninstall"
