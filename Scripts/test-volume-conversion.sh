#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-volume-conversion-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/Logger.swift" \
  "$ROOT/BORGVR-IO/VolumeDataAccessing.swift" \
  "$ROOT/BORGVR-IO/VolumeDataAccessor.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/BORGVR-IO/RawFileAccessor.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BrickedVolumeReorganizer.swift" \
  "$ROOT/Tests/VolumeConversionServiceTestSupport.swift" \
  "$ROOT/BORGVR-IO/BorgVRDICOMRigidRegistration.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeConversionService.swift" \
  "$ROOT/Tests/VolumeConversionServiceTests.swift" \
  -o "$BUILD_DIR/volume-conversion-tests"

"$BUILD_DIR/volume-conversion-tests"
