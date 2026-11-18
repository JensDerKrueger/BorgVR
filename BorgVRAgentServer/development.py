#!/usr/bin/python3 -I
"""Opt-in source deployments; SSH never executes uploaded Python on the host."""

import argparse
import base64
import fcntl
from contextlib import contextmanager, suppress
import grp
import hashlib
import io
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import shutil
import signal
import ssl
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parent
DEV_ROOT = Path("/var/lib/borgvr-agent-dev")
HELPER = Path("/usr/local/libexec/borgvr-agent-development.py")
ACCOUNT = "borgvr-agent-dev"
MARKER = "agent-development.json"
MAX_ARCHIVE = 4 * 1024 * 1024
MAX_SOURCE = 2 * 1024 * 1024
MAX_FILES = 128
TOP_FILES = {"client.py", "model_config.py", "requirements.txt"}
REQUIRED = TOP_FILES | {"borgvr_agent/__init__.py", "borgvr_agent/app.py", "borgvr_agent/protocol.py"}
UVICORN = ["-m", "uvicorn", "borgvr_agent.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8766",
           "--ssl-certfile", "/run/tls/server.crt", "--ssl-keyfile", "/run/tls/server.key", "--ws", "websockets-sansio",
           "--ws-max-size", "4194304", "--ws-ping-interval", "20", "--ws-ping-timeout", "20",
           "--timeout-keep-alive", "5", "--no-access-log", "--no-proxy-headers"]


def read_file(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError("Expected a bounded, regular single-link file: " + str(path))
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("File exceeds its limit")
        return data


def atomic_file(path, data, mode=0o660):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".dev-", delete=False) as stream:
        temp = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temp, path)
        finally:
            temp.unlink(missing_ok=True)


def write_json(path, value, mode=0o660):
    atomic_file(path, json.dumps(value, sort_keys=True).encode(), mode)


def read_json(path):
    value = json.loads(read_file(path, 65536))
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    return value


def source_name(name):
    return name in TOP_FILES or (len(name) <= 240 and len(name.split("/")) <= 8 and
        re.fullmatch(r"borgvr_agent/(?:[A-Za-z_][A-Za-z0-9_]*/)*[A-Za-z_][A-Za-z0-9_]*\.py", name) is not None)


def unpack_source(data, requirements_sha):
    if len(data) > MAX_ARCHIVE:
        raise ValueError("Source archive exceeds 4 MiB")
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as archive:
        for member in archive:
            if (len(files) >= MAX_FILES or not member.isfile() or member.issparse() or
                member.pax_headers or not source_name(member.name) or member.name in files or
                not 0 <= member.size <= 512 * 1024):
                raise ValueError("Invalid, linked, duplicate or unexpected source archive entry")
            files[member.name] = archive.extractfile(member).read()
            if sum(map(len, files.values())) > MAX_SOURCE:
                raise ValueError("Source exceeds 2 MiB")
            text = files[member.name].decode("utf-8")
            if "\0" in text:
                raise ValueError("Source must be UTF-8 text without NUL bytes")
    if not REQUIRED <= files.keys():
        raise ValueError("Incomplete agent source archive")
    if hashlib.sha256(files["requirements.txt"]).hexdigest() != requirements_sha:
        raise ValueError("Dependencies differ from the installed image. Build/update an image before enabling this source.")
    return files


def bundle_source(root):
    paths = [root / name for name in sorted(TOP_FILES)] + sorted((root / "borgvr_agent").rglob("*.py"))
    if len(paths) > MAX_FILES or (root / "borgvr_agent").is_symlink():
        raise ValueError("Unexpected source tree")
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for path in paths:
            name = path.relative_to(root).as_posix()
            if not source_name(name) or any(parent.is_symlink() for parent in path.parents if parent != root.parent):
                raise ValueError("Unexpected or symlinked source path")
            data = read_file(path, 512 * 1024)
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o644
            archive.addfile(entry, io.BytesIO(data))
    data = output.getvalue()
    unpack_source(data, hashlib.sha256(read_file(root / "requirements.txt", 65536)).hexdigest())
    return data


