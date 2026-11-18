import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import time
from types import SimpleNamespace

import pytest

import development as dev
from test_setup import operations

ROOT = Path(__file__).resolve().parents[1]


def archive(files=None, extra=None):
    files = files or {name: b"# test source\n" for name in dev.REQUIRED}
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))
        if extra:
            tar.addfile(extra, io.BytesIO(b"x" * extra.size) if extra.isfile() else None)
    return buffer.getvalue()


HASH = hashlib.sha256(b"# test source\n").hexdigest()


def test_bundle_only_contains_agent_source_and_matches_dependencies():
    files = dev.unpack_source(dev.bundle_source(ROOT), hashlib.sha256((ROOT / "requirements.txt").read_bytes()).hexdigest())
    assert dev.REQUIRED <= files.keys()
    assert not any("runtime" in name or ".env" in name or "tests/" in name for name in files)
    assert all(dev.source_name(name) for name in files)
    with pytest.raises(ValueError, match="Dependencies differ"):
        dev.unpack_source(archive(), "0" * 64)


@pytest.mark.parametrize("name", ["../outside.py", "/etc/ssh/authorized_keys", "borgvr_agent/../../outside.py",
                                  "runtime/secrets/agent_token", ".env", "borgvr_agent/a.pth", "borgvr_agent/.hidden.py"])
def test_archive_refuses_unexpected_paths(name):
    extra = tarfile.TarInfo(name)
    with pytest.raises(ValueError):
        dev.unpack_source(archive(extra=extra), HASH)


@pytest.mark.parametrize("kind", [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.DIRTYPE])
def test_archive_refuses_links_and_special_files(kind):
    member = tarfile.TarInfo("borgvr_agent/new.py")
    member.type, member.linkname = kind, "/etc/passwd"
    with pytest.raises(ValueError):
        dev.unpack_source(archive(extra=member), HASH)


def test_archive_limits_duplicates_and_compression():
    duplicate = tarfile.TarInfo("client.py")
    with pytest.raises(ValueError):
        dev.unpack_source(archive(extra=duplicate), HASH)
    with pytest.raises(ValueError):
        dev.unpack_source(b"x" * (dev.MAX_ARCHIVE + 1), HASH)
    files = {**{name: b"# test source\n" for name in dev.REQUIRED}, "borgvr_agent/huge.py": b"x" * (512 * 1024 + 1)}
    with pytest.raises(ValueError):
        dev.unpack_source(archive(files), HASH)
    with pytest.raises(tarfile.TarError):
        import gzip
        dev.unpack_source(gzip.compress(archive()), HASH)
    files = {name: b"# test source\n" for name in dev.REQUIRED}
    files.update({f"borgvr_agent/file_{i}.py": b"x" for i in range(dev.MAX_FILES)})
    with pytest.raises(ValueError):
        dev.unpack_source(archive(files), HASH)
    files = {name: b"# test source\n" for name in dev.REQUIRED}
    files.update({f"borgvr_agent/large_{i}.py": b"x" * (500 * 1024) for i in range(5)})
    with pytest.raises(ValueError):
        dev.unpack_source(archive(files), HASH)


def test_bundle_refuses_symlinks_and_hardlinks(tmp_path):
    for name in dev.TOP_FILES:
        shutil.copyfile(ROOT / name, tmp_path / name)
    shutil.copytree(ROOT / "borgvr_agent", tmp_path / "borgvr_agent", ignore=shutil.ignore_patterns("__pycache__"))
    path = tmp_path / "borgvr_agent/sneaky.py"
    path.symlink_to(ROOT / "client.py")
    with pytest.raises((ValueError, OSError)):
        dev.bundle_source(tmp_path)
    path.unlink()
    os.link(tmp_path / "client.py", path)
    with pytest.raises(ValueError):
        dev.bundle_source(tmp_path)


def test_upload_pipe_has_absolute_deadline():
    read, write = os.pipe()
    try:
        with os.fdopen(read, "rb") as stream, pytest.raises(ValueError, match="deadline"):
            dev.receive_archive(stream, timeout=0.05)
    finally:
        os.close(write)


