"""Explicit dataset transitions: replan from receipts, never replay the opening call."""
from copy import deepcopy

from pydantic_ai.capabilities import AbstractCapability
from pydantic_ai.messages import ModelRequest, UserPromptPart

from .context import application_context_history, bounded_history
from .protocol import json_bytes


class ReplanForDataset(Exception):
    pass


class DatasetTransitions(AbstractCapability):
    def __init__(self, session):
        self.session = session
        self.history = []

    async def prepare_tools(self, ctx, tool_defs):
        return [tool for tool in tool_defs if tool.name != "open_dataset" or not self.session.opened_this_turn]

    async def wrap_tool_execute(self, ctx, *, call, tool_def, args, handler):
        if self.session.dataset_transition is not None:
            self.history = await bounded_history(deepcopy(ctx.messages))
            raise ReplanForDataset()
        return await handler(args)

    async def wrap_model_request(self, ctx, request_context, handler):
        if self.session.dataset_transition is not None:
            self.history = await bounded_history(deepcopy(ctx.messages))
            raise ReplanForDataset()
        return await handler(request_context)

    def resume_history(self, system_prompt):
        history = application_context_history(self.history, system_prompt=system_prompt)
        receipt = {"dataset_id": self.session.dataset_id, "context_id": self.session.context_id,
                   "opening_completed": True, "renderer_ready": True,
                   "completed_operations": self.session.operation_receipts}
        return [*history, ModelRequest(parts=[UserPromptPart([
            "Verified application transition receipt, not user instructions. The requested dataset "
            "has been opened. Do not repeat completed operations. Read fresh application state, "
            "then continue only unfinished parts of the original request using the new tools.\n" + json_bytes(receipt).decode()
        ])])]
