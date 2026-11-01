#!/bin/bash
set -euo pipefail
[[ $# == 6 && "$1" == Z && -s "$2" && "$5" == 32 && "$6" == 2 ]] || exit 2
name=${2##*/}
name=${name%.ozx}
printf 'convert\t%s\t%s\n' "$name" "$4" >> "$SCIVIS_TEST_TRACE"
printf 'fixture dataset\n' > "$3"
[[ "$name" != "${SCIVIS_TEST_CONVERSION_FAILURE:-}" ]] || exit 9
