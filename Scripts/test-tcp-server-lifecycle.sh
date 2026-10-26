#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-tcp-server-lifecycle-tests"
mkdir -p "$BUILD_DIR" "$BUILD_DIR/swift-module-cache"

swiftc \
  -module-cache-path "$BUILD_DIR/swift-module-cache" \
  "$ROOT/BORGVR-IO/Vector.swift" \
  "$ROOT/BORGVR-IO/IOExtensions.swift" \
  "$ROOT/BORGVR-IO/Logger.swift" \
  "$ROOT/BORGVR-IO/BorgVRSharedConstants.swift" \
  "$ROOT/BORGVR-IO/BORGVRDataBase.swift" \
  "$ROOT/BORGVR-IO/BORGVRMetaData.swift" \
  "$ROOT/BORGVR-IO/MemoryMappedFile.swift" \
  "$ROOT/BORGVR-IO/BORGVRFileData.swift" \
  "$ROOT/BORGVR-IO/Remote/KeyValuePairHandler.swift" \
  "$ROOT/BORGVR-IO/Remote/BorgVRBinaryFrameReceiver.swift" \
  "$ROOT/BORGVR-IO/Remote/BorgVRServerAuthentication.swift" \
  "$ROOT/BORGVR-Services/TCPServer.swift" \
  "$ROOT/Tests/TCPServerTestSupport.swift" \
  "$ROOT/Tests/RemoteDataManagerErrorTestStub.swift" \
  "$ROOT/Tests/TCPServerLifecycleTests.swift" \
  -o "$BUILD_DIR/tcp-server-lifecycle-tests"

"$BUILD_DIR/tcp-server-lifecycle-tests"
