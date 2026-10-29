#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-vision-reprojection-depth-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"

swiftc \
  -parse-as-library \
  -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/Tests/VisionReprojectionDepthTests.swift" \
  -o "$BUILD_DIR/vision-reprojection-depth-tests"

"$BUILD_DIR/vision-reprojection-depth-tests"
