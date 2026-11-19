"""Reserve a final answer before bounded visualization work exhausts its limits."""

import time
from dataclasses import replace

from pydantic_ai.capabilities import AbstractCapability
from pydantic_ai.messages import SystemPromptPart

MAX_NATIVE_CALLS = 24
MAX_MODEL_REQUESTS = 48
MAX_TOOL_CALLS = 48
BUDGET_MARKER = "\n\n[BorgVR live control budget]\n"


class ControlBudget(AbstractCapability):
    def __init__(self, session):
        self.session = session
        self.requests = self.tool_calls = 0

    def phase(self, ctx):
        remaining = (self.session.settings.run_timeout - (time.monotonic() - self.session.run_started)
                     if self.session.run_started is not None else float("inf"))
        if (self.session.native_calls >= MAX_NATIVE_CALLS or ctx.usage.tool_calls >= 40 or
                ctx.usage.requests >= 44 or remaining <= 35):
            return "answer"
        if self.session.native_calls >= 18 or ctx.usage.tool_calls >= 24 or remaining <= 75:
            return "wrap_up"
        return "investigate"

    def instructions(self, ctx):
        return (f"Server control phase={self.phase(ctx)}; BorgVR calls remaining="
                f"{MAX_NATIVE_CALLS - self.session.native_calls}; total tool calls used={ctx.usage.tool_calls}/{MAX_TOOL_CALLS}.")

    async def prepare_tools(self, ctx, tool_defs):
        phase = self.phase(ctx)
        if phase == "answer":
            return []
        if phase == "wrap_up":
            return [tool for tool in tool_defs if tool.name not in {"rotate_view", "report_progress"}]
        return tool_defs

    async def before_model_request(self, ctx, request_context):
        self.requests, self.tool_calls = ctx.usage.requests, ctx.usage.tool_calls
        # Some vision chat templates accept only one initial system message, not a
        # second system/developer message from dynamic SDK instructions.
        updated, found = [], False
        for message in request_context.messages:
            parts = []
            for part in message.parts:
                if not found and isinstance(part, SystemPromptPart):
                    part = replace(part, content=part.content.split(BUDGET_MARKER, 1)[0] +
                                   BUDGET_MARKER + self.instructions(ctx))
                    found = True
                parts.append(part)
            updated.append(replace(message, parts=parts))
        if not found:
            raise ValueError("Missing agent system policy for control budget")
        request_context.messages = updated
        ctx.messages[:] = updated
        if self.phase(ctx) == "answer":
            settings = request_context.model_settings or {}
            request_context.model_settings = {**settings, "max_tokens": min(settings.get("max_tokens", 512), 512)}
        return request_context
