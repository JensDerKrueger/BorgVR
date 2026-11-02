#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-mac-panel-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/macOSApp/DockingController.swift" \
  "$ROOT/macOSApp/PanelWindow.swift" \
  "$ROOT/Tests/DockingControllerTests.swift" \
  -o "$BUILD_DIR/mac-panel-tests"
"$BUILD_DIR/mac-panel-tests"
