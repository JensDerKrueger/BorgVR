#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS=${1:?Usage: test-mcp-visualization.sh <macOS Debug products directory>}
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/modules" -I "$PRODUCTS" \
  "$ROOT/Tests/MCPVisualizationTests.swift" \
  "$PRODUCTS/BorgVR.app/Contents/MacOS/BorgVR.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/BorgVR.app/Contents/MacOS" \
  -o "$TEMP/mcp-tests"
"$TEMP/mcp-tests" "$ROOT/c60_32.data"
