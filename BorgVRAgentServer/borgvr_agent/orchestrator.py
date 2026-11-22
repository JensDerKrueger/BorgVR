"""One active request, with independent conversation history and continuation state."""

import asyncio
import contextlib
import logging
import time
from dataclasses import dataclass, field

from fastapi import WebSocketDisconnect
from pydantic_ai import UsageLimits
from pydantic_ai.exceptions import ModelContextWindowExceededError, UnexpectedModelBehavior
from pydantic_ai.usage import RunUsage

from .collaboration import ReplanForUser
from .context import ContextBudgetExceeded, ContextCheckpointRequired, application_context_history, bounded_history
from .continuation import TaskContinuation, channel_mask, completed_continuation, is_resume_request
from .datasets import ReplanForDataset
from .model_diagnostics import model_failure
from .protocol import ProtocolError
from .strategies import with_strategy_hints, without_strategy_hints

logger = logging.getLogger("borgvr_agent")
run_diagnostics = logging.getLogger("uvicorn.error.borgvr")


@dataclass
class TurnState:
    state_seen: bool = False
    annotation_reads: set[str] = field(default_factory=set)
    deletion_declined: bool = False
    edit_state_deletion_declined: bool = False
    volume_edit_state_seen: bool = False
    active_edit_state_id: str | None = None
    edit_channels: int = field(default_factory=lambda: channel_mask(None))
    volume_edit_declined: bool = False
    file_selection_declined: bool = False
    changes_applied: bool = False
    screenshot_count: int = 0
    visual_observations: list[dict] = field(default_factory=list)
    native_calls: int = 0
    opened_this_turn: bool = False
    operation_receipts: list[dict] = field(default_factory=list)
    continuation: TaskContinuation = field(default_factory=TaskContinuation)
    dataset_transition: object | None = None
    open_target: str | None = None
    edit_state_target: str | None = None
    run_started: float | None = None


@dataclass
class PausedTask:
    context_id: str | None
    original_prompt: str
    continuation: TaskContinuation
    receipts: list
    observations: list
    volume_edit_declined: bool
    deletion_declined: bool
    edit_state_deletion_declined: bool
    file_selection_declined: bool
    opened_dataset: bool
    conversation: list


def can_checkpoint(self):
    return (self.pending is None and not self.uncertain and self.turn.dataset_transition is None and
            self.turn.continuation.can_checkpoint(len(self.turn.operation_receipts)))

