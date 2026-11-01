#!/bin/bash
# Sequential SciVis OZX download and BorgVR conversion; compatible with macOS Bash 3.2.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
manifest="$SCRIPT_DIR/scivis-datasets.tsv"
provenance="$SCRIPT_DIR/scivis-provenance.tsv"
sizes="$SCRIPT_DIR/scivis-sizes.tsv"
converter="TerminalConverterApp"
output="$PWD/scivis"
brick_size=32
overlap=2
only=""
dry_run=false
replace=false
download_date=$(date -u +%Y-%m-%d)

usage() {
  cat <<'USAGE'
Usage: download-scivis-datasets.sh [options]
  --converter PATH  TerminalConverterApp executable (default: search PATH)
  --output DIR      Write <Dataset Name>.data here (default: ./scivis)
  --brick-size N    Brick size, including overlap (default: 32)
  --overlap N       Brick overlap (default: 2)
  --only NAME       Process just one Dataset Name
  --download-date DATE  Reported OZX download day, YYYY-MM-DD (default: today, UTC)
  --replace         Regenerate existing datasets; replace only after successful conversion
  --dry-run         Print the plan without downloading, converting, or creating files
  --help            Show this help

OZX downloads are retained in DIR/.scivis-downloads, with resumable .part files.
Conversion logs and the run report are stored in DIR/.scivis-logs.
Existing nonempty .data files are skipped unless --replace is given. Failed jobs are retried on
the next run, using the cached OZX. Processing continues after individual errors;
the script exits with status 1 if any job failed. Downloads may be very large.

Every listed dataset is attempted, including float32 and signed integer sources.
Sources and publications from scivis-provenance.tsv are passed as repeatable
--source-info entries. The last source entry records the OZX URL and download day.
Unknown times use 00:00 UTC according to the provenance convention.
The converter adds its own conversion event. Signed integers are shifted to unsigned;
float channels are quantized to UInt16 by the Zarr importer for renderer compatibility.
Physical X extents from scivis-sizes.tsv use --force-size-x (or --size-x for hints).
Estimated, uncertain literature and arbitrary display sizes are explicitly recorded
in provenance. Verified sizes do not add a separate source-info size annotation.
USAGE
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --converter|--output|--brick-size|--overlap|--only|--download-date)
      [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
      case "$1" in
        --converter) converter=$2 ;;
        --output) output=$2 ;;
        --brick-size) brick_size=$2 ;;
        --overlap) overlap=$2 ;;
        --only) only=$2 ;;
        --download-date) download_date=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --replace) replace=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ "$brick_size" =~ ^[1-9][0-9]{0,3}$ && "$overlap" =~ ^[1-9][0-9]{0,3}$ ]] || fail "Invalid brick size or overlap"
