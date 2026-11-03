#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-screen-projection-tests"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT/AppSupport/Rendering/MatrixUtilities.swift" \
  "$ROOT/Tests/ScreenProjectionTests.swift" -o "$BUILD_DIR/projection-tests"
"$BUILD_DIR/projection-tests"
