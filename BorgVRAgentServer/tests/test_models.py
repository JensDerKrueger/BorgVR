import argparse
from dataclasses import replace
import os
from pathlib import Path
import subprocess
import runpy
import sys
from types import SimpleNamespace

import pytest
import yaml

import configure
from model_config import CUDA_IMAGE, ROCM_IMAGE, PROFILES, ModelConfig, profile_values


@pytest.mark.parametrize("profile", [name for name in PROFILES if name != "custom"])
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
    assert config.thinking == "default"
    assert "qwen3" not in config.arguments() and "--reasoning-parser" not in config.arguments()
    assert "hermes" in config.arguments()


def test_mistral_nvfp4_profile_has_vision_parsers_and_conservative_runtime():
    config = ModelConfig.from_env(profile_values("mistral-small4-nvfp4"))
    assert config.model == "mistralai/Mistral-Small-4-119B-2603-NVFP4"
    assert config.tool_parser == config.reasoning_parser == "mistral"
    assert config.thinking == "on" and config.vision
    assert config.context == 16384 and config.sequences == 1 and config.eager
    args = config.arguments()
    assert args[args.index("--quantization") + 1] == "compressed-tensors"
    assert args[args.index("--attention-backend") + 1] == "TRITON_MLA"
    assert "--enforce-eager" in args and "qwen3" not in args


def test_mistral_switch_and_return_reset_model_options_but_keep_hardware_and_endpoint(tmp_path):
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    configure.create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "all")
    original = configure.read_configuration(tmp_path)
    original.update(BORGVR_TENSOR_PARALLEL_SIZE="2", BORGVR_NCCL_P2P_DISABLE="true",
                    BORGVR_DISABLE_CUSTOM_ALL_REDUCE="true")
    args = parser.parse_args(["--profile", "mistral-small4-nvfp4"])
    mistral = {**original, **configure.inference_values(args, original)}
    assert ModelConfig.from_env(mistral).attention_backend == "TRITON_MLA"
    for key in ("BORGVR_GPU", "BORGVR_TENSOR_PARALLEL_SIZE", "BORGVR_NCCL_P2P_DISABLE",
                "BORGVR_DISABLE_CUSTOM_ALL_REDUCE", "BORGVR_BIND_ADDRESS", "BORGVR_PORT", "BORGVR_AGENT_IMAGE"):
        assert mistral[key] == original[key]
    args = parser.parse_args(["--profile", "qwen38-27b"])
    qwen = ModelConfig.from_env({**mistral, **configure.inference_values(args, mistral)})
    assert qwen.quantization == qwen.attention_backend == "auto"
    assert not qwen.eager and qwen.thinking == "off" and qwen.tensor_parallel_size == 2


def test_mistral_nvfp4_rejects_rocm_before_writing_configuration():
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    args = parser.parse_args(["--profile", "mistral-small4-nvfp4", "--backend", "rocm"])
    with pytest.raises(ValueError, match="NVIDIA CUDA/Blackwell"):
        configure.inference_values(args)


@pytest.mark.parametrize("key,value", [("VISION_ENABLED", "false"), ("GPU_MEMORY_FRACTION", "nan"),
    ("GPU_MEMORY_FRACTION", "1.1"), ("MAX_SEQS", "0"), ("CONTEXT_LENGTH", "-1"),
    ("DTYPE", "unsupported"), ("THINKING_MODE", "maybe"), ("TOOL_PARSER", "../code.py"),
    ("REASONING_PARSER", "$(id)"), ("CPU_OFFLOAD_GB", "-1"), ("MODEL_REVISION", "../main"),
    ("ATTENTION_BACKEND", "../code.py")])
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


@pytest.mark.parametrize("size", [1, 2, 4, 8])
def test_tensor_parallel_size_reaches_vllm_and_uses_local_processes(size):
    config = ModelConfig.from_env({**profile_values("qwen38-27b"), "BORGVR_TENSOR_PARALLEL_SIZE": str(size)})
    args = config.arguments()
    assert args[args.index("--tensor-parallel-size") + 1] == str(size)
    if size > 1:
        assert args[args.index("--distributed-executor-backend") + 1] == "mp"
    else:
        assert "--distributed-executor-backend" not in args
    assert ModelConfig.from_env({}).tensor_parallel_size == 1


