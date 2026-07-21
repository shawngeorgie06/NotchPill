#!/usr/bin/env bash
# Create a stable, non-expiring self-signed code-signing certificate for
# NotchPill — a FREE alternative to a paid Apple Developer ID cert.
#
# Why: pure ad-hoc signing (`codesign -s -`) produces a *different* code
# identity on every build, and macOS ties Accessibility/Calendar (TCC)
# permission grants to the code signature. So each update silently drops those
# grants and hover shortcuts break. Signing every release with ONE stable
# self-signed cert keeps the identity constant, so permissions persist.
#
# This does NOT make the app notarized — Gatekeeper still flags it once, which
# the Homebrew cask / installer handle by stripping the quarantine flag. It only
# fixes identity stability.
#
# Run once. It:
#   1. generates the cert + private key,
#   2. imports & trusts it in your login keychain (so local builds can sign),
#   3. exports a .p12 and prints the base64 + values to paste into GitHub
#      repository secrets so CI release builds sign with the same identity.
set -euo pipefail

IDENTITY_NAME="${NOTCHPILL_CERT_NAME:-NotchPill Self-Signed}"
OUT_DIR="${1:-$HOME/.notchpill-signing}"
DAYS=3650
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
cd "$OUT_DIR"

if security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
  echo "==> A valid '$IDENTITY_NAME' identity already exists in your keychain."
  echo "    Delete it first if you want to regenerate:"
  echo "      security delete-identity -c \"$IDENTITY_NAME\""
  echo "    Or reuse the existing .p12 in $OUT_DIR for CI secrets."
  exit 0
fi

# Random password protects the exported .p12 (also becomes a CI secret).
P12_PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

echo "==> Generating self-signed code-signing certificate ($DAYS days)…"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days "$DAYS" -nodes \
  -subj "/CN=$IDENTITY_NAME/O=NotchPill" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null

openssl pkcs12 -export -inkey key.pem -in cert.pem \
  -out NotchPillSigning.p12 -passout "pass:$P12_PASS" -name "$IDENTITY_NAME" 2>/dev/null

echo "==> Importing into your login keychain and trusting for code signing…"
echo "    (macOS may prompt for your login password to update trust settings.)"
security import NotchPillSigning.p12 -k "$LOGIN_KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign -A
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" cert.pem

echo ""
echo "==> Verifying the identity is usable for signing:"
security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || {
  echo "ERROR: identity not valid after import. Check the prompts above." >&2
  exit 1
}

B64="$(base64 -i NotchPillSigning.p12)"

cat <<EOF

============================================================================
 DONE. Local builds can now sign with: "$IDENTITY_NAME"
 (Scripts/build-release.sh picks it up automatically — see the note below.)
============================================================================

To sign RELEASE builds in GitHub Actions the same way, add these repository
secrets at:
  https://github.com/shawngeorgie06/NotchPill/settings/secrets/actions

  Secret name                     Value
  ------------------------------  ----------------------------------------
  NOTCHPILL_SIGN_IDENTITY         $IDENTITY_NAME
  APPLE_CERTIFICATE_PASSWORD      $P12_PASS
  APPLE_CERTIFICATE_P12           (the base64 block below — paste all of it)

APPLE_CERTIFICATE_P12 value:
----------------------------------------------------------------------------
$B64
----------------------------------------------------------------------------

For LOCAL signed builds, run:
  NOTCHPILL_SIGN_IDENTITY="$IDENTITY_NAME" ./Scripts/build-release.sh

Files are in: $OUT_DIR  (keep NotchPillSigning.p12 private; never commit it)
EOF
