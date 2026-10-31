#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-subbrick-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -parse-as-library -module-cache-path "$BUILD_DIR/swift-module-cache" \
  -import-objc-header "$ROOT/AppSupport/Rendering/Shaders/ShaderTypes.h" \
  "$ROOT/BORGVR-IO/Vector.swift" "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BorgVRSharedConstants.swift" \
  "$ROOT/BORGVR-Render/Transfer Function 1D/TransferFunction1D.swift" \
  "$ROOT/BORGVR-Render/VolumeAtlas/VolumeAtlasSubbrickCache.swift" \
  "$ROOT/Tests/VolumeSubbrickTests.swift" -o "$BUILD_DIR/subbrick-tests"
"$BUILD_DIR/subbrick-tests"
