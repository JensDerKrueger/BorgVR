"""BorgVR v1 WebSocket session and scope handshake."""

import asyncio
import contextlib
import time
import uuid

from .agent_factory import build_agent, relevant_strategies
from .budget import MAX_MODEL_REQUESTS, MAX_NATIVE_CALLS, MAX_TOOL_CALLS
from .collaboration import Collaboration
from .context import application_context_history
from .datasets import DatasetTransitions
from .native_dispatch import dispatch_native
from .orchestrator import TurnState, can_checkpoint, run, finish_text
from .policies import system_prompt
from .protocol import (
    APPLICATION_TOOLS, CONVERSION_TOOLS, DATASET_TRANSITIONS, MAX_RESULT_BYTES,
    Cancel, CollaborationFeedback, ContextChanged, Hello, ProtocolError, ToolResult, UserChange, UserMessage,
    decode_message, json_bytes, select_tools,
)
from .strategies import StrategyIndex, parse_strategies


class Session:
    def __init__(self, ws, settings, model, run_slots, strategy_encoder=None):
        self.ws, self.settings, self.model, self.run_slots = ws, settings, model, run_slots
        self.session_id = uuid.uuid4().hex
        self.send_lock = asyncio.Lock()
        self.task = None
        self.turn = TurnState()
        self.pending = None
        self.retired_reads = {}
        self.request_id = None
        self.seen_requests = set()
        self.history = []
        self.dataset_id = self.context_id = None
        self.application_session = False
        self.dataset_opening = False
        self.search_results = {}
        self.dataset_control = DatasetTransitions(self)
        self.paused_task = None
        self.tools = []
        self.uncertain = False
        self.agent = None
        self.diagnostic_tools = frozenset()
        self.native_call_limit = MAX_NATIVE_CALLS
        self.request_timeout = settings.run_timeout
        self.tool_call_limit = MAX_TOOL_CALLS
        self.model_request_limit = MAX_MODEL_REQUESTS
        self.budget = None
        self.collaboration = None
        self.strategy_encoder = strategy_encoder
        self.strategy_index = None
        self.dataset_just_opened = False

    async def send(self, value):
        async with asyncio.timeout(self.settings.send_timeout):
            async with self.send_lock:
                await self.ws.send_text(json_bytes({"session_id": self.session_id, **value}).decode())

    async def receive(self, timeout):
        async with asyncio.timeout(timeout):
            raw = await self.ws.receive_text()
        return decode_message(raw)

    def retire_read(self, call_id, outgoing):
        if len(self.retired_reads) >= 32:
            self.retired_reads.pop(next(iter(self.retired_reads)))
        self.retired_reads[call_id] = (outgoing["request_id"], outgoing["dataset_id"], outgoing["context_id"])

    build_agent = build_agent
    relevant_strategies = relevant_strategies
    system_prompt = system_prompt
    call_tool = dispatch_native
    can_checkpoint = can_checkpoint
    run = run
    finish_text = finish_text

    async def stop(self):
        if self.task is not None:
            if not self.task.done():
                self.task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self.task
            self.task = None

    async def serve(self):
        hello = Hello.model_validate(await self.receive(self.settings.hello_timeout))
        if hello.expert_knowledge_toml is not None:
            rules = parse_strategies(hello.expert_knowledge_toml)
            if rules and self.strategy_encoder is not None:
                self.strategy_index = StrategyIndex(rules, self.strategy_encoder)
        if hello.execution_limits is not None:
            self.native_call_limit = min(hello.execution_limits.max_calls, self.settings.max_native_calls)
            self.request_timeout = min(hello.execution_limits.timeout_seconds, self.settings.max_run_timeout)
            self.tool_call_limit = max(MAX_TOOL_CALLS, self.native_call_limit * 2)
            self.model_request_limit = self.tool_call_limit + 8
        self.application_session = hello.application_session
        self.dataset_opening = hello.dataset_opening
        self.tools = self.context_tools(hello.tools, hello.dataset_id)
        if hello.collaboration:
            self.collaboration = Collaboration(self, hello.knowledge)
        self.dataset_id, self.context_id = hello.dataset_id, hello.context_id
        self.agent = self.build_agent()
        await self.send({"type": "ready", "protocol": 1, "model": self.settings.model,
                         "capabilities": self.settings.capabilities(),
                         "execution_limits": {"max_calls": self.native_call_limit, "timeout_seconds": self.request_timeout},
                         "collaboration": self.collaboration is not None,
                         "application_session": self.application_session,
                         "dataset_opening": self.dataset_opening,
                         "tools": [tool.name for tool in self.tools]})
        while True:
            receiving_timeout = (max(self.settings.idle_timeout, self.request_timeout + self.settings.tool_timeout)
                                 if self.task is not None and not self.task.done() else self.settings.idle_timeout)
            value = await self.receive(receiving_timeout)
            match value.get("type"):
                case "user_message":
                    message = UserMessage.model_validate(value)
                    if self.uncertain:
                        raise ProtocolError("Uncertain tool completion; reconnect after reconciling the app state")
                    if message.request_id in self.seen_requests:
                        raise ProtocolError("Repeated request ID; requests are never replayed")
                    if len(self.seen_requests) >= 64:
                        raise ProtocolError("Session turn limit reached; reconnect")
                    if self.task is not None and not self.task.done():
                        await self.send({"type": "error", "request_id": message.request_id,
                                         "code": "busy", "message": "Cancel or finish the active request first."})
                        continue
                    self.seen_requests.add(message.request_id)
                    self.request_id = message.request_id
                    self.task = asyncio.create_task(self.run(message))
                case "tool_result":
                    response = ToolResult.model_validate(value)
                    retired = self.retired_reads.get(response.call_id)
                    if (retired is not None and response.dataset_transition is None and
                            retired == (response.request_id, response.dataset_id, response.context_id)):
                        del self.retired_reads[response.call_id]
                        continue
                    if (self.pending is None or response.call_id != self.pending.call_id
                        or response.request_id != self.request_id or response.dataset_id != self.dataset_id
                        or response.context_id != self.context_id or self.pending.result.done()):
                        raise ProtocolError("Stale or unexpected tool result")
                    if len(json_bytes(response.result)) > MAX_RESULT_BYTES:
                        raise ProtocolError("Tool result too large")
                    if response.error is not None and response.image_png_base64 is not None:
                        raise ProtocolError("An error cannot contain an image")
                    transition = response.dataset_transition
                    if transition is not None:
                        action = self.pending.name
                        if (action not in DATASET_TRANSITIONS or transition.context_id == self.context_id or
                                response.error is not None or response.image_png_base64 is not None or
                                not isinstance(response.result, dict) or response.result.get("not_applied") is True or
                                not self.is_verified_transition(action, transition.dataset_id, response.result)):
                            raise ProtocolError("Unexpected or unverified dataset transition")
                        self.tools = self.context_tools(transition.tools, transition.dataset_id)
                        self.dataset_id, self.context_id = transition.dataset_id, transition.context_id
                        self.turn.dataset_transition = transition
                        if action == "open_dataset":
                            self.turn.opened_this_turn = True
                            self.dataset_just_opened = True
                        self.turn.state_seen = False
                        if self.collaboration is not None:
                            self.collaboration = Collaboration(self, self.collaboration.knowledge)
                        await self.send({"type": "context_updated", "context_id": self.context_id,
                                         "tools": [tool.name for tool in self.tools]})
                    elif self.pending.name in DATASET_TRANSITIONS and not (isinstance(response.result, dict) and response.result.get("not_applied") is True):
                        raise ProtocolError("A scope change requires a verified transition receipt")
                    self.pending.result.set_result(response)
                case "cancel":
                    message = Cancel.model_validate(value)
                    if message.request_id != self.request_id:
                        raise ProtocolError("Cancellation targets a different request")
                    await self.stop()
                case "user_change":
                    event = UserChange.model_validate(value)
                    if (self.collaboration is None or event.dataset_id != self.dataset_id or
                            event.context_id != self.context_id):
                        raise ProtocolError("Unexpected or stale user intervention")
                    self.collaboration.update(event)
                case "collaboration_feedback":
                    if self.collaboration is None:
                        raise ProtocolError("Collaboration was not negotiated")
                    self.collaboration.accept_feedback(CollaborationFeedback.model_validate(value))
                case "context_changed":
                    message = ContextChanged.model_validate(value)
                    if message.context_id == self.context_id:
                        raise ProtocolError("A new context must have a new ID")
                    self.paused_task = None
                    if self.application_session:
                        if self.uncertain or self.pending is not None or (self.task is not None and not self.task.done()):
                            raise ProtocolError("An active or uncertain request requires a fresh connection")
                        if message.tools is None:
                            raise ProtocolError("An app context change requires a fresh tool catalog")
                        tools = self.context_tools(message.tools, message.dataset_id)
                        self.tools = tools
                        self.history = application_context_history(self.history, system_prompt=self.system_prompt())
                        self.dataset_just_opened = message.dataset_id is not None and message.dataset_id != self.dataset_id
                        self.dataset_id, self.context_id = message.dataset_id, message.context_id
                        self.turn.state_seen = False
                        self.turn.screenshot_count = 0
                        self.turn.visual_observations = []
                        if self.collaboration is not None:
                            self.collaboration = Collaboration(self, self.collaboration.knowledge)
                        self.agent = self.build_agent()
                        await self.send({"type": "context_updated", "context_id": self.context_id,
                                         "tools": [tool.name for tool in self.tools]})
                        continue
                    if message.dataset_id is None or message.tools is not None:
                        raise ProtocolError("Application sessions were not negotiated")
                    await self.stop()
                    self.history = []
                    self.dataset_id, self.context_id = message.dataset_id, message.context_id
                    await self.send({"type": "context_updated", "context_id": self.context_id})
                case _:
                    raise ProtocolError("Unsupported message type")

    def is_verified_transition(self, action, dataset_id, state):
        dataset = state.get("dataset")
        if action == "open_dataset":
            return (self.dataset_opening and dataset_id is not None and dataset_id == self.turn.open_target
                    and state.get("rendererReady") is True and isinstance(dataset, dict) and dataset.get("id") == dataset_id)
        if action == "close_dataset":
            return self.dataset_id is not None and dataset_id is None and dataset is None and state.get("rendererReady") is False
        if action == "select_edit_state":
            active = state.get("activeStateID")
            target = self.turn.edit_state_target
            return (dataset_id is not None and dataset_id == self.dataset_id and state.get("available") is True
                    and ((target == "original" and active is None)
                         or (isinstance(target, str) and isinstance(active, str) and target.lower() == active.lower())))
        if action == "create_edit_state":
            active, created = state.get("activeStateID"), state.get("createdStateID")
            if not (dataset_id is not None and dataset_id == self.dataset_id and state.get("available") is True and
                    isinstance(active, str) and isinstance(created, str) and active.lower() == created.lower()):
                return False
            try:
                return str(uuid.UUID(created)) == created.lower() and (
                    not isinstance(self.turn.active_edit_state_id, str) or active.lower() != self.turn.active_edit_state_id.lower())
            except ValueError:
                return False
        return False

    def context_tools(self, definitions, dataset_id):
        tools = select_tools(definitions)
        if not self.dataset_opening:
            tools = [tool for tool in tools if tool.name != "open_dataset"]
        if dataset_id is not None:
            return [tool for tool in tools if tool.name not in CONVERSION_TOOLS]
        return [tool for tool in tools if tool.name in APPLICATION_TOOLS]
