#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-volume-atlas-edit-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"

swiftc \
  -module-cache-path "$BUILD_DIR/swift-module-cache" \
  -import-objc-header "$ROOT/AppSupport/Rendering/Shaders/ShaderTypes.h" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/Logger.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BorgVRSharedConstants.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditMask.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeOriginalBrick.swift" \
  "$ROOT/BORGVR-IO/BorgVRCPUVolumeEditExecutor.swift" \
  "$ROOT/BORGVR-Render/Helpers/AlignedBuffer.swift" \
  "$ROOT/BORGVR-Render/Transfer Function 1D/TransferFunction1D.swift" \
  "$ROOT/BORGVR-Render/VolumeAtlas/AsyncEmptinessUpdater.swift" \
  "$ROOT/BORGVR-Render/VolumeAtlas/VolumeAtlas.swift" \
  "$ROOT/BORGVR-Render/VolumeAtlas/VolumeAtlasBrushRenderer.swift" \
  "$ROOT/Tests/VolumeAtlasEditTests.swift" \
  -o "$BUILD_DIR/volume-atlas-edit-tests"

"$BUILD_DIR/volume-atlas-edit-tests"
