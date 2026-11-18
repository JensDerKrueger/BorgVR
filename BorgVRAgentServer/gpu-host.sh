#!/usr/bin/env bash

is_wsl() {
  [[ "$(uname -r)" == *[Mm]icrosoft* ]]
}

check_nvidia_driver() {
  if command -v nvidia-smi >/dev/null; then
    nvidia-smi
  elif [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
    /usr/lib/wsl/lib/nvidia-smi
  else
    return 1
  fi
}
