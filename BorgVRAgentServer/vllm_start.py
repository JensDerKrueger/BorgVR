"""Keep credentials out of Compose interpolation and process arguments."""

import os
from pathlib import Path

from model_config import ModelConfig

if __name__ == "__main__":
    os.environ["VLLM_API_KEY"] = Path("/run/secrets/vllm_token").read_text().strip()
    config = ModelConfig.from_env(os.environ)
    if config.nccl_p2p_disable:
        os.environ["NCCL_P2P_DISABLE"] = "1"
    if config.tensor_parallel_size > 1:
        import torch
        visible = torch.cuda.device_count()
        if visible < config.tensor_parallel_size:
            raise SystemExit(f"Tensor parallelism requires {config.tensor_parallel_size} GPUs, but only {visible} are visible. Check --gpu all and Docker GPU access.")
    os.execvp("vllm", config.arguments())
