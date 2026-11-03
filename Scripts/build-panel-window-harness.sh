#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-panel-window-harness"
APP="$BUILD_DIR/BorgVR Panel Test.app"
mkdir -p "$APP/Contents/MacOS" "$BUILD_DIR/swift-module-cache"
swiftc -target "$(uname -m)-apple-macosx15.2" -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/macOSApp/MacKeyboardShortcuts.swift" \
  "$ROOT/macOSApp/DockingController.swift" \
  "$ROOT/macOSApp/PanelWindow.swift" \
  "$ROOT/macOSApp/NativePanelToolbar.swift" \
  "$ROOT/macOSApp/DockablePanelViews.swift" \
  "$ROOT/Tests/PanelWindowHarness.swift" \
  -o "$APP/Contents/MacOS/PanelWindowHarness"
cp "$ROOT/Tests/PanelWindowHarness-Info.plist" "$APP/Contents/Info.plist"
printf '%s\n' "$APP"
