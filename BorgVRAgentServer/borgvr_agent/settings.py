"""Deployment settings for the standalone agent."""

import hmac
import os
from dataclasses import dataclass, field
from pathlib import Path

from model_config import ModelConfig, OpenAIConfig, choice


@dataclass(frozen=True)
class Settings:
    token: str
    vllm_token: str
    model: str = "Qwen/Qwen3.6-35B-A3B"
    vllm_url: str = "http://vllm:8000/v1"
    max_sessions: int = 4
    run_timeout: float = 180
    tool_timeout: float = 45
    idle_timeout: float = 300
    hello_timeout: float = 10
    send_timeout: float = 10
    max_native_calls: int = 1024
    max_run_timeout: float = 7200
    inference: ModelConfig | OpenAIConfig = ModelConfig.from_env({})
    workflow_database: Path | None = None
    backend: str = "vllm"
    openai_key: str = field(default="", repr=False)

    def capabilities(self):
        return {"vision": self.inference.vision, "tool_calling": True}

    @classmethod
    def from_env(cls):
        def secret(name, default):
            value = Path(os.environ.get(name, default)).read_text().strip()
            if len(value) < 32 or not value.isascii() or any(c.isspace() for c in value):
                raise ValueError(f"Invalid secret in {name}")
            return value

        backend = choice(os.environ.get("BORGVR_LLM_BACKEND", "vllm"), ("vllm", "openai"))
        use_openai = backend == "openai"
        inference = (OpenAIConfig if use_openai else ModelConfig).from_env(os.environ)
        return cls(
            token=secret("BORGVR_TOKEN_FILE", "/run/secrets/agent_token"),
            vllm_token="" if use_openai else secret("BORGVR_VLLM_TOKEN_FILE", "/run/secrets/vllm_token"),
            model=inference.model, inference=inference,
            vllm_url=os.environ.get("BORGVR_VLLM_URL", cls.vllm_url),
            workflow_database=Path(os.environ["BORGVR_WORKFLOW_DB"]) if os.environ.get("BORGVR_WORKFLOW_DB") else None,
            backend=backend,
            openai_key=secret("BORGVR_OPENAI_KEY_FILE", "/run/secrets/openai_api_key") if use_openai else "",
        )


def authorized(header: str | None, token: str) -> bool:
    return hmac.compare_digest((header or "").encode(), f"Bearer {token}".encode())
