#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BORGVR_ASTC_FIXTURES=$(mktemp -d "${TMPDIR:-/tmp}/borgvr-astc-fixtures.XXXXXX")
export BORGVR_ASTC_FIXTURES
trap 'rm -rf "$BORGVR_ASTC_FIXTURES"' EXIT
bash "$ROOT/Scripts/test-volume-atlas-edits.sh"
node "$ROOT/Tests/ASTCDecoderTests.cjs" "$BORGVR_ASTC_FIXTURES"
