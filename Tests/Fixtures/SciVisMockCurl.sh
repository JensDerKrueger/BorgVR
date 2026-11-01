#!/bin/bash
set -euo pipefail
output=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --proto|--proto-redir|--retry|--retry-delay|--connect-timeout|--speed-limit|--speed-time|--continue-at) shift 2 ;;
    --fail|--location) shift ;;
    https://*) url=$1; shift ;;
    *) exit 2 ;;
  esac
done
name=${url##*/}
name=${name%.ozx}
printf 'download\t%s\n' "$name" >> "$SCIVIS_TEST_TRACE"
printf 'fixture archive\n' > "$output"
[[ "$name" != "${SCIVIS_TEST_DOWNLOAD_FAILURE:-}" ]] || exit 7
