#!/bin/bash
# Clones and builds the MediaRemote adapter required on macOS 15.4+.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/mediaremote-adapter"
REPO="https://github.com/ungive/mediaremote-adapter.git"

if [[ ! -d "$VENDOR/.git" ]]; then
  echo "Cloning mediaremote-adapter into Vendor/…"
  mkdir -p "$(dirname "$VENDOR")"
  git clone --depth 1 "$REPO" "$VENDOR"
fi

echo "Building MediaRemoteAdapter.framework…"
mkdir -p "$VENDOR/build"
(
  cd "$VENDOR/build"
  cmake ..
  cmake --build .
)

echo "Done. Open NotchPill.xcodeproj and build (⌘R)."
