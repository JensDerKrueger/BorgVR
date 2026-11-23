#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOCKER=(docker --host unix:///var/run/docker.sock)
OLD=borgvr-ai-agent-1
VLLM=borgvr-ai-vllm-1
GATEWAY=borgvr-ai-model-gateway-1

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 && $EUID == 0 ]] || die 'Usage: sudo bash ./migrate-endpoint.sh'
[[ -f "$DIR/.env" ]] || die 'Run inside the existing BorgVR deployment directory.'
[[ ! -e "$DIR/runtime/agent-development.json" && ! -L "$DIR/runtime/agent-development.json" ]] ||
  die 'Disable the old SSH development mode from the previous checkout before migrating.'

compose() {
  "${DOCKER[@]}" compose --project-directory "$DIR" --env-file "$DIR/.env" -f "$DIR/compose.yaml" "$@"
}

verify_owner() {
  local owner
  owner="$("${DOCKER[@]}" inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1")"
  [[ "$(cd -- "$owner" && pwd -P)" == "$(cd -- "$DIR" && pwd -P)" ]] ||
    die "Container $1 does not belong to this deployment directory."
}

model_state() {
  "${DOCKER[@]}" inspect --format '{{.Id}}/{{.State.StartedAt}}/{{.RestartCount}}' "$VLLM"
}

verify_owner "$VLLM"
before="$(model_state)"
[[ "$("${DOCKER[@]}" inspect --format '{{.State.Health.Status}}' "$VLLM")" == healthy ]] || die 'vLLM must be running and healthy.'
if "${DOCKER[@]}" inspect "$GATEWAY" >/dev/null 2>&1; then
  verify_owner "$GATEWAY"
  python3 "$DIR/check_model.py"
  exit 0
fi
verify_owner "$OLD"
[[ "$("${DOCKER[@]}" inspect --format '{{.State.Running}}' "$OLD")" == true ]] || die 'The old agent must still be running for rollback.'
compose config --quiet
compose pull model-gateway
compose run --rm --no-deps --entrypoint nginx model-gateway -t -c /etc/nginx/borgvr.conf

armed=0
rollback() {
  local code=$?
  trap - EXIT
  if ((armed)); then
    printf '%s\n' 'Cutover failed; restoring the previous agent on the original port.' >&2
    compose rm --stop --force model-gateway >&2 || true
    "${DOCKER[@]}" start "$OLD" >&2 || printf '%s\n' 'Could not restore the previous agent; inspect the port and container.' >&2
  fi
  exit "$code"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
armed=1
"${DOCKER[@]}" stop "$OLD"
compose up -d --no-deps --no-build --pull never --wait --wait-timeout 90 model-gateway
python3 "$DIR/check_model.py"
[[ "$(model_state)" == "$before" ]] || die 'The vLLM container changed during cutover.'
armed=0
printf '%s\n' 'The original HTTPS port now serves vLLM. vLLM was not restarted.' \
  'The previous agent remains stopped for rollback. Import runtime/secrets/vllm_token in BorgVR.'
