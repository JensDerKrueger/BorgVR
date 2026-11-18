import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
from types import SimpleNamespace

import pytest
import yaml

import configure
from configure import AGENT_UID, AGENT_GID, DEFAULT_AGENT_IMAGE, PYTHON_IMAGE, create_configuration, hostname


@pytest.mark.parametrize("value", ["ai.example.org", "localhost", "192.168.1.2", "::1"])
def test_hostnames(value):
    assert hostname(value) == value


@pytest.mark.parametrize("value", ["https://ai.example.org", "ai.example.org\nDNS:evil", "x/../../y",
                                  "$(touch evil)", "", "0.0.0.0", "-evil", "evil..example"])
def test_bad_hostnames(value):
    with pytest.raises(argparse.ArgumentTypeError):
        hostname(value)


def test_configuration_is_non_destructive_and_private(tmp_path):
    create_configuration(tmp_path, "ai.example.org", "127.0.0.1", 8766, "0")
    env = (tmp_path / ".env").read_bytes()
    token = (tmp_path / "runtime/secrets/agent_token").read_bytes()
    other_token = (tmp_path / "runtime/secrets/vllm_token").read_bytes()
    assert token != other_token and len(token.strip()) >= 32
    assert (tmp_path / ".env").stat().st_mode & 0o777 == 0o600
    assert (tmp_path / "runtime").stat().st_mode & 0o777 == 0o700
    assert (tmp_path / "runtime/secrets/agent_token").stat().st_mode & 0o777 == 0o600
    assert (tmp_path / "runtime/secrets/vllm_token").stat().st_mode & 0o777 == 0o640
    cert = tmp_path / "runtime/tls/server.crt"
    output = subprocess.check_output(["openssl", "x509", "-in", str(cert), "-noout", "-text"], text=True)
    assert "DNS:ai.example.org" in output and "IP Address:127.0.0.1" in output
    (tmp_path / "runtime/secrets/vllm_token").chmod(0o600)
    create_configuration(tmp_path, "different.example.org", "0.0.0.0", 9876, "1")
    assert (tmp_path / ".env").read_bytes() == env
    assert (tmp_path / "runtime/secrets/agent_token").read_bytes() == token
    assert (tmp_path / "runtime/secrets/vllm_token").read_bytes() == other_token
    assert (tmp_path / "runtime/secrets/vllm_token").stat().st_mode & 0o777 == 0o640


def test_sudo_configuration_keeps_agent_unprivileged(tmp_path, monkeypatch):
    changed = []
    monkeypatch.setattr(configure.os, "getuid", lambda: 0)
    monkeypatch.setattr(configure.os, "chown", lambda path, uid, gid: changed.append((path, uid, gid)))
    monkeypatch.setattr(configure, "prepare_shared_token", lambda root: None)
    monkeypatch.setattr(configure, "prepare_runtime_access", lambda root: None)
    create_configuration(tmp_path, "192.168.1.2", "127.0.0.1", 8766, "0")
    env = (tmp_path / ".env").read_text()
    assert f"BORGVR_UID={AGENT_UID}\n" in env and f"BORGVR_GID={AGENT_GID}\n" in env
    assert f"BORGVR_AGENT_IMAGE={DEFAULT_AGENT_IMAGE}\n" in env
    assert AGENT_UID != 0 and AGENT_GID != 0
    mounts = tmp_path / "runtime"
    assert set(changed) == {(mounts / name, AGENT_UID, AGENT_GID) for name in (
        "secrets", "tls", "secrets/agent_token", "secrets/vllm_token", "tls/server.key", "tls/server.crt")}
    changed.clear()
    create_configuration(tmp_path, "localhost", "0.0.0.0", 9876, "1")
    assert not changed and (tmp_path / ".env").read_text() == env


def test_runtime_owner_uses_sudo_caller_and_retains_existing_installer(monkeypatch):
    monkeypatch.setenv("SUDO_UID", "1234")
    monkeypatch.setenv("SUDO_USER", "installer")
    monkeypatch.setattr(configure.pwd, "getpwuid", lambda uid: SimpleNamespace(
        pw_uid=uid, pw_gid=5678, pw_name="installer"))
    assert configure.runtime_owner(SimpleNamespace(st_uid=0, st_gid=0)) == (1234, 5678)
    assert configure.runtime_owner(SimpleNamespace(st_uid=4321, st_gid=8765)) == (4321, 8765)
    monkeypatch.delenv("SUDO_UID")
    assert configure.runtime_owner(SimpleNamespace(st_uid=0, st_gid=0)) is None
    assert configure.runtime_owner(SimpleNamespace(st_uid=1234, st_gid=5678)) == (1234, 5678)
    monkeypatch.setenv("SUDO_UID", "0")
    assert configure.runtime_owner(SimpleNamespace(st_uid=0, st_gid=0)) is None