async def run(self, message):
    paused, self.paused_task = self.paused_task, None
    resume_requested = is_resume_request(message.text)
    if not resume_requested or (paused is not None and paused.context_id != self.context_id):
        paused = None
    original_prompt = paused.original_prompt if paused else message.text
    self.turn = TurnState(run_started=time.monotonic()) if paused is None else TurnState(
        run_started=time.monotonic(), continuation=paused.continuation,
        operation_receipts=list(paused.receipts), changes_applied=True,
        deletion_declined=paused.deletion_declined, volume_edit_declined=paused.volume_edit_declined,
        edit_state_deletion_declined=paused.edit_state_deletion_declined,
        file_selection_declined=paused.file_selection_declined, opened_this_turn=paused.opened_dataset,
    )
    conversation = paused.conversation if paused else self.history
    if self.collaboration is not None:
        self.collaboration.begin_turn()
    outcome = "aborted"
    try:
        await self.send({"type": "started", "request_id": message.request_id})
        if resume_requested and paused is None:
            await self.finish_text(message, "There is no paused task in this session. Tell me what you would like me to do next.",
                                   resume_unavailable=True)
            outcome = "completed"
            return
        prompt, history, usage = original_prompt, self.history, RunUsage()
        if paused:
            self.turn.continuation.begin_resume(len(self.turn.operation_receipts))
            history = self.turn.continuation.snapshot_history(
                system_prompt=self.system_prompt(), context_id=self.context_id,
                renderer_ready=self.dataset_id is not None, receipts=self.turn.operation_receipts,
                observations=paused.observations,
            )
        async with asyncio.timeout(self.request_timeout):
            selected, strategy_context = [], None
            while True:
                if self.collaboration is not None:
                    await self.collaboration.idle.wait()
                try:
                    if self.strategy_index is not None and strategy_context != self.context_id:
                        selected = await self.relevant_strategies(original_prompt)
                        strategy_context = self.context_id
                    prepared = with_strategy_hints(history, self.system_prompt(), selected) if selected else history
                    result = await self.agent.run(
                        prompt, message_history=prepared, usage=usage,
                        model_settings=self.settings.inference.request_settings(),
                        usage_limits=UsageLimits(request_limit=self.model_request_limit, tool_calls_limit=self.tool_call_limit),
                    )
                    if self.collaboration is not None:
                        await asyncio.sleep(0)
                        if self.collaboration.changed.is_set():
                            self.collaboration.safe_history = await bounded_history(without_strategy_hints(result.all_messages()))
                            raise ReplanForUser()
                    break
                except ContextCheckpointRequired:
                    if not self.can_checkpoint():
                        raise ContextBudgetExceeded("No safe continuation boundary", reason="checkpoint_unavailable")
                    history = self.turn.continuation.checkpoint(
                        system_prompt=self.system_prompt(), context_id=self.context_id,
                        renderer_ready=self.dataset_id is not None, receipts=self.turn.operation_receipts,
                        observations=self.turn.visual_observations,
                    )
                    logger.warning("Context continuation: checkpoint=%d confirmed_mutation_tools=%s trace=%s",
                                   self.turn.continuation.count, sorted(self.turn.continuation.actions), self.turn.continuation.trace_id)
                    self.turn.annotation_reads.clear()
                    self.turn.state_seen = self.turn.volume_edit_state_seen = False
                    if self.collaboration is not None:
                        self.collaboration.needs_context = True
                    # RunUsage, the native-call count, local approval decisions and the original timeout survive.
                    prompt = original_prompt
                except ReplanForDataset:
                    conversation = application_context_history(conversation, system_prompt=self.system_prompt())
                    self.turn.annotation_reads.clear()
                    history = self.dataset_control.resume_history(self.system_prompt())
                    self.dataset_control.history = []
                    self.turn.dataset_transition = None
                    self.turn.state_seen = False
                    self.turn.screenshot_count = 0
                    self.turn.visual_observations = []
                    self.agent = self.build_agent()
                    prompt = original_prompt
                except ReplanForUser:
                    self.turn.annotation_reads.clear()
                    await self.send({"type": "collaboration_paused", "request_id": message.request_id})
                    await self.collaboration.idle.wait()
                    self.collaboration.changed.clear()
                    self.turn.state_seen = False
                    self.turn.screenshot_count = 0
                    self.turn.visual_observations = []
                    history = self.collaboration.resume_history()
                    self.collaboration.needs_context = False
                    self.collaboration.domains.clear()
                    prompt = None
                    await self.send({"type": "collaboration_resumed", "request_id": message.request_id,
                                     "view_revision": self.collaboration.revision})
        messages = (completed_continuation(self.system_prompt(), original_prompt, result.output, conversation)
                    if self.turn.continuation.count or paused else without_strategy_hints(result.all_messages()))
        self.history = await bounded_history(messages)
        await self.finish_text(message, result.output)
        outcome = "completed"
    except asyncio.CancelledError:
        outcome = "cancelled"
        self.history = conversation
        with contextlib.suppress(Exception):
            await self.send({"type": "cancelled", "request_id": message.request_id,
                             "requires_reconnect": self.uncertain})
        raise
    except Exception as error:
        context_limit = isinstance(error, (ContextBudgetExceeded, ModelContextWindowExceededError))
        can_pause = (self.turn.changes_applied and self.pending is None and not self.uncertain and
                     self.turn.dataset_transition is None and
                     (context_limit or not isinstance(error, (ProtocolError, WebSocketDisconnect))))
        outcome = "paused" if can_pause else "failed"
        self.history = conversation
        # Do not log exception bodies: providers can include private prompts/tool data.
        reason = (error.reason if isinstance(error, ContextBudgetExceeded) else
                  "provider_context" if isinstance(error, ModelContextWindowExceededError) else "other")
        logger.warning("Agent run %s: %s (BorgVR calls=%d, model requests=%d, tool calls=%d) "
                       "reason=%s checkpoints=%d confirmed_mutation_tools=%s",
                       outcome, type(error).__name__, self.turn.native_calls,
                       self.budget.requests if self.budget else 0, self.budget.tool_calls if self.budget else 0,
                       reason, self.turn.continuation.count, sorted(self.turn.continuation.actions))
        if isinstance(error, UnexpectedModelBehavior):
            category, tool = model_failure(error, self.diagnostic_tools)
            logger.warning("Agent model diagnostic: trace=%s category=%s tool=%s",
                           self.turn.continuation.trace_id, category, tool or "-")
        code = "context_limit" if context_limit else "run_failed"
        if can_pause:
            self.paused_task = PausedTask(
                self.context_id, original_prompt, self.turn.continuation, self.turn.operation_receipts[-6:],
                self.turn.visual_observations[-2:], self.turn.volume_edit_declined, self.turn.deletion_declined,
                self.turn.edit_state_deletion_declined, self.turn.file_selection_declined, self.turn.opened_this_turn,
                conversation,
            )
            count = self.turn.continuation.actions["edit_volume"]
            text = ("I completed part of the task, but couldn't finish or verify the whole result. "
                    + (f"Confirmed volume edit commands: {count}. " if count else "")
                    + "Would you like me to continue? Say or type “Continue”.")
            self.history = completed_continuation(self.system_prompt(), original_prompt, text, conversation)
            with contextlib.suppress(Exception):
                await self.finish_text(message, text, partial={"reason": code, "confirmed_volume_edits": count})
            return
        if self.uncertain:
            text = "Command completion is uncertain. Inspect the visualization before starting a new conversation."
        elif self.turn.changes_applied:
            text = "Changes were applied, but the request or its visual verification could not be completed."
        elif context_limit:
            text = "The request exceeds the model context. Start a new conversation or use a shorter request."
        else:
            text = "The request failed or exceeded its limits."
        with contextlib.suppress(Exception):
            await self.send({"type": "error", "request_id": message.request_id,
                             "code": code, "requires_reconnect": self.uncertain,
                             "changes_applied": self.turn.changes_applied,
                             "message": text})
    finally:
        self.dataset_just_opened = False
        checkpoint = self.turn.continuation
        if checkpoint.count or checkpoint.actions or self.uncertain:
            run_diagnostics.info(
                "Agent mutation audit: trace=%s outcome=%s checkpoints=%d confirmed=%s "
                "repeated_confirmed=%s blocked_replays=%s uncertain=%s",
                checkpoint.trace_id, outcome, checkpoint.count, dict(checkpoint.actions),
                dict(checkpoint.repeated_actions), dict(checkpoint.blocked_actions), self.uncertain,
            )

async def finish_text(self, message, text, **metadata):
    await self.send({"type": "assistant_message", "request_id": message.request_id,
                     "text": text, "final": True, **metadata})
    completion = {"type": "completed", "request_id": message.request_id}
    if "partial" in metadata:
        completion["outcome"] = "partial"
    await self.send(completion)
