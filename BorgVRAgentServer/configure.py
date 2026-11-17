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

from model_config import CUDA_IMAGE, ROCM_IMAGE, PROFILES, ModelConfig, profile_values

ROOT = Path(__file__).resolve().parent
PYTHON_IMAGE = "python:3.12.15-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70"
VLLM_IMAGE = CUDA_IMAGE
DEFAULT_AGENT_IMAGE = "ghcr.io/jensderkrueger/borgvr-agent:3.9.1"
AGENT_UID = AGENT_GID = 10001


def image_reference(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./:@+-]{0,511}", value):
        raise argparse.ArgumentTypeError("Expected a container image reference")
    return value


def write_configuration_changes(root, changes):
    env = root / ".env"
    if env.is_symlink() or not env.is_file() or env.stat().st_nlink != 1:
        raise ValueError("Expected a regular, private .env file")
    info, original = env.stat(), env.read_text()
    lines = original.splitlines(keepends=True)
    for key, value in changes.items():
        matches = [i for i, line in enumerate(lines) if line.partition("=")[0] == key]
        if len(matches) > 1:
            raise ValueError("Duplicate configuration entry: " + key)
        if matches:
            lines[matches[0]] = key + "=" + value + "\n"
        else:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(key + "=" + value + "\n")
    updated = "".join(lines)
    if updated == original:
        print("Configuration values unchanged.")
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
        with tempfile.NamedTemporaryFile(mode="w", dir=root, prefix=".env-update-", delete=False) as handle:
            temporary = Path(handle.name)
            if os.getuid() == 0:
                os.fchown(handle.fileno(), info.st_uid, info.st_gid)
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, env)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Previous configuration saved privately: {backup}")


def set_agent_image(root, image):
    write_configuration_changes(root, {"BORGVR_AGENT_IMAGE": image_reference(image)})


def read_configuration(root):
    env = root / ".env"
    if env.is_symlink() or not env.is_file():
        raise ValueError("Expected a regular .env file")
    result = {}
    for line in env.read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator and key.startswith("BORGVR_"):
            if key in result:
                raise ValueError("Duplicate configuration entry: " + key)
            result[key] = value
    return result


MODEL_OPTIONS = {
    "model": "MODEL", "model-revision": "MODEL_REVISION", "tool-parser": "TOOL_PARSER",
    "reasoning-parser": "REASONING_PARSER", "thinking": "THINKING_MODE",
    "dtype": "DTYPE", "quantization": "QUANTIZATION", "context-length": "CONTEXT_LENGTH",
    "max-seqs": "MAX_SEQS", "max-output-tokens": "MAX_OUTPUT_TOKENS",
    "gpu-memory-fraction": "GPU_MEMORY_FRACTION", "min-free-gib": "MIN_FREE_GIB",
    "enforce-eager": "ENFORCE_EAGER", "cpu-offload-gb": "CPU_OFFLOAD_GB",
}


def add_model_options(parser):
    parser.add_argument("--profile", choices=PROFILES)
    parser.add_argument("--backend", choices=("cuda", "rocm"))
    parser.add_argument("--vllm-image", type=image_reference)
    parser.add_argument("--gpu")
    for name in MODEL_OPTIONS:
        parser.add_argument("--" + name)


def device_group(name):
    import grp
    try:
        return str(grp.getgrnam(name).gr_gid)
    except KeyError:
        return "0"


