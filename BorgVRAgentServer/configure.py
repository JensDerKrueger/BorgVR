"""Non-destructive configuration and secret generation, including sudo installation."""

import argparse
import ipaddress
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
PYTHON_IMAGE = "python:3.12.15-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70"
VLLM_IMAGE = "vllm/vllm-openai:v0.34.0@sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1"
MODEL_REVISION = "345d467b117d1fd5eda9b879a5988de9ae5f47a7"
DEFAULT_AGENT_IMAGE = "ghcr.io/jensderkrueger/borgvr-agent@sha256:729d464bf75d8b2fbf67c0733875d08db5cd121d6a15db01ef3d6679b4c1e053"
AGENT_UID = AGENT_GID = 10001


def image_reference(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./:@+-]{0,511}", value):
        raise argparse.ArgumentTypeError("Expected a container image reference")
    return value


def set_agent_image(root, image):
    image_reference(image)
    env = root / ".env"
    if env.is_symlink() or not env.is_file() or env.stat().st_nlink != 1:
        raise ValueError("Expected a regular, private .env file")
    info, original = env.stat(), env.read_text()
    lines = original.splitlines(keepends=True)
    matches = [i for i, line in enumerate(lines) if line.partition("=")[0] == "BORGVR_AGENT_IMAGE"]
    if len(matches) != 1:
        raise ValueError("Expected exactly one BORGVR_AGENT_IMAGE entry in .env")
    if lines[matches[0]].partition("=")[2].strip() == image:
        print("Agent image reference unchanged.")
        return
    runtime = root / "runtime"
    if runtime.is_symlink() or not runtime.is_dir():
        raise ValueError("Expected a private runtime directory for the configuration backup")
    backup = None
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=runtime, prefix="env-before-update-", delete=False) as handle:
            backup = Path(handle.name)
            handle.write(original)
        lines[matches[0]] = "BORGVR_AGENT_IMAGE=" + image + "\n"
        with tempfile.NamedTemporaryFile(mode="w", dir=root, prefix=".env-update-", delete=False) as handle:
            temporary = Path(handle.name)
            if os.getuid() == 0:
                os.fchown(handle.fileno(), info.st_uid, info.st_gid)
            handle.write("".join(lines))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, env)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Previous configuration saved privately: {backup}")


def prepare_shared_token(root):
    gid = int(read_value("BORGVR_GID", root))
    directory = root / "runtime" / "secrets"
    if directory.is_symlink() or directory.parent.is_symlink():
        raise ValueError("Refusing symlinked secret directories")
    descriptor = os.open(directory / "vllm_token", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_gid != gid:
            raise ValueError("Internal token must be a regular private file owned by BORGVR_GID")
        # The two containers share this group; neither needs a DAC-bypass capability.
        os.fchmod(descriptor, 0o640)
    finally:
        os.close(descriptor)


def hostname(value):
    try:
        address = ipaddress.ip_address(value)
        if address.is_unspecified or address.is_multicast:
            raise argparse.ArgumentTypeError("Use a reachable host address, not a wildcard")
    except ValueError:
        if (len(value) > 253 or not value.isascii()
            or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                   for label in value.split("."))):
            raise argparse.ArgumentTypeError("Expected a hostname or IP address, not a URL")
    return value


