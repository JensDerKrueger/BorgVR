#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-settings-tests"
mkdir -p "$BUILD_DIR"
swiftc -warnings-as-errors -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT/BORGVR-IO/BorgVRSettingsArchive.swift" \
  "$ROOT/Tests/SettingsArchiveTests.swift" \
  -o "$BUILD_DIR/settings-tests"
"$BUILD_DIR/settings-tests"
