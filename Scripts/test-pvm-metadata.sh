#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-pvm-metadata-tests"
mkdir -p "$BUILD_DIR"
swiftc -O -parse-as-library -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT/BORGVR-IO/Vector.swift" "$ROOT/BORGVR-IO/Importers/VolumeFileParser.swift" \
  "$ROOT/BORGVR-IO/Importers/BorgVRVolumeGeometry.swift" \
  "$ROOT/BORGVR-IO/BORGVRChannelInterpretation.swift" \
  "$ROOT/BORGVR-IO/Importers/QVIS/QVISParser.swift" "$ROOT/BORGVR-IO/Importers/NRRD/NRRDParser.swift" \
  "$ROOT/BORGVR-IO/Importers/PVM/PVMParser.swift" "$ROOT/BORGVR-IO/Importers/I3D/I3MParser.swift" \
  "$ROOT"/BORGVR-IO/Importers/UVF/*.swift \
  "$ROOT/BORGVR-IO/Importers/VFF/VFFParser.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" "$ROOT/BORGVR-IO/Importers/ZARR/ZstandardDecoder.swift" \
  "$ROOT/BORGVR-IO/Importers/ZARR/ZarrStore.swift" "$ROOT/BORGVR-IO/Importers/ZARR/ZarrParser.swift" \
  "$ROOT/Tests/PVMMetadataTests.swift" -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
