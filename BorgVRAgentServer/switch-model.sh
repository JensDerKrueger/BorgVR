#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ((EUID != 0)) && [[ "${1:-}" != --help && "${1:-}" != -h ]]; then
  exec sudo -- "$DIR/switch-model.sh" "$@"
fi
exec python3 "$DIR/switch_model.py" "$@"
