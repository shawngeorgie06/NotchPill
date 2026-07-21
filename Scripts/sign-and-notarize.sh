#!/usr/bin/env bash
# Sign (and optionally notarize) a built NotchPill.app for distribution.
#
# Ad-hoc (local only, Gatekeeper blocks downloads):
#   ./Scripts/sign-and-notarize.sh path/to/NotchPill.app
#
# Developer ID + notarization (opens normally after download):
#   export NOTCHPILL_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export NOTCHPILL_NOTARY_KEYCHAIN_PROFILE="notchpill-notary"
#   ./Scripts/sign-and-notarize.sh path/to/NotchPill.app
#
# Or use Apple ID credentials instead of a keychain profile:
#   export APPLE_ID="you@example.com"
#   export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
#   export APPLE_TEAM_ID="TEAMID"

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 path/to/NotchPill.app" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="${ROOT}/NotchPill/NotchPill.entitlements"
IDENTITY="${NOTCHPILL_SIGN_IDENTITY:-${DEVELOPER_ID_SIGNING_IDENTITY:-}}"
NOTARY_PROFILE="${NOTCHPILL_NOTARY_KEYCHAIN_PROFILE:-}"

sign_ad_hoc() {
  echo "==> Ad-hoc signing (downloads will be blocked by Gatekeeper)…"
  codesign --force --sign - "$APP"
}

sign_developer_id() {
  echo "==> Developer ID signing with: $IDENTITY"

  local framework="${APP}/Contents/Resources/MediaRemoteAdapter.framework"
  if [[ -d "$framework" ]]; then
    echo "    signing MediaRemoteAdapter.framework"
    codesign --force --options runtime --timestamp \
      --sign "$IDENTITY" "$framework"
  fi

  local binary="${APP}/Contents/MacOS/NotchPill"
  echo "    signing NotchPill binary"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$binary"

  echo "    signing app bundle"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

  codesign --verify --deep --strict --verbose=2 "$APP"
  spctl -a -t exec -vv "$APP" || true
}

notarize() {
  local zip
  zip="$(mktemp -t notchpill-notarize).zip"
  trap 'rm -f "$zip"' RETURN

  echo "==> Submitting to Apple notary service…"
  ditto -c -k --keepParent "$APP" "$zip"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    xcrun notarytool submit "$zip" \
      --apple-id "$APPLE_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  else
    echo "warning: signed but not notarized — set NOTCHPILL_NOTARY_KEYCHAIN_PROFILE or APPLE_ID credentials" >&2
    return 0
  fi

  echo "==> Stapling notarization ticket…"
  xcrun stapler staple "$APP"
  spctl -a -t exec -vv "$APP"
}

if [[ -z "$IDENTITY" ]]; then
  sign_ad_hoc
  echo ""
  echo "Tip: export NOTCHPILL_SIGN_IDENTITY=\"Developer ID Application: …\" for a distributable build."
  exit 0
fi

sign_developer_id
notarize

echo ""
echo "Signed and notarized: $APP"
