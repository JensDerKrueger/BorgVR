#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/borgvr-import-localization.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

CATALOG="$ROOT/AppSupport/UI/ImportMessages.xcstrings"
xcrun xcstringstool compile --output-directory "$BUILD_DIR" "$CATALOG"
swift "$ROOT/Tests/ImportLocalizationTests.swift" "$CATALOG" "$BUILD_DIR"
