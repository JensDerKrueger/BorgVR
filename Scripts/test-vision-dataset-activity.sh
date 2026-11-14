#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/borgvr-vision-activity.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

swiftc -parse-as-library \
  "$ROOT/VisionApp/VisionDatasetActivityGate.swift" \
  "$ROOT/Tests/VisionDatasetActivityGateTests.swift" \
  -o "$BUILD_DIR/activity-tests"
"$BUILD_DIR/activity-tests"
