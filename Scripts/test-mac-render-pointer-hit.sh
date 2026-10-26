#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-mac-render-pointer-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/macOSApp/MacRenderPointerHitTest.swift" \
  "$ROOT/Tests/MacRenderPointerHitTestTests.swift" \
  -o "$BUILD_DIR/mac-render-pointer-tests"
"$BUILD_DIR/mac-render-pointer-tests"