brick_size=$((10#$brick_size))
overlap=$((10#$overlap))
(( brick_size > 2 * overlap )) || fail "Brick size must exceed twice the overlap"
[[ -r "$manifest" ]] || fail "Missing dataset manifest: $manifest"
[[ -r "$provenance" ]] || fail "Missing provenance manifest: $provenance"
[[ -r "$sizes" ]] || fail "Missing size manifest: $sizes"
[[ "$download_date" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] || fail "Invalid download date; use YYYY-MM-DD"
awk -F '\t' '
  /^#/ || NF == 0 { next }
  NF != 4 || $1 !~ /^[a-zA-Z0-9_-]+$/ || seen[$1]++ ||
  $2 !~ /^(uint8|uint16|uint32|int16|float32)$/ ||
  $4 != "https://ome-zarr-scivis.s3.us-east-1.amazonaws.com/v0.5/96x2-ozx/" $1 ".ozx" { exit 1 }
  { words = split($3, w, /[[:space:]]+/); if (words < 1 || words > 10) exit 1; count++ }
  END { if (!count) exit 1 }
' "$manifest" || fail "Invalid dataset manifest"
awk -F '\t' '
  FNR == NR { if ($0 !~ /^#/ && NF) names[$1] = 1; next }
  /^#/ || NF == 0 { next }
  NF != 3 || !($1 in names) || !length($3) || $3 ~ /[[:cntrl:]]/ { exit 1 }
  $2 != "recorded" && $2 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ { exit 1 }
' "$manifest" "$provenance" || fail "Invalid provenance manifest"
awk -F '\t' '
  FNR == NR { if ($0 !~ /^#/ && NF) names[$1] = 1; next }
  /^#/ || NF == 0 { next }
  NF != 4 || !($1 in names) || seen[$1]++ || !length($4) { bad = 1; exit 1 }
  $2 !~ /^(force|hint|estimate|literature|display)$/ { bad = 1; exit 1 }
  $3 != "-" && ($3 !~ /^[0-9]+([.][0-9]+)?$/ || $3 + 0 <= 0) { bad = 1; exit 1 }
  $3 == "-" { bad = 1; exit 1 }
  END { for (name in names) if (!seen[name]) bad = 1; exit bad }
' "$manifest" "$sizes" || fail "Invalid size manifest"
if [[ -n "$only" ]]; then
  awk -F '\t' -v name="$only" '$1 == name { found = 1 } END { exit !found }' "$manifest" || fail "Unknown dataset: $only"
fi

work=""
cleanup() { if [[ -n "$work" ]]; then rm -rf -- "$work"; fi; }
publish_output() {
  [[ -f "$work/$name.data" && -s "$work/$name.data" ]] || return 1
  if "$replace"; then
    if [[ -e "$target" || -L "$target" ]]; then
      [[ -f "$target" && -s "$target" && ! -L "$target" ]] || return 1
    fi
    # The staging directory is on the same filesystem, so rename replaces atomically.
    mv -f -- "$work/$name.data" "$target"
  else
    ln -- "$work/$name.data" "$target"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! "$dry_run"; then
  converter=$(command -v "$converter") || fail "Converter not found; use --converter PATH"
  [[ -f "$converter" && -x "$converter" ]] || fail "Converter must be an executable file, not a directory: $converter (use --converter ./TerminalConverterApp)"
  converter="$(CDPATH= cd -- "$(dirname -- "$converter")" && pwd)/$(basename -- "$converter")"
  converter_help=$("$converter" --help) || fail "Cannot run converter"
  [[ "$converter_help" == *--source-info* ]] || fail "Converter does not support --source-info; install the current version"
  if awk -F '\t' -v selected="$only" '
    $0 !~ /^#/ && (selected == "" || $1 == selected) { needed = 1 }
    END { exit !needed }
  ' "$sizes"; then
    [[ "$converter_help" == *--force-size-x* && "$converter_help" == *--size-x* ]] || fail "Converter does not support physical size overrides; install the version with --size-x/--force-size-x"
  fi
  command -v curl >/dev/null || fail "curl is required"
  mkdir -p -- "$output/.scivis-downloads" "$output/.scivis-logs"
  output=$(CDPATH= cd -- "$output" && pwd)
  report=$(mktemp "$output/.scivis-logs/run-XXXXXXXX")
  printf 'dataset\tstatus\n' > "$report"
  cp -- "$provenance" "$report.sources.tsv"
  cp -- "$sizes" "$report.sizes.tsv"
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
  source_info=()
  while IFS=$'\t' read -r source_name source_date source_text; do
    [[ "$source_name" == "$name" ]] || continue
    if [[ "$source_date" == recorded ]]; then
      source_date="${download_date}T00:00:00Z"
    fi
    source_info+=(--source-info "$source_date" "$source_text")
  done < "$provenance"
  if [[ ${#source_info[@]} -gt 0 ]]; then
    source_info+=(--source-info "${download_date}T00:00:00Z" "Redistribution chain (dates unknown): Open SciVis curated by Pavol Klacansky, https://klacansky.com/open-scivis-datasets/ ; converted to OME-Zarr and distributed by https://github.com/InsightSoftwareConsortium/OMEZarrOpenSciVisDatasets .")
  fi
  size_mode=""
  while IFS=$'\t' read -r size_name mode meters evidence; do
    [[ "$size_name" == "$name" ]] || continue
    size_mode=$mode
    size_meters=$meters
    size_evidence=$evidence
    break
  done < "$sizes"
  printf 'X extent: %s m (%s).\n' "$size_meters" "$size_mode"
  case "$size_mode" in
    estimate|literature) source_info+=(--source-info "${download_date}T00:00:00Z" "Estimated X extent: $size_meters m. $size_evidence") ;;
    display) source_info+=(--source-info "${download_date}T00:00:00Z" "Display X extent: $size_meters m; not a physical calibration. $size_evidence") ;;
  esac
  source_info+=(--source-info "${download_date}T00:00:00Z" "Downloaded on $download_date as OME-Zarr OZX from $url ; collection https://github.com/InsightSoftwareConsortium/OMEZarrOpenSciVisDatasets .")
  import_options=("${source_info[@]}")
  case "$size_mode" in
    force|estimate|literature|display) import_options+=(--force-size-x "$size_meters") ;;
    hint) import_options+=(--size-x "$size_meters") ;;
  esac
  if "$dry_run"; then
    printf 'Download: %s\n' "$url"
    printf 'Convert: '; printf '%q ' "$converter" Z "$output/.scivis-downloads/$name.ozx" "$output/$name.data" "$description" "$brick_size" "$overlap" "${import_options[@]}"; printf '\n'
    continue
  fi
  target="$output/$name.data"
  if [[ -e "$target" || -L "$target" ]]; then
    if [[ -f "$target" && -s "$target" && ! -L "$target" ]]; then
      if "$replace"; then
        printf 'Regenerating; previous dataset retained until conversion succeeds.\n'
      else
        printf 'Already present; skipped.\n'
        printf '%s\tskipped\n' "$name" >> "$report"
        skipped=$((skipped + 1))
        continue
      fi
    else
      printf 'Refusing to replace existing empty or nonregular output.\n' >&2
      printf '%s\toutput_conflict\n' "$name" >> "$report"
      failed=$((failed + 1))
      continue
    fi
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
  if "$converter" Z "$source" "$work/$name.data" "$description" "$brick_size" "$overlap" "${import_options[@]}" </dev/null 2>&1 | tee "$log"; then
    if publish_output; then
      printf '%s\tconverted\n' "$name" >> "$report"
      converted=$((converted + 1))
      printf 'Saved: %s\n' "$target"
    else
      printf 'Output missing or destination cannot be replaced; previous dataset retained.\n' >&2
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
