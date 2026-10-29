#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-volume-traversal-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"

swiftc -parse-as-library \
  -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/Tests/VolumeTraversalTests.swift" \
  -o "$BUILD_DIR/volume-traversal-tests"

"$BUILD_DIR/volume-traversal-tests"