def installation():
    # This directory and manifest are administrator-owned, never writable by the SSH account.
    for path in (DEV_ROOT.parent, DEV_ROOT, DEV_ROOT / "installation.json"):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("Development installation is not administrator-owned")
    return read_json(DEV_ROOT / "installation.json")


def admin_directory(path):
    for directory in (path, *path.parents):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("Development helper paths must be administrator-owned directories without writable ancestors")


def expected_account(record):
    account = pwd.getpwnam(ACCOUNT)
    if (account.pw_uid != record["uid"] or account.pw_gid != record["gid"] or
        account.pw_dir != str(DEV_ROOT / "home") or account.pw_uid == 0 or
        set(os.getgrouplist(ACCOUNT, account.pw_gid)) != {account.pw_gid}):
        raise ValueError("Development account identity or groups changed")
    return account


def wait_ready(control, identifier, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            state = read_json(control / "status.json")
        except FileNotFoundError:
            state = {}
        if state.get("request") == identifier:
            if state.get("phase") == "ready":
                return state
            if state.get("phase") == "failed":
                raise ValueError("Development agent failed to start. Inspect dev logs; dependencies were not installed.")
        time.sleep(0.2)
    raise ValueError("Agent reload deadline exceeded. Inspect dev status/logs before retrying; do not repeat visualization commands.")


def request_reload(control, release):
    identifier = uuid.uuid4().hex
    write_json(control / "request.json", {"request": identifier, "release": release})
    return identifier


@contextmanager
def deployment_lock(control):
    fd = os.open(control / "deploy.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o660)
    with os.fdopen(fd, "w") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Invalid development lock")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def stage_source(data, record, *, wait=True):
    files = unpack_source(data, record["requirements_sha256"])
    releases, control = DEV_ROOT / "releases", DEV_ROOT / "control"
    with deployment_lock(control):
        protected = set()
        for name in ("request.json", "status.json"):
            with suppress(FileNotFoundError):
                protected.add(read_json(control / name).get("release"))
        release = uuid.uuid4().hex
        directory = releases / release
        directory.mkdir(mode=0o750)
        for name, content in files.items():
            target = directory / name
            target.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
            atomic_file(target, content, 0o640)
        source_sha = hashlib.sha256(data).hexdigest()
        write_json(directory / "source.json", {"sha256": source_sha}, 0o640)
        old = sorted((p for p in releases.iterdir() if p.is_dir() and not p.is_symlink() and
                      re.fullmatch(r"[a-f0-9]{32}", p.name)), key=lambda p: p.stat().st_mtime, reverse=True)
        for path in old[3:]:
            if path.name not in protected and path.name != release:
                shutil.rmtree(path)
        identifier = request_reload(control, release)
        if wait:
            state = wait_ready(control, identifier)
            return state
        return {"request": identifier, "release": release, "sha256": source_sha}


def receive_archive(stream, timeout=30):
    try:
        fd = stream.fileno()
    except (AttributeError, io.UnsupportedOperation):
        return stream.read(MAX_ARCHIVE + 1)  # In-memory test streams only.
    if stat.S_ISREG(os.fstat(fd).st_mode):
        return stream.read(MAX_ARCHIVE + 1)
    data, deadline = bytearray(), time.monotonic() + timeout
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_READ)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not selector.select(min(10, remaining)):
                raise ValueError("Source upload receive deadline/inactivity limit exceeded")
            chunk = os.read(fd, 65536)
            if not chunk:
                return bytes(data)
            data.extend(chunk)
            if len(data) > MAX_ARCHIVE:
                raise ValueError("Source archive exceeds 4 MiB")


def ssh_command(command, stdin=None):
    if command not in {"deploy", "status", "logs", "restart"}:
        raise ValueError("Only deploy, status, logs and restart are allowed; shell, SFTP and forwarding are disabled.")
    record = installation()
    account = expected_account(record)
    if os.getuid() != account.pw_uid or not record.get("enabled"):
        raise ValueError("Development access is disabled or this is not the development account")
    control = DEV_ROOT / "control"
    if command == "deploy":
        data = receive_archive(stdin or sys.stdin.buffer)
        print(json.dumps(stage_source(data, record)))
    elif command == "status":
        print(json.dumps(read_json(control / "status.json")))
    elif command == "logs":
        data = read_file(control / "agent.log", 1024 * 1024)
        print(data[-65536:].decode("utf-8", errors="replace"), end="")
    else:
        with deployment_lock(control):
            current = read_json(control / "request.json")
            if not re.fullmatch(r"[a-f0-9]{32}", str(current.get("release", ""))):
                raise ValueError("Invalid release")
            print(json.dumps(wait_ready(control, request_reload(control, current["release"]))))


def health_status():
    try:
        context = ssl.create_default_context(cafile="/run/tls/server.crt")
        context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
        with opener.open("https://127.0.0.1:8766/healthz", timeout=1) as response:
            return response.status == 200, None if response.status == 200 else "Unexpected health response"
    except (OSError, ValueError) as error:
        return False, (type(error).__name__ + ": " + str(error))[:1024]


def supervise(releases=Path("/opt/borgvr-dev/releases"), control=Path("/run/borgvr-dev"), *,
              command=None, health=None):
    os.umask(0o007)
    command = command or [sys.executable, *UVICORN]
    running, child, current, selector = True, None, None, selectors.DefaultSelector()
    log_path = control / "agent.log"

    def stopping(signum, frame):
        nonlocal running
        running = False

    def stop_child():
        nonlocal child
        if child is None:
            return
        with suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            pass
        with suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=3)
        if child.stdout:
            selector.unregister(child.stdout)
            child.stdout.close()
        child = None

    def append_log(data):
        # This is a bounded development log, not a second unbounded Docker log.
        if log_path.exists() and log_path.lstat().st_size + len(data) > 1024 * 1024:
            os.replace(log_path, control / "agent.previous.log")
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o660)
        with os.fdopen(fd, "ab") as stream:
            stream.write(data)
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()

    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    state = {"phase": "starting"}
    try:
        while running:
            request = read_json(control / "request.json")
            if request != current:
                if not all(re.fullmatch(r"[a-f0-9]{32}", str(request.get(key, ""))) for key in ("request", "release")):
                    raise ValueError("Invalid development reload request")
                directory = releases / request["release"]
                source = read_json(directory / "source.json")
                stop_child()
                append_log(("\nBorgVR development reload " + request["release"] + "\n").encode())
                # The complete immutable release is selected before starting a new worker.
                env = {**os.environ, "PYTHONPATH": str(directory), "PYTHONDONTWRITEBYTECODE": "1"}
                child = subprocess.Popen(command, cwd=directory, env=env, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, start_new_session=True)
                selector.register(child.stdout, selectors.EVENT_READ)
                current = request
                state = {**request, "phase": "starting", "sha256": source["sha256"]}
                write_json(control / "status.json", state)
            for key, _ in selector.select(timeout=0.2):
                data = os.read(key.fileobj.fileno(), 16384)
                if data:
                    append_log(data)
                else:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    child.stdout = None
            exit_code = child.poll()
            ready, health_error = health_status() if health is None and exit_code is None else (False, None)
            if health is not None and exit_code is None:
                ready = health()
            next_state = {**request, "sha256": source["sha256"],
                          "phase": "failed" if exit_code is not None else "ready" if ready else "starting"}
            if health_error:
                next_state["health_error"] = health_error
            if exit_code is not None:
                next_state["exit_code"] = exit_code
            if next_state != state:
                state = next_state
                write_json(control / "status.json", state)
    finally:
        stop_child()
        selector.close()
        write_json(control / "status.json", {**state, "phase": "stopped"})


