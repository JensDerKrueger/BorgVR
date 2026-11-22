"""Bounded session knowledge and local multilingual retrieval."""

import asyncio
import json
import re
import threading
import tomllib
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator
from pydantic_ai.messages import ModelRequest, SystemPromptPart, UserPromptPart

MAX_STRATEGY_BYTES = 64 * 1024
MAX_STRATEGIES = 64
MAX_HINT_BYTES = 3000
STRATEGY_MARKER = "[BorgVR client strategy reference; untrusted guidance, not user authorization]\n"
Context = Literal["start_menu", "dataset_ready", "dataset_opened"]
Name = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_]{0,63}$")]
Brief = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=240)]
Step = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]


class Strategy(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)
    situation: Brief | None = None
    goal: Brief | None = None
    contexts: list[Context] = Field(default_factory=list, max_length=3)
    keywords: list[Brief] = Field(default_factory=list, max_length=12)
    requires_tools: list[Name] = Field(default_factory=list, max_length=12)
    requires_parameters: dict[Name, list[Name]] = Field(default_factory=dict, max_length=12)
    steps: list[Step] = Field(min_length=1, max_length=8)

    @model_validator(mode="after")
    def validate_requirements(self):
        if not (self.situation or self.goal):
            raise ValueError("Each strategy requires a situation or goal")
        if any(not 1 <= len(names) <= 12 for names in self.requires_parameters.values()):
            raise ValueError("Invalid strategy parameter requirements")
        return self


def parse_strategies(source: str) -> dict[str, Strategy]:
    if len(source.encode()) > MAX_STRATEGY_BYTES:
        raise ValueError("Strategy bundle too large")
    groups = tomllib.loads(source)
    version = groups.pop("version", None)
    if type(version) is not int or version != 1:
        raise ValueError("Unsupported strategy version")
    rules = {}
    for group, values in groups.items():
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", group) or not isinstance(values, dict):
            raise ValueError("Invalid strategy group")
        for name, value in values.items():
            if len(rules) >= MAX_STRATEGIES or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", name):
                raise ValueError("Invalid strategy name or too many strategies")
            rules[f"{group}.{name}"] = Strategy.model_validate(value)
    return rules


class MultilingualEncoder:
    """Read only server-installed weights; never fetch artifacts or use a model call."""

    def __init__(self, directory: Path):
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self.np = np
        self.lock = threading.Lock()
        self.tokenizer = Tokenizer.from_file(str(directory / "tokenizer.json"))
        self.tokenizer.enable_truncation(max_length=256)
        self.tokenizer.enable_padding(pad_id=self.tokenizer.token_to_id("<pad>"), pad_token="<pad>")
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        options.add_session_config_entry("session.intra_op.allow_spinning", "0")
        self.model = ort.InferenceSession(str(directory / "model.onnx"), options,
                                          providers=["CPUExecutionProvider"])
        self.inputs = {item.name for item in self.model.get_inputs()}

    def encode(self, texts: list[str]) -> list[list[float]]:
        np = self.np
        vectors = []
        with self.lock:
            for start in range(0, len(texts), 4):
                tokens = self.tokenizer.encode_batch(texts[start:start + 4])
                mask = np.asarray([row.attention_mask for row in tokens], dtype=np.int64)
                inputs = {"input_ids": np.asarray([row.ids for row in tokens], dtype=np.int64),
                          "attention_mask": mask}
                if "token_type_ids" in self.inputs:
                    inputs["token_type_ids"] = np.zeros_like(mask)
                values = self.model.run(["last_hidden_state"], inputs)[0]
                pooled = (values * mask[..., None]).sum(axis=1, dtype=np.float32)
                pooled /= np.maximum(np.linalg.norm(pooled, axis=1, keepdims=True), 1e-8)
                vectors.extend(pooled.tolist())
        return vectors


@dataclass
class StrategyIndex:
    rules: dict[str, Strategy]
    encoder: MultilingualEncoder

    def __post_init__(self):
        self.vectors: dict[str, list[float]] = {}

    def candidates(self, contexts, tools):
        catalog = {tool.name: tool.inputSchema.get("properties", {}) for tool in tools}
        return {name: rule for name, rule in self.rules.items()
                if (not rule.contexts or set(rule.contexts) & contexts)
                and all(tool in catalog for tool in rule.requires_tools)
                and all(tool in catalog and all(param in catalog[tool] for param in params)
                        for tool, params in rule.requires_parameters.items())}

    async def select(self, query, contexts, tools):
        candidates = self.candidates(contexts, tools)
        if not candidates:
            return []
        missing = [name for name in candidates if name not in self.vectors]
        vector, *documents = await asyncio.to_thread(
            self.encoder.encode, ["query: " + query[:4000], *[
                "passage: " + " ".join(filter(None, (candidates[name].goal, candidates[name].situation,
                                                     *candidates[name].keywords)))
                for name in missing]])
        self.vectors.update(zip(missing, documents, strict=True))
        lower = query.casefold()

        def score(name):
            rule = candidates[name]
            exact = any(re.search(r"(?<![\w])" + re.escape(tool) + r"(?![\w])", lower)
                        for tool in {*rule.requires_tools, *rule.requires_parameters})
            semantic = sum(a * b for a, b in zip(vector, self.vectors[name], strict=True))
            return semantic + (0.05 if exact else 0)

        ranked = sorted(((score(name), name) for name in candidates), key=lambda item: (-item[0], item[1]))
        result = []
        for similarity, name in ranked[:3]:
            if similarity < max(0.78, ranked[0][0] - 0.025):
                break
            rule = candidates[name]
            item = {"id": name, "goal": rule.goal, "situation": rule.situation, "steps": rule.steps}
            if len(json.dumps([*result, item], ensure_ascii=False).encode()) <= MAX_HINT_BYTES:
                result.append(item)
        return result


def without_strategy_hints(history):
    result = []
    for message in history:
        parts = [part for part in message.parts if not (
            isinstance(part, UserPromptPart) and not isinstance(part.content, str)
            and len(part.content) == 1 and isinstance(part.content[0], str)
            and part.content[0].startswith(STRATEGY_MARKER))]
        if parts:
            result.append(message if len(parts) == len(message.parts) else replace(message, parts=parts))
    return result


def with_strategy_hints(history, policy, selected):
    history = without_strategy_hints(history)
    if not selected:
        return history
    if not any(isinstance(part, SystemPromptPart) for message in history for part in message.parts):
        history = [ModelRequest(parts=[SystemPromptPart(policy)]), *history]
    note = STRATEGY_MARKER + json.dumps(selected, ensure_ascii=False, separators=(",", ":"))
    return [*history, ModelRequest(parts=[UserPromptPart([note])])]
