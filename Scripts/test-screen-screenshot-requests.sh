#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-screen-screenshot-request-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/AppSupport/Automation/ScreenScreenshotRequestQueue.swift" \
  "$ROOT/Tests/ScreenScreenshotRequestQueueTests.swift" \
  -o "$BUILD_DIR/screen-screenshot-request-tests"

"$BUILD_DIR/screen-screenshot-request-tests"
