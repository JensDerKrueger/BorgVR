#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-file-export-recovery-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/AppSupport/Annotations/CoordinatedFileExportRecovery.swift" \
  "$ROOT/Tests/FileExportRecoveryTests.swift" \
  -o "$BUILD_DIR/file-export-recovery-tests"
"$BUILD_DIR/file-export-recovery-tests"