@pytest.fixture
def deployment(tmp_path, monkeypatch):
    monkeypatch.setattr(dev, "DEV_ROOT", tmp_path)
    (tmp_path / "releases").mkdir()
    (tmp_path / "control").mkdir()
    return tmp_path


def test_snapshot_is_complete_before_request_and_old_release_is_immutable(deployment):
    one = dev.stage_source(archive(), {"requirements_sha256": HASH}, wait=False)
    files = {name: b"# test source\n" for name in dev.REQUIRED}
    files["borgvr_agent/app.py"] = b"# new version\n"
    two = dev.stage_source(archive(files), {"requirements_sha256": HASH}, wait=False)
    assert one["release"] != two["release"]
    assert (deployment / "releases" / one["release"] / "borgvr_agent/app.py").read_bytes() == b"# test source\n"
    assert (deployment / "releases" / two["release"] / "borgvr_agent/app.py").read_bytes() == b"# new version\n"
    assert dev.read_json(deployment / "control/request.json")["release"] == two["release"]
    for _ in range(12):
        dev.stage_source(archive(files), {"requirements_sha256": HASH}, wait=False)
    assert len(list((deployment / "releases").iterdir())) <= 5


def test_concurrent_upload_is_rejected_and_bad_bundle_keeps_current_request(deployment):
    dev.stage_source(archive(), {"requirements_sha256": HASH}, wait=False)
    before = (deployment / "control/request.json").read_bytes()
    with dev.deployment_lock(deployment / "control"), pytest.raises(BlockingIOError):
        dev.stage_source(archive(), {"requirements_sha256": HASH}, wait=False)
    with pytest.raises(ValueError):
        dev.stage_source(archive(), {"requirements_sha256": "0" * 64}, wait=False)
    assert (deployment / "control/request.json").read_bytes() == before


@pytest.mark.parametrize("command", ["", "bash", "sh -c id", "status; id", "sudo docker ps", "deploy\nstatus", "sftp", "stage"])
def test_forced_ssh_command_rejects_shell_before_reading_any_state(monkeypatch, command):
    monkeypatch.setattr(dev, "installation", lambda: pytest.fail("Rejected command accessed installation"))
    with pytest.raises(ValueError, match="Only deploy"):
        dev.ssh_command(command)


def test_public_key_only_and_no_client_supplied_authorized_key_options(tmp_path):
    path = tmp_path / "key.pub"
    encoded = base64.b64encode(struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + b"x" * 32).decode()
    path.write_text("ssh-ed25519 " + encoded + " comment\n")
    assert dev.public_key(path) == "ssh-ed25519 " + encoded
    for value in ["-----BEGIN OPENSSH PRIVATE KEY-----", 'command="sh" ssh-ed25519 ' + encoded, "ssh-ed25519 eA=="]:
        path.write_text(value)
        with pytest.raises(ValueError):
            dev.public_key(path)


def test_overlay_keeps_base_security_and_never_touches_vllm():
    data = dev.overlay(1234)
    assert set(data["services"]) == {"agent"}
    agent = data["services"]["agent"]
    assert agent["group_add"] == ["1234"]
    assert "privileged" not in agent and "cap_add" not in agent and "ports" not in agent and "user" not in agent
    assert all(m["bind"]["create_host_path"] is False for m in agent["volumes"])
    assert [m["read_only"] for m in agent["volumes"]] == [True, False, True]
    assert not any("docker.sock" in m["source"] for m in agent["volumes"])


def test_remote_uses_fixed_command_strict_host_keys_and_no_shell(monkeypatch):
    calls = []
    monkeypatch.setattr(dev.subprocess, "run", lambda args, **kw: calls.append((args, kw)))
    monkeypatch.setattr(dev, "bundle_source", lambda root: b"source")
    dev.remote("134.91.11.251", 22, Path("/tmp/key"), "push")
    args, kw = calls[0]
    assert "StrictHostKeyChecking=yes" in args and "IdentitiesOnly=yes" in args
    assert args[-2:] == ["borgvr-agent-dev@134.91.11.251", "deploy"]
    assert kw["input"] == b"source" and kw["timeout"] == 90 and "shell" not in kw
    with pytest.raises(ValueError):
        dev.remote("host;touch pwned", 22, Path("/tmp/key"), "status")


