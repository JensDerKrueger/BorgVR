#!/bin/bash
# Sequential SciVis OZX download and BorgVR conversion; compatible with macOS Bash 3.2.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
manifest="$SCRIPT_DIR/scivis-datasets.tsv"
converter="TerminalConverterApp"
output="$PWD/scivis"
brick_size=32
overlap=2
only=""
dry_run=false

usage() {
  cat <<'USAGE'
Usage: download-scivis-datasets.sh [options]
  --converter PATH  TerminalConverterApp executable (default: search PATH)
  --output DIR      Write <Dataset Name>.data here (default: ./scivis)
  --brick-size N    Brick size, including overlap (default: 32)
  --overlap N       Brick overlap (default: 2)
  --only NAME       Process just one Dataset Name
  --dry-run         Print the plan without downloading, converting, or creating files
  --help            Show this help

OZX downloads are retained in DIR/.scivis-downloads, with resumable .part files.
Conversion logs and the run report are stored in DIR/.scivis-logs.
Existing nonempty .data files are never overwritten. Failed jobs are retried on
the next run, using the cached OZX. Processing continues after individual errors;
the script exits with status 1 if any job failed. Downloads may be very large.

Every listed dataset is attempted, including float32 and signed integer sources.
USAGE
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --converter|--output|--brick-size|--overlap|--only)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --converter) converter=$2 ;;
        --output) output=$2 ;;
        --brick-size) brick_size=$2 ;;
        --overlap) overlap=$2 ;;
        --only) only=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$brick_size" =~ ^[1-9][0-9]{0,3}$ && "$overlap" =~ ^[1-9][0-9]{0,3}$ ]] || fail "Invalid brick size or overlap"
brick_size=$((10#$brick_size))
overlap=$((10#$overlap))
(( brick_size > 2 * overlap )) || fail "Brick size must exceed twice the overlap"
[[ -r "$manifest" ]] || fail "Missing dataset manifest: $manifest"
awk -F '\t' '
  /^#/ || NF == 0 { next }
  NF != 4 || $1 !~ /^[a-zA-Z0-9_-]+$/ || seen[$1]++ ||
  $2 !~ /^(uint8|uint16|uint32|int16|float32)$/ ||
  $4 != "https://ome-zarr-scivis.s3.us-east-1.amazonaws.com/v0.5/96x2-ozx/" $1 ".ozx" { exit 1 }
  { words = split($3, w, /[[:space:]]+/); if (words < 1 || words > 10) exit 1; count++ }
  END { if (!count) exit 1 }
' "$manifest" || fail "Invalid dataset manifest"
if [[ -n "$only" ]]; then
  awk -F '\t' -v name="$only" '$1 == name { found = 1 } END { exit !found }' "$manifest" || fail "Unknown dataset: $only"
fi

work=""
cleanup() { if [[ -n "$work" ]]; then rm -rf -- "$work"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! "$dry_run"; then
  converter=$(command -v "$converter") || fail "Converter not found; use --converter PATH"
  [[ -f "$converter" && -x "$converter" ]] || fail "Converter must be an executable file, not a directory: $converter (use --converter ./TerminalConverterApp)"
  converter="$(CDPATH= cd -- "$(dirname -- "$converter")" && pwd)/$(basename -- "$converter")"
  command -v curl >/dev/null || fail "curl is required"
  mkdir -p -- "$output/.scivis-downloads" "$output/.scivis-logs"
  output=$(CDPATH= cd -- "$output" && pwd)
  report=$(mktemp "$output/.scivis-logs/run-XXXXXXXX")
  printf 'dataset\tstatus\n' > "$report"
  printf 'Converter: %s\nOutput: %s\nRun report: %s\n' "$converter" "$output" "$report"
fi

converted=0
skipped=0
failed=0
selected=0
while IFS=$'\t' read -r name type description url; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -z "$only" || "$name" == "$only" ]] || continue
  selected=$((selected + 1))
  printf '\n[%d] %s (%s): %s\n' "$selected" "$name" "$type" "$description"
  if "$dry_run"; then
    printf 'Download: %s\n' "$url"
    printf 'Convert: '; printf '%q ' "$converter" Z "$output/.scivis-downloads/$name.ozx" "$output/$name.data" "$description" "$brick_size" "$overlap"; printf '\n'
    continue
  fi
  target="$output/$name.data"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -f "$target" && -s "$target" ]]; then
      printf 'Already present; skipped.\n'
      printf '%s\tskipped\n' "$name" >> "$report"
      skipped=$((skipped + 1))
    else
      printf 'Refusing to replace existing empty or nonregular output.\n' >&2
      printf '%s\toutput_conflict\n' "$name" >> "$report"
      failed=$((failed + 1))
    fi
    continue
  fi
  source="$output/.scivis-downloads/$name.ozx"
  if [[ ! -s "$source" ]]; then
    printf 'Downloading (partial downloads resume automatically)...\n'
    if curl --fail --location --proto '=https' --proto-redir '=https' \
      --retry 3 --retry-delay 2 --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
      --continue-at - --output "$source.part" "$url"; then
      if [[ ! -s "$source.part" ]]; then
        printf 'Download returned an empty file.\n' >&2
        printf '%s\tdownload_failed\n' "$name" >> "$report"
        failed=$((failed + 1))
        continue
      fi
      mv -- "$source.part" "$source"
    else
      printf 'Download failed; partial file retained. Continuing.\n' >&2
      printf '%s\tdownload_failed\n' "$name" >> "$report"
      failed=$((failed + 1))
      continue
    fi
  else
    printf 'Using cached OZX.\n'
  fi
  work=$(mktemp -d "$output/.scivis-$name.XXXXXXXX")
  log="$output/.scivis-logs/$name.log"
  printf 'Converting; log: %s\n' "$log"
  if "$converter" Z "$source" "$work/$name.data" "$description" "$brick_size" "$overlap" 2>&1 | tee "$log"; then
    if [[ -s "$work/$name.data" ]] && ln -- "$work/$name.data" "$target"; then
      printf '%s\tconverted\n' "$name" >> "$report"
      converted=$((converted + 1))
      printf 'Saved: %s\n' "$target"
    else
      printf 'Missing output or output appeared during conversion; not replacing it.\n' >&2
      printf '%s\toutput_failed\n' "$name" >> "$report"
      failed=$((failed + 1))
    fi
  else
    printf 'Conversion failed; OZX retained. Continuing.\n' >&2
    printf '%s\tconversion_failed\n' "$name" >> "$report"
    failed=$((failed + 1))
  fi
  cleanup
  work=""
done < "$manifest"

printf '\nSelected: %d; converted: %d; skipped: %d; failed: %d\n' "$selected" "$converted" "$skipped" "$failed"
if ! "$dry_run"; then printf 'Run report: %s\n' "$report"; fi
[[ "$failed" -eq 0 ]]
