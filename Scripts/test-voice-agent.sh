#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d)
SERVER_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TEMP"
}
trap cleanup EXIT HUP INT TERM
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/policy-modules" \
  "$ROOT/AppSupport/Voice/VoiceAgentProtocol.swift" "$ROOT/AppSupport/Voice/VoiceAgentMarkdown.swift" \
  "$ROOT/Tests/VoiceAgentPolicyTests.swift" -o "$TEMP/policy-tests"
"$TEMP/policy-tests"
if [ "$#" -eq 0 ]; then
  printf 'For the native TLS/WSS/GSC integration test, pass <macOS Debug products directory> <agent-venv-python>.\n'
  exit 0
fi
PRODUCTS=${1:?Usage: test-voice-agent.sh <macOS Debug products directory> <agent-venv-python>}
PYTHON=${2:?Pass the Python interpreter with BorgVRAgentServer test dependencies installed}
"$PYTHON" "$ROOT/Tests/VoiceAgentFixture.py" "$TEMP" > "$TEMP/server.log" 2>&1 &
SERVER_PID=$!
attempt=0
while [ ! -f "$TEMP/ready.json" ]; do
  attempt=$((attempt+1))
  if [ "$attempt" -gt 100 ] || ! kill -0 "$SERVER_PID" 2>/dev/null; then cat "$TEMP/server.log"; exit 1; fi
  sleep 0.1
done
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/modules" -I "$PRODUCTS" \
  "$ROOT/Tests/VoiceAgentTests.swift" "$PRODUCTS/BorgVR.app/Contents/MacOS/BorgVR.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/BorgVR.app/Contents/MacOS" -o "$TEMP/voice-agent-tests"
if ! "$TEMP/voice-agent-tests" "$ROOT/c60_32.data" "$TEMP"; then cat "$TEMP/server.log"; exit 1; fi
