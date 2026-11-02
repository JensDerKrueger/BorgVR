#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-subbrick-simulator-tests"
APP="$BUILD_DIR/Subbrick Simulator Tests.app"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
DEVICE="${1:-booted}"
mkdir -p "$APP" "$BUILD_DIR/swift-module-cache"
xcrun --sdk iphonesimulator swiftc -parse-as-library -sdk "$SDK" \
  -target "$(uname -m)-apple-ios18.0-simulator" -module-cache-path "$BUILD_DIR/swift-module-cache" \
  -import-objc-header "$ROOT/AppSupport/Rendering/Shaders/ShaderTypes.h" \
  "$ROOT/BORGVR-IO/Vector.swift" "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" "$ROOT/BORGVR-IO/BorgVRASTCCodec.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" "$ROOT/BORGVR-IO/BORGVRChannelInterpretation.swift" \
  "$ROOT/BORGVR-IO/BorgVRSharedConstants.swift" \
  "$ROOT/BORGVR-Render/Transfer Function 1D/TransferFunction1D.swift" \
  "$ROOT/BORGVR-Render/VolumeAtlas/VolumeAtlasSubbrickCache.swift" \
  "$ROOT/Tests/VolumeSubbrickSimulatorTests.swift" -o "$APP/SubbrickSimulatorTests"
cp "$ROOT/Tests/VolumeSubbrickSimulatorTests-Info.plist" "$APP/Info.plist"
codesign --force --sign - "$APP"
xcrun simctl install "$DEVICE" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" de.borgvr.SubbrickSimulatorTests data)
rm -f "$CONTAINER/Documents/result.txt"
SIMCTL_CHILD_MTL_DEBUG_LAYER=1 xcrun simctl launch --console "$DEVICE" de.borgvr.SubbrickSimulatorTests
grep -x PASS "$CONTAINER/Documents/result.txt"