def public_key(path):
    fields = read_file(path, 4096).decode("ascii").strip().split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519":
        raise ValueError("Supply a dedicated OpenSSH Ed25519 PUBLIC key (.pub), never a private key")
    raw = base64.b64decode(fields[1], validate=True)
    expected = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32)
    if len(raw) != len(expected) + 32 or not raw.startswith(expected):
        raise ValueError("Invalid Ed25519 public key")
    return "ssh-ed25519 " + fields[1]


def marker(root=ROOT):
    return root / "runtime" / MARKER


def overlay_file(root=ROOT):
    record = installation()
    if not record.get("enabled") or record["checkout"] != str(root.resolve()):
        raise ValueError("Development state belongs to a different installation or is disabled")
    return DEV_ROOT / "compose.json"


def run_compose(root):
    # Keep backend selection in setup.sh; this private operation only recreates agent.
    subprocess.run(["bash", str(root / "setup.sh"), "_dev-agent-up"], check=True, timeout=120)


def save_startup_failure(root, error):
    report = {"error_type": type(error).__name__, "error": str(error)[:2048]}
    try:
        report["supervisor"] = read_json(DEV_ROOT / "control/status.json")
    except (OSError, ValueError) as status_error:
        report["supervisor_error"] = type(status_error).__name__
    try:
        result = subprocess.run(["bash", str(root / "setup.sh"), "_dev-agent-health"],
                                capture_output=True, text=True, timeout=15, check=True)
        report["docker_health"] = json.loads(result.stdout[:65536])
    except (OSError, ValueError, subprocess.SubprocessError) as health_error:
        report["docker_health_error"] = type(health_error).__name__
    path = DEV_ROOT / "startup-failure.json"
    write_json(path, report, 0o600)
    print("Development startup failed; diagnostics saved before restoring the normal agent: " + str(path), file=sys.stderr)


