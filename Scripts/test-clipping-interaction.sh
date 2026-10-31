#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-clipping-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -parse-as-library -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/BORGVR-Render/ClippingInteraction.swift" "$ROOT/Tests/ClippingInteractionTests.swift" \
  -o "$BUILD_DIR/clipping-tests"
"$BUILD_DIR/clipping-tests"
