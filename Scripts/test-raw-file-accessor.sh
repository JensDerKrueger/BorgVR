#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-raw-file-accessor-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/VolumeDataAccessing.swift" \
  "$ROOT/BORGVR-IO/VolumeDataAccessor.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/BORGVR-IO/RawFileAccessor.swift" \
  "$ROOT/Tests/RawFileAccessorTests.swift" \
  -o "$BUILD_DIR/raw-file-accessor-tests"

"$BUILD_DIR/raw-file-accessor-tests"
