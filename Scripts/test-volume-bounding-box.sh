#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-bounding-box-tests"
mkdir -p "$BUILD_DIR"
swiftc -parse-as-library -module-cache-path "$BUILD_DIR/module-cache" \
  -import-objc-header "$ROOT/AppSupport/Rendering/Shaders/ShaderTypes.h" \
  "$ROOT/BORGVR-Render/Helpers/Tesselation.swift" \
  "$ROOT/AppSupport/Rendering/VolumeBoundingBoxRenderer.swift" \
  "$ROOT/Tests/VolumeBoundingBoxTests.swift" -o "$BUILD_DIR/bounding-box-tests"
"$BUILD_DIR/bounding-box-tests"