def overlay(gid):
    bind = lambda source, target, ro: {"type": "bind", "source": str(source), "target": target,
                                      "read_only": ro, "bind": {"create_host_path": False}}
    return {"services": {"agent": {
        "command": ["python", "/opt/borgvr-development.py", "supervise"],
        "group_add": [str(gid)],
        "volumes": [bind(DEV_ROOT / "releases", "/opt/borgvr-dev/releases", True),
                    bind(DEV_ROOT / "control", "/run/borgvr-dev", False),
                    bind(HELPER, "/opt/borgvr-development.py", True)],
        "labels": {"org.borgvr.agent.development": "true"},
    }}}


def require_admin():
    if sys.platform != "linux" or os.geteuid() != 0:
        raise ValueError("Run this development setup on the Linux Docker host with sudo")


def enable(root, key_file):
    require_admin()
    key = public_key(key_file)
    if not (root / ".env").is_file():
        raise ValueError("Install the normal BorgVR server first")
    if any(not (root / name).is_file() for name in REQUIRED):
        raise ValueError("Development requires the complete agent source checkout/archive, not only the production deployment bundle")
    if DEV_ROOT.exists() or HELPER.exists() or marker(root).exists():
        raise ValueError("Development setup already exists. Use dev push/status, or dev disable --remove before enabling again.")
    try:
        pwd.getpwnam(ACCOUNT)
    except KeyError:
        pass
    else:
        raise ValueError("The development account already exists and is not managed by this installation")
    try:
        grp.getgrnam(ACCOUNT)
    except KeyError:
        pass
    else:
        raise ValueError("An unrelated development group already exists")
    admin_directory(DEV_ROOT.parent)
    from configure import image_reference, read_configuration
    config = read_configuration(root)
    image = image_reference(config["BORGVR_AGENT_IMAGE"])
    # Read the dependency snapshot from the installed image, not the checkout or a remote shell.
    result = subprocess.run(["docker", "--host", "unix:///var/run/docker.sock", "run", "--rm", "--pull", "never", "--network", "none",
        "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--entrypoint", "python",
        "--memory", "128m", "--pids-limit", "64", image,
        "-c", "import hashlib;print(hashlib.sha256(open('/app/requirements.txt','rb').read()).hexdigest())"],
        check=True, capture_output=True, text=True, timeout=60)
    requirement_sha = result.stdout.strip()
    if not re.fullmatch(r"[a-f0-9]{64}", requirement_sha):
        raise ValueError("Invalid dependency snapshot from image")
    bundle = bundle_source(root)
    unpack_source(bundle, requirement_sha)
    DEV_ROOT.mkdir(mode=0o755)
    DEV_ROOT.chmod(0o755)
    record = {"checkout": str(root.resolve()), "enabled": False, "requirements_sha256": requirement_sha,
              "account_created": False}
    write_json(DEV_ROOT / "installation.json", record, 0o644)
    try:
        subprocess.run(["useradd", "--system", "--user-group", "--no-create-home", "--home-dir", str(DEV_ROOT / "home"),
                        "--shell", "/bin/sh", ACCOUNT], check=True, timeout=30)
    finally:
        # Preserve recovery information even if useradd fails after creating an account/group.
        with suppress(KeyError):
            group = grp.getgrnam(ACCOUNT)
            record["gid"] = group.gr_gid
        with suppress(KeyError):
            partial = pwd.getpwnam(ACCOUNT)
            if partial.pw_dir == str(DEV_ROOT / "home"):
                record.update(uid=partial.pw_uid, gid=partial.pw_gid, account_created=True)
        write_json(DEV_ROOT / "installation.json", record, 0o644)
    account = pwd.getpwnam(ACCOUNT)
    record.update(uid=account.pw_uid, gid=account.pw_gid, account_created=True)
    write_json(DEV_ROOT / "installation.json", record, 0o644)
    for name, mode in (("home", 0o750), ("home/.ssh", 0o750), ("releases", 0o750), ("control", 0o2770)):
        path = DEV_ROOT / name
        path.mkdir(mode=mode)
        os.chown(path, 0 if name.startswith("home") else account.pw_uid, account.pw_gid)
        path.chmod(mode)
    if not HELPER.parent.exists():
        HELPER.parent.mkdir(mode=0o755)
        HELPER.parent.chmod(0o755)
    admin_directory(HELPER.parent)
    if HELPER.parent.stat().st_mode & 0o005 != 0o005:
        raise ValueError("The helper directory must be readable/traversable by the restricted SSH account")
    atomic_file(HELPER, read_file(Path(__file__), 256 * 1024), 0o755)
    write_json(DEV_ROOT / "compose.json", overlay(account.pw_gid), 0o644)
    record["enabled"] = True
    write_json(DEV_ROOT / "installation.json", record, 0o644)
    # Stage with the same unprivileged identity used for later SSH uploads.
    subprocess.run(["/usr/bin/python3", "-I", str(HELPER), "stage"], input=bundle, check=True, timeout=30,
                   user=account.pw_uid, group=account.pw_gid, extra_groups=[], cwd=DEV_ROOT / "home",
                   env={"PATH": "/usr/bin:/bin", "HOME": str(DEV_ROOT / "home"), "LANG": "C.UTF-8"})
    write_json(marker(root), {"root": str(DEV_ROOT)}, 0o600)
    try:
        run_compose(root)
    except Exception as error:
        # Capture the failed container before recreation replaces its healthcheck history.
        try:
            save_startup_failure(root, error)
        except (OSError, ValueError) as diagnostic_error:
            print("Could not save development diagnostics: " + type(diagnostic_error).__name__, file=sys.stderr)
        record["enabled"] = False
        write_json(DEV_ROOT / "installation.json", record, 0o644)
        marker(root).unlink(missing_ok=True)
        # Restore only the agent; never stop a healthy model as part of error recovery.
        try:
            run_compose(root)
        except Exception as restore_error:
            print("Normal agent restoration also failed its startup/readiness check: " +
                  type(restore_error).__name__ + ". Check agent and vLLM health before retrying.", file=sys.stderr)
        raise
    forced = '/usr/bin/python3 -I ' + str(HELPER) + ' ssh'
    authorized = DEV_ROOT / "home/.ssh/authorized_keys"
    atomic_file(authorized, ('restrict,command="' + forced + '" ' + key + ' BorgVR-development\n').encode(), 0o640)
    os.chown(authorized, 0, account.pw_gid)
    print("Development mode enabled. Only agent was recreated; vLLM was not restarted. SSH account: " + ACCOUNT)


