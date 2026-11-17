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
import yaml
from websockets.exceptions import InvalidStatus

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from client import DirectConnect
from configure import AGENT_UID, AGENT_GID, create_configuration
from uninstall import Docker, PROJECT, LABEL, docker_plan, apply_plan


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
    compose = yaml.safe_load((Path(__file__).resolve().parents[1] / "compose.yaml").read_text())
    tmpfs_args = [arg for mount in compose["services"]["agent"]["tmpfs"] for arg in ("--tmpfs", mount)]
    container = None
    protected_container = None
    probe_created = False
    probe_image = "borgvr-uninstall-probe:ci"
    volume_created = network_created = False
    with tempfile.TemporaryDirectory(prefix="borgvr-container-") as directory:
        root = Path(directory)
        create_configuration(root, "localhost", "127.0.0.1", 8766, "0")
        runtime = root / "runtime"
        try:
            assert not docker("ps", "-aq", "--filter", f"label={LABEL}={PROJECT}"), "A BorgVR deployment already exists; refusing the test"
            assert not docker("volume", "ls", "-q", "--filter", "name=borgvr-ai_model-cache"), "Model volume already exists"
            assert not docker("network", "ls", "-q", "--filter", "name=borgvr-ai_default"), "Network already exists"
            assert not docker("image", "ls", "-q", "--filter", "reference=" + probe_image), "Probe image already exists"
            docker("volume", "create", "--label", f"{LABEL}={PROJECT}", "borgvr-ai_model-cache")
            volume_created = True
            docker("network", "create", "--label", f"{LABEL}={PROJECT}", "borgvr-ai_default")
            network_created = True
            container = docker(
                "run", "-d", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
                *tmpfs_args, "--memory", "512m", "--pids-limit", "128",
                "--user", f"{AGENT_UID}:{AGENT_GID}" if os.getuid() == 0 else f"{os.getuid()}:{os.getgid()}",
                "-p", "127.0.0.1::8766",
                "--label", f"{LABEL}={PROJECT}", "--label", f"com.docker.compose.project.working_dir={root}",
                "--network", "borgvr-ai_default", "-v", "borgvr-ai_model-cache:/test-model-cache:ro",
                "-e", "BORGVR_VLLM_URL=http://127.0.0.1:9/v1",
                "-v", f"{runtime / 'secrets'}:/run/secrets:ro", "-v", f"{runtime / 'tls'}:/run/tls:ro", args.image,
            )
            port = docker("port", container, "8766/tcp").split(":")[-1]
            asyncio.run(check(f"https://127.0.0.1:{port}", runtime / "tls/server.crt",
                              (runtime / "secrets/agent_token").read_text().strip()))
            docker("exec", container, "python", "-c",
                   "from pathlib import Path; assert not Path('/app/runtime').exists(); assert not Path('/app/.env').exists(); assert Path('/app/LICENSE').exists()")
            client = Docker()
            plan = docker_plan(root, client, remove_images=False)
            assert plan["containers"] == [container] and plan["volumes"] == ["borgvr-ai_model-cache"]
            apply_plan(root, client, plan)
            container = None
            volume_created = network_created = False
            assert not (root / "runtime").exists() and not (root / ".env").exists()
            assert not docker("ps", "-aq", "--filter", f"label={LABEL}={PROJECT}")
            assert not docker("volume", "ls", "-q", "--filter", "name=borgvr-ai_model-cache")
            assert not docker("network", "ls", "-q", "--filter", "name=borgvr-ai_default")
            # A container outside the project must protect the real image from deletion.
            protected_container = docker("create", "--network", "none", args.image)
            subprocess.run(["docker", "buildx", "build", "--load", "--network", "none", "--tag", probe_image,
                            "--file", "-", str(root)], input='FROM scratch\nLABEL org.opencontainers.image.source="https://github.com/JensDerKrueger/BorgVR"\nCMD ["unused"]\n',
                           check=True, capture_output=True, text=True)
            probe_created = True
            (root / ".env").write_text("BORGVR_AGENT_IMAGE=" + probe_image + "\n")
            image_plan = docker_plan(root, client, remove_images=True)
            assert image_plan["images"] == [probe_image]
            assert args.image in image_plan["shared_images_retained"]
            apply_plan(root, client, image_plan)
            probe_created = False
            assert not docker("image", "ls", "-q", "--filter", "reference=" + probe_image)
            docker("image", "inspect", args.image)
            print("Production TLS/auth/startup and isolated uninstaller checks passed; no GPU/model inference was attempted.")
        finally:
            if container:
                subprocess.run(["docker", "rm", "-f", container], capture_output=True)
            if volume_created:
                subprocess.run(["docker", "volume", "rm", "borgvr-ai_model-cache"], capture_output=True)
            if network_created:
                subprocess.run(["docker", "network", "rm", "borgvr-ai_default"], capture_output=True)
            if protected_container:
                subprocess.run(["docker", "rm", "-f", protected_container], capture_output=True)
            if probe_created:
                subprocess.run(["docker", "image", "rm", probe_image], capture_output=True)


if __name__ == "__main__":
    main()
