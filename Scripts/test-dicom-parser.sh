#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-dicom-parser-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/DICOMVRMap.swift" \
  "$ROOT/Tests/DICOMParserTestSupport.swift" \
  "$ROOT/BORGVR-IO/DICOM.swift" \
  "$ROOT/Tests/DICOMParserTests.swift" \
  -o "$BUILD_DIR/dicom-parser-tests"

"$BUILD_DIR/dicom-parser-tests"
