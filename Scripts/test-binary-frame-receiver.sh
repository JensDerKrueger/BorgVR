#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-binary-frame-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Remote/BorgVRBinaryFrameReceiver.swift" \
  "$ROOT/Tests/BinaryFrameReceiverTests.swift" \
  -o "$BUILD_DIR/binary-frame-tests"

"$BUILD_DIR/binary-frame-tests"
