#!/bin/bash
# Download-only, portable server job. No Swift, BorgVR, or Python installation required.
set -euo pipefail

output="$PWD"
only=""
dry_run=false
usage() {
  printf '%s\n' 'Usage: download-large-scivis-datasets.sh [--output DIR] [--only NAME] [--dry-run]' \
    'Downloads isotropic_pressure (256 GiB), rotstrat_temperature (256 GiB),' \
    'and dns (900 GiB), sequentially, with resume and SHA-512 verification.' \
    'RAW inputs, matching NRRD headers and .sources.tsv provenance are retained.' \
    'This script does NOT quantize or brick the volumes. Convert them separately' \
    'with the SciVis RAW importer; floating-point data must become UInt16 for BorgVR.'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|--only)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      if [[ "$1" == --output ]]; then output=$2; else only=$2; fi
      shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$only" in ''|isotropic_pressure|rotstrat_temperature|dns) ;; *) usage >&2; exit 2 ;; esac
if ! "$dry_run"; then
  command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 2; }
  if command -v sha512sum >/dev/null; then
    hash_command=(sha512sum)
  elif command -v shasum >/dev/null; then
    hash_command=(shasum -a 512)
  else
    printf 'Install sha512sum (Linux) or shasum (macOS).\n' >&2; exit 2
  fi
  mkdir -p -- "$output"
  output=$(CDPATH= cd -- "$output" && pwd)
fi

failed=0
while IFS=$'\t' read -r name expected checksum type dimensions url; do
  [[ -z "$only" || "$name" == "$only" ]] || continue
  printf '\n%s: %s bytes; %s\n' "$name" "$expected" "$url"
  "$dry_run" && continue
  filename=${url##*/}
  target="$output/$filename"
  partial="$target.part"
  if [[ -L "$target" || -L "$partial" || ( -e "$target" && ! -f "$target" ) || ( -e "$partial" && ! -f "$partial" ) ]]; then
    printf 'Unsafe input path: %s\n' "$name" >&2; failed=1; continue
  fi
  source="$target"
  if [[ ! -f "$target" ]]; then
    source="$partial"
    if [[ ! -f "$partial" || "$(wc -c < "$partial")" -ne "$expected" ]]; then
      remaining=$expected
      if [[ -f "$partial" ]]; then remaining=$((expected - $(wc -c < "$partial"))); fi
      available_kib=$(LC_ALL=C df -Pk "$output" | awk 'NR == 2 { print $4 }')
      if [[ ! "$available_kib" =~ ^[0-9]+$ ]] || (( remaining < 0 || remaining + 1073741824 > available_kib * 1024 )); then
        printf 'Not enough free disk space (including 1 GiB reserve): %s\n' "$name" >&2; failed=1; continue
      fi
      if ! curl --fail --location --retry 4 --connect-timeout 20 \
        --speed-time 120 --speed-limit 1024 --continue-at - --output "$partial" "$url"; then
        printf 'Download failed; rerun to resume: %s\n' "$name" >&2; failed=1; continue
      fi
    fi
  fi
  actual=$(wc -c < "$source")
  if [[ "$actual" -ne "$expected" ]]; then
    printf 'Incorrect byte count; file retained: %s\n' "$source" >&2; failed=1; continue
  fi
  printf 'Checking SHA-512 (this reads the full file)...\n'
  hash=$("${hash_command[@]}" < "$source")
  if [[ "${hash%% *}" != "$checksum" ]]; then
    printf 'Checksum mismatch; file retained for inspection: %s\n' "$source" >&2; failed=1; continue
  fi
  if [[ "$source" == "$partial" ]]; then
    # Do not overwrite a file created by another process during the download.
    if ! ln -- "$partial" "$target"; then failed=1; continue; fi
    rm -- "$partial"
  fi
  header="$output/$name.nhdr"
  provenance="$output/$name.sources.tsv"
  if [[ -L "$header" || -L "$provenance" ]]; then
    printf 'Unsafe sidecar path: %s\n' "$name" >&2; failed=1; continue
  fi
  nrrd_type=float
  [[ "$type" == float64 ]] && nrrd_type=double
  if [[ ! -e "$header" ]]; then
    (set -o noclobber; printf 'NRRD0005\ntype: %s\ndimension: 3\nsizes: %s\nencoding: raw\nendian: little\ndata file: %s\n\n' \
      "$nrrd_type" "$dimensions" "$filename" > "$header")
  fi
  case "$name" in
    isotropic_pressure) attribution='Johns Hopkins Turbulence Databases; Yeung, Donzis and Sreenivasan (2012), Dissipation, enstrophy and pressure statistics in turbulence simulations at high Reynolds numbers. JFM 700, 5-15.' ;;
    rotstrat_temperature) attribution='Johns Hopkins Turbulence Databases; Rosenberg, Pouquet, Marino and Mininni (2015), Evidence for Bolgiano-Obukhov scaling in rotating stratified turbulence using high-resolution direct numerical simulations. Physics of Fluids 27, 055105.' ;;
    dns) attribution='Myoungkyu Lee and Robert D. Moser (2015), Direct numerical simulation of turbulent channel flow up to Re_tau = 5200. JFM 774, 395-415. DOI: 10.1017/jfm.2015.268.' ;;
  esac
  if [[ ! -e "$provenance" ]]; then
    day=$(date -u +%Y-%m-%d)
    (set -o noclobber; printf '%sT00:00:00Z\t%s\n%sT00:00:00Z\tDownloaded as little-endian %s RAW from %s ; SHA-512 %s ; catalog http://klacansky.com/open-scivis-datasets/\n' \
      "$day" "$attribution" "$day" "$type" "$url" "$checksum" > "$provenance")
  fi
  printf 'Verified: %s\n' "$target"
done <<'DATASETS'
isotropic_pressure	274877906944	742831ea384d7dd30fcbfce0383959d3389761a1612acacabbaa2d8532bfc734d32169dce89acaad5ba72185d465eceb62a8b8dfb60c48eeb403810bd98c8a3d	float32	4096 4096 4096	http://klacansky.com/open-scivis-datasets/isotropic_pressure/isotropic_pressure_4096x4096x4096_float32.raw
rotstrat_temperature	274877906944	582d56df9be44d5d008f0df80ab61278f9edd8864da166653c4781c76fead4b5d35e6477210c78c85083f41f45438ad30898b7c8894964d08ab215a44c942d78	float32	4096 4096 4096	http://klacansky.com/open-scivis-datasets/rotstrat_temperature/rotstrat_temperature_4096x4096x4096_float32.raw
dns	966367641600	12923141c4195db5f91a9a288fbea85d26572373fa236a4185870617e369d23876ef23e6213f788b4456b7ae098e2ec9b572d4a8809891dd0d872124c2cfb997	float64	10240 7680 1536	http://klacansky.com/open-scivis-datasets/dns/dns_10240x7680x1536_float64.raw
DATASETS
exit "$failed"
