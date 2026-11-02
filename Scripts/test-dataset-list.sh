#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-dataset-list-tests"
mkdir -p "$BUILD_DIR/swift-module-cache"
swiftc -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/AppSupport/Datasets/DatasetListPresentation.swift" \
  "$ROOT/Tests/DatasetListPresentationTests.swift" \
  -o "$BUILD_DIR/dataset-list-tests"
"$BUILD_DIR/dataset-list-tests"
