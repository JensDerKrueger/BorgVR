#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS=${1:?Usage: test-dataset-first-frame.sh <macOS Debug products directory>}
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

# Exercise the actual app model, including its request identity guards.
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/modules" -I "$PRODUCTS" \
  "$ROOT/Tests/DatasetFirstFrameTests.swift" \
  "$PRODUCTS/BorgVR.app/Contents/MacOS/BorgVR.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/BorgVR.app/Contents/MacOS" \
  -o "$TEMP/first-frame-tests"
"$TEMP/first-frame-tests"
