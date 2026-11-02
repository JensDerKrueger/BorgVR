#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-panel-parameter-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/AppSupport/Datasets/PanelParameterStorage.swift" \
  "$ROOT/Tests/PanelParameterStorageTests.swift" \
  -o "$BUILD_DIR/panel-parameter-tests"
"$BUILD_DIR/panel-parameter-tests"