@pytest.mark.parametrize("value", ["-1", "4294967295", "1234\n", "١٢٣٤", "unknown"])
def test_runtime_owner_rejects_invalid_sudo_uid(monkeypatch, value):
    monkeypatch.setenv("SUDO_UID", value)
    with pytest.raises(ValueError, match="SUDO_UID"):
        configure.runtime_owner(SimpleNamespace(st_uid=0, st_gid=0))


def test_runtime_owner_rejects_missing_or_mismatched_account(monkeypatch):
    monkeypatch.setenv("SUDO_UID", "1234")
    monkeypatch.setenv("SUDO_USER", "another-user")
    monkeypatch.setattr(configure.pwd, "getpwuid", lambda uid: SimpleNamespace(
        pw_uid=uid, pw_gid=5678, pw_name="installer"))
    with pytest.raises(ValueError, match="SUDO_USER"):
        configure.runtime_owner(SimpleNamespace(st_uid=0, st_gid=0))
    def missing(uid):
        raise KeyError(uid)
    monkeypatch.setattr(configure.pwd, "getpwuid", missing)
    with pytest.raises(ValueError, match="existing installer"):
        configure.runtime_owner(SimpleNamespace(st_uid=0, st_gid=0))


def test_runtime_access_keeps_container_group_and_private_backups(tmp_path, monkeypatch):
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    runtime = tmp_path / "runtime"
    backup = runtime / "tls-before-install-test"
    backup.mkdir()
    (backup / "server.key").write_text("old private key")
    (runtime / "env-before-update-test").write_text("old configuration")
    paths = [runtime, *runtime.rglob("*")]
    contents = {path: path.read_bytes() for path in paths if path.is_file()}
    env = (tmp_path / ".env").read_bytes()
    groups = {}
    monkeypatch.setattr(configure.os, "getuid", lambda: 0)
    monkeypatch.setattr(configure, "runtime_owner", lambda info: (1234, 5678))
    monkeypatch.setattr(configure.os, "fchown", lambda fd, uid, gid: groups.update({
        os.fstat(fd).st_ino: (uid, gid)}))
    for _ in range(2):
        configure.prepare_runtime_access(tmp_path)
        for path in paths:
            relative = path.relative_to(runtime).parts
            shared = relative[:1] in (("secrets",), ("tls",))
            expected_gid = int(configure.read_value("BORGVR_GID", tmp_path)) if shared else 5678
            assert groups[path.stat().st_ino] == (1234, expected_gid)
            expected_mode = (0o750 if path.is_dir() else 0o640) if shared else (0o700 if path.is_dir() else 0o600)
            assert path.stat().st_mode & 0o777 == expected_mode
    assert (tmp_path / ".env").read_bytes() == env
    assert all(path.read_bytes() == data for path, data in contents.items())


@pytest.mark.parametrize("link", ["symlink", "hardlink", "directory-symlink"])
def test_runtime_access_refuses_links_before_changing_permissions(tmp_path, monkeypatch, link):
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    outside = tmp_path / "outside"
    outside.write_text("must not change")
    before = outside.stat()
    entry = tmp_path / "runtime" / "unexpected"
    if link == "hardlink":
        os.link(outside, entry)
    elif link == "directory-symlink":
        entry.symlink_to(tmp_path, target_is_directory=True)
    else:
        entry.symlink_to(outside)
    changed = []
    monkeypatch.setattr(configure.os, "getuid", lambda: 0)
    monkeypatch.setattr(configure, "runtime_owner", lambda info: (1234, 5678))
    monkeypatch.setattr(configure.os, "fchown", lambda *args: changed.append(args))
    with pytest.raises((ValueError, OSError)):
        configure.prepare_runtime_access(tmp_path)
    assert not changed
    assert outside.read_text() == "must not change"
    assert outside.stat().st_mode == before.st_mode


