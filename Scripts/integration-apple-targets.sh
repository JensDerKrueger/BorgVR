#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT="$ROOT/BorgVR.xcodeproj"

build() {
  scheme=$1
  destination=$2
  printf 'Building %s ...\n' "$scheme"
  xcodebuild \
    -quiet \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "$destination" \
    CODE_SIGNING_ALLOWED=NO \
    build
}

build macOSApp 'platform=macOS'
build macOSServer 'platform=macOS'
build TerminalConverterApp 'platform=macOS'
build TerminalServerApp 'platform=macOS'
build iOSApp 'generic/platform=iOS Simulator'
build VisionApp 'generic/platform=visionOS Simulator'

printf 'All Apple targets built successfully\n'
