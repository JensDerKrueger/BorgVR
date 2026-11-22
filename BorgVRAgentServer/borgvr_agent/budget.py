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
        remaining = (getattr(self.session, "request_timeout", self.session.settings.run_timeout) - (time.monotonic() - self.session.turn.run_started)
                     if self.session.turn.run_started is not None else float("inf"))
        native_limit = getattr(self.session, "native_call_limit", MAX_NATIVE_CALLS)
        tool_limit = getattr(self.session, "tool_call_limit", MAX_TOOL_CALLS)
        model_limit = getattr(self.session, "model_request_limit", MAX_MODEL_REQUESTS)
        if (self.session.turn.native_calls >= native_limit or ctx.usage.tool_calls >= tool_limit - 8 or
                ctx.usage.requests >= model_limit - 4 or remaining <= 35):
            return "answer"
        if self.session.turn.native_calls >= native_limit - 6 or ctx.usage.tool_calls >= tool_limit - 24 or remaining <= 75:
            return "wrap_up"
        return "investigate"

    def instructions(self, ctx):
        return (f"Server control phase={self.phase(ctx)}; BorgVR calls remaining="
                f"{getattr(self.session, 'native_call_limit', MAX_NATIVE_CALLS) - self.session.turn.native_calls}; "
                f"total tool calls used={ctx.usage.tool_calls}/{getattr(self.session, 'tool_call_limit', MAX_TOOL_CALLS)}.")

    async def prepare_tools(self, ctx, tool_defs):
        phase = self.phase(ctx)
        if phase == "answer":
            collaboration = getattr(self.session, "collaboration", None)
            if collaboration is not None and not collaboration.asked_for_help:
                return [tool for tool in tool_defs if tool.name == "ask_collaboration_feedback"]
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
