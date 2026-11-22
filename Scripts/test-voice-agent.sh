#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP=$(mktemp -d)
cleanup() {
  rm -rf "$TEMP"
}
trap cleanup EXIT HUP INT TERM
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/policy-modules" \
  "$ROOT/AppSupport/Voice/VoiceAgentProtocol.swift" "$ROOT/AppSupport/Voice/VoiceAgentMarkdown.swift" \
  "$ROOT/AppSupport/Voice/VoiceAgentAnnotationPolicy.swift" \
  "$ROOT/Tests/VoiceAgentPolicyTests.swift" -o "$TEMP/policy-tests"
"$TEMP/policy-tests"
if [ "$#" -eq 0 ]; then
  printf 'For the native TLS/WSS/GSC integration test, pass <macOS Debug products directory> <agent-venv-python>.\n'
  exit 0
fi
PRODUCTS=${1:?Usage: test-voice-agent.sh <macOS Debug products directory> <agent-venv-python>}
PYTHON=${2:?Pass the Python interpreter with BorgVRAgentServer test dependencies installed}
PYTHONPATH="$ROOT/BorgVRAgentServer" "$PYTHON" -c '
import sys
from pathlib import Path
from configure import create_configuration
create_configuration(Path(sys.argv[1]), "localhost", "127.0.0.1", 8766, "0")
' "$TEMP"
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/modules" -I "$PRODUCTS" \
  "$ROOT/Tests/VoiceAgentTests.swift" "$PRODUCTS/BorgVR.app/Contents/MacOS/BorgVR.debug.dylib" \
  -Xlinker -rpath -Xlinker "$PRODUCTS/BorgVR.app/Contents/MacOS" -o "$TEMP/voice-agent-tests"
"$TEMP/voice-agent-tests" "$ROOT/c60_32.data" "$TEMP"
sh "$ROOT/Scripts/test-voice-agent-catalog.sh" "$PRODUCTS" "$PYTHON"