@pytest.mark.parametrize("value", ["0", "-1", "9", "2.5", "two", "$(id)"])
def test_invalid_tensor_parallel_size_is_rejected(value):
    with pytest.raises(ValueError):
        ModelConfig.from_env({"BORGVR_TENSOR_PARALLEL_SIZE": value})


@pytest.mark.parametrize("key", ["BORGVR_NCCL_P2P_DISABLE", "BORGVR_DISABLE_CUSTOM_ALL_REDUCE"])
@pytest.mark.parametrize("value", ["1", "yes", "TRUE", "", "$(id)"])
def test_gpu_workarounds_require_strict_booleans(key, value):
    with pytest.raises(ValueError):
        ModelConfig.from_env({key: value})


def test_gpu_workaround_defaults_and_compose_isolation(tmp_path):
    config = ModelConfig.from_env({})
    assert not config.nccl_p2p_disable and not config.disable_custom_all_reduce
    assert "--disable-custom-all-reduce" not in config.arguments()
    configure.create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    root = Path(__file__).resolve().parents[1]
    services = yaml.safe_load((root / "compose.yaml").read_text())["services"]
    for key in configure.GPU_RUNTIME_OPTIONS.values():
        assert configure.read_value(key, tmp_path) == "false"
        assert services["vllm"]["environment"][key] == "${" + key + ":-false}"
        assert key not in services["agent"]["environment"]
    (tmp_path / ".env").write_text("BORGVR_MODEL=Qwen/Qwen3.8-27B\n")
    for key in configure.GPU_RUNTIME_OPTIONS.values():
        assert configure.read_value(key, tmp_path) == "false"


def test_parallel_hardware_selection_survives_model_switch_and_preserves_connection(tmp_path):
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    configure.create_configuration(tmp_path, "134.91.11.251", "134.91.11.251", 8766, "0")
    original = configure.read_configuration(tmp_path)
    tokens = {name: (tmp_path / "runtime/secrets" / name).read_bytes() for name in ("agent_token", "vllm_token")}
    certificate = (tmp_path / "runtime/tls/server.crt").read_bytes()
    options = parser.parse_args(["--profile", "qwen38-27b", "--gpu", "all", "--tensor-parallel-size", "2",
                                "--nccl-p2p-disable", "true", "--disable-custom-all-reduce", "true"])
    configure.write_configuration_changes(tmp_path, configure.inference_values(options, original))
    dual = configure.read_configuration(tmp_path)
    options = parser.parse_args(["--profile", "qwen35-4b"])
    configure.write_configuration_changes(tmp_path, configure.inference_values(options, dual))
    updated = configure.read_configuration(tmp_path)
    assert updated["BORGVR_GPU"] == "all" and updated["BORGVR_TENSOR_PARALLEL_SIZE"] == "2"
    assert all(updated[key] == "true" for key in configure.GPU_RUNTIME_OPTIONS.values())
    options = parser.parse_args(["--nccl-p2p-disable", "false", "--disable-custom-all-reduce", "false"])
    changes = configure.inference_values(options, updated)
    assert all(changes[key] == "false" for key in configure.GPU_RUNTIME_OPTIONS.values())
    for key in ("BORGVR_BIND_ADDRESS", "BORGVR_PORT", "BORGVR_UID", "BORGVR_GID"):
        assert updated[key] == original[key]
    assert (tmp_path / "runtime/tls/server.crt").read_bytes() == certificate
    assert all((tmp_path / "runtime/secrets" / name).read_bytes() == value for name, value in tokens.items())


@pytest.mark.parametrize("backend,gpu", [("cuda", "0"), ("cuda", "GPU-1234"), ("rocm", "0")])
def test_parallelism_does_not_silently_expand_gpu_access(backend, gpu):
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    options = parser.parse_args(["--backend", backend, "--gpu", gpu, "--tensor-parallel-size", "2"])
    with pytest.raises(ValueError, match="--gpu all"):
        configure.inference_values(options)


