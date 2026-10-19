#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-shareplay-session-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/BorgVRSharedConstants.swift" \
  "$ROOT/AppSupport/DatasetOriginCatalog.swift" \
  "$ROOT/Tests/SharePlaySessionEngineTestSupport.swift" \
  "$ROOT/AppSupport/BorgVRSharePlaySessionEngine.swift" \
  "$ROOT/Tests/SharePlaySessionEngineTests.swift" \
  -o "$BUILD_DIR/shareplay-session-tests"

"$BUILD_DIR/shareplay-session-tests"
