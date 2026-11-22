#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PRODUCTS=${1:?Pass the macOS Debug products directory}
PYTHON=${2:?Pass Python with the agent test dependencies}
TEMP=$(mktemp -d)
SERVER_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TEMP"
}
trap cleanup EXIT HUP INT TERM
"$PYTHON" "$ROOT/Tests/VoiceAgentTypedFixture.py" "$TEMP" > "$TEMP/server.log" 2>&1 &
SERVER_PID=$!
attempt=0
while [ ! -f "$TEMP/ready.json" ]; do
  attempt=$((attempt+1))
  if [ "$attempt" -gt 100 ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then cat "$TEMP/server.log"; exit 1; fi
  sleep 0.1
done
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/modules" -I "$PRODUCTS" \
  "$ROOT/Tests/VoiceAgentTypedCatalogTests.swift" "$PRODUCTS/BorgVR.app/Contents/MacOS/BorgVR.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/BorgVR.app/Contents/MacOS" -o "$TEMP/typed-agent-tests"
if ! "$TEMP/typed-agent-tests" "$ROOT/c60_32.data" "$TEMP" "$ROOT/AppSupport/Voice/expert-knowledge.toml"; then
  cat "$TEMP/server.log"
  exit 1
fi
