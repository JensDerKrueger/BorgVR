import json
from pathlib import Path

import pytest
from pydantic import ValidationError
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel

from borgvr_agent.context import application_context_history, SUMMARY_MARKER
from borgvr_agent.protocol import Hello
from test_agent import STATE, ROTATE, SCREENSHOT, connection, hello, open_session, reply, user, model_steps


def application_hello(dataset=None):
    return {**hello([STATE, ROTATE, SCREENSHOT]), "application_session": True, "dataset_id": dataset}


def change(dataset, context):
    return {"type": "context_changed", "dataset_id": dataset, "context_id": context,
            "tools": [STATE, ROTATE, SCREENSHOT]}


def test_dataset_free_session_requires_explicit_negotiation():
    with pytest.raises(ValidationError):
        Hello.model_validate({**hello([STATE]), "dataset_id": None})
    assert Hello.model_validate(application_hello()).dataset_id is None
    with pytest.raises(ValidationError):
        Hello.model_validate({**application_hello(), "dataset_id": ""})


def test_application_session_reads_state_without_a_dataset_and_filters_renderer_tools():
    with connection(model_steps(("get_application_state", {}), "Start menu ready")) as client, open_session(client) as ws:
        ws.send_json(application_hello())
        ready = ws.receive_json()
        assert ready["application_session"] is True
        assert ready["tools"] == ["get_application_state"]
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        call = ws.receive_json()
        assert call["dataset_id"] is None
        ws.send_json(reply(call, result={"rendererReady": False}))
        assert ws.receive_json()["text"] == "Start menu ready"
        assert ws.receive_json()["type"] == "completed"


def test_open_close_and_reopen_reconcile_tools_and_keep_only_bounded_text_history():
    seen = []

    async def function(messages, info):
        seen.append(messages)
        assert {t.name for t in info.function_tools} >= {"get_application_state"}
        return ModelResponse(parts=[TextPart("Previous conversation answer")])

    with connection(FunctionModel(function)) as client, open_session(client) as ws:
        ws.send_json(application_hello())
        session = ws.receive_json()["session_id"]
        for index, dataset in enumerate((None, "volume", None, "volume")):
            if index:
                ws.send_json(change(dataset, f"context-{index}"))
                updated = ws.receive_json()
                assert updated["session_id"] == session
                assert updated["type"] == "context_updated"
                assert updated["tools"] == (["get_application_state"] if dataset is None else
                                             ["get_application_state", "rotate_view", "capture_screenshot"])
            ws.send_json(user(f"turn-{index}"))
            assert ws.receive_json()["type"] == "started"
            assert ws.receive_json()["type"] == "assistant_message"
            assert ws.receive_json()["type"] == "completed"
        assert any(isinstance(part, UserPromptPart) and isinstance(part.content, str)
                   and SUMMARY_MARKER in part.content and "Previous conversation answer" in part.content
                   for message in seen[-1] for part in message.parts)


def test_context_change_invalidates_previous_state_read_before_mutation():
    with connection(model_steps(("get_application_state", {}), "Done", ("rotate_view", {"axis": [1, 0, 0], "degrees": 10}))) as client, open_session(client) as ws:
        ws.send_json(application_hello("first"))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        ws.send_json(reply(call))
        ws.receive_json()
        assert ws.receive_json()["type"] == "completed"
        ws.send_json(change("second", "context-2"))
        assert ws.receive_json()["type"] == "context_updated"
        ws.send_json(user("turn-2"))
        assert ws.receive_json()["type"] == "started"
        # No native rotate call: the new context has not been read yet.
        assert ws.receive_json()["type"] == "error"


def test_context_history_drops_tool_results_images_and_limits_text():
    from pydantic_ai import BinaryContent
    from pydantic_ai.messages import ModelRequest

    messages = [ModelRequest(parts=[UserPromptPart("x" * 10000),
                                   ToolReturnPart("get_application_state", {"secret_old_state": True}, "call"),
                                   UserPromptPart([BinaryContent(b"old_image", media_type="image/png")])]),
                ModelResponse(parts=[ToolCallPart("rotate_view", {"degrees": 10}, "call"), TextPart("Answer")])]
    result = application_context_history(messages, system_prompt="Current trusted system policy")
    parts = [part for message in result for part in message.parts if isinstance(part, UserPromptPart)]
    assert len(parts) == 1 and isinstance(parts[0], UserPromptPart)
    assert "secret_old_state" not in parts[0].content and "old_image" not in parts[0].content
    assert "rotate_view" not in parts[0].content and len(parts[0].content) < 2000
    assert json.loads(parts[0].content.split("\n", 1)[1])["context_changed"] is True


def test_active_context_change_cannot_redirect_a_pending_native_call():
    with connection(model_steps(("get_application_state", {}))) as client, open_session(client) as ws:
        ws.send_json(application_hello("old-volume"))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        assert call["dataset_id"] == "old-volume"
        ws.send_json(change("new-volume", "new-opening"))
        assert ws.receive_json()["code"] == "invalid_message"


def test_old_tool_result_cannot_be_reused_after_idle_context_change():
    with connection(model_steps(("get_application_state", {}), "Done")) as client, open_session(client) as ws:
        ws.send_json(application_hello())
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        ws.send_json(reply(call))
        ws.receive_json()
        ws.receive_json()
        ws.send_json(change("volume", "next-opening"))
        assert ws.receive_json()["type"] == "context_updated"
        ws.send_json(reply(call))
        assert ws.receive_json()["code"] == "invalid_message"


def test_app_entry_points_and_presentation_stay_outside_the_renderer():
    root = Path(__file__).resolve().parents[2]
    for platform in ("macOSApp", "iOSApp", "VisionApp"):
        assert "VoiceAgentButton" in (root / platform / "ModeSelectionView.swift").read_text()
    view = (root / "AppSupport/Voice/VoiceAgentViews.swift").read_text()
    assert "!agent.hasDataset" not in view and "agent.datasetOpeningID" not in view
    assert ".sheet(isPresented: $voiceAgent.isPresented)" in (root / "iOSApp/BorgVRMobileApp.swift").read_text()
    for platform in ("macOSApp", "VisionApp"):
        assert "dismissWindow(id: VoiceAgentView.windowID)" not in (root / platform / "RenderView.swift").read_text()
