import argparse
from pathlib import Path
import subprocess

import pytest

import configure
import development
from model_config import PROFILES
import switch_model as menu


@pytest.mark.parametrize("answer,expected", [("0", None), ("1", "qwen36-35b"),
    ("2", "qwen35-4b"), ("3", "qwen38-27b"), ("4", "mistral-small4-nvfp4")])
def test_numbered_menu(answer, expected):
    output = []
    assert menu.select_profile(PROFILES["qwen38-27b"]["MODEL"], ask=lambda _: answer, output=output.append) == expected
    assert any("Qwen3.8-27B [aktuell]" in line for line in output)
    assert not any("custom" in line for line in output)


def test_invalid_menu_input_and_eof_have_no_side_effects():
    answers = iter(["", "-1", "5", "$(id)", "1; exit", "١", "0"])
    assert menu.select_profile(None, ask=lambda _: next(answers), output=lambda _: None) is None
    def eof(_):
        raise EOFError
    assert menu.select_profile(None, ask=eof, output=lambda _: None) is None


@pytest.fixture
def installed(tmp_path):
    configure.create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "all")
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    changes = configure.inference_values(parser.parse_args(["--profile", "qwen38-27b", "--tensor-parallel-size", "2",
        "--nccl-p2p-disable", "true", "--disable-custom-all-reduce", "true"]), configure.read_configuration(tmp_path))
    configure.write_configuration_changes(tmp_path, changes)
    return tmp_path


def test_switch_retains_active_development_source_and_credentials(installed, monkeypatch):
    root = installed
    marker = development.marker(root)
    marker.write_text('{"root":"test-retained-development"}')
    verified = []
    monkeypatch.setattr(development, "overlay_file", lambda path: verified.append(path))
    protected = [marker, root / "runtime/tls/server.crt", root / "runtime/tls/server.key",
                 root / "runtime/secrets/agent_token", root / "runtime/secrets/vllm_token"]
    before = {path: path.read_bytes() for path in protected}
    original = configure.read_configuration(root)
    calls = []
    menu.switch(root, "mistral-small4-nvfp4", run=lambda path, command: calls.append(command))
    assert calls == ["doctor", "restart", "test"] and verified == [root]
    updated = configure.read_configuration(root)
    for key in ("BORGVR_AGENT_IMAGE", "BORGVR_VLLM_IMAGE", "BORGVR_GPU", "BORGVR_TENSOR_PARALLEL_SIZE",
                "BORGVR_NCCL_P2P_DISABLE", "BORGVR_DISABLE_CUSTOM_ALL_REDUCE", "BORGVR_BIND_ADDRESS", "BORGVR_PORT"):
        assert updated[key] == original[key]
    assert all(path.read_bytes() == data for path, data in before.items())


@pytest.mark.parametrize("failing", ["doctor", "restart", "test"])
def test_failed_switch_restores_exact_configuration(installed, failing):
    original = (installed / ".env").read_bytes()
    calls = []
    failed = False
    def run(root, command):
        nonlocal failed
        calls.append(command)
        if command == failing and not failed:
            failed = True
            raise subprocess.CalledProcessError(1, command)
    with pytest.raises(subprocess.CalledProcessError):
        menu.switch(installed, "mistral-small4-nvfp4", run=run)
    assert (installed / ".env").read_bytes() == original
    assert (installed / ".env").stat().st_mode & 0o777 == 0o600
    if failing == "doctor":
        assert calls == ["doctor"]
    else:
        assert calls[-2:] == ["restart", "test"]


def test_keyboard_interrupt_attempts_to_restore_previous_model(installed):
    original = (installed / ".env").read_bytes()
    calls = []
    def run(root, command):
        calls.append(command)
        if len(calls) == 2:
            raise KeyboardInterrupt
    with pytest.raises(KeyboardInterrupt):
        menu.switch(installed, "mistral-small4-nvfp4", run=run)
    assert calls == ["doctor", "restart", "restart", "test"]
    assert (installed / ".env").read_bytes() == original


def test_failed_recovery_does_not_claim_model_is_running(installed, capsys):
    original = (installed / ".env").read_bytes()
    def run(root, command):
        if command == "restart":
            raise subprocess.CalledProcessError(1, command)
    with pytest.raises(subprocess.CalledProcessError):
        menu.switch(installed, "mistral-small4-nvfp4", run=run)
    assert (installed / ".env").read_bytes() == original
    error = capsys.readouterr().err
    assert "Wiederanlauf ist fehlgeschlagen" in error
    assert "Bisheriges Modell läuft wieder" not in error


def test_interrupted_switch_recovers_without_erasing_new_external_changes(installed):
    def run(root, command):
        configure.write_configuration_changes(root, {"BORGVR_PORT": "9999"})
        raise KeyboardInterrupt
    with pytest.raises(KeyboardInterrupt):
        menu.switch(installed, "mistral-small4-nvfp4", run=run)
    assert configure.read_value("BORGVR_PORT", installed) == "9999"


def test_invalid_development_state_prevents_any_change(installed, monkeypatch):
    development.marker(installed).write_text("{}")
    original = (installed / ".env").read_bytes()
    def reject(root):
        raise ValueError("different installation")
    monkeypatch.setattr(development, "overlay_file", reject)
    with pytest.raises(ValueError, match="different installation"):
        menu.switch(installed, "mistral-small4-nvfp4")
    assert (installed / ".env").read_bytes() == original


def test_current_profile_is_a_noop(installed):
    original = (installed / ".env").read_bytes()
    menu.switch(installed, "qwen38-27b", run=lambda *_: pytest.fail("No restart expected"))
    assert (installed / ".env").read_bytes() == original


@pytest.mark.parametrize("profile", ["custom", "missing", "$(id)"])
def test_unlisted_profiles_are_rejected_before_any_change(installed, profile):
    original = (installed / ".env").read_bytes()
    with pytest.raises(ValueError, match="Unbekanntes"):
        menu.switch(installed, profile, run=lambda *_: pytest.fail("No setup command expected"))
    assert (installed / ".env").read_bytes() == original


def test_shell_entry_point_help_needs_no_privileges():
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(["bash", str(root / "switch-model.sh"), "--help"], capture_output=True, text=True)
    assert result.returncode == 0 and "Interactive model switching" in result.stdout
