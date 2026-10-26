#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-transfer-function-editor-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"

swiftc \
  -swift-version 5 \
  -module-cache-path "$BUILD_DIR/swift-module-cache" \
  -import-objc-header "$ROOT/AppSupport/Rendering/Shaders/ShaderTypes.h" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BorgVRSharedConstants.swift" \
  "$ROOT/BORGVR-Render/Transfer Function 1D/TransferFunction1D.swift" \
  "$ROOT/BORGVR-Render/Transfer Function 1D/TransferFunction1DUI.swift" \
  "$ROOT/AppSupport/Rendering/TransferFunctionEditorView.swift" \
  "$ROOT/Tests/TransferFunctionEditorTests.swift" \
  -o "$BUILD_DIR/transfer-function-editor-tests"

if ! OS_ACTIVITY_DT_MODE=YES "$BUILD_DIR/transfer-function-editor-tests" > "$BUILD_DIR/runtime.log" 2>&1; then
  cat "$BUILD_DIR/runtime.log"
  exit 1
fi
if grep -Eq 'Publishing changes from within view updates|Modifying state during view update' "$BUILD_DIR/runtime.log"; then
  cat "$BUILD_DIR/runtime.log"
  exit 1
fi
printf 'macOS TF editor: channel selection and runtime diagnostics passed\n'