def test_existing_init_prepares_runtime_access_without_replacing_configuration(tmp_path, monkeypatch):
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    env = (tmp_path / ".env").read_bytes()
    token = (tmp_path / "runtime/secrets/agent_token").read_bytes()
    prepared = []
    monkeypatch.setattr(configure, "prepare_runtime_access", lambda root: prepared.append(root))
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    assert prepared == [tmp_path]
    assert (tmp_path / ".env").read_bytes() == env
    assert (tmp_path / "runtime/secrets/agent_token").read_bytes() == token


def test_partial_setup_never_replaces_secrets(tmp_path):
    (tmp_path / "runtime").mkdir()
    with pytest.raises(ValueError):
        create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")


def test_shared_token_refuses_symlinks(tmp_path):
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    outside = tmp_path / "outside"
    outside.write_text("must not change")
    outside.chmod(0o600)
    token = tmp_path / "runtime/secrets/vllm_token"
    token.unlink()
    token.symlink_to(outside)
    with pytest.raises(OSError):
        configure.prepare_shared_token(tmp_path)
    assert outside.stat().st_mode & 0o777 == 0o600


def test_only_namespaced_inference_key_is_imported(tmp_path, monkeypatch):
    monkeypatch.setenv("VLLM_API_KEY", "unrelated-vllm-key" * 3)
    monkeypatch.delenv("VLLM_BORGVR_API_KEY", raising=False)
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    token = (tmp_path / "runtime/secrets/vllm_token").read_text().strip()
    assert token != os.environ["VLLM_API_KEY"]
    other = tmp_path / "explicit"
    other.mkdir()
    monkeypatch.setenv("VLLM_BORGVR_API_KEY", "borgvr-specific-key" * 3)
    create_configuration(other, "localhost", "127.0.0.1", 8766, "0")
    assert (other / "runtime/secrets/vllm_token").read_text().strip() == os.environ["VLLM_BORGVR_API_KEY"]
    assert os.environ["VLLM_BORGVR_API_KEY"] not in (other / ".env").read_text()


@pytest.mark.parametrize("value", ["", "short", "a" * 513, "a" * 40 + "\n"])
def test_invalid_namespaced_key_rejected_before_creating_files(tmp_path, monkeypatch, value):
    monkeypatch.setenv("VLLM_BORGVR_API_KEY", value)
    with pytest.raises(ValueError, match="VLLM_BORGVR_API_KEY"):
        create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    assert not (tmp_path / "runtime").exists()


def test_shell_syntax_and_help():
    root = Path(__file__).resolve().parents[1]
    subprocess.run(["bash", "-n", str(root / "gpu-host.sh")], check=True)
    for name in ("setup.sh", "setup-host.sh"):
        subprocess.run(["bash", "-n", str(root / name)], check=True)
        result = subprocess.run(["bash", str(root / name), "--help"], capture_output=True, text=True, check=True)
        assert "--install-host-deps" not in result.stdout
    assert "--backend" in result.stdout and "--docker-user" not in result.stdout


def test_deployment_has_no_public_inference_port_or_privileged_mode():
    root = Path(__file__).resolve().parents[1]
    text = (root / "compose.yaml").read_text()
    inference = text.split("  agent:")[0]
    assert "ports:" not in inference
    assert "privileged:" not in text and "ipc: host" not in text
    assert "@sha256:" in (root / "configure.py").read_text()
    assert "--ssl-certfile" in (root / "Dockerfile").read_text()
    assert "--trust-remote-code" not in (root / "vllm_start.py").read_text()
    assert "build:" not in text
    assert "build:" in (root / "compose.build.yaml").read_text()
    assert (root / "Dockerfile").read_text().splitlines()[0] == "FROM " + PYTHON_IMAGE
    vllm = yaml.safe_load(text)["services"]["vllm"]
    cuda = yaml.safe_load((root / "compose.cuda.yaml").read_text())["services"]["vllm"]
    assert cuda["group_add"] == ["${BORGVR_GID}"]
    assert vllm["cap_drop"] == ["ALL"] and "cap_add" not in vllm


def test_agent_tmpfs_is_one_mount_with_security_options():
    path = Path(__file__).resolve().parents[1] / "compose.yaml"
    agent = yaml.safe_load(path.read_text())["services"]["agent"]
    assert agent["tmpfs"] == ["/tmp:size=64m,noexec,nosuid"]