@pytest.mark.parametrize("visible", [1, 2])
@pytest.mark.parametrize("p2p,custom", [(False, False), (True, False), (False, True), (True, True)])
def test_vllm_bootstrap_checks_gpu_count_before_starting_workers(monkeypatch, visible, p2p, custom):
    root = Path(__file__).resolve().parents[1]
    monkeypatch.setenv("BORGVR_TENSOR_PARALLEL_SIZE", "2")
    monkeypatch.setenv("BORGVR_NCCL_P2P_DISABLE", str(p2p).lower())
    monkeypatch.setenv("BORGVR_DISABLE_CUSTOM_ALL_REDUCE", str(custom).lower())
    monkeypatch.delenv("NCCL_P2P_DISABLE", raising=False)
    monkeypatch.setitem(sys.modules, "torch", SimpleNamespace(cuda=SimpleNamespace(device_count=lambda: visible)))
    original_read = Path.read_text
    monkeypatch.setattr(Path, "read_text", lambda self, *args, **kwargs:
        "test-token" if str(self) == "/run/secrets/vllm_token" else original_read(self, *args, **kwargs))
    calls = []
    class Executed(Exception):
        pass
    def execute(binary, args):
        assert os.environ.get("NCCL_P2P_DISABLE") == ("1" if p2p else None)
        assert ("--disable-custom-all-reduce" in args) == custom
        assert os.environ["VLLM_API_KEY"] == "test-token"
        assert "test-token" not in args
        calls.append((binary, args))
        raise Executed()
    monkeypatch.setattr(os, "execvp", execute)
    if visible == 1:
        with pytest.raises(SystemExit, match="only 1 are visible"):
            runpy.run_path(str(root / "vllm_start.py"), run_name="__main__")
        assert not calls
    else:
        with pytest.raises(Executed):
            runpy.run_path(str(root / "vllm_start.py"), run_name="__main__")
        assert calls[0][1][calls[0][1].index("--tensor-parallel-size") + 1] == "2"


def test_nccl_workaround_cannot_silently_follow_backend_switch_to_rocm():
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    with pytest.raises(ValueError, match="requires --backend cuda"):
        configure.inference_values(parser.parse_args(["--backend", "rocm", "--nccl-p2p-disable", "true"]))


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
    cuda_all = yaml.safe_load((root / "compose.cuda-all.yaml").read_text())["services"]["vllm"]
    rocm = yaml.safe_load((root / "compose.rocm.yaml").read_text())["services"]["vllm"]
    assert "deploy" not in common and "devices" not in common
    assert cuda["deploy"]["resources"]["reservations"]["devices"][0]["driver"] == "nvidia"
    assert rocm["devices"] == ["/dev/kfd:/dev/kfd", "/dev/dri:/dev/dri"]
    assert "deploy" not in rocm and "devices" not in cuda
    assert common["cap_drop"] == ["ALL"] and "cap_add" not in rocm
    assert "privileged" not in rocm and "ipc" not in rocm
    device = cuda_all["deploy"]["resources"]["reservations"]["devices"][0]
    assert device == {"driver": "nvidia", "count": "all", "capabilities": ["gpu"]}
    assert cuda_all["group_add"] == cuda["group_add"]
    assert not {"devices", "privileged", "ipc", "cap_add", "ports"} & cuda_all.keys()


@pytest.mark.parametrize("backend", ["cuda", "rocm"])
def test_all_gpus_is_explicit_and_cuda_only(backend):
    parser = argparse.ArgumentParser()
    configure.add_model_options(parser)
    parser.add_argument("--agent-image")
    args = parser.parse_args(["--backend", backend, "--gpu", "all"])
    if backend == "rocm":
        with pytest.raises(ValueError, match="only CUDA"):
            configure.inference_values(args)
    else:
        values = configure.inference_values(args)
        assert values["BORGVR_GPU"] == "all"
        assert configure.inference_values(parser.parse_args([]))["BORGVR_GPU"] == "0"


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


@pytest.mark.parametrize("groups,expected", [(("1000", "1000", "0"), ["1000", "0"]),
    (("10001", "107", "44"), ["10001", "107", "44"]), (("0", "0", "0"), ["0"])])
def test_rocm_group_overlay_deduplicates_host_groups(tmp_path, groups, expected):
    keys = ("BORGVR_GID", "BORGVR_RENDER_GID", "BORGVR_VIDEO_GID")
    (tmp_path / ".env").write_text("".join(f"{key}={value}\n" for key, value in zip(keys, groups)))
    assert configure.gpu_groups(tmp_path)["services"]["vllm"]["group_add"] == expected
