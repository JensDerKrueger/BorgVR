#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS=${1:?Usage: test-dataset-lifecycle.sh <macOS Debug products directory>}
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT

xcrun swiftc -parse-as-library -module-cache-path "$TEMP/modules" -I "$PRODUCTS" \
  "$ROOT/Tests/DatasetLifecycleTests.swift" \
  "$PRODUCTS/BorgVR.app/Contents/MacOS/BorgVR.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/BorgVR.app/Contents/MacOS" \
  -o "$TEMP/lifecycle-tests"
"$TEMP/lifecycle-tests" "$ROOT/c60_32.data"
