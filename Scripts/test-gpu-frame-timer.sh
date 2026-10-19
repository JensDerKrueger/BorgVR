#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-gpu-frame-timer-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

xcrun swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Logger.swift" \
  "$ROOT/BORGVR-Render/Helpers/RingBuffer.swift" \
  "$ROOT/BORGVR-Render/Performance Tracking/FrameTimerProtocol.swift" \
  "$ROOT/BORGVR-Render/Performance Tracking/GPUFrameTimer.swift" \
  "$ROOT/Tests/GPUFrameTimerTests.swift" \
  -o "$BUILD_DIR/gpu-frame-timer-tests"

"$BUILD_DIR/gpu-frame-timer-tests"