def test_agent_only_recreation_does_not_pull_build_or_restart_model(operations):
    root, run = operations
    result, calls = run("_dev-agent-up")
    assert result.returncode == 0, result.stderr
    ups = [c["args"] for c in calls if "up" in c["args"]]
    assert len(ups) == 1 and ups[0][-1] == "agent"
    assert all(flag in ups[0] for flag in ("--no-deps", "--no-build", "--force-recreate"))
    assert not any("pull" in c["args"] or "stop" in c["args"] or "build" in c["args"] for c in calls)


def test_active_mode_is_retained_by_start_and_blocks_image_changes(operations):
    root, run = operations
    (root / "runtime" / dev.MARKER).write_text("{}")
    (root / "development.py").write_text("print('/administrator-owned/compose.json')")
    result, calls = run("start")
    assert result.returncode == 0, result.stderr
    assert all('/administrator-owned/compose.json' in c["args"] for c in calls if "--project-directory" in c["args"])
    for command in ("install", "configure", "model", "update"):
        result, _ = run(command)
        assert result.returncode != 0 and "Disable development mode" in result.stderr


def test_setup_dev_is_available_on_client_without_docker():
    result = subprocess.run(["bash", str(ROOT / "setup.sh"), "dev", "--help"], capture_output=True, text=True)
    assert result.returncode == 0 and "--host" in result.stdout and "--ssh-key-file" in result.stdout


def test_enable_installs_only_forced_key_and_unprivileged_staging(tmp_path, monkeypatch):
    source = tmp_path / "checkout"
    source.mkdir()
    for name in dev.TOP_FILES:
        shutil.copyfile(ROOT / name, source / name)
    shutil.copytree(ROOT / "borgvr_agent", source / "borgvr_agent", ignore=shutil.ignore_patterns("__pycache__"))
    (source / "runtime").mkdir()
    (source / ".env").write_text("BORGVR_AGENT_IMAGE=" + __import__("configure").DEFAULT_AGENT_IMAGE + "\n")
    key = tmp_path / "key.pub"
    key.write_text("ssh-ed25519 " + base64.b64encode(struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + b"x" * 32).decode())
    dev_root = tmp_path / "development"
    monkeypatch.setattr(dev, "DEV_ROOT", dev_root)
    monkeypatch.setattr(dev, "HELPER", tmp_path / "libexec/helper.py")
    monkeypatch.setattr(dev, "require_admin", lambda: None)
    monkeypatch.setattr(dev, "admin_directory", lambda path: None)
    monkeypatch.setattr(dev.os, "chown", lambda *args: None)
    account = SimpleNamespace(pw_uid=1234, pw_gid=5678, pw_dir=str(dev_root / "home"))
    created, calls, restarted = False, [], []
    def get_account(name):
        if not created:
            raise KeyError(name)
        return account
    def group(name):
        if not created:
            raise KeyError(name)
        return SimpleNamespace(gr_gid=5678, gr_mem=[])
    def run(args, **kwargs):
        nonlocal created
        calls.append((args, kwargs))
        if args[0] == "useradd": created = True
        return SimpleNamespace(stdout=hashlib.sha256((ROOT / "requirements.txt").read_bytes()).hexdigest())
    monkeypatch.setattr(dev.pwd, "getpwnam", get_account)
    monkeypatch.setattr(dev.grp, "getgrnam", group)
    monkeypatch.setattr(dev.subprocess, "run", run)
    monkeypatch.setattr(dev, "run_compose", lambda root: restarted.append(root))
    original = (source / ".env").read_bytes()
    dev.enable(source, key)
    assert restarted == [source] and (source / ".env").read_bytes() == original
    authorized = (dev_root / "home/.ssh/authorized_keys").read_text()
    assert authorized.startswith('restrict,command="/usr/bin/python3 -I ')
    assert ' ssh" ssh-ed25519 ' in authorized and "sudo" not in authorized and "docker" not in authorized
    stage = next(kw for args, kw in calls if args[-1] == "stage")
    assert stage["user"] == 1234 and stage["group"] == 5678 and stage["extra_groups"] == []
    assert (dev_root / "home").stat().st_mode & 0o777 == 0o750
    assert dev.marker(source).exists() and json.loads((dev_root / "installation.json").read_text())["enabled"]


