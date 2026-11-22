"""Bounded HTTP adapter for the configured vLLM service."""

import asyncio
from dataclasses import dataclass
import logging

import httpx

from .output_diagnostics import summarize_output
from .wire import FRAME_BYTES, decode, encode

logger = logging.getLogger("uvicorn.error.borgvr")


class ContextLimit(Exception):
    def __init__(self, reason="input_context", *, size=None, input_tokens=None, window=None):
        super().__init__(reason)
        self.reason, self.size = reason, size
        self.input_tokens, self.window = input_tokens, window


class ModelFailure(Exception):
    def __init__(self, code, *, phase="response", status=None):
        super().__init__(code)
        self.code, self.phase, self.status = code, phase, status


class OutputLimit(ModelFailure):
    def __init__(self, limit, completion_tokens):
        super().__init__("output_token_limit", phase="generation")
        self.limit, self.completion_tokens = limit, completion_tokens


@dataclass(frozen=True)
class Call:
    id: str
    name: str
    arguments: str

    def as_message(self):
        return {"role": "assistant", "content": None, "tool_calls": [
            {"id": self.id, "type": "function",
             "function": {"name": self.name, "arguments": self.arguments}}]}


class VLLM:
    def __init__(self, http, base_url, token, name, context=65536, *, max_output_tokens=None, generation_timeout=180,
                 thinking_mode="off"):
        self.http = http
        self.url = base_url.rstrip("/")
        if not self.url.endswith("/v1"):
            raise ValueError("vLLM base URL must end in /v1")
        self.token = token
        self.name = name
        self.context = context
        if context <= 512 or (max_output_tokens is not None and max_output_tokens < 1):
            raise ValueError("Invalid model budget")
        self.max_output_tokens = max_output_tokens
        self.generation_timeout = generation_timeout
        if thinking_mode not in {"off", "on", "default"}:
            raise ValueError("Invalid thinking mode")
        self.thinking_mode = thinking_mode

    async def exchange(self, method, url, *, phase, seconds, body=None):
        timeout = httpx.Timeout(seconds, connect=min(5, seconds), pool=min(5, seconds))
        try:
            async with asyncio.timeout(seconds):
                async with self.http.stream(method, url, json=body,
                                            timeout=timeout,
                                            headers={"Authorization": f"Bearer {self.token}"}) as response:
                    response.raise_for_status()
                    data = bytearray()
                    async for chunk in response.aiter_bytes():
                        data.extend(chunk)
                        if len(data) > FRAME_BYTES:
                            raise ModelFailure("response_too_large", phase=phase)
            return decode(data)
        except httpx.HTTPStatusError as error:
            raise ModelFailure("http_error", phase=phase, status=error.response.status_code) from error
        except (TimeoutError, httpx.TimeoutException) as error:
            raise ModelFailure("timeout", phase=phase) from error
        except httpx.HTTPError as error:
            raise ModelFailure("transport_error", phase=phase) from error
        except ValueError as error:
            raise ModelFailure("invalid_response_json", phase=phase) from error

    async def ready(self):
        listing = await self.exchange("GET", self.url + "/models", phase="readiness", seconds=5)
        models = listing.get("data")
        return isinstance(models, list) and any(isinstance(item, dict) and item.get("id") == self.name for item in models)

    async def complete(self, messages, tools):
        body = {"model": self.name, "messages": messages}
        if self.thinking_mode != "default":
            body["chat_template_kwargs"] = {"enable_thinking": self.thinking_mode == "on"}
        if tools:
            body["tools"] = tools
        size = len(encode(body))
        if size > 8 * 1024 * 1024:
            raise ContextLimit("serialized_request_limit", size=size)
        measured = await self.exchange("POST", self.url.removesuffix("/v1") + "/tokenize",
                                       phase="tokenize", seconds=15, body={**body, "add_generation_prompt": True})
        count, window = measured.get("count"), measured.get("max_model_len")
        if type(count) is not int or count < 0 or type(window) is not int or window < 1:
            raise ModelFailure("invalid_token_count", phase="tokenize")
        window = min(window, self.context)
        available = window - count - 512
        if available <= 0:
            raise ContextLimit("input_token_budget", input_tokens=count, window=window)
        limit = available if self.max_output_tokens is None else min(available, self.max_output_tokens)
        body.update(temperature=0.0, parallel_tool_calls=False, max_tokens=limit)
        result = await self.exchange("POST", self.url + "/chat/completions", phase="generation",
                                     seconds=self.generation_timeout, body=body)
        return self.response(result, tools, limit)

    @staticmethod
    def response(result, tools, output_limit):
        try:
            choice = result["choices"][0]
            if choice["finish_reason"] == "length":
                usage = result.get("usage")
                used = usage.get("completion_tokens") if isinstance(usage, dict) else None
                used = used if type(used) is int and 0 <= used <= output_limit else None
                shape = summarize_output(choice, tools, usage)
                logger.info("Truncated model output: limit=%d output_tokens=%s reasoning_tokens=%s reasoning_chars=%d "
                            "text_chars=%d tool_calls=%d tools=%s argument_chars=%d rgba_rows=%s rgba_source=%s",
                            output_limit, used, shape["reasoning_tokens"], shape["reasoning_chars"], shape["text_chars"],
                            shape["tool_calls"], shape["tools"], shape["argument_chars"], shape["rgba_rows"],
                            shape["rgba_source"])
                raise OutputLimit(output_limit, used)
            message = choice["message"]
            calls = message.get("tool_calls") or []
            if len(calls) == 1 and tools:
                call = calls[0]
                function = call["function"]
                fields = call["id"], function["name"], function["arguments"]
                if all(isinstance(value, str) and value for value in fields) and len(fields[0]) <= 128:
                    return Call(*fields)
            if not calls and isinstance(message.get("content"), str) and 0 < len(message["content"]) <= 32768:
                return message["content"]
        except (KeyError, IndexError, TypeError, AttributeError) as error:
            raise ModelFailure("invalid_response_shape", phase="generation") from error
        raise ModelFailure("unsupported_response", phase="generation")
