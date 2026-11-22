from pydantic_ai import BinaryContent
from pydantic_ai.messages import ModelResponse, SystemPromptPart, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel

from test_agent import STATE, ROTATE, SCREENSHOT, connection, definition, hello, open_session, png, reply, user


WAIT = definition("wait_until_rendered")
TRANSFORM = definition("set_transform", {"rotation": {"type": "array", "items": {"type": "number"},
                                                     "minItems": 4, "maxItems": 4}})
CLIP = definition("set_clipping", {name: {"type": "array", "items": {"type": "number"},
                                          "minItems": 3, "maxItems": 3}
                                   for name in ("minimum", "maximum")}, ["minimum", "maximum"])


def notes(messages):
    return [part.content for message in messages for part in message.parts
            if isinstance(part, ToolReturnPart) and part.tool_name == "record_visual_observation"
            and part.outcome == "success"]


def test_multiview_inspection_preserves_evidence_and_restores_view_past_old_request_limit():
    original_rotation = [0, 0, 0, 1]
    steps = [
        ("get_application_state", {}),
        ("report_progress", {"activity": "compare_views", "language": "de"}),
        ("wait_until_rendered", {}),
        ("capture_screenshot", {}),
        ("record_visual_observation", {"observation": "Front: A und B sind getrennt erkennbar; der Rest ist verdeckt."}),
        ("rotate_view", {"axis": [0, 1, 0], "degrees": 70}),
        ("wait_until_rendered", {}),
        ("capture_screenshot", {}),
        ("record_visual_observation", {"observation": "Seite: A und B wiedergefunden; zusaetzlich C."}),
        ("set_clipping", {"minimum": [0, 0, 0], "maximum": [1, 0.6, 1]}),
        ("wait_until_rendered", {}),
        ("capture_screenshot", {}),
        ("record_visual_observation", {"observation": "Schnitt: C wiedergefunden; D klar zusaetzlich, weitere Objekte verdeckt."}),
        ("set_clipping", {"minimum": [0, 0, 0], "maximum": [1, 1, 1]}),
        ("set_transform", {"rotation": original_rotation}),
        ("wait_until_rendered", {}),
        ("capture_screenshot", {}),
    ]
    requests = 0

    async def model(messages, info):
        nonlocal requests
        prompt = "\n".join(part.content for message in messages for part in message.parts
                           if isinstance(part, SystemPromptPart))
        assert "Actively investigate visual questions" in prompt
        assert "Do not add\nper-view counts together" in prompt
        assert "restore them\nusing their exact state values" in prompt
        assert any(isinstance(part, UserPromptPart) and part.content == "Wie viele Muenzen sind in der Spardose?"
                   for message in messages for part in message.parts)
        if requests < len(steps):
            name, arguments = steps[requests]
            requests += 1
            return ModelResponse(parts=[ToolCallPart(name, arguments, tool_call_id=f"step-{requests}")])
        evidence = notes(messages)[-1]
        assert [entry["view"] for entry in evidence["observations"]] == [1, 2, 3]
        assert "Front:" in evidence["observations"][0]["observation"]
        images = [item for message in messages for part in message.parts
                  if isinstance(part, UserPromptPart) and not isinstance(part.content, str)
                  for item in part.content if isinstance(item, BinaryContent)]
        assert 1 <= len(images) <= 2  # Context pressure may reduce images further; evidence notes survive.
        requests += 1
        return ModelResponse(parts=[TextPart("Mindestens vier Muenzen sind unterscheidbar; eine sichere Gesamtzahl ist wegen Verdeckung nicht moeglich.")])

    external = [(name, arguments) for name, arguments in steps if name not in {
        "report_progress", "record_visual_observation"}]
    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE, SCREENSHOT, WAIT, TRANSFORM, CLIP]))
        ws.receive_json()
        ws.send_json({**user(), "text": "Wie viele Muenzen sind in der Spardose?"})
        assert ws.receive_json()["type"] == "started"
        for name, arguments in external:
            call = ws.receive_json()
            if call["type"] == "assistant_message":
                assert not call["final"]
                call = ws.receive_json()
            assert call["type"] == "tool_call" and (call["name"], call["arguments"]) == (name, arguments)
            payload = {"image_png_base64": png()} if name == "capture_screenshot" else {}
            if name == "get_application_state":
                payload["result"] = {"transform": {"rotation": original_rotation},
                                     "clipMinimum": [0, 0, 0], "clipMaximum": [1, 1, 1]}
            ws.send_json(reply(call, **payload))
        result = ws.receive_json()
        assert result["type"] == "assistant_message" and result["final"]
        assert "Mindestens vier" in result["text"]
        assert ws.receive_json()["type"] == "completed"
    assert requests == 18  # Previously failed at the model-request limit of 16.