def removal_plan(root):
    if not marker(root).exists() and not DEV_ROOT.exists():
        return None
    record = installation()
    if record["checkout"] != str(root.resolve()):
        if marker(root).exists():
            raise ValueError("Development installation belongs to another checkout")
        return None
    if record.get("account_created"):
        with suppress(KeyError):
            expected_account(record)
            return {"directory": str(DEV_ROOT), "helper": str(HELPER), "account": ACCOUNT}
    return {"directory": str(DEV_ROOT), "helper": str(HELPER), "account": None}


def cleanup(root):
    plan = removal_plan(root)
    if plan is None:
        return
    require_admin()
    if plan["account"]:
        # Never run userdel --remove on a home supplied by an unrelated account.
        subprocess.run(["userdel", ACCOUNT], check=True, timeout=30)
    with suppress(KeyError):
        group = grp.getgrnam(ACCOUNT)
        if group.gr_gid != installation().get("gid") or group.gr_mem or any(p.pw_gid == group.gr_gid for p in pwd.getpwall()):
            raise ValueError("Development group is in use; refusing removal")
        subprocess.run(["groupdel", ACCOUNT], check=True, timeout=30)
    shutil.rmtree(DEV_ROOT)
    HELPER.unlink(missing_ok=True)
    marker(root).unlink(missing_ok=True)


