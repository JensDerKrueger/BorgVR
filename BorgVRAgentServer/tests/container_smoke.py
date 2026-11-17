"""Run the actual production image with TLS, without a GPU or a mocked success response."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import time

import httpx
from websockets.exceptions import InvalidStatus

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from client import DirectConnect
from configure import create_configuration


def docker(*args):
    return subprocess.run(["docker", *args], check=True, capture_output=True, text=True).stdout.strip()


async def check(url, certificate, token):
    context = ssl.create_default_context(cafile=str(certificate))
    context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    async with asyncio.timeout(30):
        async with httpx.AsyncClient(verify=context, timeout=2, trust_env=False, follow_redirects=False) as client:
            deadline = time.monotonic() + 20
            while True:
                try:
                    response = await client.get(url + "/healthz")
                    assert response.status_code == 200 and response.json() == {"status": "alive"}
                    break
                except httpx.TransportError:
                    if time.monotonic() >= deadline:
                        raise
                    await asyncio.sleep(0.2)
            assert (await client.get(url + "/readyz")).status_code == 401
            # No vLLM on this CPU build runner: do not pretend the model is ready.
            assert (await client.get(url + "/readyz", headers={"Authorization": "Bearer " + token})).status_code == 503
        endpoint = url.replace("https://", "wss://", 1) + "/v1/session"
        try:
            async with DirectConnect(endpoint, ssl=context, proxy=None, open_timeout=3):
                raise AssertionError("Unauthenticated WebSocket was accepted")
        except InvalidStatus as error:
            assert error.response.status_code == 403
        async with DirectConnect(endpoint, ssl=context, proxy=None, open_timeout=3,
                                 additional_headers={"Authorization": "Bearer " + token}) as socket:
            await socket.send(json.dumps({"type": "hello", "protocol": 1, "dataset_id": "container-test",
                                          "context_id": "test-opening", "tools": []}))
            assert json.loads(await socket.recv())["type"] == "ready"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    info = json.loads(docker("image", "inspect", args.image))[0]
    assert info["Architecture"] == "amd64" and info["Os"] == "linux"
    assert info["Config"]["User"] == "10001:10001"
    container = None
    with tempfile.TemporaryDirectory(prefix="borgvr-container-") as directory:
        root = Path(directory)
        create_configuration(root, "localhost", "127.0.0.1", 8766, "0")
        runtime = root / "runtime"
        try:
            container = docker(
                "run", "-d", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                "--tmpfs", "/tmp:size=64m,noexec,nosuid", "--memory", "512m", "--pids-limit", "128",
                "--user", f"{os.getuid()}:{os.getgid()}", "-p", "127.0.0.1::8766",
                "-e", "BORGVR_VLLM_URL=http://127.0.0.1:9/v1",
                "-v", f"{runtime / 'secrets'}:/run/secrets:ro", "-v", f"{runtime / 'tls'}:/run/tls:ro", args.image,
            )
            port = docker("port", container, "8766/tcp").split(":")[-1]
            asyncio.run(check(f"https://127.0.0.1:{port}", runtime / "tls/server.crt",
                              (runtime / "secrets/agent_token").read_text().strip()))
            docker("exec", container, "python", "-c",
                   "from pathlib import Path; assert not Path('/app/runtime').exists(); assert not Path('/app/.env').exists(); assert Path('/app/LICENSE').exists()")
            print("Production container TLS/auth/startup checks passed; no GPU/model inference was attempted.")
        finally:
            if container:
                docker("rm", "-f", container)


if __name__ == "__main__":
    main()
