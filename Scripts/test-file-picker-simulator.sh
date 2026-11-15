#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-file-picker-tests"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
DEVICE="${1:?Usage: test-file-picker-simulator.sh <booted iOS simulator ID>}"
mkdir -p "$BUILD_DIR/modules"
xcrun --sdk iphonesimulator swiftc -parse-as-library -sdk "$SDK" \
  -target "$(uname -m)-apple-ios18.0-simulator" -module-cache-path "$BUILD_DIR/modules" \
  "$ROOT/BORGVR-IO/Importers/BorgVRImportFileAccess.swift" \
  "$ROOT/AppSupport/UI/FilePickerView.swift" \
  "$ROOT/Tests/FilePickerSimulatorTests.swift" -o "$BUILD_DIR/file-picker-tests"
xcrun simctl spawn "$DEVICE" "$BUILD_DIR/file-picker-tests"
