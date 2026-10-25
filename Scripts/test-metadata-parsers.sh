#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-metadata-parser-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/BORGVR-IO/BORGVRFileData.swift" \
  "$ROOT/Tests/BORGVRMetaDataParserTests.swift" \
  -o "$BUILD_DIR/swift-metadata-parser-tests"
"$BUILD_DIR/swift-metadata-parser-tests" "$BUILD_DIR/valid-metadata.bin"

"${CXX:-c++}" \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Wpedantic \
  -I"$ROOT/BORGVRServerCPP/include" \
  "$ROOT/BORGVRServerCPP/src/BORGVRMetaData.cpp" \
  "$ROOT/Tests/BORGVRMetaDataParserTests.cpp" \
  -o "$BUILD_DIR/cpp-metadata-parser-tests"
"$BUILD_DIR/cpp-metadata-parser-tests" "$BUILD_DIR/valid-metadata.bin"
