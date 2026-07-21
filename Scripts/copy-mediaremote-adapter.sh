#!/bin/bash
set -euo pipefail

FRAMEWORK_SRC="${SRCROOT}/Vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework"
SCRIPT_SRC="${SRCROOT}/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl"
DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources"

if [[ ! -d "$FRAMEWORK_SRC" ]]; then
  echo "error: MediaRemoteAdapter.framework not found at $FRAMEWORK_SRC" >&2
  echo "Run: cd Vendor/mediaremote-adapter && mkdir -p build && cd build && cmake .. && cmake --build ." >&2
  exit 1
fi

mkdir -p "$DEST"
rm -rf "$DEST/MediaRemoteAdapter.framework"
cp -R "$FRAMEWORK_SRC" "$DEST/"
cp "$SCRIPT_SRC" "$DEST/mediaremote-adapter.pl"
