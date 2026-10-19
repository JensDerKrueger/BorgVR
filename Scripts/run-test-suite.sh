#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/borgvr-test-suite.XXXXXX") || exit 1

cleanup() {
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT HUP INT TERM

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN=$(printf '\033[32m')
  RED=$(printf '\033[31m')
  BOLD=$(printf '\033[1m')
  RESET=$(printf '\033[0m')
else
  GREEN=
  RED=
  BOLD=
  RESET=
fi

total=0
passed=0
failed=0
failed_tests=
include_integration=false

case "${1:-}" in
  "") ;;
  --full) include_integration=true ;;
  -h|--help)
    printf 'Usage: %s [--full]\n' "$(basename "$0")"
    printf '  --full  Also build all Apple application targets.\n'
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 2
    ;;
esac

if [ "$include_integration" = true ]; then
  printf '%sBorgVR full test suite%s\n\n' "$BOLD" "$RESET"
else
  printf '%sBorgVR test suite%s\n\n' "$BOLD" "$RESET"
fi

run_test_script() {
  test_script=$1
  total=$((total + 1))
  test_name=$(basename "$test_script" .sh)
  log_file="$LOG_DIR/$test_name.log"
  started_at=$(date +%s)

  printf '  %-34s' "$test_name"
  if (cd "$PROJECT_ROOT" && "$test_script") >"$log_file" 2>&1; then
    elapsed=$(( $(date +%s) - started_at ))
    passed=$((passed + 1))
    printf '%sPASS%s (%ss)\n' "$GREEN" "$RESET" "$elapsed"
    if [ "${VERBOSE:-0}" = "1" ]; then
      sed 's/^/      /' "$log_file"
    fi
  else
    status=$?
    elapsed=$(( $(date +%s) - started_at ))
    failed=$((failed + 1))
    failed_tests="${failed_tests}${failed_tests:+\n}${test_name}"
    printf '%sFAIL%s (%ss, exit %s)\n' "$RED" "$RESET" "$elapsed" "$status"
    sed 's/^/      /' "$log_file"
  fi
}

for test_script in "$SCRIPT_DIR"/test-*.sh; do
  [ -f "$test_script" ] || continue
  run_test_script "$test_script"
done

if [ "$include_integration" = true ]; then
  for test_script in "$SCRIPT_DIR"/integration-*.sh; do
    [ -f "$test_script" ] || continue
    run_test_script "$test_script"
  done
fi

if [ "$total" -eq 0 ]; then
  printf '%sNo test scripts found.%s\n' "$RED" "$RESET"
  exit 1
fi

printf '\n%sSummary:%s %s passed, %s failed, %s total\n' \
  "$BOLD" "$RESET" "$passed" "$failed" "$total"

if [ "$failed" -ne 0 ]; then
  printf '\n%sFailed tests:%s\n%b\n' "$RED" "$RESET" "$failed_tests"
  exit 1
fi

exit 0