def host_function(code, *args):
    script = Path(__file__).resolve().parents[1] / "setup-host.sh"
    return subprocess.run(["bash", "-c", 'source "$1"; shift; ' + code, "test", str(script), *args],
                          capture_output=True, text=True)


@pytest.mark.parametrize("registered,allowed", [(False, False), (False, True), (True, False)])
def test_root_runtime_restart_requires_explicit_permission(registered, allowed):
    runtimes = json.dumps({"nvidia": {}} if registered else {"runc": {}})
    result = host_function(
        "docker_local() { printf '%s\\n' " + shlex.quote(runtimes) + "; }; "
        "nvidia-ctk() { printf 'CTK %s\\n' \"$*\"; }; "
        "systemctl() { printf 'SYSTEMCTL %s\\n' \"$*\"; }; "
        'ALLOW_DOCKER_RESTART="$1"; configure_runtime', str(int(allowed)))
    assert result.returncode == (0 if registered or allowed else 1)
    if allowed and not registered:
        assert "CTK runtime configure --runtime=docker" in result.stdout
        assert "SYSTEMCTL restart docker" in result.stdout
    else:
        assert "CTK " not in result.stdout and "SYSTEMCTL " not in result.stdout


def test_host_setup_rejects_nonroot_before_any_system_work():
    if os.getuid() == 0:
        pytest.skip("This test checks the non-root rejection")
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(["bash", str(root / "setup-host.sh")], capture_output=True, text=True)
    assert result.returncode == 1 and "as root" in result.stderr


def test_user_setup_rejects_legacy_elevation_flag():
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(["bash", str(root / "setup.sh"), "--install-host-deps"], capture_output=True, text=True)
    assert result.returncode == 1 and "never elevates" in result.stderr


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


@pytest.mark.parametrize("prebuilt", [None, True, False])
def test_install_docker_sequence_without_changing_host(tmp_path, prebuilt):
    source = Path(__file__).resolve().parents[1]
    for name in ("setup.sh", "gpu-host.sh", "configure.py", "model_config.py", "firewall.py"):
        shutil.copyfile(source / name, tmp_path / name)
    binary = tmp_path / "bin"
    binary.mkdir()
    trace = tmp_path / "commands.jsonl"
    executable(binary / "docker", '''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
with open(os.environ["TRACE"], "a") as handle:
    handle.write(json.dumps(args)+"\\n")
if "run" in args:
    print(300*1024*1024 if any("disk_usage" in a for a in args) else "CUDA OK")
sys.exit(1 if "inspect" in args else 0)
''')
    executable(binary / "uname", '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
    executable(binary / "nvidia-smi", '#!/bin/sh\necho "NVIDIA test fixture"\n')
    forbidden = tmp_path / "unexpected-privilege"
    for name in ("sudo", "apt-get", "systemctl", "usermod"):
        executable(binary / name, '#!/bin/sh\ntouch "$FORBIDDEN"\nexit 99\n')
    env = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"],
           "TRACE": str(trace), "FORBIDDEN": str(forbidden)}
    args = ["bash", str(tmp_path / "setup.sh"), "install", "--host", "ai.example.org"]
    if prebuilt is not None:
        args.append("--prebuilt-agent" if prebuilt else "--build-agent")
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert not forbidden.exists()
    calls = [json.loads(line) for line in trace.read_text().splitlines()]
    assert all(call[:2] == ["--host", "unix:///var/run/docker.sock"] for call in calls)
    assert any("build" in call for call in calls) is (prebuilt is False)
    assert any(call[-2:] == ["pull", "agent"] for call in calls) is (prebuilt is not False)
    assert any("up" in call and "--no-build" in call and "never" in call for call in calls)
    assert not any("down" in call for call in calls)
    probes = [i for i, call in enumerate(calls) if "run" in call and "--no-deps" in call]
    assert len(probes) == 2 and max(probes) < next(i for i, call in enumerate(calls) if "up" in call)
    if prebuilt is False:
        assert any(str(tmp_path / "compose.build.yaml") in call for call in calls)
    else:
        assert DEFAULT_AGENT_IMAGE in (tmp_path / ".env").read_text()


