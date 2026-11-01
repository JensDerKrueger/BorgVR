#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-scivis-provenance-tests"
mkdir -p "$BUILD_DIR"
swiftc -O -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/BORGVRChannelInterpretation.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/BORGVR-IO/BORGVRFileData.swift" \
  "$ROOT/Tests/SciVisProvenanceTests.swift" \
  -o "$BUILD_DIR/audit"
"$BUILD_DIR/audit" "$1" "$ROOT/Scripts/scivis-datasets.tsv" "$ROOT/Scripts/scivis-provenance.tsv" "$2" "${3:-}"
