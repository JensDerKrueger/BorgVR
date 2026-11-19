import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

from pydantic import ValidationError
from pydantic_ai import ModelRetry
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel
import pytest

from borgvr_agent.app import Session
from borgvr_agent.budget import ControlBudget
from borgvr_agent.collaboration import Collaboration
from borgvr_agent.protocol import CollaborationFeedback, Hello, ProtocolError, RuleDecision, ToolDefinition, ToolResult, UserChange
from test_agent import STATE, ROTATE, SETTINGS, connection, hello, open_session, reply, user


def change(revision=1, active=False, **kwargs):
    return {"type": "user_change", "dataset_id": "test-volume", "context_id": "opening-1",
            "revision": revision, "active": active, "domains": ["transform"],
            **({} if active else {"state": {"manual_rotation": 30}}), **kwargs}


def test_events_are_bounded_and_stale_events_cannot_reopen_a_finished_intervention():
    session = SimpleNamespace(state_seen=True)
    collaboration = Collaboration(session, ["Prefer high-contrast bone views."])
    collaboration.update(UserChange.model_validate(change(active=True)))
    assert not collaboration.idle.is_set() and not session.state_seen
    collaboration.update(UserChange.model_validate(change(revision=2)))
    assert collaboration.idle.is_set() and collaboration.revision == 2
    collaboration.changed.clear()
    collaboration.update(UserChange.model_validate(change(revision=1, active=True)))
    collaboration.update(UserChange.model_validate(change(revision=2, active=True)))
    assert collaboration.idle.is_set() and not collaboration.changed.is_set()
    with pytest.raises(ProtocolError):
        collaboration.update(UserChange.model_validate(change(revision=3, state=None)))
    with pytest.raises(ProtocolError):
        collaboration.update(UserChange.model_validate(change(revision=3, state={"too_large": "x" * 262144})))
    for invalid in ({"revision": True}, {"revision": 0}, {"domains": ["secret_path"]}, {"extra": True}):
        with pytest.raises(ValidationError):
            UserChange.model_validate(change(**invalid))
    for knowledge in (["x" * 501], ["x"] * 17):
        with pytest.raises(ValidationError):
            Hello.model_validate({**hello([STATE]), "collaboration": True, "knowledge": knowledge})


def test_model_generation_is_cancelled_but_original_goal_is_kept():
    invocations = 0
    cancelled = []
    async def model(messages, info):
        nonlocal invocations
        invocations += 1
        goals = [part.content for message in messages for part in message.parts
                 if isinstance(part, UserPromptPart) and isinstance(part.content, str)]
        assert goals[-1] == "Turn the test volume."
        if invocations == 1:
            try:
                await asyncio.sleep(30)
            except asyncio.CancelledError:
                cancelled.append(True)
                raise
        assert any("manual_rotation" in str(part.content) for message in messages for part in message.parts
                   if isinstance(part, UserPromptPart))
        return ModelResponse(parts=[TextPart("Continuing your original task from your new view.")])

    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json({**hello([STATE]), "collaboration": True})
        assert ws.receive_json()["collaboration"] is True
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        # A model-side event makes this test deterministic, not a sleep-based cancellation race.
        import time
        deadline = time.monotonic() + 2
        while invocations == 0 and time.monotonic() < deadline:
            time.sleep(.005)
        ws.send_json(change(active=True))
        assert ws.receive_json()["type"] == "collaboration_paused"
        ws.send_json(change(revision=2))
        assert ws.receive_json()["type"] == "collaboration_resumed"
        assert ws.receive_json()["text"].startswith("Continuing")
        assert ws.receive_json()["type"] == "completed"
    assert cancelled == [True] and invocations == 2


def test_pending_native_command_finishes_once_and_its_receipt_survives_replan():
    count = 0
    async def model(messages, info):
        nonlocal count
        count += 1
        if count == 1:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="s")])
        if count == 2:
            return ModelResponse(parts=[ToolCallPart("rotate_view", {"axis": [0, 1, 0], "degrees": 20}, tool_call_id="r")])
        receipts = [part for message in messages for part in message.parts
                    if isinstance(part, ToolReturnPart) and part.tool_name == "rotate_view"]
        assert len(receipts) == 1 and receipts[0].content["state_superseded_by_user"]
        assert receipts[0].content["outcome"] == "success"
        return ModelResponse(parts=[TextPart("Kept the user view; no command replayed.")])
    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json({**hello([STATE, ROTATE]), "collaboration": True})
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        ws.send_json(reply(call, view_revision=0))
        call = ws.receive_json()
        assert call["name"] == "rotate_view"
        ws.send_json(change(active=True))
        ws.send_json(change(revision=2))
        ws.send_json(reply(call, view_revision=0))
        assert ws.receive_json()["type"] == "collaboration_paused"
        assert ws.receive_json()["type"] == "collaboration_resumed"
        assert ws.receive_json()["text"].startswith("Kept")
        assert ws.receive_json()["type"] == "completed"
    assert count == 3


def test_rejected_stale_command_is_not_claimed_as_applied_or_uncertain():
    async def check():
        class Socket:
            async def send_text(self, raw):
                event = json.loads(raw)
                session.pending[2].set_result(ToolResult.model_validate(reply(event, view_revision=1,
                    result={"ok": False, "not_applied": True, "code": "user_changed_view"})))
        session = Session(Socket(), SETTINGS, None, asyncio.Semaphore(1))
        session.dataset_id, session.context_id, session.request_id = "test-volume", "opening-1", "turn-1"
        session.collaboration = Collaboration(session, [])
        session.state_seen = True
        result = await session.call_tool(ToolDefinition.model_validate(ROTATE), {"axis": [0, 1, 0], "degrees": 20})
        assert result["not_applied"] and not session.changes_applied and not session.uncertain
        assert session.collaboration.changed.is_set() and not session.state_seen
    asyncio.run(check())


