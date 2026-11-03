#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-atlas-paging-history-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"

swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/BORGVR-Render/Helpers/RingBuffer.swift" \
  "$ROOT/BORGVR-Render/Performance Tracking/AtlasPagingHistory.swift" \
  "$ROOT/Tests/AtlasPagingHistoryTests.swift" \
  -o "$BUILD_DIR/atlas-paging-history-tests"

"$BUILD_DIR/atlas-paging-history-tests"
