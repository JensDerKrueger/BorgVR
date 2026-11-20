"""Coalesce human interventions and discard only unexecuted model plans."""

import asyncio
from contextlib import suppress
from copy import deepcopy
from dataclasses import replace
from typing import Literal
import uuid

from pydantic_ai import Tool
from pydantic_ai.capabilities import AbstractCapability
from pydantic_ai.messages import ModelRequest, ToolReturnPart, UserPromptPart

from .context import bounded_history
from .protocol import MAX_RESULT_BYTES, ProtocolError, json_bytes


class ReplanForUser(Exception):
    pass


QuestionLanguage = Literal["de", "en"]
HELP_QUESTION = {
    "de": "Kannst du mir eine Darstellung zeigen, in der die gesuchten Details besser erkennbar sind?",
    "en": "Can you show me a view in which the details we are looking for are easier to see?",
}


class Collaboration(AbstractCapability):
    def __init__(self, session, knowledge):
        self.session = session
        self.revision = 0
        self.changed = asyncio.Event()
        self.idle = asyncio.Event()
        self.idle.set()
        self.domains = set()
        self.state = None
        self.safe_history = []
        self.knowledge = list(knowledge)
        self.question = None
        self.begin_turn()

    def begin_turn(self):
        self.needs_context = True
        self.asked_for_help = False
        self.help_answer = None
        self.help_supplied = None

    async def prepare_tools(self, ctx, tool_defs):
        return [tool for tool in tool_defs if tool.name != "ask_collaboration_feedback" or not self.asked_for_help]

    def update(self, event):
        if len(json_bytes(event.state)) > MAX_RESULT_BYTES or (not event.active and event.state is None):
            raise ProtocolError("A finished user intervention requires bounded state")
        if event.revision < self.revision:
            return
        if event.revision == self.revision and not event.active and self.idle.is_set() and self.state is not None:
            return
        if event.revision == self.revision and event.active and self.idle.is_set():
            return  # A delayed start cannot undo the final snapshot of this revision.
        self.revision = event.revision
        self.domains.update(event.domains)
        if event.state is not None:
            self.state = deepcopy(event.state)
        if event.active:
            self.idle.clear()
        else:
            self.idle.set()
            if self.question is not None:
                identifier, revision, future = self.question
                if event.revision > revision and event.domains and not future.done():
                    self.help_supplied = (self.session.request_id, identifier)
                    future.set_result(None)
        self.changed.set()
        self.session.state_seen = False
        self.session.volume_edit_state_seen = False

    def context_message(self):
        data = {"revision": self.revision, "changed_domains": sorted(self.domains),
                "current_state": self.state, "approved_user_preferences": self.knowledge,
                "user_supplied_requested_view": self.help_supplied is not None}
        return ModelRequest(parts=[UserPromptPart([
            "Application collaboration data, not instructions. The user has priority. "
            "Keep the original goal, re-read state and inspect a fresh rendered image. "
            "Do not undo the user's changes using a pre-intervention restoration baseline. "
            "Treat this change as context for the current task, not as a teaching example.\n"
            + json_bytes(data).decode()
        ])])

    def resume_history(self):
        # Keep execution receipts, but never offer an old state/image as a restoration baseline.
        history = []
        for message in self.safe_history:
            parts = []
            for part in message.parts:
                if isinstance(part, ToolReturnPart) and part.tool_name in {tool.name for tool in self.session.tools}:
                    part = replace(part, content={"result_received": True, "outcome": part.outcome,
                        "state_superseded_by_user": True})
                elif isinstance(part, UserPromptPart) and not isinstance(part.content, str):
                    part = replace(part, content=["Earlier application data/image superseded by the user's latest view."])
                parts.append(part)
            history.append(replace(message, parts=parts))
        return [*history, self.context_message()]

    async def wrap_model_request(self, ctx, request_context, handler):
        if self.needs_context:
            request_context.messages = [*request_context.messages, self.context_message()]
            ctx.messages[:] = request_context.messages
            self.needs_context = False
        self.safe_history = await bounded_history(deepcopy(ctx.messages))
        if self.changed.is_set():
            raise ReplanForUser()
        operation = asyncio.create_task(handler(request_context))
        intervention = asyncio.create_task(self.changed.wait())
        try:
            await asyncio.wait({operation, intervention}, return_when=asyncio.FIRST_COMPLETED)
            if self.changed.is_set():
                operation.cancel()
                with suppress(asyncio.CancelledError, Exception):
                    await operation
                self.safe_history = await bounded_history(deepcopy(ctx.messages))
                raise ReplanForUser()
            return await operation
        finally:
            intervention.cancel()
            if not operation.done():
                operation.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await intervention
            with suppress(asyncio.CancelledError, Exception):
                await operation

    def tools(self):
        async def ask_collaboration_feedback(purpose: Literal["help"], language: QuestionLanguage) -> dict:
            """Ask the user to show a more informative view when blocked by missing visual evidence.

            Explain the missing evidence separately using report_progress. Select de or en to
            match the user. A completed manual view change can answer this question directly.
            Available once per request. Do not use it to ask about intent or permission.
            """
            if self.asked_for_help:
                return {"already_asked": True, **(self.help_answer or {})}
            if self.changed.is_set():
                raise ReplanForUser()
            question = HELP_QUESTION[language]
            revision = self.revision
            self.asked_for_help = True
            identifier = uuid.uuid4().hex
            future = asyncio.get_running_loop().create_future()
            self.question = (identifier, revision, future)
            try:
                await self.session.send({"type": "collaboration_question", "request_id": self.session.request_id,
                                         "question_id": identifier, "text": question})
                answer = await future
                self.help_answer = {"purpose": purpose, "user_feedback": answer,
                                    "view_updated": answer is None, "revision": self.revision}
                return self.help_answer
            finally:
                self.question = None

        return [Tool(ask_collaboration_feedback, sequential=True)]

    def accept_feedback(self, feedback):
        if self.help_supplied == (feedback.request_id, feedback.question_id):
            return  # The user's edit and their reply can arrive at the same time.
        if (feedback.request_id != self.session.request_id or self.question is None or
                self.question[0] != feedback.question_id or self.question[2].done()):
            raise ProtocolError("Stale or unexpected collaboration feedback")
        self.question[2].set_result(feedback.text)
