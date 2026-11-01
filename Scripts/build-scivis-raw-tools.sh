#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-"${TMPDIR:-/tmp}/borgvr-scivis-raw-tools"}
mkdir -p "$OUTPUT"
swiftc -O -parse-as-library -module-cache-path "$OUTPUT/module-cache" \
  "$ROOT/Scripts/SciVisRawQuantizer.swift" -o "$OUTPUT/scivis-raw-quantizer"
swiftc -O -module-cache-path "$OUTPUT/module-cache" \
  "$ROOT/BORGVR-IO/Vector.swift" "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/BORGVRChannelInterpretation.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" "$ROOT/BORGVR-IO/BORGVRFileData.swift" \
  "$ROOT/Tests/SciVisRawMetadataTests.swift" -o "$OUTPUT/scivis-raw-auditor"
