"""Validated model/runtime options shared by setup, vLLM and the agent."""

from dataclasses import dataclass
import math
import re

CUDA_IMAGE = "vllm/vllm-openai:v0.34.0@sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1"
ROCM_IMAGE = "vllm/vllm-openai-rocm:v0.34.0@sha256:3cb773d23f063afa86291ef75773cdd486154ddea94c213300f4ed7cc42b7af1"
MODEL_REVISION = "345d467b117d1fd5eda9b879a5988de9ae5f47a7"

PROFILES = {
    "qwen36-35b": {
        "MODEL": "Qwen/Qwen3.6-35B-A3B", "MODEL_REVISION": MODEL_REVISION,
        "TOOL_PARSER": "qwen3_coder", "REASONING_PARSER": "qwen3", "THINKING_MODE": "off",
        "VISION_ENABLED": "true", "CONTEXT_LENGTH": "16384", "MAX_SEQS": "2",
        "MIN_FREE_GIB": "200",
    },
    "qwen35-4b": {
        "MODEL": "Qwen/Qwen3.5-4B", "MODEL_REVISION": "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a",
        "TOOL_PARSER": "qwen3_coder", "REASONING_PARSER": "qwen3", "THINKING_MODE": "off",
        "VISION_ENABLED": "true", "CONTEXT_LENGTH": "8192", "MAX_SEQS": "1",
        "MIN_FREE_GIB": "80",
    },
    "qwen38-27b": {
        "MODEL": "Qwen/Qwen3.8-27B", "MODEL_REVISION": "37561816e66b5b9153b1b64c10968c18c1e6f4a0",
        "TOOL_PARSER": "qwen3_coder", "REASONING_PARSER": "qwen3", "THINKING_MODE": "off",
        "VISION_ENABLED": "true", "CONTEXT_LENGTH": "16384", "MAX_SEQS": "2",
        "MIN_FREE_GIB": "160",
    },
    "custom": {
        "MODEL": "", "MODEL_REVISION": "", "TOOL_PARSER": "",
        "REASONING_PARSER": "none", "THINKING_MODE": "default", "VISION_ENABLED": "true",
        "CONTEXT_LENGTH": "8192", "MAX_SEQS": "1", "MIN_FREE_GIB": "80",
    },
}
BASE = {"DTYPE": "auto", "QUANTIZATION": "auto", "GPU_MEMORY_FRACTION": "0.85",
        "ENFORCE_EAGER": "false", "CPU_OFFLOAD_GB": "0", "ATTENTION_BACKEND": "auto"}
MODEL_KEYS = set(BASE) | set(PROFILES["qwen36-35b"])


def boolean(value):
    if value not in ("true", "false"):
        raise ValueError("Expected true or false")
    return value == "true"


def choice(value, values):
    if value not in values:
        raise ValueError("Expected one of: " + ", ".join(values))
    return value


def number(value, minimum, maximum, integer=False):
    result = int(value) if integer else float(value)
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ValueError(f"Value must be between {minimum} and {maximum}")
    return result


def identifier(value, optional=False):
    if optional and value == "none":
        return value
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}", value):
        raise ValueError("Expected a parser/quantization identifier, not a path or command")
    return value


def profile_values(name):
    return {"BORGVR_" + key: value for key, value in {**BASE, **PROFILES[name]}.items()}


@dataclass(frozen=True)
class ModelConfig:
    model: str
    revision: str
    tool_parser: str
    reasoning_parser: str
    thinking: str
    vision: bool
    dtype: str
    quantization: str
    context: int
    sequences: int
    memory_fraction: float
    min_free_gib: int
    eager: bool
    cpu_offload_gb: float
    tensor_parallel_size: int = 1
    nccl_p2p_disable: bool = False
    disable_custom_all_reduce: bool = False
    attention_backend: str = "auto"

    @classmethod
    def from_env(cls, env):
        model = env.get("BORGVR_MODEL", PROFILES["qwen36-35b"]["MODEL"])
        profile = next((name for name, values in PROFILES.items() if values["MODEL"] == model), "custom")
        values = {**profile_values(profile), **env}
        get = lambda key: values["BORGVR_" + key]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}(?:/[A-Za-z0-9][A-Za-z0-9_.-]{0,95})?", model):
            raise ValueError("Model must be a Hugging Face repository identifier")
        revision = get("MODEL_REVISION")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./-]{0,127}", revision) or ".." in revision.split("/"):
            raise ValueError("Specify an explicit model revision (commit recommended, or main)")
        context = number(get("CONTEXT_LENGTH"), 2048, 1048576, True)
        if not boolean(get("VISION_ENABLED")):
            raise ValueError("BorgVR requires an image-capable model with tool calling; text-only models are not supported")
        return cls(model, revision, identifier(get("TOOL_PARSER")),
                   identifier(get("REASONING_PARSER"), True),
                   choice(get("THINKING_MODE"), ("default", "off", "on")), boolean(get("VISION_ENABLED")),
                   choice(get("DTYPE"), ("auto", "float16", "bfloat16", "float32")),
                   identifier(get("QUANTIZATION")), context,
                   number(get("MAX_SEQS"), 1, 16, True),
                   number(get("GPU_MEMORY_FRACTION"), 0.05, 0.98), number(get("MIN_FREE_GIB"), 1, 1048576, True),
                   boolean(get("ENFORCE_EAGER")), number(get("CPU_OFFLOAD_GB"), 0, 4096),
                   number(values.get("BORGVR_TENSOR_PARALLEL_SIZE", "1"), 1, 8, True),
                   boolean(values.get("BORGVR_NCCL_P2P_DISABLE", "false")),
                   boolean(values.get("BORGVR_DISABLE_CUSTOM_ALL_REDUCE", "false")),
                   identifier(get("ATTENTION_BACKEND")))

    def arguments(self):
        result = ["vllm", "serve", self.model, "--revision", self.revision,
                  "--host", "0.0.0.0", "--port", "8000", "--tensor-parallel-size", str(self.tensor_parallel_size),
                  "--dtype", self.dtype, "--max-model-len", str(self.context),
                  "--gpu-memory-utilization", str(self.memory_fraction), "--max-num-seqs", str(self.sequences),
                  "--enable-auto-tool-choice", "--tool-call-parser", self.tool_parser, "--no-enable-log-requests"]
        if self.reasoning_parser != "none":
            result += ["--reasoning-parser", self.reasoning_parser]
        if self.attention_backend != "auto":
            result += ["--attention-backend", self.attention_backend]
        if self.tensor_parallel_size > 1:
            result += ["--distributed-executor-backend", "mp"]
        if self.disable_custom_all_reduce:
            result += ["--disable-custom-all-reduce"]
        if self.vision:
            result += ["--limit-mm-per-prompt", '{"image":2,"video":0}']
        if self.quantization != "auto":
            result += ["--quantization", self.quantization]
        if self.eager:
            result += ["--enforce-eager"]
        if self.cpu_offload_gb:
            result += ["--cpu-offload-gb", str(self.cpu_offload_gb)]
        return result
