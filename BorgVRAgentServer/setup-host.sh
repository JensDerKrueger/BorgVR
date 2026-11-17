#!/usr/bin/env bash
set -euo pipefail
DOCKER_USER=""
ALLOW_DOCKER_RESTART=0
WORK=""

usage() {
  printf '%s\n' \
    'Usage (root): ./setup-host.sh [--docker-user USER] [--allow-docker-restart]' \
    '  --docker-user USER       Explicitly grant an existing non-root user Docker access.' \
    '                           WARNING: membership in the docker group is root-equivalent.' \
    '  --allow-docker-restart   Permit NVIDIA runtime registration and a Docker restart.' \
    '                           Existing containers may be interrupted.' \
    'Ubuntu 22.04/24.04/26.04, Linux x86_64; a working NVIDIA driver is required.' \
    'No app checkout, model, credentials, certificates or user configuration is created.'
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
docker_local() { docker --host unix:///var/run/docker.sock "$@"; }

validate_docker_user() {
  [[ "$DOCKER_USER" =~ ^[a-z_][a-z0-9_.-]*\$?$ && ${#DOCKER_USER} -le 64 ]] \
    || die 'Expected an existing Linux login name for --docker-user.'
  local uid
  uid="$(id -u -- "$DOCKER_USER")" || die "User does not exist: $DOCKER_USER"
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != 0 ]] || die '--docker-user must name a non-root account.'
}

grant_docker_access() {
  [[ -n "$DOCKER_USER" ]] || return 0
  getent group docker >/dev/null || groupadd docker
  if ! id -nG -- "$DOCKER_USER" | tr ' ' '\n' | grep -Fxq docker; then
    printf 'Granting root-equivalent Docker access to %s.\n' "$DOCKER_USER"
    usermod -aG docker "$DOCKER_USER"
  fi
  printf 'Log out and back in as %s before running setup.sh.\n' "$DOCKER_USER"
}

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
  command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null \
    || die 'A working NVIDIA driver is required. No driver will be installed or replaced.'
  # Never read .env or source configuration from the application/user directory as root.
  source /etc/os-release
  [[ "$ID" == ubuntu && "$VERSION_ID" =~ ^(22\.04|24\.04|26\.04)$ ]] \
    || die 'Automatic host setup supports Ubuntu 22.04, 24.04 and 26.04 only.'
  [[ -z "$DOCKER_USER" ]] || validate_docker_user
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
  if ! command -v nvidia-ctk >/dev/null; then
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
  configure_runtime
  grant_docker_access
  printf '%s\n' 'Host preparation complete. Continue as the normal user with ./setup.sh install.'
}

main() {
  while (($#)); do
    case "$1" in
      --docker-user)
        (($# >= 2)) || die 'Missing login name for --docker-user.'
        DOCKER_USER="$2"; shift 2 ;;
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