def disable(root, remove=False):
    require_admin()
    if removal_plan(root) is None:
        raise ValueError("No development installation belongs to this checkout")
    record = installation()
    record["enabled"] = False
    write_json(DEV_ROOT / "installation.json", record, 0o644)
    (DEV_ROOT / "home/.ssh/authorized_keys").unlink(missing_ok=True)
    marker(root).unlink(missing_ok=True)
    run_compose(root)
    if remove:
        cleanup(root)
    print("Normal agent image restored; development SSH key revoked. vLLM was not restarted.")


def remote(host, port, key, action, root=ROOT):
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", host):
            raise ValueError("Invalid SSH host")
    if not 1 <= port <= 65535:
        raise ValueError("Invalid SSH port")
    args = ["ssh", "-T", "-p", str(port), "-i", str(key), "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3", ACCOUNT + "@" + host, "deploy" if action == "push" else action]
    subprocess.run(args, input=bundle_source(root) if action == "push" else b"", check=True, timeout=90)


def main():
    # The installed forced command exposes no administrator actions or shell interpreter.
    if sys.argv[1:] == ["ssh"]:
        ssh_command(os.environ.get("SSH_ORIGINAL_COMMAND", ""))
        return
    if sys.argv[1:] == ["stage"]:
        record = installation()
        if os.getuid() != expected_account(record).pw_uid:
            raise ValueError("Staging must run as the unprivileged development account")
        print(json.dumps(stage_source(sys.stdin.buffer.read(MAX_ARCHIVE + 1), record, wait=False)))
        return
    if sys.argv[1:] == ["supervise"]:
        supervise()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("enable", "disable", "push", "status", "logs", "restart", "compose-file"))
    parser.add_argument("--ssh-key-file", type=Path)
    parser.add_argument("--host")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--key", type=Path)
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    if args.host:
        if args.action not in {"push", "status", "logs", "restart"} or args.key is None or args.remove or args.ssh_key_file:
            parser.error("Remote operations need push/status/logs/restart, --host and --key only")
        remote(args.host, args.port, args.key, args.action)
    elif args.action == "compose-file":
        print(overlay_file())
    elif args.action == "enable":
        if args.ssh_key_file is None:
            parser.error("enable requires --ssh-key-file with a dedicated .pub key")
        enable(ROOT, args.ssh_key_file)
    elif args.action == "disable":
        disable(ROOT, args.remove)
    else:
        parser.error("Use --host and --key for this development operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error