def test_disable_revokes_key_before_returning_to_image(deployment, monkeypatch):
    (deployment / "home/.ssh").mkdir(parents=True)
    key = deployment / "home/.ssh/authorized_keys"
    key.write_text("restricted key")
    root = deployment / "checkout"
    (root / "runtime").mkdir(parents=True)
    dev.marker(root).write_text("{}")
    state = {"enabled": True}
    monkeypatch.setattr(dev, "require_admin", lambda: None)
    monkeypatch.setattr(dev, "removal_plan", lambda root: {"account": "managed"})
    monkeypatch.setattr(dev, "installation", lambda: dict(state))
    def up(root):
        assert not key.exists() and not dev.marker(root).exists()
        assert dev.read_json(deployment / "installation.json")["enabled"] is False
    monkeypatch.setattr(dev, "run_compose", up)
    dev.disable(root)


def test_uninstall_cleans_development_after_containers_not_before(tmp_path, monkeypatch):
    import uninstall
    events = []
    monkeypatch.setattr(uninstall, "development_plan", lambda root: {"account": "managed"})
    monkeypatch.setattr(dev, "cleanup", lambda root: events.append("development"))
    monkeypatch.setattr(uninstall, "remove_rules", lambda root: None)
    docker = SimpleNamespace(run=lambda *args, **kwargs: events.append(args[0]))
    plan = {"containers": ["one"], "volumes": [], "networks": [], "images": []}
    uninstall.apply_plan(tmp_path, docker, plan)
    assert events == ["container", "development"]


def test_supervisor_reloads_only_after_complete_upload_and_stops_children(deployment):
    initial = dev.stage_source(archive(), {"requirements_sha256": HASH}, wait=False)
    script = '''import sys,json,os
from pathlib import Path
import development as d
root=Path(sys.argv[1]); control=root/'control'
child="import os,time; print('WORKER '+os.getcwd(),flush=True); time.sleep(120)"
d.supervise(root/'releases',control,command=[sys.executable,'-u','-c',child],health=lambda:True)
'''
    process = subprocess.Popen([sys.executable, "-c", script, str(deployment)], cwd=ROOT,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        state = dev.wait_ready(deployment / "control", initial["request"], timeout=5)
        files = {name: b"# test source\n" for name in dev.REQUIRED}
        files["borgvr_agent/app.py"] = b"# second worker\n"
        next_state = dev.stage_source(archive(files), {"requirements_sha256": HASH})
        assert state["release"] != next_state["release"] and next_state["phase"] == "ready"
        assert next_state["sha256"] == hashlib.sha256(archive(files)).hexdigest()
    finally:
        process.terminate()
        _, errors = process.communicate(timeout=15)
        assert process.returncode == 0, errors.decode()
    assert dev.read_json(deployment / "control/status.json")["phase"] == "stopped"


def test_failed_worker_is_reported_instead_of_acknowledging_success(deployment):
    initial = dev.stage_source(archive(), {"requirements_sha256": HASH}, wait=False)
    script = '''import sys
from pathlib import Path
import development as d
root=Path(sys.argv[1])
d.supervise(root/'releases',root/'control',command=[sys.executable,'-c','raise SystemExit(42)'],health=lambda:False)
'''
    process = subprocess.Popen([sys.executable, "-c", script, str(deployment)], cwd=ROOT,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        with pytest.raises(ValueError, match="failed to start"):
            dev.wait_ready(deployment / "control", initial["request"], timeout=5)
    finally:
        process.terminate()
        _, errors = process.communicate(timeout=15)
        assert process.returncode == 0, errors.decode()
