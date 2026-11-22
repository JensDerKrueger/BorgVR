"""Non-destructive configuration and secret generation, including sudo installation."""

import argparse
from contextlib import ExitStack
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import ssl
import stat
import subprocess
import tempfile

from model_config import CUDA_IMAGE, ROCM_IMAGE, PROFILES, ModelConfig, profile_values

ROOT = Path(__file__).resolve().parent
PYTHON_IMAGE = "python:3.12.15-slim-bookworm@sha256:6a0e06f5ba0b373d051aabd3fffb9b873f27f9a2a3a14bcbe37dee6f0e3bbc70"
VLLM_IMAGE = CUDA_IMAGE
DEFAULT_AGENT_IMAGE = "borgvr-agent:next"
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
        prepare_runtime_access(root)
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
    prepare_runtime_access(root)
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
    "max-seqs": "MAX_SEQS",
    "gpu-memory-fraction": "GPU_MEMORY_FRACTION", "min-free-gib": "MIN_FREE_GIB",
    "enforce-eager": "ENFORCE_EAGER", "cpu-offload-gb": "CPU_OFFLOAD_GB",
}
GPU_RUNTIME_OPTIONS = {
    "nccl-p2p-disable": "BORGVR_NCCL_P2P_DISABLE",
    "disable-custom-all-reduce": "BORGVR_DISABLE_CUSTOM_ALL_REDUCE",
}


def add_model_options(parser):
    parser.add_argument("--profile", choices=PROFILES)
    parser.add_argument("--backend", choices=("cuda", "rocm"))
    parser.add_argument("--vllm-image", type=image_reference)
    parser.add_argument("--gpu")
    parser.add_argument("--tensor-parallel-size")
    for name in GPU_RUNTIME_OPTIONS:
        parser.add_argument("--" + name, choices=("true", "false"))
    for name in MODEL_OPTIONS:
        parser.add_argument("--" + name)


def device_group(name):
    import grp
    try:
        return str(grp.getgrnam(name).gr_gid)
    except KeyError:
        return "0"


def gpu_groups(root):
    groups = [read_value(name, root) for name in ("BORGVR_GID", "BORGVR_RENDER_GID", "BORGVR_VIDEO_GID")]
    if any(not value.isdecimal() or int(value) > 2**32 - 2 for value in groups):
        raise ValueError("GPU groups must be numeric group IDs")
    return {"services": {"vllm": {"group_add": list(dict.fromkeys(str(int(value)) for value in groups))}}}


def validate_model_gpu(values):
    config = ModelConfig.from_env(values)
    if config.nccl_p2p_disable and values.get("BORGVR_BACKEND", "cuda") != "cuda":
        raise ValueError("--nccl-p2p-disable true requires --backend cuda")
    if config.tensor_parallel_size > 1 and (values.get("BORGVR_BACKEND", "cuda") != "cuda" or values.get("BORGVR_GPU", "0") != "all"):
        raise ValueError("Multi-GPU inference currently requires --backend cuda --gpu all. Select --tensor-parallel-size 1 for a single GPU or ROCm.")
    return config


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
    parallel = getattr(args, "tensor_parallel_size", None)
    if parallel is not None:
        values["BORGVR_TENSOR_PARALLEL_SIZE"] = parallel
    values.setdefault("BORGVR_TENSOR_PARALLEL_SIZE", "1")
    # Hardware workarounds must survive model profile changes.
    for name, key in GPU_RUNTIME_OPTIONS.items():
        value = getattr(args, name.replace("-", "_"), None)
        if value is not None:
            values[key] = value
        values.setdefault(key, "false")
    backend = args.backend or existing.get("BORGVR_BACKEND", "cuda")
    if backend not in ("cuda", "rocm"):
        raise ValueError("Backend must be cuda or rocm")
    gpu = args.gpu or existing.get("BORGVR_GPU", "0")
    if not re.fullmatch(r"[0-9]+|GPU-[A-Fa-f0-9-]+", gpu) and not (gpu == "all" and backend == "cuda"):
        raise ValueError("GPU must be an index or GPU UUID; only CUDA also accepts all")
    image = args.vllm_image or existing.get("BORGVR_VLLM_IMAGE", CUDA_IMAGE if backend == "cuda" else ROCM_IMAGE)
    if args.backend and backend != existing.get("BORGVR_BACKEND", "cuda") and not args.vllm_image:
        image = CUDA_IMAGE if backend == "cuda" else ROCM_IMAGE
    values.update(BORGVR_BACKEND=backend, BORGVR_VLLM_IMAGE=image_reference(image), BORGVR_GPU=gpu,
                  BORGVR_RENDER_GID=device_group("render"), BORGVR_VIDEO_GID=device_group("video"))
    values["BORGVR_TENSOR_PARALLEL_SIZE"] = str(validate_model_gpu(values).tensor_parallel_size)
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


