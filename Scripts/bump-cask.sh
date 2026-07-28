#!/usr/bin/env bash
# Update the Homebrew cask in shawngeorgie06/homebrew-tap to a released version.
# Usage: ./Scripts/bump-cask.sh 1.1.8
# Requires: gh (authenticated) and push access to the tap repo.
set -euo pipefail

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>  (e.g. 1.1.8)" >&2; exit 1; }
VERSION="${VERSION#v}"

ZIP_URL="https://github.com/shawngeorgie06/NotchPill/releases/download/v${VERSION}/NotchPill-${VERSION}-macOS-arm64.zip"

# The Release workflow REBUILDS the app on a runner and replaces the release
# asset. Hashing before it finishes pins the cask to a zip that no longer
# exists, and `brew install` then fails the checksum for everyone — which is
# exactly what happened for v1.7.1. So wait for the run to finish first.
if command -v gh >/dev/null 2>&1; then
  echo "==> Waiting for the Release workflow for v${VERSION}…"
  for _ in $(seq 1 60); do
    STATUS="$(gh run list --workflow Release --branch "v${VERSION}" --limit 1 \
                --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion)"' 2>/dev/null || true)"
    case "$STATUS" in
      completed:success) echo "    workflow finished"; break ;;
      completed:*)       echo "Release workflow did not succeed ($STATUS); not touching the cask." >&2; exit 1 ;;
      "" |*:*)           printf '.'; sleep 10 ;;
    esac
  done
  echo
else
  echo "!!  gh not found — cannot confirm the release build finished." >&2
  echo "!!  If CI is still running, this will pin the cask to a stale asset." >&2
fi

echo "==> Fetching $ZIP_URL to compute sha256…"
SHA="$(curl -fsSL "$ZIP_URL" | shasum -a 256 | awk '{print $1}')"

# Cross-check against the SHA256SUMS.txt published beside the zip. If they
# disagree, the asset was replaced mid-download — hashing again later is the fix,
# pushing a guess is not.
PUBLISHED="$(curl -fsSL "https://github.com/shawngeorgie06/NotchPill/releases/download/v${VERSION}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "$PUBLISHED" && "$PUBLISHED" != "$SHA" ]]; then
  echo "Asset hash ($SHA) disagrees with published SHA256SUMS ($PUBLISHED)." >&2
  echo "The release is probably mid-update; re-run in a minute." >&2
  exit 1
fi
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
