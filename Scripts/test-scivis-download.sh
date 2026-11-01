#!/bin/bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/borgvr-scivis-script-XXXXXXXX")
work=$(CDPATH= cd -- "$work" && pwd)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
cp "$ROOT/Tests/Fixtures/SciVisMockCurl.sh" "$work/bin/curl"
cp "$ROOT/Tests/Fixtures/SciVisMockConverter.sh" "$work/test converter"
chmod +x "$work/bin/curl" "$work/test converter"
export PATH="$work/bin:$PATH"
export SCIVIS_TEST_TRACE="$work/trace.tsv"
script="$ROOT/Scripts/download-scivis-datasets.sh"
output="$work/output with spaces"

bash "$script" --dry-run --output "$output" > "$work/plan.log"
[[ ! -e "$output" && ! -e "$SCIVIS_TEST_TRACE" ]]
grep -q 'Selected: 51;' "$work/plan.log"
if bash "$script" --dry-run --only unknown > /dev/null 2>&1; then exit 1; fi
if bash "$script" --dry-run --brick-size 32 --overlap 16 > /dev/null 2>&1; then exit 1; fi
if bash "$script" --dry-run --download-date wrong > /dev/null 2>&1; then exit 1; fi
for invalid in . "$work" "$work/missing-converter" /usr/bin/true; do
  if bash "$script" --converter "$invalid" --output "$output" --only blunt_fin > "$work/invalid.log" 2>&1; then exit 1; fi
  [[ ! -e "$output" && ! -e "$SCIVIS_TEST_TRACE" ]]
done
if SCIVIS_TEST_NO_SIZE_X=1 bash "$script" --converter "$work/test converter" --output "$output" --only bunny > "$work/old-converter.log" 2>&1; then exit 1; fi
[[ ! -e "$output" && ! -e "$SCIVIS_TEST_TRACE" ]]
grep -q 'does not support physical size overrides' "$work/old-converter.log"

(
  cd "$work"
  bash "$script" --converter './test converter' --output "$work/relative" --only blunt_fin > "$work/relative.log" 2>&1
)
grep -q 'Selected: 1; converted: 1;' "$work/relative.log"
grep -Fq "Converter: $work/test converter" "$work/relative.log"
rm -- "$SCIVIS_TEST_TRACE"

export SCIVIS_TEST_DOWNLOAD_FAILURE=engine
export SCIVIS_TEST_CONVERSION_FAILURE=aneurism
if bash "$script" --converter "$work/test converter" --output "$output" > "$work/first.log" 2>&1; then exit 1; fi
grep -q 'converted: 49; skipped: 0; failed: 2' "$work/first.log"
[[ ! -e "$output/engine.data" && ! -e "$output/aneurism.data" && -s "$output/zeiss.data" ]]
[[ -s "$output/.scivis-downloads/engine.ozx.part" && -s "$output/.scivis-downloads/aneurism.ozx" ]]
[[ $(find "$output" -maxdepth 1 -type d -name '.scivis-*.????????' | wc -l | tr -d ' ') == 0 ]]
awk -F '\t' '$1 == "convert" && $2 == "boston_teapot" && $3 == "CT scan of the SIGGRAPH teapot containing a lobster." { found = 1 } END { exit !found }' "$SCIVIS_TEST_TRACE"

unset SCIVIS_TEST_DOWNLOAD_FAILURE SCIVIS_TEST_CONVERSION_FAILURE
bash "$script" --converter "$work/test converter" --output "$output" > "$work/retry.log" 2>&1
grep -q 'converted: 2; skipped: 49; failed: 0' "$work/retry.log"
[[ -s "$output/engine.data" && -s "$output/aneurism.data" ]]
[[ $(awk -F '\t' '$1 == "download" { n++ } END { print n }' "$SCIVIS_TEST_TRACE") == 52 ]]
[[ $(awk -F '\t' '$1 == "convert" { n++ } END { print n }' "$SCIVIS_TEST_TRACE") == 52 ]]
before=$(wc -l < "$SCIVIS_TEST_TRACE")
bash "$script" --converter "$work/test converter" --output "$output" > "$work/again.log" 2>&1
grep -q 'converted: 0; skipped: 51; failed: 0' "$work/again.log"
[[ $(wc -l < "$SCIVIS_TEST_TRACE") == "$before" ]]
bash "$script" --converter "$work/test converter" --output "$work/single" --only blunt_fin > "$work/single.log" 2>&1
grep -q 'Selected: 1; converted: 1;' "$work/single.log"
bash "$script" --converter "$work/test converter" --output "$work/provenance" --only bunny --download-date 2026-10-31 > "$work/provenance.log" 2>&1
awk -F '\t' '$1 == "source" && $2 == "bunny" && $3 == "2000-01-28T00:00:00Z" && $4 ~ /Terry S. Yoo/ { found = 1 } END { exit !found }' "$SCIVIS_TEST_TRACE"
awk -F '\t' '$1 == "source" && $2 == "bunny" { date = $3; text = $4 } END { exit !(date == "2026-10-31T00:00:00Z" && text ~ /^Downloaded on 2026-10-31/ && text ~ /bunny.ozx/) }' "$SCIVIS_TEST_TRACE"
awk -F '\t' '$1 == "source" && $2 == "tooth" { n++; text = $4; if ($4 ~ /^Estimated X extent: 0.02 m/) estimate = 1 } END { exit !(n == 2 && estimate && text ~ /^Downloaded/) }' "$SCIVIS_TEST_TRACE"
if grep -E 'attributed separately above|day precision|midnight UTC placeholder|Attribution recorded for this import' "$SCIVIS_TEST_TRACE"; then exit 1; fi
awk -F '\t' '$1 == "size" && $2 == "bunny" && $3 == "--force-size-x" && $4 == "0.173000192" { found = 1 } END { exit !found }' "$SCIVIS_TEST_TRACE"
awk -F '\t' '$1 == "size" && $2 == "marmoset_neurons" && $4 == "0.000338944" { found = 1 } END { exit !found }' "$SCIVIS_TEST_TRACE"
awk -F '\t' '$1 == "source" && $2 == "bunny" && $4 ~ /^(Physical|Estimated|Display) X extent:/ { exit 1 }' "$SCIVIS_TEST_TRACE"
awk -F '\t' '$1 == "source" && $2 == "blunt_fin" && $4 ~ /^Display X extent: 1.0 m; not a physical calibration/ { found = 1 } END { exit !found }' "$SCIVIS_TEST_TRACE"
[[ $(awk -F '\t' '$1 == "size" { seen[$2] = 1 } END { for (name in seen) n++; print n }' "$SCIVIS_TEST_TRACE") == 51 ]]
printf 'previous dataset\n' > "$work/provenance/bunny.data"
if SCIVIS_TEST_CONVERSION_FAILURE=bunny bash "$script" --converter "$work/test converter" --output "$work/provenance" --only bunny --replace > "$work/replace-failed.log" 2>&1; then exit 1; fi
[[ $(< "$work/provenance/bunny.data") == 'previous dataset' ]]
bash "$script" --converter "$work/test converter" --output "$work/provenance" --only bunny --replace > "$work/replace.log" 2>&1
grep -q 'converted: 1; skipped: 0; failed: 0' "$work/replace.log"
[[ $(< "$work/provenance/bunny.data") == 'fixture dataset' ]]
printf 'SciVis batch script tests passed (51 approved sizes, estimated/display provenance, verified-size annotations omitted, retries and paths).\n'