def runtime_owner(info):
    # Retain the installer on later invocations, including a direct root login.
    if info.st_uid != 0:
        return info.st_uid, info.st_gid
    value = os.environ.get("SUDO_UID")
    if value is None or value == "0":
        return None
    if not value.isascii() or not value.isdecimal() or not 0 < int(value) < 2**32 - 1:
        raise ValueError("SUDO_UID must identify a non-root installer account")
    try:
        account = pwd.getpwuid(int(value))
    except KeyError as error:
        raise ValueError("SUDO_UID must identify an existing installer account") from error
    if os.environ.get("SUDO_USER", account.pw_name) != account.pw_name:
        raise ValueError("SUDO_USER does not match SUDO_UID")
    return account.pw_uid, account.pw_gid


def prepare_runtime_access(root):
    if os.getuid() != 0:
        return
    with ExitStack() as handles:
        def opened(path, flags, parent=None):
            descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            handles.callback(os.close, descriptor)
            return descriptor

        runtime = opened(root / "runtime", os.O_RDONLY | os.O_DIRECTORY)
        owner = runtime_owner(os.fstat(runtime))
        if owner is None:
            return  # A direct root installation without a sudo caller remains root-only.
        uid, gid = owner
        agent_gid = int(read_value("BORGVR_GID", root))
        if not 0 < agent_gid < 2**32 - 1:
            raise ValueError("BORGVR_GID must identify an unprivileged container group")
        records = []

        def inspect(descriptor, relative):
            info = os.fstat(descriptor)
            directory = stat.S_ISDIR(info.st_mode)
            if not directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
                raise ValueError("Runtime entries must be directories or regular, single-link files")
            if len(records) >= 1024 or len(relative) > 16:
                raise ValueError("Unexpectedly large runtime directory; inspect it before changing permissions")
            shared = relative in (("secrets",), ("tls",), ("secrets", "agent_token"),
                                  ("secrets", "vllm_token"), ("tls", "server.key"), ("tls", "server.crt"))
            mode = (0o750 if directory else 0o640) if shared else (0o700 if directory else 0o600)
            records.append((descriptor, agent_gid if shared else gid, mode))
            if directory:
                for name in os.listdir(descriptor):
                    inspect(opened(name, os.O_RDONLY, descriptor), (*relative, name))

        # Validate the whole tree first; descriptor-based changes never follow symlinks.
        inspect(runtime, ())
        for descriptor, group, mode in records:
            os.fchown(descriptor, uid, group)
            os.fchmod(descriptor, mode)


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


def certificate_matches(tls, host):
    # Use normal TLS hostname verification, but exchange bytes in memory, without sockets.
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(tls / "server.crt", tls / "server.key")
    client = ssl.create_default_context(cafile=str(tls / "server.crt"))
    client.verify_flags |= getattr(ssl, "VERIFY_X509_PARTIAL_CHAIN", 0)
    client_in, client_out, server_in, server_out = (ssl.MemoryBIO() for _ in range(4))
    peer = server.wrap_bio(server_in, server_out, server_side=True)
    connection = client.wrap_bio(client_in, client_out, server_hostname=host)
    for _ in range(8):
        try:
            connection.do_handshake()
            return True
        except ssl.SSLCertVerificationError:
            return False
        except ssl.SSLWantReadError:
            pass
        server_in.write(client_out.read())
        try:
            peer.do_handshake()
        except ssl.SSLWantReadError:
            pass
        client_in.write(server_out.read())
    raise ValueError("Could not verify the existing TLS certificate")


