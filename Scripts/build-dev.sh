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

# Use the kernel's executable path, never argv/process names or System Events.
# Include start time in snapshots so a reused PID is not signaled.
dev_processes() {
  local scope="${1:-all}"
  local table pid weekday month day clock year executable bundle identifier
  table="$(/bin/ps -ww -axo pid=,lstart=,comm=)" || {
    echo "!! Cannot inspect processes; refusing to replace the dev app." >&2
    return 1
  }
  while read -r pid weekday month day clock year executable; do
    case "$executable" in
      "$DEST/Contents/MacOS/NotchPill"|"$ROOT"/build-dev/*.app/Contents/MacOS/NotchPill|"$ROOT"/build/*.app/Contents/MacOS/NotchPill) ;;
      *) continue ;;
    esac
    if [[ "$scope" == "prebuild" ]]; then
      case "$executable" in
        "$ROOT/build-dev/Build/Products/Debug/NotchPill.app/Contents/MacOS/NotchPill"|"$ROOT"/build-dev/stage/*.app/Contents/MacOS/NotchPill) ;;
        *) continue ;;
      esac
    fi
    bundle="${executable%/Contents/MacOS/NotchPill}"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null)" || {
      echo "!! Cannot verify candidate dev bundle: $bundle" >&2
      return 1
    }
    [[ "$identifier" == "$DEV_BUNDLE_ID" ]] || continue
    printf '%s %s %s %s %s %s %s\n' "$pid" "$weekday" "$month" "$day" "$clock" "$year" "$executable"
  done <<< "$table"
}

quit_dev() {
  local scope="${1:-all}"
  local original current entry pid attempt signal
  original="$(dev_processes "$scope")" || return 1
  [[ -n "$original" ]] || return 0
  for signal in TERM KILL; do
    while IFS= read -r entry; do
      # Revalidate executable, bundle identity and process start time immediately
      # before each signal. Never escalate against an unverified/reused PID.
      current="$(dev_processes "$scope")" || return 1
      if /usr/bin/grep -Fxq -- "$entry" <<< "$current"; then
        pid="${entry%% *}"
        /bin/kill -"$signal" "$pid" 2>/dev/null || true
      fi
    done <<< "$original"
    for ((attempt=0; attempt<20; attempt++)); do
      current="$(dev_processes "$scope")" || return 1
      [[ -n "$current" ]] || return 0
      /bin/sleep 0.25
    done
  done
  echo "!! Dev app is still running; refusing to replace its bundle." >&2
  return 1
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

# Stop source/staged dev builds before xcodebuild or staging overwrites them.
quit_dev prebuild

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
  ENABLE_DEBUG_DYLIB=NO \
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
