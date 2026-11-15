#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLATFORM=${1:-macos}
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-metal-slice-tests/$PLATFORM"
mkdir -p "$BUILD_DIR/modules"
case "$PLATFORM" in
  macos) SDK=macosx; TARGET="$(uname -m)-apple-macos15.0" ;;
  ios-simulator) SDK=iphonesimulator; TARGET="$(uname -m)-apple-ios18.0-simulator" ;;
  visionos-simulator) SDK=xrsimulator; TARGET="$(uname -m)-apple-xros2.0-simulator" ;;
  *) printf 'Unknown test platform: %s\n' "$PLATFORM" >&2; exit 1 ;;
esac
if [ "$PLATFORM" != macos ]; then
  DEVICE=${2:?Provide a booted simulator ID}
fi
SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
xcrun --sdk "$SDK" swiftc -parse-as-library -sdk "$SDK_PATH" -target "$TARGET" \
  -module-cache-path "$BUILD_DIR/modules" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/Logger.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/TerminalConverterApp/DataGenerator.swift" \
  "$ROOT/TerminalConverterApp/GPUMandelbulbGenerator.swift" \
  "$ROOT/TerminalConverterApp/MetalSliceGenerator.swift" \
  "$ROOT/Tests/MetalSliceGeneratorTests.swift" -o "$BUILD_DIR/metal-slice-tests"
if [ "$PLATFORM" = macos ]; then
  MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 "$BUILD_DIR/metal-slice-tests"
else
  SIMCTL_CHILD_MTL_DEBUG_LAYER=1 \
    xcrun simctl spawn "$DEVICE" "$BUILD_DIR/metal-slice-tests"
fi
