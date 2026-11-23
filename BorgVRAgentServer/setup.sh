#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/gpu-host.sh"
COMMAND=install
HAS_INIT_OPTIONS=0
INIT_ARGS=()
UNINSTALL_ARGS=()
MODEL_ARGS=()
OPEN_FIREWALL=0
FIREWALL_ZONE=""
DOCKER=(docker --host unix:///var/run/docker.sock)

usage() {
  printf '%s\n' \
    'Usage: sudo ./setup.sh [install|init|configure|model|profiles|doctor|start|stop|restart|update|status|logs|test|uninstall] [options]' \
    'Run setup-host.sh separately if Docker/GPU prerequisites are missing.' \
    '  --host HOST         Certificate DNS name/IP (install/init; initially localhost).' \
    '  --bind IPV4         Listen address (install/init; initially 127.0.0.1).' \
    '  --port PORT         HTTPS port (default 8766).' \
    '  --open-firewall     Explicitly add the model TCP-port exception in active UFW/firewalld.' \
    '                      Applies to install/start/restart/update; never enables a firewall.' \
    '  --firewall-zone Z   firewalld zone (default: its default zone); needs --open-firewall.' \
    '  --gpu INDEX_OR_UUID  Select one GPU (default 0; AMD also accepts an index).' \
    '                      CUDA also accepts all; WSL requires this explicit all-GPU access.' \
    '  --tensor-parallel-size N  Shard one model across N GPUs (1..8; default 1).' \
    '                      Multiple GPUs currently require --backend cuda --gpu all.' \
    '  --nccl-p2p-disable true|false  Disable NCCL direct GPU transfers (default false).' \
    '  --disable-custom-all-reduce true|false  Disable vLLM custom all-reduce (default false).' \
    '                      Hardware workarounds persist across model changes.' \
    '  --backend cuda|rocm  Select NVIDIA CUDA or AMD ROCm (install/init/configure).' \
    '  --profile NAME      Model preset; list with: ./setup.sh profiles.' \
    '  --model REPO --model-revision REV --tool-parser NAME  Custom image-capable model.' \
    '  --vllm-image REF --dtype auto|float16|bfloat16|float32 --quantization NAME' \
    '  --context-length N --max-seqs N --gpu-memory-fraction F' \
    '  --reasoning-parser NAME|none --thinking default|off|on --min-free-gib N' \
    '  --enforce-eager true|false --cpu-offload-gb N  Optional memory/performance controls.' \
    '  --attention-backend NAME  Override vLLM attention selection (default auto).' \
    'Update pulls configured images, checks access, starts services and tests the model.' \
    'Install recreates existing BorgVR containers without deleting images or model volumes.' \
    'Explicit install options update existing settings; omitted options and tokens are kept.' \
    'Model switch: sudo ./setup.sh model qwen35-4b (without a profile: list choices).' \
    'Uninstall previews by default; supports --yes, --remove-images, --remove-checkout, --files-only.' \
    'Changing --host may replace the TLS certificate; the old certificate is backed up.'

}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    install|init|configure|model|profiles|doctor|start|stop|restart|update|status|logs|test|uninstall) COMMAND="$1"; shift ;;
    --gpu|--tensor-parallel-size|--nccl-p2p-disable|--disable-custom-all-reduce|--backend|--profile|--model|--model-revision|--tool-parser|--reasoning-parser|--thinking|--dtype|--quantization|--context-length|--max-seqs|--gpu-memory-fraction|--min-free-gib|--enforce-eager|--cpu-offload-gb|--attention-backend|--vllm-image)
      (($# >= 2)) || die "Missing value for $1"
      MODEL_ARGS+=("$1" "$2"); shift 2 ;;
    --yes|--remove-images|--remove-checkout|--files-only) UNINSTALL_ARGS+=("$1"); shift ;;
    --open-firewall) OPEN_FIREWALL=1; shift ;;
    --firewall-zone)
      (($# >= 2)) || die 'Missing zone for --firewall-zone.'
      [[ "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || die 'Invalid firewalld zone.'
      FIREWALL_ZONE="$2"; shift 2 ;;
    --install-host-deps) die 'Run sudo ./setup-host.sh separately; setup.sh never elevates privileges.' ;;
    --host|--bind|--port)
      (($# >= 2)) || die "Missing value for $1"
      HAS_INIT_OPTIONS=1
      INIT_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ "$COMMAND" == model && "$1" != -* && ${#MODEL_ARGS[@]} == 0 ]]; then
        MODEL_ARGS+=(--profile "$1"); shift
      else die "Unknown argument: $1"; fi ;;
  esac
done
if [[ -e "$DIR/runtime/agent-development.json" || -L "$DIR/runtime/agent-development.json" ]]; then
  [[ "$COMMAND" == uninstall || "$COMMAND" == profiles ]] ||
    die 'Retire the old development installation with its previous checkout (dev disable --remove) before migrating.'
fi
if [[ -n "$FIREWALL_ZONE" ]] && ((!OPEN_FIREWALL)); then
  die '--firewall-zone requires --open-firewall.'
fi
if ((OPEN_FIREWALL)); then
  [[ "$COMMAND" == install || "$COMMAND" == start || "$COMMAND" == restart || "$COMMAND" == update ]] \
    || die '--open-firewall applies only to install/start/restart/update.'
  ((EUID == 0)) || die 'Run setup with sudo to use --open-firewall.'
fi
if ((${#UNINSTALL_ARGS[@]})) && [[ "$COMMAND" != uninstall ]]; then
  die 'Deletion options apply only to uninstall.'
fi
if ((${#MODEL_ARGS[@]})) && [[ "$COMMAND" != install && "$COMMAND" != init && "$COMMAND" != configure && "$COMMAND" != model ]]; then
  die 'Model options apply to install/init/configure/model.'
fi
if [[ "$COMMAND" == configure ]]; then
  ((HAS_INIT_OPTIONS == 0)) || die 'Change host/bind/port with install, not configure.'
elif [[ "$COMMAND" == update ]]; then
  ((HAS_INIT_OPTIONS == 0)) || die 'Change host/bind/port with install, not update.'
elif [[ "$COMMAND" != install && "$COMMAND" != init ]] && ((${#INIT_ARGS[@]})); then
  die 'Host/bind/port/GPU options apply only to install/init. Edit existing .env deliberately.'
fi

choose_docker() {
  command -v docker >/dev/null || die 'Docker is missing. Run sudo ./setup-host.sh.'
  "${DOCKER[@]}" info >/dev/null 2>&1 \
    || die 'Cannot access the local Docker daemon. Run sudo ./setup.sh, and check that Docker is running.'
  "${DOCKER[@]}" compose version >/dev/null || die 'Docker Compose v2 plugin is required.'
}
compose() {
  if [[ "$BACKEND" == rocm ]]; then
    "${DOCKER[@]}" compose --project-directory "$DIR" --env-file "$DIR/.env" \
      -f "$DIR/compose.yaml" -f "$DIR/compose.rocm.yaml" -f <(python3 "$DIR/configure.py" gpu-groups) "$@"
  elif [[ "$(python3 "$DIR/configure.py" get BORGVR_GPU)" == all ]]; then
    "${DOCKER[@]}" compose --project-directory "$DIR" --env-file "$DIR/.env" \
      -f "$DIR/compose.yaml" -f "$DIR/compose.cuda-all.yaml" "$@"
  else
    "${DOCKER[@]}" compose --project-directory "$DIR" --env-file "$DIR/.env" \
      -f "$DIR/compose.yaml" -f "$DIR/compose.cuda.yaml" "$@"
  fi
}
check_gpu() {
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die 'The inference deployment targets Linux x86_64 with an NVIDIA or AMD GPU.'
  local gpu image dtype parallel render_gid video_gid
  gpu="$(python3 "$DIR/configure.py" get BORGVR_GPU)"
  image="$(python3 "$DIR/configure.py" get BORGVR_VLLM_IMAGE)"
  dtype="$(python3 "$DIR/configure.py" get BORGVR_DTYPE)"
  parallel="$(python3 "$DIR/configure.py" get BORGVR_TENSOR_PARALLEL_SIZE)"
  GPU_ARGS=()
  if [[ "$BACKEND" == cuda ]]; then
    check_nvidia_driver || die 'A working NVIDIA driver is required (install the Windows driver when using WSL).'
    if is_wsl && [[ "$gpu" != all ]]; then
      die 'WSL cannot isolate a GPU by index. Explicitly select --gpu all with install/configure; all GPUs will be exposed.'
    fi
    if [[ "$gpu" == all ]]; then GPU_ARGS=(--gpus all); else GPU_ARGS=(--gpus "device=$gpu"); fi
  else
    if is_wsl; then die 'AMD/ROCm on WSL needs different device mappings and is not supported by this deployment.'; fi
    [[ -c /dev/kfd && -d /dev/dri ]] || die 'ROCm requires a working AMD driver exposing /dev/kfd and /dev/dri.'
    render_gid="$(python3 "$DIR/configure.py" get BORGVR_RENDER_GID)"
    video_gid="$(python3 "$DIR/configure.py" get BORGVR_VIDEO_GID)"
    GPU_ARGS=(--device /dev/kfd --device /dev/dri --group-add "$render_gid" --group-add "$video_gid" -e "ROCR_VISIBLE_DEVICES=$gpu")
  fi
  printf 'Checking %s in the configured vLLM image. Its first download can be large.\n' "$BACKEND"
  "${DOCKER[@]}" run --rm "${GPU_ARGS[@]}" --cap-drop ALL --security-opt no-new-privileges:true \
    -e "BORGVR_PROBE_DTYPE=$dtype" -e "BORGVR_PROBE_TENSOR_PARALLEL_SIZE=$parallel" --entrypoint python3 "$image" -c \
    'import os,torch
assert torch.cuda.is_available(), "GPU runtime unavailable"
parallel=int(os.environ["BORGVR_PROBE_TENSOR_PARALLEL_SIZE"])
available=torch.cuda.device_count()
assert available >= parallel, f"Tensor parallelism requires {parallel} GPUs, but only {available} are visible"
dtype=os.environ["BORGVR_PROBE_DTYPE"]
for index in range(parallel):
    x=torch.ones(1,device=f"cuda:{index}",dtype=getattr(torch,dtype) if dtype!="auto" else torch.float32)
    torch.cuda.synchronize(index)
    free,total=torch.cuda.mem_get_info(index)
    print("GPU",index,torch.cuda.get_device_name(index),"ROCm" if torch.version.hip else "CUDA",torch.version.hip or torch.version.cuda,"free/total GiB",round(free/2**30,1),round(total/2**30,1),"OK")
print("Tensor parallel size:",parallel,"visible GPUs:",available)' \
    || die 'GPU/dtype probe failed. Check driver, backend/image compatibility and selected GPU. Try float16 if bfloat16 is unsupported. No driver was changed.'
  compose config --quiet
}

check_service_secrets() {
  printf '%s\n' 'Checking private credentials with each service user and mount configuration.'
  compose run --rm --no-deps --entrypoint python3 vllm -c \
    'from pathlib import Path; assert len(Path("/run/secrets/vllm_token").read_text().strip()) >= 32' \
    || die 'vLLM cannot read its internal token. Check the secret file group and permissions.'
  compose run --rm --no-deps --entrypoint nginx model-gateway -t -c /etc/nginx/borgvr.conf
}

check_firewall() {
  local args=()
  if ((OPEN_FIREWALL)); then args+=(--open); fi
  if [[ -n "$FIREWALL_ZONE" ]]; then args+=(--zone "$FIREWALL_ZONE"); fi
  python3 "$DIR/firewall.py" ${args[@]+"${args[@]}"}
}
start_services() {
  compose up -d --remove-orphans --no-build --pull never --wait --wait-timeout 3600 || return $?
  check_firewall
}
test_server() {
  python3 "$DIR/check_model.py"

}

command -v python3 >/dev/null || die 'Python 3 is missing. Run sudo ./setup-host.sh.'
if [[ "$COMMAND" == profiles ]]; then exec python3 "$DIR/configure.py" profiles; fi
if [[ "$COMMAND" == model ]]; then
  if ((${#MODEL_ARGS[@]} == 0)); then
    if [[ -r "$DIR/.env" ]]; then
      printf 'Configured model: '; python3 "$DIR/configure.py" get BORGVR_MODEL
    elif [[ -f "$DIR/.env" ]]; then
      printf '%s\n' 'Run sudo ./setup.sh model to also inspect the private configuration.'
    fi
    exec python3 "$DIR/configure.py" profiles
  fi
  choose_docker
  python3 "$DIR/configure.py" configure "${MODEL_ARGS[@]}"
  COMMAND=update
fi
if [[ "$COMMAND" == configure ]]; then
  exec python3 "$DIR/configure.py" configure ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}
fi
if [[ "$COMMAND" == uninstall ]]; then
  exec python3 "$DIR/uninstall.py" ${UNINSTALL_ARGS[@]+"${UNINSTALL_ARGS[@]}"}
fi
command -v openssl >/dev/null || die 'OpenSSL is missing. Run sudo ./setup-host.sh.'
case "$COMMAND" in
  init) python3 "$DIR/configure.py" init ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}; exit 0 ;;
  install)
    python3 "$DIR/configure.py" install --check ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"}
    choose_docker
    if [[ -f "$DIR/.env" ]]; then
      BACKEND="$(python3 "$DIR/configure.py" get BORGVR_BACKEND)"
      [[ "$BACKEND" == cuda || "$BACKEND" == rocm ]] || die 'Backend must be cuda or rocm.'
      compose config --quiet
      printf '%s\n' 'Recreating BorgVR containers; model cache, images and access tokens are retained.'
      compose down --remove-orphans || die 'Could not remove existing BorgVR containers; configuration was not changed.'
    fi
    python3 "$DIR/configure.py" install ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} ;;
esac
[[ -f "$DIR/.env" ]] || die 'Run sudo ./setup.sh install first.'
if [[ "$COMMAND" == install || "$COMMAND" == start || "$COMMAND" == restart || "$COMMAND" == update || "$COMMAND" == doctor ]]; then
  python3 "$DIR/configure.py" validate-model
fi
BACKEND="$(python3 "$DIR/configure.py" get BORGVR_BACKEND)"
[[ "$BACKEND" == cuda || "$BACKEND" == rocm ]] || die 'Backend must be cuda or rocm.'
choose_docker
if [[ "$COMMAND" == start || "$COMMAND" == restart || "$COMMAND" == update ]]; then
  python3 "$DIR/configure.py" prepare-secrets
fi
case "$COMMAND" in
  install)
    # Probe the daemon's backing filesystem without reading privileged host directories.
    python_image="$(python3 "$DIR/configure.py" image python)"
    available_kib="$("${DOCKER[@]}" run --rm --network none --read-only --cap-drop ALL \
      --security-opt no-new-privileges:true --entrypoint python "$python_image" \
      -c 'import shutil; print(shutil.disk_usage("/").free // 1024)')"
    [[ "$available_kib" =~ ^[0-9]+$ ]] || die 'Could not determine free space in Docker storage.'
    min_free_gib="$(python3 "$DIR/configure.py" get BORGVR_MIN_FREE_GIB)"
    ((available_kib >= min_free_gib * 1024 * 1024)) || die "Keep at least $min_free_gib GiB free in Docker storage for this model profile (configurable)."
    check_gpu
    compose pull model-gateway
    check_service_secrets
    start_services
    test_server
    printf '%s\n' 'Server is running. Run: sudo ./setup.sh test' \
      'Configure Settings > AI Assistant in the native BorgVR app; see README.md for client setup.' ;;
  doctor) check_gpu; check_firewall ;;
  start|restart)
    check_service_secrets
    if [[ "$COMMAND" == restart ]]; then compose stop; fi
    start_services ;;
  update)
    compose config --quiet
    compose pull
    if [[ "$(python3 "$DIR/configure.py" get BORGVR_TENSOR_PARALLEL_SIZE)" != 1 ]]; then check_gpu; fi
    check_service_secrets
    start_services || die 'Update did not become healthy. Inspect setup.sh logs; configuration backups are in runtime/env-before-update-*.'
    test_server
    printf '%s\n' 'Update completed; the actual model answered successfully.' ;;
  stop) compose stop ;;
  status) compose ps; check_firewall ;;
  logs) compose logs --tail 100 -f ;;
  test) test_server ;;
esac