def install_changes(root, args):
    if not (root / ".env").exists():
        if (root / "runtime").exists():
            raise ValueError("runtime exists without .env; inspect the existing configuration first")
        return inference_values(args), False
    existing = read_configuration(root)
    changes = inference_values(args, existing)
    for name, key in (("bind", "BORGVR_BIND_ADDRESS"), ("port", "BORGVR_PORT")):
        value = getattr(args, name)
        if value is not None:
            changes[key] = str(value)
    for path in (root / ".env", root / "runtime", root / "runtime/tls",
                 root / "runtime/tls/server.crt", root / "runtime/tls/server.key"):
        if path.is_symlink() or not path.exists() or (path.is_file() and path.stat().st_nlink != 1):
            raise ValueError("Expected regular private configuration/TLS paths")
    renew = False
    if args.host is not None:
        renew = not certificate_matches(root / "runtime/tls", args.host)
    return changes, renew


def install_configuration(root, args):
    changes, renew = install_changes(root, args)
    if args.check:
        return
    if not (root / ".env").exists():
        create_configuration(root, args.host or "localhost", args.bind or "127.0.0.1", args.port or 8766,
                             args.gpu or "0", args.agent_image or DEFAULT_AGENT_IMAGE, changes)
        return
    prepare_shared_token(root)
    prepare_runtime_access(root)
    if not renew:
        write_configuration_changes(root, changes)
        return
    tls = root / "runtime/tls"
    backup = Path(tempfile.mkdtemp(prefix="tls-before-install-", dir=root / "runtime"))
    names = ("server.key", "server.crt")
    owners = {name: (tls / name).stat() for name in names}
    for name in names:
        shutil.copy2(tls / name, backup / name)
    # Generate the complete replacement before touching either live TLS file.
    with tempfile.TemporaryDirectory(prefix="tls-install-", dir=root / "runtime") as stage:
        stage = Path(stage)
        generate_certificate(stage, args.host)
        for name in names:
            (stage / name).chmod(stat.S_IMODE(owners[name].st_mode))
            if os.getuid() == 0:
                os.chown(stage / name, owners[name].st_uid, owners[name].st_gid)
        try:
            for name in names:
                os.replace(stage / name, tls / name)
            write_configuration_changes(root, changes)
        except Exception:
            for name in names:
                shutil.copy2(backup / name, tls / name)
                if os.getuid() == 0:
                    os.chown(tls / name, owners[name].st_uid, owners[name].st_gid)
            raise
    print(f"TLS certificate updated for {args.host}; clients must trust the new certificate. Backup: {backup}")
    prepare_runtime_access(root)


def generate_certificate(tls_dir, host):
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
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    (tls_dir / "server.key").chmod(0o600)


def create_configuration(root, host, bind, port, gpu, agent_image=DEFAULT_AGENT_IMAGE, inference=None):
    env = root / ".env"
    if env.exists():
        prepare_shared_token(root)
        prepare_runtime_access(root)
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
    generate_certificate(tls_dir, host)
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
        "BORGVR_TENSOR_PARALLEL_SIZE": "1",
        **{key: "false" for key in GPU_RUNTIME_OPTIONS.values()},
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
    prepare_runtime_access(root)
    print(f"Configuration created for https://{host}:{port}; listen address {bind}.")
    print("Agent token: runtime/secrets/agent_token (not printed). Certificate: runtime/tls/server.crt")


def read_value(name, root=ROOT):
    if not re.fullmatch(r"BORGVR_[A-Z][A-Z0-9_]*", name):
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
                "BORGVR_VIDEO_GID": device_group("video"), "BORGVR_TENSOR_PARALLEL_SIZE": "1",
                **{key: "false" for key in GPU_RUNTIME_OPTIONS.values()}}
    if name in defaults:
        return defaults[name]
    raise ValueError("Missing configuration value")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("prepare-secrets")
    sub.add_parser("validate-model")
    sub.add_parser("gpu-groups")
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
    install = sub.add_parser("install")
    install.add_argument("--host", type=hostname)
    install.add_argument("--bind", type=bind_address)
    install.add_argument("--port", type=int, choices=range(1024, 65536), metavar="1024..65535")
    install.add_argument("--agent-image", type=image_reference)
    install.add_argument("--check", action="store_true")
    add_model_options(install)
    get = sub.add_parser("get")
    get.add_argument("name")
    image = sub.add_parser("image")
    image.add_argument("name", choices=["python"])
    args = parser.parse_args()
    if args.command == "install":
        install_configuration(ROOT, args)
    elif args.command == "validate-model":
        validate_model_gpu(read_configuration(ROOT))
        gpu_groups(ROOT)
    elif args.command == "gpu-groups":
        print(json.dumps(gpu_groups(ROOT)))
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
        prepare_runtime_access(ROOT)
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
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error
