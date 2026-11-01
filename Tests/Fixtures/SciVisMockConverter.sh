#!/bin/bash
set -euo pipefail
if [[ $# == 1 && "$1" == --help ]]; then
  printf 'Repeatable --source-info DATE TEXT\n'
  if [[ "${SCIVIS_TEST_NO_SIZE_X:-}" != 1 ]]; then printf '%s\n' '--size-x METERS --force-size-x METERS'; fi
  exit 0
fi
[[ $# -ge 9 && "$1" == Z && -s "$2" && "$5" == 32 && "$6" == 2 ]] || exit 2
name=${2##*/}
name=${name%.ozx}
printf 'convert\t%s\t%s\n' "$name" "$4" >> "$SCIVIS_TEST_TRACE"
printf 'fixture dataset\n' > "$3"
shift 6
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --force-size-x || "$1" == --size-x ]]; then
    [[ $# -ge 2 ]] || exit 2
    printf 'size\t%s\t%s\t%s\n' "$name" "$1" "$2" >> "$SCIVIS_TEST_TRACE"
    shift 2
    continue
  fi
  [[ $# -ge 3 && "$1" == --source-info ]] || exit 2
  printf 'source\t%s\t%s\t%s\n' "$name" "$2" "$3" >> "$SCIVIS_TEST_TRACE"
  last_source=$3
  shift 3
done
[[ "$last_source" == *"/$name.ozx"* && "$last_source" == Downloaded* ]] || exit 2
[[ "$name" != "${SCIVIS_TEST_CONVERSION_FAILURE:-}" ]] || exit 9
