import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

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
    for name in ("setup.sh", "setup-host.sh"):
        subprocess.run(["bash", "-n", str(root / name)], check=True)
        result = subprocess.run(["bash", str(root / name), "--help"], capture_output=True, text=True, check=True)
        assert "--install-host-deps" not in result.stdout
    assert "--docker-user" in result.stdout


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
    assert vllm["group_add"] == ["${BORGVR_GID}"]
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


@pytest.mark.parametrize("username,uid,valid", [("borgvr", "1000", True), ("root", "0", False),
    ("--root", "1000", False), ("bad name", "1000", False), ("x;touch", "1000", False)])
def test_root_setup_validates_delegated_account(username, uid, valid):
    result = host_function('DOCKER_USER="$1"; FAKE_UID="$2"; '
                           'id() { printf "%s\\n" "$FAKE_UID"; }; validate_docker_user', username, uid)
    assert (result.returncode == 0) == valid


@pytest.mark.parametrize("username,groups,changes", [("", "staff", False),
    ("borgvr", "staff docker", False), ("borgvr", "staff", True)])
def test_root_setup_only_delegates_when_explicit(username, groups, changes):
    result = host_function('DOCKER_USER="$1"; groups="$2"; '
                           'getent() { return 0; }; id() { printf "%s\\n" "$groups"; }; '
                           'usermod() { printf "USERMOD %s\\n" "$*"; }; grant_docker_access', username, groups)
    assert result.returncode == 0
    assert ("USERMOD -aG docker borgvr" in result.stdout) == changes


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
    for name in ("setup.sh", "configure.py"):
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
    probes = [i for i, call in enumerate(calls) if "run" in call and "--no-deps" in call]
    assert len(probes) == 2 and max(probes) < next(i for i, call in enumerate(calls) if "up" in call)
    if prebuilt is False:
        assert any(str(tmp_path / "compose.build.yaml") in call for call in calls)
    else:
        assert DEFAULT_AGENT_IMAGE in (tmp_path / ".env").read_text()


def test_user_setup_docker_access_failure_never_falls_back_to_sudo(tmp_path):
    source = Path(__file__).resolve().parents[1]
    shutil.copyfile(source / "setup.sh", tmp_path / "setup.sh")
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
