#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-zstandard-tests"
mkdir -p "$BUILD_DIR"
ZSTD_EXECUTABLE=$(command -v zstd || true)
export ZSTD_EXECUTABLE
swiftc -O -parse-as-library -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT/BORGVR-IO/Importers/ZARR/ZstandardDecoder.swift" "$ROOT/Tests/ZstandardDecoderTests.swift" \
  -o "$BUILD_DIR/tests"
"$BUILD_DIR/tests"
