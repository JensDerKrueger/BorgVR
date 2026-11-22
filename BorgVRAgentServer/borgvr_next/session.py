"""WebSocket event loop. Native receipts are correlated before delivery."""

import asyncio
from contextlib import suppress
from dataclasses import dataclass
import logging
import sqlite3
import time
from uuid import UUID, uuid4

from .agent import Trace, Turn, perform
from .expert_knowledge import advisory_message, parse_bundle
from .model import ContextLimit, ModelFailure, OutputLimit
from .wire import (
    DEFAULT_TURN_SECONDS, RESULT_BYTES, Cancel, Execution, Hello, InvalidMessage, ManualChange, Result, ScopeChange, User,
    catalog, decode, encode, validate_png,
)

logger = logging.getLogger("uvicorn.error.borgvr")
IDLE_SECONDS = 300


@dataclass
class Pending:
    id: str
    execution: Execution
    result: asyncio.Future


class Session:
    def __init__(self, socket, model, slots, evidence=None, profile=None):
        self.id = uuid4().hex
        self.socket, self.model, self.slots = socket, model, slots
        self.evidence, self.profile = evidence, profile
        self.send_lock = asyncio.Lock()
        self.history, self.seen = [], set()
        self.catalog_ids = {}
        self.active = self.task = self.pending = None
        self.reconnect = False
        self.revision = 0
        self.manual_idle = asyncio.Event()
        self.manual_idle.set()
        self.manual_update = asyncio.Event()
        self.manual_trace = None
        self.max_calls = None
        self.deadline = DEFAULT_TURN_SECONDS
        self.receive_timeout = None

    async def send(self, event, **data):
        async with asyncio.timeout(10):
            async with self.send_lock:
                await self.socket.send_text(encode({"type": event, "session_id": self.id, **data}))

    async def receive(self, timeout):
        async with asyncio.timeout(timeout) as receive_timeout:
            self.receive_timeout = receive_timeout
            try:
                frame = await self.socket.receive()
            finally:
                self.receive_timeout = None
        if frame["type"] == "websocket.disconnect":
            return None
        if frame.get("text") is None:
            raise InvalidMessage("Expected text frame")
        return decode(frame["text"])

    def set_scope(self, dataset_id, context_id, tools):
        accepted = catalog(tools, dataset_id, application_session=self.hello.application_session,
                           dataset_opening=self.hello.dataset_opening)
        self.dataset_id, self.context_id, self.tools = dataset_id, context_id, accepted
        self.revision = 0
        self.manual_idle.set()
        self.manual_update.clear()
        self.manual_trace = None
        self.history.clear()

    async def run(self):
        raw = await self.receive(10)
        if raw is None:
            return
        hello = Hello.model_validate(raw)
        self.hello = hello
        self.rules = parse_bundle(hello.expert_knowledge_toml)
        if hello.execution_limits is not None:
            self.max_calls = hello.execution_limits.max_calls
            self.deadline = hello.execution_limits.timeout_seconds
        limits = {"timeout_seconds": self.deadline}
        if self.max_calls is not None:
            limits["max_calls"] = self.max_calls
        self.set_scope(hello.dataset_id, hello.context_id, hello.tools)
        await self.send("ready", protocol=1, model=self.model.name, capabilities={"vision": True, "tool_calling": True},
                        application_session=hello.application_session, dataset_opening=hello.dataset_opening,
                        collaboration=hello.collaboration, tools=list(self.tools),
                        execution_limits=limits)
        while (event := await self.receive(
                max(IDLE_SECONDS, self.deadline + 10) if self.active is not None else IDLE_SECONDS)) is not None:
            match event.get("type"):
                case "user_message":
                    await self.start(User.model_validate(event))
                case "tool_result":
                    self.accept_result(Result.model_validate(event))
                case "user_change":
                    await self.accept_manual(ManualChange.model_validate(event))
                case "cancel":
                    message = Cancel.model_validate(event)
                    if self.active is None or self.active.request_id != message.request_id:
                        raise InvalidMessage("Unexpected cancel")
                    await self.stop()
                case "context_changed":
                    await self.change_scope(ScopeChange.model_validate(event))
                case _:
                    raise InvalidMessage("Unknown message")

    def guidance(self, opened=False):
        return advisory_message(self.rules, self.hello.knowledge, self.tools, self.dataset_id, opened)

    async def change_scope(self, change):
        if change.context_id == self.context_id:
            raise InvalidMessage("Scope ID must change")
        if self.hello.application_session:
            if change.tools is None or self.active is not None or self.reconnect:
                raise InvalidMessage("A scope change requires an idle application session")
            self.set_scope(change.dataset_id, change.context_id, change.tools)
            await self.send("context_updated", context_id=self.context_id, tools=list(self.tools))
        else:
            if change.tools is not None or change.dataset_id is None:
                raise InvalidMessage("Invalid legacy scope change")
            await self.stop()
            self.set_scope(change.dataset_id, change.context_id, list(self.tools.values()))
            await self.send("context_updated", context_id=self.context_id)

    async def start(self, message):
        if self.reconnect or message.request_id in self.seen or len(self.seen) >= 64:
            raise InvalidMessage("A fresh session is required")
        if self.active is not None:
            await self.send("error", request_id=message.request_id, code="busy", message="An active request is running.")
            return
        self.seen.add(message.request_id)
        turn = Turn(message.request_id, message.text, Trace() if self.profile else None)
        self.active = turn
        self.task = asyncio.create_task(self.execute(turn))

    async def execute(self, turn):
        outcome = "cancelled"
        try:
            await self.send("started", request_id=turn.request_id)
            async with asyncio.timeout(self.deadline):
                answer = await perform(turn, self)
            self.history = [*self.history, {"role": "user", "content": turn.text},
                            {"role": "assistant", "content": answer}][-12:]
            outcome = "completed"
            await self.send("assistant_message", request_id=turn.request_id, text=answer, final=True)
            self.active = None
            await self.send("completed", request_id=turn.request_id)
        except asyncio.CancelledError:
            self.reconnect |= turn.uncertain
            with suppress(Exception):
                await self.send("cancelled", request_id=turn.request_id, requires_reconnect=self.reconnect)
            raise
        except (ModelFailure, ContextLimit, InvalidMessage, TimeoutError) as error:
            outcome = "failed"
            self.reconnect |= turn.uncertain
            if isinstance(error, ContextLimit):
                logger.warning("Agent turn failed: phase=%s reason=%s bytes=%s input_tokens=%s window=%s tool_calls=%d",
                               "prepare_request" if error.size is not None else "tokenize",
                               error.reason, error.size, error.input_tokens, error.window, turn.dispatched)
            elif isinstance(error, OutputLimit):
                logger.warning("Agent turn failed: phase=generation reason=%s output_limit=%d output_tokens=%s tool_calls=%d",
                               error.code, error.limit, error.completion_tokens, turn.dispatched)
            elif isinstance(error, ModelFailure):
                logger.warning("Agent turn failed: phase=%s reason=%s http_status=%s tool_calls=%d",
                               error.phase, error.code, error.status or "-", turn.dispatched)
            else:
                logger.warning("Agent turn failed: reason=%s tool_calls=%d", type(error).__name__, turn.dispatched)
            with suppress(Exception):
                await self.send("error", request_id=turn.request_id,
                                code="context_limit" if isinstance(error, ContextLimit) else "run_failed",
                                changes_applied=turn.changed, requires_reconnect=self.reconnect,
                                message="The task could not be completed. Check the current view before continuing.")
        finally:
            if self.active is turn:
                self.active = None
            # A long turn must not extend the idle socket lifetime after completion.
            if self.active is None and self.receive_timeout is not None and not self.receive_timeout.expired():
                self.receive_timeout.reschedule(asyncio.get_running_loop().time() + IDLE_SECONDS)
            turn.observe("terminal", outcome=outcome, changes_applied=turn.changed, uncertain=turn.uncertain)
            if turn.trace is not None:
                await self.save_trace(turn.request_id, turn.trace)

    async def save_trace(self, scope, trace):
        try:
            await asyncio.to_thread(self.evidence.submit, self.profile, self.id, scope, trace.finish())
        except sqlite3.Error:
            logger.warning("Observer evidence unavailable")

    async def stop(self):
        if self.task is not None:
            if self.active is not None:
                self.task.cancel()
            with suppress(asyncio.CancelledError):
                await self.task

    async def synchronize(self, turn, revision):
        if self.manual_idle.is_set() and revision == self.revision:
            return revision
        await self.send("collaboration_paused", request_id=turn.request_id)
        await self.manual_idle.wait()
        revision = self.revision
        await self.send("collaboration_resumed", request_id=turn.request_id, view_revision=revision)
        return revision

    async def infer(self, messages, tools, revision):
        if revision != self.revision or not self.manual_idle.is_set():
            return None
        self.manual_update.clear()

        async def request():
            async with self.slots:
                return await self.model.complete(messages, tools)

        generating = asyncio.create_task(request())
        intervening = asyncio.create_task(self.manual_update.wait())
        try:
            await asyncio.wait([generating, intervening], return_when=asyncio.FIRST_COMPLETED)
            if self.manual_update.is_set():
                return None
            return await generating
        finally:
            for task in (generating, intervening):
                if not task.done():
                    task.cancel()
            await asyncio.gather(generating, intervening, return_exceptions=True)

    async def dispatch(self, turn, name, arguments, revision):
        if revision != self.revision or not self.manual_idle.is_set():
            return {"ok": False, "not_applied": True, "code": "user_changed_view"}, None
        effect = self.tools[name].execution
        if effect.approval_group in turn.declined:
            return {"ok": False, "not_applied": True, "code": "user_declined"}, None
        if effect.transition == "open":
            target = arguments.get("id")
            if not isinstance(target, str) or turn.opened or self.catalog_ids.get(target, 0) <= time.monotonic():
                return {"ok": False, "not_applied": True, "code": "search_required"}, None
        if effect.transition == "create_edit":
            signature = encode(dict(sorted({"duplicate": False, **arguments}.items())))
            if signature in turn.created_edits:
                return {"ok": False, "not_applied": True, "code": "already_created_in_request"}, None
        pending = Pending(uuid4().hex, effect, asyncio.get_running_loop().create_future())
        self.pending = pending
        envelope = {"request_id": turn.request_id, "call_id": pending.id, "name": name, "arguments": arguments,
                    "context_id": self.context_id, "dataset_id": self.dataset_id}
        if self.hello.collaboration:
            envelope["view_revision"] = revision
        turn.dispatched += 1
        try:
            await self.send("tool_call", **envelope)
            async with asyncio.timeout(effect.timeout_seconds):
                result = await pending.result
            if result.error is not None:
                return {"ok": False, "error": result.error}, None
            if self.hello.collaboration and not effect.changes_state and result.view_revision != revision:
                return {"ok": False, "not_applied": True, "code": "stale_observation"}, None
            if effect.transition is not None and not (
                    isinstance(result.result, dict) and result.result.get("not_applied") is True):
                try:
                    await self.apply_transition(turn, effect.transition, arguments, result)
                except InvalidMessage:
                    turn.uncertain = True
                    raise
            if effect.role == "catalog_search" and isinstance(result.result, dict):
                rows = result.result.get("matches")
                if isinstance(rows, list):
                    now = time.monotonic()
                    self.catalog_ids = {key: value for key, value in self.catalog_ids.items() if value > now}
                    for row in rows[:20]:
                        if isinstance(row, dict) and isinstance(key := row.get("id"), str) and 0 < len(key) <= 128:
                            self.catalog_ids[key] = now + 300
                    while len(self.catalog_ids) > 512:
                        del self.catalog_ids[next(iter(self.catalog_ids))]
            image = result.image_png_base64 if revision == self.revision else None
            return result.result, image
        except (TimeoutError, asyncio.CancelledError):
            turn.uncertain |= effect.changes_state
            with suppress(Exception):
                await self.send("tool_cancel", request_id=turn.request_id, call_id=pending.id)
            raise
        finally:
            self.pending = None
            pending.result.cancel()

    def accept_result(self, message):
        pending = self.pending
        if (pending is None or self.active is None or message.call_id != pending.id or
                message.request_id != self.active.request_id or message.dataset_id != self.dataset_id or
                message.context_id != self.context_id or pending.result.done()):
            raise InvalidMessage("Invalid receipt scope")
        if len(encode(message.result)) > RESULT_BYTES:
            raise InvalidMessage("Receipt exceeds bound")
        if self.hello.collaboration and message.view_revision is None:
            raise InvalidMessage("Missing collaboration revision")
        if message.dataset_transition is not None and (pending.execution.transition is None
                or message.error is not None or message.image_png_base64 is not None or
                not isinstance(message.result, dict) or message.result.get("not_applied") is True):
            raise InvalidMessage("Unexpected scope transition")
        if message.image_png_base64 is not None:
            if pending.execution.role != "render_image" or message.error is not None:
                raise InvalidMessage("Unexpected image")
            validate_png(message.image_png_base64)
        pending.result.set_result(message)

    async def apply_transition(self, turn, kind, arguments, receipt):
        update, state = receipt.dataset_transition, receipt.result
        if update is None or update.context_id == self.context_id or not isinstance(state, dict):
            raise InvalidMessage("Missing verified scope transition")
        if kind == "open":
            dataset = state.get("dataset")
            if (update.dataset_id != arguments.get("id") or update.dataset_id is None or
                    state.get("rendererReady") is not True or not isinstance(dataset, dict) or
                    dataset.get("id") != update.dataset_id):
                raise InvalidMessage("Unverified opening")
            turn.opened = True
        elif kind == "close":
            if update.dataset_id is not None or state.get("dataset") is not None or state.get("rendererReady") is not False:
                raise InvalidMessage("Unverified close")
        else:
            active = state.get("activeStateID")
            if self.dataset_id is None or update.dataset_id != self.dataset_id or state.get("available") is not True:
                raise InvalidMessage("Unverified edit state")
            if kind == "select_edit":
                target = arguments.get("id")
                if not ((target == "original" and active is None) or (
                        isinstance(target, str) and isinstance(active, str) and target.lower() == active.lower())):
                    raise InvalidMessage("Unverified edit state selection")
            else:
                new_id = state.get("createdStateID")
                try:
                    valid_id = isinstance(new_id, str) and str(UUID(new_id)) == new_id.lower()
                except ValueError:
                    valid_id = False
                if (not valid_id or not isinstance(active, str) or active.lower() != new_id.lower() or
                        new_id.lower() == turn.active_edit_state):
                    raise InvalidMessage("Unverified edit state creation")
                turn.created_edits.add(encode(dict(sorted({"duplicate": False, **arguments}.items()))))
        self.set_scope(update.dataset_id, update.context_id, update.tools)
        await self.send("context_updated", context_id=self.context_id, tools=list(self.tools))

    async def accept_manual(self, event):
        if (not self.hello.collaboration or event.dataset_id != self.dataset_id or
                event.context_id != self.context_id or (not event.active and event.state is None) or
                len(encode(event.state)) > RESULT_BYTES):
            raise InvalidMessage("Invalid intervention")
        if event.revision < self.revision or (event.revision == self.revision and self.manual_idle.is_set()):
            return
        self.revision = event.revision
        self.manual_update.set()
        if event.active:
            self.manual_idle.clear()
        else:
            self.manual_idle.set()
        detail = {"revision": event.revision, "active": event.active, "domains": event.domains, "state": event.state}
        if self.active:
            self.active.observe("manual_change", **detail)
        elif self.profile and not event.active and event.domains:
            trace = Trace()
            trace.add("manual_change", **detail)
            await self.save_trace("manual-" + uuid4().hex, trace)