def test_user_setup_docker_access_failure_never_falls_back_to_sudo(tmp_path):
    source = Path(__file__).resolve().parents[1]
    for name in ("setup.sh", "gpu-host.sh", "configure.py", "model_config.py", "firewall.py"):
        shutil.copyfile(source / name, tmp_path / name)
    (tmp_path / ".env").write_text("# test fixture\n")
    binary = tmp_path / "bin"
    binary.mkdir()
    executable(binary / "docker", '#!/bin/sh\nexit 1\n')
    marker = tmp_path / "unexpected-sudo"
    executable(binary / "sudo", '#!/bin/sh\ntouch "$FORBIDDEN"\nexit 99\n')
    env = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"], "FORBIDDEN": str(marker)}
    result = subprocess.run(["bash", str(tmp_path / "setup.sh"), "status"], env=env, capture_output=True, text=True)
    assert result.returncode == 1 and "sudo ./setup.sh" in result.stderr
    assert not marker.exists()


def test_image_modes_cannot_be_mixed():
    script = Path(__file__).resolve().parents[1] / "setup.sh"
    for args in (("install", "--build-agent", "--prebuilt-agent"), ("init", "--build-agent")):
        result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True)
        assert result.returncode == 1


@pytest.fixture
def operations(tmp_path):
    source = Path(__file__).resolve().parents[1]
    for name in ("setup.sh", "gpu-host.sh", "configure.py", "model_config.py", "uninstall.py", "firewall.py"):
        shutil.copyfile(source / name, tmp_path / name)
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    binary = tmp_path / "bin"
    binary.mkdir()
    trace = tmp_path / "operations.jsonl"
    executable(binary / "docker", '''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:]
for value in args:
    if value.startswith("/dev/fd/"):
        with open(value) as overlay:
            assert isinstance(json.load(overlay)["services"]["vllm"]["group_add"],list)
with open(os.environ["TRACE"], "a") as handle:
    handle.write(json.dumps({"args":args,"image":os.environ.get("BORGVR_AGENT_IMAGE")})+"\\n")
if "run" in args and any("disk_usage" in a for a in args):
    print(300*1024*1024)
sys.exit(42 if os.environ.get("FAIL_COMMAND") in args else 0)
''')
    executable(binary / "uname", '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
    executable(binary / "nvidia-smi", '#!/bin/sh\necho "NVIDIA test fixture"\n')
    env = {**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"], "TRACE": str(trace)}

    def run(*args, failure=""):
        result = subprocess.run(["bash", str(tmp_path / "setup.sh"), *args],
                                env={**env, "FAIL_COMMAND": failure}, capture_output=True, text=True)
        calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
        return result, calls

    return tmp_path, run


@pytest.mark.parametrize("all_gpus", [False, True])
def test_gpu_access_matches_explicit_configuration(operations, all_gpus):
    root, run = operations
    if all_gpus:
        result, _ = run("configure", "--gpu", "all")
        assert result.returncode == 0, result.stderr
        executable(root / "bin/uname", '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; -r) echo 6.6.0-microsoft-standard-WSL2;; esac\n')
    result, calls = run("doctor")
    assert result.returncode == 0, result.stderr
    probe = next(call["args"] for call in calls if "--gpus" in call["args"])
    assert probe[probe.index("--gpus") + 1] == ("all" if all_gpus else "device=0")
    selected = str(root / ("compose.cuda-all.yaml" if all_gpus else "compose.cuda.yaml"))
    other = str(root / ("compose.cuda.yaml" if all_gpus else "compose.cuda-all.yaml"))
    compose_calls = [call["args"] for call in calls if "--project-directory" in call["args"]]
    assert compose_calls and all(selected in call and other not in call for call in compose_calls)


@pytest.mark.parametrize("backend", ["cuda", "rocm"])
def test_wsl_never_silently_broadens_gpu_access(operations, backend):
    root, run = operations
    if backend == "rocm":
        result, _ = run("configure", "--backend", "rocm")
        assert result.returncode == 0, result.stderr
    before = (root / ".env").read_bytes()
    executable(root / "bin/uname", '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; -r) echo 6.6.0-microsoft-standard-WSL2;; esac\n')
    result, calls = run("doctor")
    assert result.returncode != 0
    assert ("--gpu all" if backend == "cuda" else "not supported") in result.stderr
    assert not any("--gpus" in call["args"] or "up" in call["args"] for call in calls)
    assert (root / ".env").read_bytes() == before


def test_nvidia_driver_uses_wsl_fallback_only_when_not_on_path(tmp_path):
    helper = Path(__file__).resolve().parents[1] / "gpu-host.sh"
    fallback = tmp_path / "wsl-nvidia-smi"
    executable(fallback, '#!/bin/sh\necho WSL-driver\n')
    local_helper = tmp_path / "gpu-host.sh"
    local_helper.write_text(helper.read_text().replace("/usr/lib/wsl/lib/nvidia-smi", str(fallback)))
    binary = tmp_path / "bin"
    binary.mkdir()
    bash = shutil.which("bash")
    env = {**os.environ, "PATH": str(binary)}
    def check():
        return subprocess.run([bash, "-c", 'source "$1"; check_nvidia_driver', "test", str(local_helper)],
                              env=env, capture_output=True, text=True)
    assert check().stdout.strip() == "WSL-driver"
    executable(binary / "nvidia-smi", '#!/bin/sh\necho PATH-driver\n')
    assert check().stdout.strip() == "PATH-driver"
    executable(binary / "nvidia-smi", '#!/bin/sh\nexit 13\n')
    assert check().returncode == 13  # A broken driver must not be hidden by the fallback.


def test_update_downloads_and_probes_before_persisting_then_tests_model(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    token = (root / "runtime/secrets/vllm_token").read_bytes()
    image = "ghcr.io/jensderkrueger/borgvr-agent:3.9.99"
    result, calls = run("update", "--agent-image", image)
    assert result.returncode == 0, result.stderr
    args = [call["args"] for call in calls]
    assert next(i for i, call in enumerate(args) if "pull" in call) < next(i for i, call in enumerate(args) if "run" in call)
    assert next(i for i, call in enumerate(args) if "up" in call) < next(i for i, call in enumerate(args) if "exec" in call)
    assert all(call["image"] == image for call in calls if "--project-directory" in call["args"])
    backups = list((root / "runtime").glob("env-before-update-*"))
    assert len(backups) == 1 and backups[0].read_bytes() == original
    assert backups[0].stat().st_mode & 0o777 == 0o600
    assert (root / ".env").read_text() == original.decode().replace(DEFAULT_AGENT_IMAGE, image)
    assert (root / ".env").stat().st_mode & 0o777 == 0o600
    assert (root / "runtime/secrets/vllm_token").read_bytes() == token


@pytest.mark.parametrize("failure", ["pull", "run"])
def test_failed_update_preparation_preserves_running_configuration(operations, failure):
    root, run = operations
    original = (root / ".env").read_bytes()
    result, calls = run("update", "--agent-image", "ghcr.io/jensderkrueger/borgvr-agent:3.9.99", failure=failure)
    assert result.returncode != 0
    assert (root / ".env").read_bytes() == original
    assert not list((root / "runtime").glob("env-before-update-*"))
    assert not any("up" in call["args"] or "stop" in call["args"] for call in calls)


def test_failed_update_start_keeps_backup_and_reports_failure(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    result, calls = run("update", "--agent-image", "ghcr.io/jensderkrueger/borgvr-agent:3.9.99", failure="up")
    assert result.returncode != 0 and "Update did not become healthy" in result.stderr
    assert next((root / "runtime").glob("env-before-update-*")).read_bytes() == original
    assert not any("exec" in call["args"] for call in calls)


def test_update_without_new_image_keeps_pins(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    result, calls = run("update")
    assert result.returncode == 0, result.stderr
    assert (root / ".env").read_bytes() == original
    assert not list((root / "runtime").glob("env-before-update-*"))
    assert any("pull" in call["args"] for call in calls)
    assert any("exec" in call["args"] and "--smoke" in call["args"] for call in calls)


@pytest.mark.parametrize("command", ["start", "stop", "restart", "status", "logs", "test"])
def test_operation_commands_only_address_this_deployment(operations, command):
    root, run = operations
    result, calls = run(command)
    assert result.returncode == 0, result.stderr
    compose_calls = [call["args"] for call in calls if "--project-directory" in call["args"]]
    assert compose_calls and all(str(root / "compose.yaml") in call and str(root / ".env") in call for call in compose_calls)
    assert not any("pull" in call for call in compose_calls)
    if command == "restart":
        assert next(i for i, call in enumerate(compose_calls) if "stop" in call) < next(i for i, call in enumerate(compose_calls) if "up" in call)


def test_setup_uninstall_is_preview_unless_confirmed(operations):
    root, run = operations
    result, calls = run("uninstall", "--files-only")
    assert result.returncode == 0 and "Preview only" in result.stdout
    assert (root / ".env").exists() and not calls
    result, calls = run("uninstall", "--files-only", "--yes")
    assert result.returncode == 0 and not (root / ".env").exists() and not (root / "runtime").exists()
    assert not calls


def test_operation_flags_do_not_change_unrelated_settings(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    for args in (("update", "--host", "other.example.org"), ("update", "--yes"),
                 ("stop", "--remove-images"), ("uninstall", "--agent-image", "test:1"),
                 ("update", "--agent-image", "bad image")):
        result, calls = run(*args)
        assert result.returncode != 0 and (root / ".env").read_bytes() == original


def test_image_update_refuses_symlinked_env(tmp_path):
    outside = tmp_path / "outside"
    outside.write_text("BORGVR_AGENT_IMAGE=original:1\n")
    (tmp_path / ".env").symlink_to(outside)
    with pytest.raises(ValueError):
        configure.set_agent_image(tmp_path, "replacement:1")
    assert outside.read_text() == "BORGVR_AGENT_IMAGE=original:1\n"


def test_image_update_failure_keeps_original_and_private_backup(operations, monkeypatch):
    root, _ = operations
    original = (root / ".env").read_bytes()

    def failed_replace(*args):
        raise OSError("Simulated atomic replacement failure")

    monkeypatch.setattr(configure.os, "replace", failed_replace)
    with pytest.raises(OSError):
        configure.set_agent_image(root, "replacement:1")
    assert (root / ".env").read_bytes() == original
    assert next((root / "runtime").glob("env-before-update-*")).read_bytes() == original
    assert not list(root.glob(".env-update-*"))


def test_configure_profile_and_backend_changes_no_containers(operations):
    root, run = operations
    result, calls = run("configure", "--profile", "qwen35-4b", "--backend", "rocm", "--gpu", "1")
    assert result.returncode == 0, result.stderr
    assert not calls
    assert configure.read_value("BORGVR_BACKEND", root) == "rocm"
    assert configure.read_value("BORGVR_GPU", root) == "1"
    result, calls = run("update")
    assert result.returncode == 0, result.stderr
    assert all(str(root / "compose.rocm.yaml") in call["args"] for call in calls if "--project-directory" in call["args"])


@pytest.mark.parametrize("backend", ["cuda", "rocm"])
def test_reinstall_removes_old_containers_before_gpu_probe_without_deleting_data(operations, backend):
    root, run = operations
    configure.write_configuration_changes(root, {"BORGVR_BACKEND": backend})
    original = (root / ".env").read_bytes()
    cert = (root / "runtime/tls/server.crt").read_bytes()
    tokens = [(root / "runtime/secrets" / name).read_bytes() for name in ("agent_token", "vllm_token")]
    # Switch to CUDA after shutting down the previously configured backend.
    result, calls = run("install", "--backend", "cuda")
    assert result.returncode == 0, result.stderr
    args = [call["args"] for call in calls]
    down = next(i for i, call in enumerate(args) if "down" in call)
    assert str(root / f"compose.{backend}.yaml") in args[down]
    assert args[down][-1] == "down" and "-v" not in args[down] and "--volumes" not in args[down]
    assert down < next(i for i, call in enumerate(args) if "run" in call)
    assert down < next(i for i, call in enumerate(args) if "up" in call)
    assert not any("rmi" in call or "prune" in call or "volume" in call for call in args)
    assert (root / "runtime/tls/server.crt").read_bytes() == cert
    assert [(root / "runtime/secrets" / name).read_bytes() for name in ("agent_token", "vllm_token")] == tokens
    if backend == "cuda":
        assert (root / ".env").read_bytes() == original


@pytest.mark.parametrize("host", ["ai1", "192.168.1.50"])
def test_reinstall_changes_network_and_certificate_but_preserves_tokens(operations, host):
    root, run = operations
    original = (root / ".env").read_bytes()
    cert = (root / "runtime/tls/server.crt").read_bytes()
    key = (root / "runtime/tls/server.key").read_bytes()
    token = (root / "runtime/secrets/agent_token").read_bytes()
    result, calls = run("install", "--host", host, "--bind", "0.0.0.0", "--port", "9876")
    assert result.returncode == 0, result.stderr
    assert configure.read_value("BORGVR_BIND_ADDRESS", root) == "0.0.0.0"
    assert configure.read_value("BORGVR_PORT", root) == "9876"
    assert configure.certificate_matches(root / "runtime/tls", host)
    assert configure.certificate_matches(root / "runtime/tls", "127.0.0.1")
    assert (root / "runtime/secrets/agent_token").read_bytes() == token
    backup = next((root / "runtime").glob("tls-before-install-*"))
    assert (backup / "server.crt").read_bytes() == cert and (backup / "server.key").read_bytes() == key
    assert backup.stat().st_mode & 0o777 == 0o700
    assert next((root / "runtime").glob("env-before-update-*")).read_bytes() == original
    assert "clients must trust the new certificate" in result.stdout
    # Repeating the same host must not replace the certificate again.
    current = (root / "runtime/tls/server.crt").read_bytes()
    result, _ = run("install", "--host", host)
    assert result.returncode == 0, result.stderr
    assert (root / "runtime/tls/server.crt").read_bytes() == current
    assert configure.read_value("BORGVR_BIND_ADDRESS", root) == "0.0.0.0"
    assert configure.read_value("BORGVR_PORT", root) == "9876"


def test_failed_reinstall_down_does_not_change_configuration(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    cert = (root / "runtime/tls/server.crt").read_bytes()
    result, calls = run("install", "--host", "ai1", "--bind", "0.0.0.0", failure="down")
    assert result.returncode != 0
    assert (root / ".env").read_bytes() == original
    assert (root / "runtime/tls/server.crt").read_bytes() == cert
    assert not any("up" in call["args"] or "run" in call["args"] for call in calls)


def test_invalid_reinstall_options_do_not_stop_server(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    result, calls = run("install", "--host", "https://bad.example")
    assert result.returncode != 0 and not calls
    assert (root / ".env").read_bytes() == original


def test_failed_reinstall_config_write_restores_certificate(operations, monkeypatch):
    root, _ = operations
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    args = parser.parse_args([])
    args.host, args.bind, args.port, args.agent_image, args.check = "ai1", "0.0.0.0", None, None, False
    original = (root / ".env").read_bytes()
    files = {name: (root / "runtime/tls" / name).read_bytes() for name in ("server.crt", "server.key")}

    def fail(*args):
        raise OSError("Simulated config write failure")

    monkeypatch.setattr(configure, "write_configuration_changes", fail)
    with pytest.raises(OSError, match="Simulated"):
        configure.install_configuration(root, args)
    assert (root / ".env").read_bytes() == original
    assert all((root / "runtime/tls" / name).read_bytes() == data for name, data in files.items())
    assert configure.certificate_matches(root / "runtime/tls", "localhost")


def test_model_switch_is_one_command_and_preserves_credentials(operations):
    root, run = operations
    token = (root / "runtime/secrets/agent_token").read_bytes()
    cert = (root / "runtime/tls/server.crt").read_bytes()
    for profile, model in (("qwen35-4b", "Qwen/Qwen3.5-4B"), ("qwen36-35b", "Qwen/Qwen3.6-35B-A3B")):
        result, calls = run("model", profile)
        assert result.returncode == 0, result.stderr
        assert configure.read_value("BORGVR_MODEL", root) == model
        assert (root / "runtime/secrets/agent_token").read_bytes() == token
        assert (root / "runtime/tls/server.crt").read_bytes() == cert
        assert any("up" in call["args"] for call in calls)
        assert any("--capabilities" in call["args"] for call in calls)
        assert not any("down" in call["args"] or "volume" in call["args"] for call in calls)


def test_model_list_and_invalid_selection_do_not_change_configuration(operations):
    root, run = operations
    original = (root / ".env").read_bytes()
    result, calls = run("model")
    assert result.returncode == 0 and not calls
    assert "Configured model:" in result.stdout and "qwen35-4b" in result.stdout
    result, calls = run("model", "missing-profile")
    assert result.returncode != 0 and (root / ".env").read_bytes() == original
    assert not any("pull" in call["args"] or "up" in call["args"] for call in calls)