def inference_values(args, existing=None):
    existing = existing or {}
    profile = args.profile
    if args.model and args.model != existing.get("BORGVR_MODEL", PROFILES["qwen36-35b"]["MODEL"]):
        if not profile:
            profile = next((name for name, item in PROFILES.items() if item["MODEL"] == args.model), "custom")
        if profile == "custom" and not args.model_revision:
            raise ValueError("A different custom model needs --model-revision; the previous model's commit is not reusable")
    values = {**profile_values("qwen36-35b"), **existing}
    if profile:
        values.update(profile_values(profile))
    for name, key in MODEL_OPTIONS.items():
        value = getattr(args, name.replace("-", "_"))
        if value is not None:
            values["BORGVR_" + key] = value
    ModelConfig.from_env(values)
    backend = args.backend or existing.get("BORGVR_BACKEND", "cuda")
    if backend not in ("cuda", "rocm"):
        raise ValueError("Backend must be cuda or rocm")
    gpu = args.gpu or existing.get("BORGVR_GPU", "0")
    if not re.fullmatch(r"[0-9]+|GPU-[A-Fa-f0-9-]+", gpu):
        raise ValueError("GPU must be an index or GPU UUID")
    image = args.vllm_image or existing.get("BORGVR_VLLM_IMAGE", CUDA_IMAGE if backend == "cuda" else ROCM_IMAGE)
    if args.backend and backend != existing.get("BORGVR_BACKEND", "cuda") and not args.vllm_image:
        image = CUDA_IMAGE if backend == "cuda" else ROCM_IMAGE
    values.update(BORGVR_BACKEND=backend, BORGVR_VLLM_IMAGE=image_reference(image), BORGVR_GPU=gpu,
                  BORGVR_RENDER_GID=device_group("render"), BORGVR_VIDEO_GID=device_group("video"))
    if args.agent_image:
        values["BORGVR_AGENT_IMAGE"] = image_reference(args.agent_image)
    return {key: value for key, value in values.items() if key not in existing or existing[key] != value}


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


def create_configuration(root, host, bind, port, gpu, agent_image=DEFAULT_AGENT_IMAGE, inference=None):
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
        **profile_values("qwen36-35b"),
        "BORGVR_BACKEND": "cuda", "BORGVR_RENDER_GID": device_group("render"),
        "BORGVR_VIDEO_GID": device_group("video"),
        "BORGVR_GPU": gpu,
        "BORGVR_CONTEXT_LENGTH": "16384",
        "BORGVR_GPU_MEMORY_FRACTION": "0.85",
        "BORGVR_UID": str(uid), "BORGVR_GID": str(gid),
        "BORGVR_BIND_ADDRESS": bind, "BORGVR_PORT": str(port),
        **(inference or {}),
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
    configuration = read_configuration(root)
    for key, value in configuration.items():
        if key == name:
            if not re.fullmatch(r"[A-Za-z0-9_./:@+-]+", value):
                raise ValueError("Configuration contains unsupported characters")
            return value
    if name == "BORGVR_AGENT_IMAGE":
        return DEFAULT_AGENT_IMAGE
    defaults = {**profile_values(next((key for key, item in PROFILES.items()
                                       if item["MODEL"] == configuration.get("BORGVR_MODEL")), "qwen36-35b")),
                "BORGVR_BACKEND": "cuda", "BORGVR_RENDER_GID": device_group("render"),
                "BORGVR_VIDEO_GID": device_group("video")}
    if name in defaults:
        return defaults[name]
    raise ValueError("Missing configuration value")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare-secrets")
    sub.add_parser("validate-model")
    sub.add_parser("profiles")
    change = sub.add_parser("configure")
    change.add_argument("--agent-image", type=image_reference)
    add_model_options(change)
    validate = sub.add_parser("validate-image")
    validate.add_argument("image", type=image_reference)
    update = sub.add_parser("set-agent-image")
    update.add_argument("image", type=image_reference)
    init = sub.add_parser("init")
    init.add_argument("--host", type=hostname, default="localhost")
    init.add_argument("--bind", type=bind_address, default="127.0.0.1")
    init.add_argument("--port", type=int, choices=range(1024, 65536), metavar="1024..65535", default=8766)
    add_model_options(init)
    init.add_argument("--agent-image", type=image_reference, default=DEFAULT_AGENT_IMAGE)
    get = sub.add_parser("get")
    get.add_argument("name")
    image = sub.add_parser("image")
    image.add_argument("name", choices=["python"])
    args = parser.parse_args()
    if args.command == "validate-model":
        ModelConfig.from_env(read_configuration(ROOT))
    elif args.command == "profiles":
        for name, values in PROFILES.items():
            print(f"{name}: {values['MODEL'] or 'explicit model/revision/parser required'}; context {values['CONTEXT_LENGTH']}; disk reserve {values['MIN_FREE_GIB']} GiB")
    elif args.command == "configure":
        write_configuration_changes(ROOT, inference_values(args, read_configuration(ROOT)))
    elif args.command == "validate-image":
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
        inference = inference_values(args)
        create_configuration(ROOT, args.host, args.bind, args.port, args.gpu or "0", args.agent_image, inference)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