def bind_address(value):
    try:
        ipaddress.IPv4Address(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use an explicit IPv4 listen address") from error
    return value


def create_configuration(root, host, bind, port, gpu, agent_image=DEFAULT_AGENT_IMAGE):
    env = root / ".env"
    if env.exists():
        prepare_shared_token(root)
        print("Existing .env retained; credentials and certificates were not changed.")
        return
    privileged = os.getuid() == 0
    uid, gid = (AGENT_UID, AGENT_GID) if privileged else (os.getuid(), os.getgid())
    runtime = root / "runtime"
    if runtime.exists():
        raise ValueError("runtime exists without .env. Inspect it manually; refusing to replace existing secrets.")
    vllm_token = os.environ.get("VLLM_BORGVR_API_KEY", secrets.token_urlsafe(48))
    if not re.fullmatch(r"[A-Za-z0-9_.-]{32,512}", vllm_token):
        raise ValueError("VLLM_BORGVR_API_KEY must contain 32..512 ASCII letters, digits, underscores, dots or hyphens")
    runtime.mkdir(mode=0o700)
    secret_dir, tls_dir = runtime / "secrets", runtime / "tls"
    secret_dir.mkdir(mode=0o700)
    tls_dir.mkdir(mode=0o700)
    for name in ("agent_token", "vllm_token"):
        path = secret_dir / name
        with open(path, "x", opener=lambda p, flags: os.open(p, flags, 0o600)) as handle:
            handle.write((vllm_token if name == "vllm_token" else secrets.token_urlsafe(48)) + "\n")
    try:
        address = ipaddress.ip_address(host)
        san = f"IP:{address}"
    except ValueError:
        san = f"DNS:{host}"
    san = ",".join(dict.fromkeys([san, "DNS:localhost", "IP:127.0.0.1"]))
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
        "-days", "365", "-subj", "/CN=BorgVR Agent",
        "-addext", f"subjectAltName={san}",
        "-addext", "basicConstraints=critical,CA:FALSE",
        "-addext", "extendedKeyUsage=serverAuth",
        "-keyout", str(tls_dir / "server.key"), "-out", str(tls_dir / "server.crt"),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (tls_dir / "server.key").chmod(0o600)
    if privileged:
        # Keep the container unprivileged while allowing access to its private mounts.
        for path in (secret_dir, tls_dir, secret_dir / "agent_token", secret_dir / "vllm_token",
                     tls_dir / "server.key", tls_dir / "server.crt"):
            os.chown(path, uid, gid)
    values = {
        "BORGVR_VLLM_IMAGE": VLLM_IMAGE,
        "BORGVR_AGENT_IMAGE": agent_image,
        "BORGVR_MODEL": "Qwen/Qwen3.6-35B-A3B",
        "BORGVR_MODEL_REVISION": MODEL_REVISION,
        "BORGVR_GPU": gpu,
        "BORGVR_CONTEXT_LENGTH": "16384",
        "BORGVR_GPU_MEMORY_FRACTION": "0.85",
        "BORGVR_UID": str(uid), "BORGVR_GID": str(gid),
        "BORGVR_BIND_ADDRESS": bind, "BORGVR_PORT": str(port),
    }
    with open(env, "x", opener=lambda p, flags: os.open(p, flags, 0o600)) as handle:
        handle.write("# Generated by configure.py. Never commit .env or runtime/.\n")
        for key, value in values.items():
            handle.write(f"{key}={value}\n")
    prepare_shared_token(root)
    print(f"Configuration created for https://{host}:{port}; listen address {bind}.")
    print("Agent token: runtime/secrets/agent_token (not printed). Certificate: runtime/tls/server.crt")


def read_value(name, root=ROOT):
    if not re.fullmatch(r"BORGVR_[A-Z_]+", name):
        raise ValueError("Invalid configuration key")
    for line in (root / ".env").read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and key == name:
            if not re.fullmatch(r"[A-Za-z0-9_./:@+-]+", value):
                raise ValueError("Configuration contains unsupported characters")
            return value
    if name == "BORGVR_AGENT_IMAGE":
        return DEFAULT_AGENT_IMAGE
    raise ValueError("Missing configuration value")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare-secrets")
    validate = sub.add_parser("validate-image")
    validate.add_argument("image", type=image_reference)
    update = sub.add_parser("set-agent-image")
    update.add_argument("image", type=image_reference)
    init = sub.add_parser("init")
    init.add_argument("--host", type=hostname, default="localhost")
    init.add_argument("--bind", type=bind_address, default="127.0.0.1")
    init.add_argument("--port", type=int, choices=range(1024, 65536), metavar="1024..65535", default=8766)
    init.add_argument("--gpu", default="0")
    init.add_argument("--agent-image", type=image_reference, default=DEFAULT_AGENT_IMAGE)
    get = sub.add_parser("get")
    get.add_argument("name")
    image = sub.add_parser("image")
    image.add_argument("name", choices=["python"])
    args = parser.parse_args()
    if args.command == "validate-image":
        return
    elif args.command == "set-agent-image":
        set_agent_image(ROOT, args.image)
    elif args.command == "prepare-secrets":
        prepare_shared_token(ROOT)
    elif args.command == "get":
        print(read_value(args.name))
    elif args.command == "image":
        print(PYTHON_IMAGE)
    else:
        if not re.fullmatch(r"[0-9]+|GPU-[A-Fa-f0-9-]+", args.gpu):
            parser.error("GPU must be an index or NVIDIA GPU UUID")
        create_configuration(ROOT, args.host, args.bind, args.port, args.gpu, args.agent_image)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
