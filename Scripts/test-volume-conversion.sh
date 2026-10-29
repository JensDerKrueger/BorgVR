#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-volume-conversion-tests"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"

mkdir -p "$BUILD_DIR" "$SWIFT_MODULE_CACHE"

swiftc \
  "${BORGVR_EDIT_TEST_OPTIMIZATION:--Onone}" \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/VolumeFileParser.swift" \
  "$ROOT/BORGVR-IO/QVISParser.swift" \
  "$ROOT/BORGVR-IO/NRRDParser.swift" \
  "$ROOT/BORGVR-IO/PVMParser.swift" \
  "$ROOT/BORGVR-IO/I3MParser.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/Logger.swift" \
  "$ROOT/BORGVR-IO/VolumeDataAccessing.swift" \
  "$ROOT/BORGVR-IO/VolumeDataAccessor.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/BORGVR-IO/RawFileAccessor.swift" \
  "$ROOT/BORGVR-IO/BorgVRIntegerVolumeSampler.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BORGVRFileData.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditMask.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeOriginalBrick.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditStates.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditDataSource.swift" \
  "$ROOT/BORGVR-IO/BorgVRCPUVolumeEditExecutor.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditMaterializer.swift" \
  "$ROOT/BORGVR-IO/BorgVRMetalVolumeEditProcessor.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditJournal.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeEditBrickCache.swift" \
  "$ROOT/BORGVR-IO/BorgVREditableVolumeData.swift" \
  "$ROOT/BORGVR-IO/BorgVRMarchingCubes33.swift" \
  "$ROOT/BORGVR-IO/BorgVRMetalIsoSurfaceClassifier.swift" \
  "$ROOT/BORGVR-IO/BorgVRIsoSurfaceExtractor.swift" \
  "$ROOT/BORGVR-IO/BrickedVolumeReorganizer.swift" \
  "$ROOT/Tests/VolumeConversionServiceTestSupport.swift" \
  "$ROOT/BORGVR-IO/BorgVRDICOMRigidRegistration.swift" \
  "$ROOT/BORGVR-IO/BorgVRVolumeConversionService.swift" \
  "$ROOT/AppSupport/Automation/VolumeEditingCommands.swift" \
  "$ROOT/AppSupport/Rendering/VolumeBrushModel.swift" \
  "$ROOT/AppSupport/SharePlay/BorgVRVolumeEditCollaboration.swift" \
  "$ROOT/Tests/VolumeEditingAutomationTestSupport.swift" \
  "$ROOT/Tests/VolumeEditingAutomationTests.swift" \
  "$ROOT/Tests/VolumeEditCollaborationTests.swift" \
  "$ROOT/Tests/IsoSurfaceEditTests.swift" \
  "$ROOT/Tests/VolumeConversionServiceTests.swift" \
  "$ROOT/Tests/I3MParserTests.swift" \
  "$ROOT/Tests/VolumeEditTests.swift" \
  -o "$BUILD_DIR/volume-conversion-tests"

"$BUILD_DIR/volume-conversion-tests" "$@"
