#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMAND=install
PREBUILT_AGENT=1
AGENT_IMAGE_SET=0
IMAGE_MODE=""
INIT_ARGS=()
DOCKER=(docker --host unix:///var/run/docker.sock)

usage() {
  printf '%s\n' \
    'Usage: sudo ./setup.sh [install|init|doctor|start|stop|status|logs|test] [options]' \
    'Run setup-host.sh separately if Docker/NVIDIA prerequisites are missing.' \
    '  --prebuilt-agent    Use a local/published agent image (default; never build).' \
    '  --build-agent       Developer mode: build the agent from source instead.' \
    '  --agent-image REF   Agent image reference (initial setup; default published digest).' \
    '  --host HOST         Certificate DNS name/IP (initial setup only; default localhost).' \
    '  --bind IPV4         Listen address (initial setup only; default 127.0.0.1).' \
    '  --port PORT         HTTPS/WSS port (default 8766).' \
    '  --gpu INDEX_OR_UUID  Select ONE NVIDIA GPU (default 0).' \
    'Existing configuration, secrets and cached models are preserved.'
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    install|init|doctor|start|stop|status|logs|test) COMMAND="$1"; shift ;;
    --install-host-deps) die 'Run sudo ./setup-host.sh separately; setup.sh never elevates privileges.' ;;
    --prebuilt-agent|--build-agent)
      [[ -z "$IMAGE_MODE" || "$IMAGE_MODE" == "$1" ]] || die 'Choose only one agent image mode.'
      IMAGE_MODE="$1"
      if [[ "$1" == --build-agent ]]; then PREBUILT_AGENT=0; else PREBUILT_AGENT=1; fi
      shift ;;
    --host|--bind|--port|--gpu|--agent-image)
      (($# >= 2)) || die "Missing value for $1"
      if [[ "$1" == --agent-image ]]; then AGENT_IMAGE_SET=1; fi
      INIT_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
if [[ -n "$IMAGE_MODE" && "$COMMAND" != install ]]; then
  die 'Agent image modes apply only to install.'
fi
if ((!PREBUILT_AGENT && !AGENT_IMAGE_SET)); then INIT_ARGS+=(--agent-image borgvr-agent:3.9); fi
if [[ "$COMMAND" != install && "$COMMAND" != init ]] && ((${#INIT_ARGS[@]})); then
  die 'Host/bind/port/GPU options apply only to install/init. Edit existing .env deliberately.'
fi

choose_docker() {
  command -v docker >/dev/null || die 'Docker is missing. Run sudo ./setup-host.sh.'
  "${DOCKER[@]}" info >/dev/null 2>&1 \
    || die 'Cannot access the local Docker daemon. Run sudo ./setup.sh, and check that Docker is running.'
  "${DOCKER[@]}" compose version >/dev/null || die 'Docker Compose v2 plugin is required.'
}
compose() {
  "${DOCKER[@]}" compose --project-directory "$DIR" --env-file "$DIR/.env" -f "$DIR/compose.yaml" "$@"
}
check_gpu() {
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die 'The inference deployment targets Linux x86_64 with an NVIDIA GPU.'
  command -v nvidia-smi >/dev/null && nvidia-smi || die 'A working NVIDIA driver is required.'
  local gpu image
  gpu="$(python3 "$DIR/configure.py" get BORGVR_GPU)"
  image="$(python3 "$DIR/configure.py" get BORGVR_VLLM_IMAGE)"
  printf '%s\n' 'Checking CUDA in the pinned vLLM image. Its first download can be large.'
  "${DOCKER[@]}" run --rm --gpus "device=$gpu" --cap-drop ALL --security-opt no-new-privileges:true \
    --entrypoint python3 "$image" -c \
    'import torch; assert torch.cuda.is_available(), "CUDA unavailable"; x=torch.ones(1, device="cuda"); torch.cuda.synchronize(); print(torch.cuda.get_device_name(0), "CUDA", torch.version.cuda, "OK")' \
    || die 'GPU container check failed. Check driver compatibility with this image, Container Toolkit and GPU selection. No driver was changed.'
  compose config --quiet
}

command -v python3 >/dev/null || die 'Python 3 is missing. Run sudo ./setup-host.sh.'
command -v openssl >/dev/null || die 'OpenSSL is missing. Run sudo ./setup-host.sh.'
case "$COMMAND" in
  init) python3 "$DIR/configure.py" init ${INIT_ARGS[@]+"${INIT_ARGS[@]}"}; exit 0 ;;
  install) python3 "$DIR/configure.py" init ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} ;;
esac
[[ -f "$DIR/.env" ]] || die 'Run sudo ./setup.sh install first.'
choose_docker
case "$COMMAND" in
  install)
    # Probe the daemon's backing filesystem without reading privileged host directories.
    python_image="$(python3 "$DIR/configure.py" image python)"
    available_kib="$("${DOCKER[@]}" run --rm --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges:true --entrypoint python "$python_image" \
      -c 'import shutil; print(shutil.disk_usage("/").free // 1024)')"
    [[ "$available_kib" =~ ^[0-9]+$ ]] || die 'Could not determine free space in Docker storage.'
    ((available_kib >= 200 * 1024 * 1024)) || die 'Keep at least 200 GiB free in Docker storage for images, weights and build caches.'
    check_gpu
    if ((PREBUILT_AGENT)); then
      agent_image="$(python3 "$DIR/configure.py" get BORGVR_AGENT_IMAGE)"
      if ! "${DOCKER[@]}" image inspect "$agent_image" >/dev/null 2>&1; then
        [[ "$agent_image" != borgvr-agent:3.9 ]] \
          || die 'Load the trusted local image, or set BORGVR_AGENT_IMAGE in the existing .env to a published image.'
        compose pull agent
      fi
    else
      agent_image="$(python3 "$DIR/configure.py" get BORGVR_AGENT_IMAGE)"
      [[ "$agent_image" != *@* ]] || die 'Source builds need a writable image tag in .env, not a registry digest.'
      "${DOCKER[@]}" compose --project-directory "$DIR" --env-file "$DIR/.env" \
        -f "$DIR/compose.yaml" -f "$DIR/compose.build.yaml" build --pull agent
    fi
    compose up -d --no-build --pull never --wait --wait-timeout 3600
    printf '%s\n' 'Server is running. Run: sudo ./setup.sh test' \
      'The native BorgVR voice client is not connected yet; see README.md for the server test and protocol.' ;;
  doctor) check_gpu ;;
  start) compose up -d --no-build --pull never --wait --wait-timeout 3600 ;;
  stop) compose stop ;;
  status) compose ps ;;
  logs) compose logs --tail 100 -f ;;
  test)
    compose exec -T agent python client.py --url https://127.0.0.1:8766 \
      --ca /run/tls/server.crt --token-file /run/secrets/agent_token --smoke ;;
esac
