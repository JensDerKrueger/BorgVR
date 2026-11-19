"""Reserve a final answer before bounded visualization work exhausts its limits."""

import time

from pydantic_ai.capabilities import AbstractCapability

MAX_NATIVE_CALLS = 24
MAX_MODEL_REQUESTS = 48
MAX_TOOL_CALLS = 48


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

    def get_instructions(self):
        return self.instructions

    def instructions(self, ctx):
        # Keep changing instructions short: the SDK also retains them in conversation history.
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
        if self.phase(ctx) == "answer":
            settings = request_context.model_settings or {}
            request_context.model_settings = {**settings, "max_tokens": min(settings.get("max_tokens", 512), 512)}
        return request_context
