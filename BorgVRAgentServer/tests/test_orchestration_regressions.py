import asyncio
from dataclasses import replace

import pytest
from pydantic_ai.messages import ModelRequest, ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel

from borgvr_agent.app import Session
from borgvr_agent.context import ContextCheckpointRequired
from borgvr_agent.continuation import TaskContinuation
from borgvr_agent.protocol import ToolDefinition
from test_agent import EDIT, EDIT_STATUS, ROTATE, SETTINGS, STATE, connection, hello, open_session, reply, user


def test_automatic_checkpoint_does_not_resend_regrouped_edits_or_drop_older_turns():
    known = {"center_meters": [0, 0, 0], "radius_meters": 0.002}
    other = {"center_meters": [0, 0, 0.01], "radius_meters": 0.002}
    batch = {"mode": "erase", "samples": [known, other]}
    regrouped = {"mode": "erase", "samples": [other]}
    steps = iter([
        "First answer.",
        ("get_application_state", {}), ("get_volume_edit_state", {}), ("edit_volume", batch),
        ContextCheckpointRequired(),
        ("get_application_state", {}), ("get_volume_edit_state", {}), ("edit_volume", regrouped),
        "Edit verified.", "Last answer.",
    ])
    prompts = []

    async def respond(messages, info):
        prompts.append([p.content for m in messages if isinstance(m, ModelRequest)
                        for p in m.parts if isinstance(p, UserPromptPart)])
        step = next(steps)
        if isinstance(step, Exception):
            raise step
        if isinstance(step, str):
            return ModelResponse(parts=[TextPart(step)])
        return ModelResponse(parts=[ToolCallPart(*step, tool_call_id=f"model-{len(prompts)}")])

    with connection(FunctionModel(respond)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, EDIT_STATUS, EDIT]))
        assert ws.receive_json()["type"] == "ready"
        ws.send_json({**user("first"), "text": "Remember the synthetic landmark."})
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["text"] == "First answer."
        assert ws.receive_json()["type"] == "completed"
        ws.send_json(user("edit"))
        assert ws.receive_json()["type"] == "started"
        for name in ["get_application_state", "get_volume_edit_state", "edit_volume",
                     "get_application_state", "get_volume_edit_state"]:
            call = ws.receive_json()
            assert call["name"] == name
            ws.send_json(reply(call, result={"available": True, "shared": False, "channels": [1]}))
        message = ws.receive_json()
        assert message["type"] == "assistant_message" and message["text"] == "Edit verified."
        assert ws.receive_json()["type"] == "completed"
        ws.send_json(user("last"))
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["text"] == "Last answer."
        assert ws.receive_json()["type"] == "completed"
    assert any("Remember the synthetic landmark." in str(part) for part in prompts[-1])


@pytest.mark.anyio
@pytest.mark.parametrize("definition,arguments,uncertain", [
    (STATE, {}, False),
    (ROTATE, {"axis": [0, 1, 0], "degrees": 20}, True),
])
async def test_timeout_marks_only_potential_mutations_as_uncertain(definition, arguments, uncertain, anyio_backend):
    class SilentSocket:
        async def send_text(self, raw):
            pass

    session = Session(SilentSocket(), replace(SETTINGS, tool_timeout=0.01), None, asyncio.Semaphore(1))
    session.turn.state_seen = True
    if uncertain:
        with pytest.raises(TimeoutError):
            await session.call_tool(ToolDefinition.model_validate(definition), arguments)
    else:
        result = await session.call_tool(ToolDefinition.model_validate(definition), arguments)
        assert result["code"] == "read_timeout"
    assert session.uncertain is uncertain


@pytest.fixture
def anyio_backend():
    return "asyncio"


def test_two_clients_share_inference_even_while_one_waits_for_a_tool():
    async def respond(messages, info):
        text = str(messages)
        if "First client" in text and not any(isinstance(part, ToolReturnPart) for m in messages for part in m.parts):
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="first-state")])
        return ModelResponse(parts=[TextPart("Ready")])

    settings = replace(SETTINGS, inference=replace(SETTINGS.inference, sequences=1))
    with connection(FunctionModel(respond), settings) as client, open_session(client) as first, open_session(client) as second:
        for ws in (first, second):
            ws.send_json(hello([STATE]))
            assert ws.receive_json()["type"] == "ready"
        first.send_json({**user("first"), "text": "First client"})
        assert first.receive_json()["type"] == "started"
        call = first.receive_json()
        assert call["name"] == "get_application_state"
        second.send_json({**user("second"), "text": "Second client"})
        assert second.receive_json()["type"] == "started"
        assert second.receive_json()["text"] == "Ready"
        assert second.receive_json()["type"] == "completed"
        first.send_json(reply(call))
        assert first.receive_json()["text"] == "Ready"
        assert first.receive_json()["type"] == "completed"


def test_inverse_edit_only_supersedes_receipts_for_channels_it_changed():
    journal = TaskContinuation()
    sample = {"center_meters": [0, 0, 0], "radius_meters": 0.01}
    erase = {"mode": "erase", "samples": [sample]}
    restore = {"mode": "restore", "samples": [sample]}
    journal.record("scope", "edit_volume", erase, 0b0011)
    journal.record("scope", "edit_volume", restore, 0b0001)
    journal.begin_resume(2)
    assert journal.edit_replay_indices("scope", erase, 0b0001) == []
    assert journal.edit_replay_indices("scope", erase, 0b0010) == [0]
    assert journal.edit_replay_indices("scope", restore, 0b0001) == [0]
