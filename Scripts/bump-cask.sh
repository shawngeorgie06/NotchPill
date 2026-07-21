#!/usr/bin/env bash
# Update the Homebrew cask in shawngeorgie06/homebrew-tap to a released version.
# Usage: ./Scripts/bump-cask.sh 1.1.8
# Requires: gh (authenticated) and push access to the tap repo.
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>  (e.g. 1.1.8)" >&2; exit 1; }
VERSION="${VERSION#v}"

ZIP_URL="https://github.com/shawngeorgie06/NotchPill/releases/download/v${VERSION}/NotchPill-${VERSION}-macOS-arm64.zip"
echo "==> Fetching $ZIP_URL to compute sha256…"
SHA="$(curl -fsSL "$ZIP_URL" | shasum -a 256 | awk '{print $1}')"
[[ -n "$SHA" ]] || { echo "Could not download release asset for v$VERSION." >&2; exit 1; }
echo "    sha256 = $SHA"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gh repo clone shawngeorgie06/homebrew-tap "$TMP/tap" -- --depth 1 >/dev/null 2>&1
CASK="$TMP/tap/Casks/notchpill.rb"
/usr/bin/sed -i '' -E "s/^  version \"[^\"]*\"/  version \"${VERSION}\"/" "$CASK"
/usr/bin/sed -i '' -E "s/^  sha256 \"[^\"]*\"/  sha256 \"${SHA}\"/" "$CASK"

cd "$TMP/tap"
if git diff --quiet; then
  echo "Cask already at v$VERSION."
  exit 0
fi
git commit -am "notchpill ${VERSION}"
git push origin HEAD:main
echo "==> Cask updated to v$VERSION. Users get it via: brew upgrade --cask notchpill"