def test_evidence_notes_require_an_actual_image_and_are_reset_each_turn():
    calls = 0

    async def model(messages, info):
        nonlocal calls
        calls += 1
        if calls == 1:
            return ModelResponse(parts=[ToolCallPart("record_visual_observation", {"observation": "not yet seen"}, tool_call_id="premature")])
        if calls == 2:
            feedback = [part.content for message in messages for part in message.parts
                        if isinstance(part, ToolReturnPart) and part.outcome == "retried"]
            assert any("Capture and inspect" in str(item) for item in feedback)
            return ModelResponse(parts=[ToolCallPart("capture_screenshot", {}, tool_call_id="image")])
        if calls == 3:
            return ModelResponse(parts=[ToolCallPart("record_visual_observation", {"observation": "One visible object."}, tool_call_id="note")])
        if calls == 4:
            assert notes(messages)[-1]["observations"] == [{"view": 1, "observation": "One visible object."}]
            return ModelResponse(parts=[TextPart("One observed, not a guaranteed total.")])
        if calls == 5:
            return ModelResponse(parts=[ToolCallPart("record_visual_observation", {"observation": "previous image is stale"}, tool_call_id="stale")])
        assert any(isinstance(part, ToolReturnPart) and part.tool_call_id == "stale" and part.outcome == "retried"
                   and "Capture and inspect" in str(part.content) for message in messages for part in message.parts)
        return ModelResponse(parts=[TextPart("A new image is needed.")])

    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json(hello([SCREENSHOT]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json(), image_png_base64=png()))
        assert ws.receive_json()["final"]
        assert ws.receive_json()["type"] == "completed"
        ws.send_json(user("turn-2"))
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["text"] == "A new image is needed."
        assert ws.receive_json()["type"] == "completed"


def test_no_visual_evidence_tool_without_screenshot_capability():
    async def model(messages, info):
        assert "record_visual_observation" not in {tool.name for tool in info.function_tools}
        return ModelResponse(parts=[TextPart("No image tool is available; I cannot count visually.")])
    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        assert "cannot count" in ws.receive_json()["text"]
        assert ws.receive_json()["type"] == "completed"
import pytest



@pytest.mark.parametrize("invalid", ["", "   ", "x" * 1201])
def test_evidence_note_size_validation_does_not_accept_empty_or_unbounded_text(invalid):
    from test_agent import model_steps
    model = model_steps(("capture_screenshot", {}),
                        ("record_visual_observation", {"observation": invalid}),
                        ("record_visual_observation", {"observation": "One visible object; hidden objects unresolved."}),
                        "Observed, not an exact total.")
    with connection(model) as client, open_session(client) as ws:
        ws.send_json(hello([SCREENSHOT]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json(), image_png_base64=png()))
        assert ws.receive_json()["text"] == "Observed, not an exact total."
        assert ws.receive_json()["type"] == "completed"


def test_evidence_notes_are_bounded_and_updating_same_view_does_not_duplicate_it():
    steps = [("capture_screenshot", {}),
             ("record_visual_observation", {"observation": "Initial finding."}),
             ("record_visual_observation", {"observation": "Corrected finding, same view."})]
    for view in range(2, 10):
        steps += [("capture_screenshot", {}),
                  ("record_visual_observation", {"observation": f"Finding for view {view}."})]
    index = 0

    async def model(messages, info):
        nonlocal index
        if index < len(steps):
            name, arguments = steps[index]
            index += 1
            return ModelResponse(parts=[ToolCallPart(name, arguments, tool_call_id=str(index))])
        last = notes(messages)[-1]["observations"]
        assert len(last) == 8 and [entry["view"] for entry in last] == list(range(1, 9))
        assert last[0]["observation"] == "Corrected finding, same view."
        assert any(isinstance(part, ToolReturnPart) and part.outcome == "retried"
                   and "Evidence-note limit" in str(part.content) for message in messages for part in message.parts)
        return ModelResponse(parts=[TextPart("The note budget is bounded.")])

    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json(hello([SCREENSHOT]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        for _ in range(9):
            call = ws.receive_json()
            assert call["name"] == "capture_screenshot"
            ws.send_json(reply(call, image_png_base64=png()))
        assert ws.receive_json()["text"] == "The note budget is bounded."
        assert ws.receive_json()["type"] == "completed"
