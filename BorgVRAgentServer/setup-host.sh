#!/usr/bin/env bash
set -euo pipefail
BACKEND=cuda
ALLOW_DOCKER_RESTART=0
WORK=""

usage() {
  printf '%s\n' \
    'Usage (root): ./setup-host.sh [--backend cuda|rocm] [--allow-docker-restart]' \
    '  --backend cuda|rocm     NVIDIA Container Toolkit or existing AMD ROCm driver.' \
    '  --allow-docker-restart   Permit NVIDIA runtime registration and a Docker restart.' \
    '                           Existing containers may be interrupted.' \
    'Ubuntu 22.04/24.04/26.04, Linux x86_64; a working matching GPU driver is required.' \
    'No app checkout, model, credentials, certificates or user configuration is created.'
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
docker_local() { docker --host unix:///var/run/docker.sock "$@"; }

configure_runtime() {
  local registered
  registered="$(docker_local info --format '{{json .Runtimes}}' | python3 -c \
    'import json,sys; r=json.load(sys.stdin); assert isinstance(r,dict); print("yes" if "nvidia" in r else "no")')" \
    || die 'Could not inspect Docker runtimes; refusing to change daemon configuration.'
  if [[ "$registered" == yes ]]; then
    printf '%s\n' 'NVIDIA Docker runtime is already registered; no restart needed.'
    return 0
  fi
  ((ALLOW_DOCKER_RESTART)) \
    || die 'NVIDIA runtime registration requires --allow-docker-restart. Rerun during a maintenance window.'
  printf '%s\n' 'Registering NVIDIA runtime and restarting Docker; existing containers may be interrupted.'
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  docker_local info >/dev/null
}

install_host() {
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die 'Host setup requires Linux x86_64.'
  if [[ "$BACKEND" == cuda ]]; then
    command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null \
      || die 'A working NVIDIA driver is required. No driver will be installed or replaced.'
  else
    [[ -c /dev/kfd && -d /dev/dri ]] || die 'A working AMD ROCm driver exposing /dev/kfd and /dev/dri is required; no driver will be installed.'
  fi
  # Never read .env or source configuration from the application/user directory as root.
  source /etc/os-release
  [[ "$ID" == ubuntu && "$VERSION_ID" =~ ^(22\.04|24\.04|26\.04)$ ]] \
    || die 'Automatic host setup supports Ubuntu 22.04, 24.04 and 26.04 only.'
  printf 'Preparing Ubuntu %s (%s); existing GPU drivers are preserved.\n' "$VERSION_ID" "$VERSION_CODENAME"
  apt-get update
  apt-get install -y ca-certificates curl gnupg python3 openssl
  WORK="$(mktemp -d)"
  trap 'if [[ -n "$WORK" ]]; then rm -rf -- "$WORK"; fi' EXIT
  if ! command -v docker >/dev/null; then
    for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
      if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
        die "Conflicting package $package exists. Resolve package ownership manually; nothing will be removed."
      fi
    done
    install -m 0755 -d /etc/apt/keyrings
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
      https://download.docker.com/linux/ubuntu/gpg -o "$WORK/docker.asc"
    install -m 0644 "$WORK/docker.asc" /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  docker_local info >/dev/null \
    || die 'The local Docker daemon is unavailable. Start it before rerunning host setup.'
  docker_local compose version >/dev/null \
    || die 'Install the Compose v2 plugin from the existing Docker package source, then rerun.'
  if [[ "$BACKEND" == cuda ]] && ! command -v nvidia-ctk >/dev/null; then
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
      https://nvidia.github.io/libnvidia-container/gpgkey -o "$WORK/nvidia-key"
    gpg --batch --yes --dearmor -o "$WORK/nvidia-key.gpg" "$WORK/nvidia-key"
    install -m 0644 "$WORK/nvidia-key.gpg" /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 120 \
      https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -o "$WORK/nvidia-repository"
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      "$WORK/nvidia-repository" > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
  fi
  if [[ "$BACKEND" == cuda ]]; then configure_runtime; fi
  printf '%s\n' 'Host preparation complete. Continue with sudo ./setup.sh install.'
}

main() {
  while (($#)); do
    case "$1" in
      --backend)
        (($# >= 2)) || die 'Missing backend for --backend.'
        [[ "$2" == cuda || "$2" == rocm ]] || die 'Backend must be cuda or rocm.'
        BACKEND="$2"; shift 2 ;;
      --allow-docker-restart) ALLOW_DOCKER_RESTART=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
  ((EUID == 0)) || die 'Run this host-only script as root. Run setup.sh separately as the normal user.'
  install_host
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
