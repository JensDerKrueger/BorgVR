#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-tf-ray-specialization-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -parse-as-library -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/Tests/TFRaySpecializationTests.swift" -o "$BUILD_DIR/tf-ray-specialization-tests"
"$BUILD_DIR/tf-ray-specialization-tests"