def test_feedback_then_explicit_rule_approval_and_next_turn_knowledge():
    rule = "For this task, inspect cross-sections perpendicular to the viewing direction."
    count = 0
    async def model(messages, info):
        nonlocal count
        count += 1
        names = {tool.name for tool in info.function_tools}
        assert {"ask_collaboration_feedback", "propose_visualization_rule"} <= names
        if count == 1:
            return ModelResponse(parts=[ToolCallPart("ask_collaboration_feedback", {"question": "Was your rotation intended to help?"}, tool_call_id="q")])
        if count == 2:
            assert any(isinstance(part, ToolReturnPart) and part.content.get("user_feedback") == "Yes, inspect perpendicular sections."
                       for message in messages for part in message.parts if isinstance(part, ToolReturnPart))
            return ModelResponse(parts=[ToolCallPart("propose_visualization_rule", {"rule": rule}, tool_call_id="p")])
        if count == 3:
            return ModelResponse(parts=[TextPart("Rule proposed, not saved automatically.")])
        assert any(rule in str(part.content) for message in messages for part in message.parts if isinstance(part, UserPromptPart))
        return ModelResponse(parts=[TextPart("Approved preference received as task data.")])
    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json({**hello([STATE]), "collaboration": True})
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        question = ws.receive_json()
        assert question["type"] == "collaboration_question"
        ws.send_json({"type": "collaboration_feedback", "request_id": "turn-1", "question_id": question["question_id"],
                      "text": "Yes, inspect perpendicular sections."})
        proposal = ws.receive_json()
        assert proposal["type"] == "rule_proposal" and proposal["text"] == rule
        assert ws.receive_json()["text"].startswith("Rule proposed")
        ws.receive_json()
        ws.send_json({"type": "rule_decision", "proposal_id": proposal["proposal_id"], "accepted": True})
        ws.send_json(user("turn-2"))
        ws.receive_json()
        assert ws.receive_json()["text"].startswith("Approved preference")
        assert ws.receive_json()["type"] == "completed"


def test_unconfirmed_rule_is_never_persisted_and_feedback_is_required():
    async def check():
        sent = []
        async def send(value):
            sent.append(value)
        session = SimpleNamespace(send=send, request_id="request", tools=[])
        collaboration = Collaboration(session, [])
        propose = collaboration.tools()[1].function
        with pytest.raises(ModelRetry):
            await propose("Never infer teaching from rotation alone.")
        collaboration.feedback = "This was just for this dataset."
        result = await propose("Prefer a side view when examining this dataset type.")
        assert result["saved"] is False and collaboration.knowledge == []
        collaboration.decide_rule(RuleDecision(type="rule_decision", proposal_id=result["proposal_id"], accepted=False))
        assert collaboration.knowledge == []
        with pytest.raises(ProtocolError):
            collaboration.decide_rule(RuleDecision(type="rule_decision", proposal_id=result["proposal_id"], accepted=True))
        with pytest.raises(ProtocolError):
            collaboration.accept_feedback(CollaborationFeedback(type="collaboration_feedback", request_id="other", question_id="stale", text="yes"))
    asyncio.run(check())


def test_cancel_during_human_pause_does_not_resume():
    async def model(messages, info):
        await asyncio.sleep(30)
        return ModelResponse(parts=[TextPart("Must not resume")])
    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json({**hello([STATE]), "collaboration": True})
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(change(active=True))
        # The pause may happen before the very first model request.
        ws.send_json({"type": "cancel", "request_id": "turn-1"})
        event = ws.receive_json()
        if event["type"] == "collaboration_paused":
            event = ws.receive_json()
        assert event["type"] == "cancelled"


def test_help_remains_available_at_budget_end_but_native_mutations_do_not():
    async def check():
        collaboration = SimpleNamespace(asked_revision=None, revision=0)
        session = SimpleNamespace(native_calls=24, settings=SETTINGS, run_started=None, collaboration=collaboration)
        ctx = SimpleNamespace(usage=SimpleNamespace(tool_calls=24, requests=24))
        tools = [SimpleNamespace(name=name) for name in ["rotate_view", "ask_collaboration_feedback"]]
        budget = ControlBudget(session)
        assert [tool.name for tool in await budget.prepare_tools(ctx, tools)] == ["ask_collaboration_feedback"]
        collaboration.asked_revision = 0
        assert await budget.prepare_tools(ctx, tools) == []
    asyncio.run(check())


def test_native_agent_dependency_boundary():
    root = Path(__file__).resolve().parents[2]
    controller = (root / "AppSupport/Voice/VoiceAgentController.swift").read_text()
    contract = (root / "AppSupport/Voice/VoiceAgentApplicationBridge.swift").read_text()
    for core_type in ("BorgVRCommand", "BorgVRMCP", "BorgVRSession", "AppModel", "RenderingParameters"):
        assert core_type not in controller and core_type not in contract
    for relative in ("AppSupport/Application/BorgVRSession.swift", "AppSupport/Automation/VolumeEditingCommands.swift"):
        source = (root / relative).read_text()
        assert "VoiceAgent" not in source and "voiceAgent" not in source
