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
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/macOSApp/MacKeyboardShortcuts.swift" \
  "$ROOT/macOSApp/DockingController.swift" \
  "$ROOT/macOSApp/PanelWindow.swift" \
  "$ROOT/macOSApp/NativePanelToolbar.swift" \
  "$ROOT/Tests/NativePanelToolbarTests.swift" \
  -o "$BUILD_DIR/native-toolbar-tests"
"$BUILD_DIR/native-toolbar-tests"
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/macOSApp/MacKeyboardShortcuts.swift" \
  "$ROOT/macOSApp/DockingController.swift" \
  "$ROOT/macOSApp/PanelWindow.swift" \
  "$ROOT/AppSupport/UI/FractionProgressLine.swift" \
  "$ROOT/macOSApp/NativePanelToolbar.swift" \
  "$ROOT/macOSApp/DockablePanelViews.swift" \
  "$ROOT/Tests/DockablePanelCanvasTests.swift" \
  -o "$BUILD_DIR/panel-canvas-tests"
"$BUILD_DIR/panel-canvas-tests"
