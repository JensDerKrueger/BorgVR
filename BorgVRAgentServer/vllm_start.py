"""Keep credentials out of Compose interpolation and process arguments."""

import os
from pathlib import Path

if __name__ == "__main__":
    os.environ["VLLM_API_KEY"] = Path("/run/secrets/vllm_token").read_text().strip()
    os.execvp("vllm", [
        "vllm", "serve", os.environ["BORGVR_MODEL"],
        "--revision", os.environ["BORGVR_MODEL_REVISION"],
        "--host", "0.0.0.0", "--port", "8000",
        "--tensor-parallel-size", "1", "--dtype", "bfloat16",
        "--max-model-len", os.environ["BORGVR_CONTEXT_LENGTH"],
        "--gpu-memory-utilization", os.environ["BORGVR_GPU_MEMORY_FRACTION"],
        "--max-num-seqs", "2", "--limit-mm-per-prompt", '{"image":2,"video":0}',
        "--enable-auto-tool-choice", "--tool-call-parser", "qwen3_coder",
        "--reasoning-parser", "qwen3", "--no-enable-log-requests",
    ])
