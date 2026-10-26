#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-cpp-server-security-tests"

mkdir -p "$BUILD_DIR"

"${MAKE:-make}" -C "$ROOT/BORGVRServerCPP" src/GeneratedWebAssets.cpp src/GeneratedWebAssets.h

"${CXX:-c++}" \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Wpedantic \
  -pthread \
  -DBORGVR_PARTIAL_INPUT_TIMEOUT_MS=300 \
  -DBORGVR_AUTHENTICATION_TIMEOUT_MS=5000 \
  -DBORGVR_SOCKET_RECEIVE_TIMEOUT_MS=1000 \
  -DBORGVR_SOCKET_SEND_TIMEOUT_MS=2000 \
  -I"$ROOT/BORGVRServerCPP/include" \
  "$ROOT/BORGVRServerCPP/src/BORGVRFileData.cpp" \
  "$ROOT/BORGVRServerCPP/src/BORGVRMetaData.cpp" \
  "$ROOT/BORGVRServerCPP/src/BorgVRAuthCrypto.cpp" \
  "$ROOT/BORGVRServerCPP/src/GeneratedWebAssets.cpp" \
  "$ROOT/BORGVRServerCPP/src/HTTPWebServer.cpp" \
  "$ROOT/BORGVRServerCPP/src/LZ4.cpp" \
  "$ROOT/BORGVRServerCPP/src/MemoryMappedFile.cpp" \
  "$ROOT/BORGVRServerCPP/src/Socket.cpp" \
  "$ROOT/BORGVRServerCPP/src/TCPServer.cpp" \
  "$ROOT/Tests/CppServerSecurityTests.cpp" \
  -o "$BUILD_DIR/cpp-server-security-tests"

"$BUILD_DIR/cpp-server-security-tests"
