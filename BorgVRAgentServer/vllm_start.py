"""Keep credentials out of Compose interpolation and process arguments."""

import os
from pathlib import Path

from model_config import ModelConfig

if __name__ == "__main__":
    os.environ["VLLM_API_KEY"] = Path("/run/secrets/vllm_token").read_text().strip()
    os.execvp("vllm", ModelConfig.from_env(os.environ).arguments())
