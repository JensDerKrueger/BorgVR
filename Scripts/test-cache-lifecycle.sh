#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-cache-lifecycle-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Remote/CacheMap.swift" \
  "$ROOT/BORGVR-IO/Remote/CachingRemoteLifecycle.swift" \
  "$ROOT/Tests/CacheMapLifecycleTests.swift" \
  -o "$BUILD_DIR/cache-lifecycle-tests"

"$BUILD_DIR/cache-lifecycle-tests"
