#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
umask 077

state=.openai-test
compose() {
    sudo docker compose --env-file "$state/compose.env" -f compose.openai-test.yaml "$@"
}

case "${1:-}" in
    init)
        if [[ $(id -u) == 0 ]]; then
            printf '%s\n' 'Run this script as your normal user, without sudo.' >&2
            exit 1
        fi
        mkdir -p "$state/tls"
        if [[ ! -f "$state/compose.env" ]]; then
            printf 'BORGVR_TEST_UID=%s\nBORGVR_TEST_GID=%s\nBORGVR_OPENAI_MODEL=gpt-5.4-mini\n' \
                "$(id -u)" "$(id -g)" > "$state/compose.env"
        fi
        if [[ ! -s "$state/agent_token" ]]; then
            openssl rand -hex 32 > "$state/agent_token"
        fi
        if [[ ! -s "$state/tls/server.crt" || ! -s "$state/tls/server.key" ]]; then
            openssl req -x509 -newkey rsa:3072 -sha256 -days 365 -noenc \
                -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
                -addext 'basicConstraints=critical,CA:FALSE' \
                -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
                -addext 'extendedKeyUsage=serverAuth' \
                -keyout "$state/tls/server.key" -out "$state/tls/server.crt"
        fi
        printf 'OpenAI test instance initialized in %s/%s\n' "$PWD" "$state"
        ;;
    key)
        [[ -f "$state/compose.env" && -t 0 ]] || { printf '%s\n' 'Run init first; enter the key in an interactive terminal.' >&2; exit 1; }
        IFS= read -r -s -p 'OpenAI API key: ' key
        printf '\n'
        LC_ALL=C
        if [[ ${#key} -lt 32 || "$key" == *[![:graph:]]* ]]; then
            printf '%s\n' 'Invalid key; existing file left unchanged.' >&2
            exit 1
        fi
        tmp=$(mktemp "$state/.api-key.XXXXXXXX")
        trap 'rm -f -- "$tmp"' EXIT
        printf '%s\n' "$key" > "$tmp"
        mv -f -- "$tmp" "$state/openai_api_key"
        printf 'Key saved to %s/%s/openai_api_key (0600).\n' "$PWD" "$state"
        ;;
    start)
        [[ -s "$state/openai_api_key" ]] || { printf '%s\n' 'Run init and key first.' >&2; exit 1; }
        # Compose file-backed secrets mount the old inode after atomic key replacement.
        compose up -d --build --force-recreate --wait --wait-timeout 60 agent
        ;;
    test)
        compose exec -T agent python client.py --url https://127.0.0.1:8766 \
            --ca /run/tls/server.crt --token-file /run/secrets/agent_token --capabilities
        ;;
    stop)
        compose down
        ;;
    *)
        printf 'Usage: %s {init|key|start|test|stop}\n' "$0" >&2
        exit 2
        ;;
esac
