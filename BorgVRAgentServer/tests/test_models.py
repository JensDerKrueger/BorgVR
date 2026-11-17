import argparse
from dataclasses import replace
import os
from pathlib import Path
import subprocess

import pytest
import yaml

import configure
from model_config import CUDA_IMAGE, ROCM_IMAGE, PROFILES, ModelConfig, profile_values


@pytest.mark.parametrize("profile", ["qwen36-35b", "qwen35-4b", "qwen38-27b"])
def test_profiles_pin_independent_model_revisions_and_keep_vision(profile):
    config = ModelConfig.from_env(profile_values(profile))
    assert config.model == PROFILES[profile]["MODEL"]
    assert len(config.revision) == 40 and config.vision
    args = config.arguments()
    assert "--trust-remote-code" not in args and "--enable-auto-tool-choice" in args
    assert args[args.index("--revision") + 1] == config.revision


def test_custom_model_has_no_qwen_request_or_parser_assumptions():
    values = profile_values("custom")
    values.update(BORGVR_MODEL="Other/Vision-Instruct", BORGVR_MODEL_REVISION="main", BORGVR_TOOL_PARSER="hermes")
    config = ModelConfig.from_env(values)
    assert "extra_body" not in config.request_settings()
    assert "qwen3" not in config.arguments() and "--reasoning-parser" not in config.arguments()
    assert "hermes" in config.arguments()


@pytest.mark.parametrize("key,value", [("VISION_ENABLED", "false"), ("GPU_MEMORY_FRACTION", "nan"),
    ("GPU_MEMORY_FRACTION", "1.1"), ("MAX_SEQS", "0"), ("CONTEXT_LENGTH", "-1"),
    ("DTYPE", "unsupported"), ("THINKING_MODE", "maybe"), ("TOOL_PARSER", "../code.py"),
    ("REASONING_PARSER", "$(id)"), ("CPU_OFFLOAD_GB", "-1"), ("MODEL_REVISION", "../main")])
def test_model_options_reject_invalid_or_unsafe_values(key, value):
    with pytest.raises((ValueError, TypeError)):
        ModelConfig.from_env({**profile_values("qwen36-35b"), "BORGVR_" + key: value})


def test_memory_and_quantization_controls_reach_vllm():
    config = replace(ModelConfig.from_env(profile_values("qwen35-4b")), dtype="float16", quantization="awq",
                     eager=True, cpu_offload_gb=8)
    args = config.arguments()
    assert "--enforce-eager" in args and args[args.index("--quantization") + 1] == "awq"
    assert args[args.index("--max-num-seqs") + 1] == "1"
    assert args[args.index("--dtype") + 1] == "float16"


@pytest.mark.parametrize("backend,image", [("cuda", CUDA_IMAGE), ("rocm", ROCM_IMAGE)])
def test_initial_backend_and_small_profile_configuration(tmp_path, backend, image):
    source = Path(__file__).resolve().parents[1]
    args = [os.sys.executable, str(source / "configure.py"), "profiles"]
    assert "qwen38-27b" in subprocess.check_output(args, text=True)
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    options = parser.parse_args(["--backend", backend, "--profile", "qwen35-4b"])
    values = configure.inference_values(options)
    assert values["BORGVR_VLLM_IMAGE"] == image
    assert values["BORGVR_MIN_FREE_GIB"] == "80"
    configure.create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0", inference=values)
    assert configure.read_value("BORGVR_BACKEND", tmp_path) == backend
    assert configure.read_value("BORGVR_MODEL", tmp_path) == "Qwen/Qwen3.5-4B"


def test_backend_overlays_do_not_mix_devices_or_weaken_security():
    root = Path(__file__).resolve().parents[1]
    common = yaml.safe_load((root / "compose.yaml").read_text())["services"]["vllm"]
    cuda = yaml.safe_load((root / "compose.cuda.yaml").read_text())["services"]["vllm"]
    rocm = yaml.safe_load((root / "compose.rocm.yaml").read_text())["services"]["vllm"]
    assert "deploy" not in common and "devices" not in common
    assert cuda["deploy"]["resources"]["reservations"]["devices"][0]["driver"] == "nvidia"
    assert rocm["devices"] == ["/dev/kfd:/dev/kfd", "/dev/dri:/dev/dri"]
    assert "deploy" not in rocm and "devices" not in cuda
    assert common["cap_drop"] == ["ALL"] and "cap_add" not in rocm
    assert "privileged" not in rocm and "ipc" not in rocm


def test_model_switch_does_not_reuse_old_revision_or_private_keys(tmp_path):
    configure.create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    original = configure.read_configuration(tmp_path)
    token = (tmp_path / "runtime/secrets/agent_token").read_bytes()
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    options = parser.parse_args(["--profile", "qwen38-27b", "--backend", "rocm"])
    changes = configure.inference_values(options, original)
    configure.write_configuration_changes(tmp_path, changes)
    updated = configure.read_configuration(tmp_path)
    assert updated["BORGVR_MODEL_REVISION"] == PROFILES["qwen38-27b"]["MODEL_REVISION"]
    assert updated["BORGVR_MODEL_REVISION"] != original["BORGVR_MODEL_REVISION"]
    assert updated["BORGVR_VLLM_IMAGE"] == ROCM_IMAGE
    assert (tmp_path / "runtime/secrets/agent_token").read_bytes() == token
    options = parser.parse_args(["--model", "Other/Vision", "--tool-parser", "hermes"])
    with pytest.raises(ValueError, match="revision"):
        configure.inference_values(options, updated)


def test_legacy_configuration_keeps_model_and_cuda_defaults(tmp_path):
    (tmp_path / ".env").write_text("BORGVR_MODEL=Qwen/Qwen3.6-35B-A3B\nBORGVR_GPU=0\n")
    assert configure.read_value("BORGVR_BACKEND", tmp_path) == "cuda"
    assert configure.read_value("BORGVR_MAX_SEQS", tmp_path) == "2"
    assert configure.read_value("BORGVR_MIN_FREE_GIB", tmp_path) == "200"


def test_recursive_python_caches_are_excluded_from_image_context():
    text = (Path(__file__).resolve().parents[1] / ".dockerignore").read_text()
    assert "**/__pycache__" in text and "**/*.pyc" in text
