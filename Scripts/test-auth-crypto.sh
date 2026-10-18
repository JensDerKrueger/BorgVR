#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="${TMPDIR:-/tmp}/borgvr-auth-crypto-tests"

mkdir -p "$BUILD_DIR"

"${CXX:-c++}" \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Wpedantic \
  -I"$ROOT/BORGVRServerCPP/include" \
  "$ROOT/BORGVRServerCPP/src/BorgVRAuthCrypto.cpp" \
  "$ROOT/Tests/BorgVRAuthCryptoTests.cpp" \
  -o "$BUILD_DIR/auth-crypto-tests"
"$BUILD_DIR/auth-crypto-tests"
