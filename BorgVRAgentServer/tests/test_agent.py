import asyncio
import base64
import io
import json
from pathlib import Path
from dataclasses import replace

import httpx
from fastapi.testclient import TestClient
from PIL import Image
from pydantic_ai import BinaryContent
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel
import pytest
from starlette.websockets import WebSocketDisconnect
from model_config import ModelConfig, profile_values

from borgvr_agent.app import Settings, bounded_history, create_app
from borgvr_agent.protocol import (
    Hello, MAX_MESSAGE_BYTES, ProtocolError, ToolDefinition,
    decode_image, decode_message, select_tools, validate_arguments,
)

SETTINGS = Settings(token="a" * 64, vllm_token="b" * 64)
AUTH = {"Authorization": f"Bearer {SETTINGS.token}"}


def definition(name, properties=None, required=None):
    return {"name": name, "description": "Test fixture: " + name,
            "inputSchema": {"type": "object", "properties": properties or {},
                            "required": required or [], "additionalProperties": False}}


STATE = definition("get_application_state")
ROTATE = definition("rotate_view", {"axis": {"type": "array", "minItems": 3, "maxItems": 3,
                                            "items": {"type": "number"}},
                                    "degrees": {"type": "number"}}, ["axis", "degrees"])
SCREENSHOT = definition("capture_screenshot", {"output_path": {"type": "string"},
                                               "include_alpha": {"type": "boolean"}})
TF = next(entry for entry in json.loads((Path(__file__).resolve().parents[1] /
                                        "diagnostic_catalog.json").read_text())
          if entry["name"] == "set_transfer_function")


def hello(tools=None):
    return {"type": "hello", "protocol": 1, "dataset_id": "test-volume",
            "context_id": "opening-1", "tools": tools or []}


def user(request_id="turn-1"):
    return {"type": "user_message", "request_id": request_id, "text": "Turn the test volume."}


def reply(call, **kwargs):
    return {"type": "tool_result", "request_id": call["request_id"], "call_id": call["call_id"],
            "dataset_id": call["dataset_id"], "context_id": call["context_id"],
            "result": {"test": True}, **kwargs}


def model_steps(*steps):
    count = 0

    async def function(messages, info):
        nonlocal count
        step = steps[min(count, len(steps) - 1)]
        count += 1
        if isinstance(step, str):
            return ModelResponse(parts=[TextPart(step)])
        name, arguments = step
        return ModelResponse(parts=[ToolCallPart(name, arguments, tool_call_id=f"model-call-{count}")])

    return FunctionModel(function)


def connection(model=None, settings=SETTINGS):
    return TestClient(create_app(settings, model or model_steps("Ready")))


def open_session(client, tools=None):
    return client.websocket_connect("/v1/session", headers=AUTH)


def test_real_agent_loop_with_external_tools_and_image():
    calls = []

    async def function(messages, info):
        calls.append(messages)
        if len(calls) == 1:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="s")])
        if len(calls) == 2:
            return ModelResponse(parts=[ToolCallPart("rotate_view", {"axis": [0, 1, 0], "degrees": 30}, tool_call_id="r")])
        if len(calls) == 3:
            return ModelResponse(parts=[ToolCallPart("capture_screenshot", {}, tool_call_id="i")])
        assert any(isinstance(item, BinaryContent)
                   for message in messages for part in message.parts if isinstance(part, UserPromptPart)
                   and not isinstance(part.content, str) for item in part.content)
        return ModelResponse(parts=[TextPart("The test view is ready.")])

    with connection(FunctionModel(function)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE, SCREENSHOT, definition("delete_edit_state")]))
        ready = ws.receive_json()
        assert ready["tools"] == ["get_application_state", "rotate_view", "capture_screenshot"]
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        for name in ("get_application_state", "rotate_view", "capture_screenshot"):
            call = ws.receive_json()
            assert call["name"] == name
            extra = {"image_png_base64": png()} if name == "capture_screenshot" else {}
            ws.send_json(reply(call, **extra))
        assert ws.receive_json()["text"] == "The test view is ready."
        assert ws.receive_json()["type"] == "completed"
    assert len(calls) == 4


@pytest.mark.parametrize("headers,path", [({}, "/v1/session"),
    ({"Authorization": "Bearer wrong"}, "/v1/session"),
    ({**AUTH, "Origin": "https://other.example"}, "/v1/session"),
    (AUTH, "/v1/session?token=not-allowed")])
def test_rejects_auth_origin_and_query_before_accept(headers, path):
    with connection() as client:
        with pytest.raises(WebSocketDisconnect), client.websocket_connect(path, headers=headers):
            pytest.fail("Unauthorized connection accepted")


def test_readiness_requires_auth_without_contacting_model():
    with connection() as client:
        assert client.get("/healthz").json() == {"status": "alive"}
        assert client.get("/readyz").status_code == 401


@pytest.mark.parametrize("response,expected", [
    ({"data": [{"id": SETTINGS.model}]}, 200), ({"data": [{"id": "wrong-model"}]}, 503),
    ({"data": [], "large": "a" * 65536}, 503), ({"data": None}, 503),
])
def test_model_readiness_is_bounded_and_checks_model(monkeypatch, response, expected):
    import borgvr_agent.app as module
    original_client = httpx.AsyncClient

    def handler(request):
        assert request.headers["Authorization"] == f"Bearer {SETTINGS.vllm_token}"
        return httpx.Response(200, json=response)

    monkeypatch.setattr(module.httpx, "AsyncClient", lambda **kwargs: original_client(
        **kwargs, transport=httpx.MockTransport(handler)))
    with connection() as client:
        assert client.get("/readyz", headers=AUTH).status_code == expected


@pytest.mark.parametrize("custom", [False, True])
def test_openai_compatible_http_adapter_and_png_payload(monkeypatch, custom):
    import borgvr_agent.app as module
    import httpx2

    requests = []
    inference = SETTINGS.inference
    if custom:
        inference = ModelConfig.from_env({**profile_values("custom"), "BORGVR_MODEL": "Other/Vision-Instruct",
                                          "BORGVR_MODEL_REVISION": "main", "BORGVR_TOOL_PARSER": "hermes"})
    settings = replace(SETTINGS, model=inference.model, inference=inference)
    token_requests = []
    original_client = httpx.AsyncClient

    def tokenize(request):
        assert request.url.path == "/tokenize"
        assert request.headers["Authorization"] == f"Bearer {SETTINGS.vllm_token}"
        body = json.loads(request.content)
        assert body["add_generation_prompt"] is True
        token_requests.append(body)
        return httpx.Response(200, json={"count": 1024, "max_model_len": inference.context})

    class TokenClient(original_client):
        def __init__(self, **kwargs):
            super().__init__(**kwargs, transport=httpx.MockTransport(tokenize))

    monkeypatch.setattr(module.httpx, "AsyncClient", TokenClient)

    def handler(request):
        assert request.url.path == "/v1/chat/completions"
        assert request.headers["Authorization"] == f"Bearer {SETTINGS.vllm_token}"
        body = json.loads(request.content)
        if custom:
            assert "chat_template_kwargs" not in body
        else:
            assert body["chat_template_kwargs"] == {"enable_thinking": False}
        assert body["parallel_tool_calls"] is False
        assert body["model"] == settings.model
        state_tool = next(tool["function"] for tool in body["tools"] if tool["function"]["name"] == "get_application_state")
        assert state_tool["strict"] is True
        assert state_tool["parameters"]["properties"] == {}
        assert state_tool["parameters"]["additionalProperties"] is False
        assert "exactly {}" in state_tool["description"]
        screenshot_tool = next(tool["function"] for tool in body["tools"] if tool["function"]["name"] == "capture_screenshot")
        assert screenshot_tool.get("strict") is not True
        tf_tool = next(tool["function"] for tool in body["tools"] if tool["function"]["name"] == "set_transfer_function")
        assert tf_tool["strict"] is True
        assert set(tf_tool["parameters"]["required"]) == {"channel", "samples"}
        row_schema = tf_tool["parameters"]["properties"]["samples"]["items"]
        assert row_schema["minItems"] == row_schema["maxItems"] == 4
        assert row_schema["items"]["type"] == "integer"
        assert "NOT [position,R,G,B,A]" in tf_tool["description"]
        requests.append(body)
        assert body["messages"] == token_requests[-1]["messages"]
        assert body["tools"] == token_requests[-1]["tools"]
        name = ("get_application_state", "capture_screenshot", None)[len(requests) - 1]
        message = {"role": "assistant", "content": None}
        if name:
            message["tool_calls"] = [{"id": f"api-call-{len(requests)}", "type": "function",
                                      "function": {"name": name, "arguments": "{}"}}]
        else:
            assert any(item.get("type") == "image_url" and item["image_url"]["url"].startswith("data:image/png;base64,")
                       for msg in body["messages"] if isinstance(msg.get("content"), list)
                       for item in msg["content"])
            message["content"] = "HTTP adapter ready"
        return httpx2.Response(200, json={"id": "test", "object": "chat.completion", "created": 1,
            "model": settings.model, "choices": [{"index": 0, "message": message,
                                                  "finish_reason": "tool_calls" if name else "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})

    monkeypatch.setattr(module, "DefaultAsyncHttpxClient", lambda **kwargs: httpx2.AsyncClient(
        **kwargs, transport=httpx2.MockTransport(handler)))
    with TestClient(create_app(settings)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, SCREENSHOT, TF]))
        ready = ws.receive_json()
        assert ready["capabilities"] == {"vision": True, "tool_calling": True}
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json()))
        ws.send_json(reply(ws.receive_json(), image_png_base64=png()))
        assert ws.receive_json()["text"] == "HTTP adapter ready"
        assert ws.receive_json()["type"] == "completed"
    assert len(requests) == 3
    assert len(token_requests) == 3
    assert TF["inputSchema"]["required"] == ["samples"]  # Model strictness must not rewrite the native catalog.


def test_tool_arguments_are_actually_validated_not_just_advertised():
    # Tool.from_schema itself intentionally does not validate JSON Schema arguments.
    model = model_steps(("get_application_state", {}),
                        ("rotate_view", {"axis": [0, 1, 0], "degrees": "BAD"}),
                        ("rotate_view", {"axis": [0, 1, 0], "degrees": 10}), "Done")
    with connection(model) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json()))
        call = ws.receive_json()
        assert call["arguments"]["degrees"] == 10
        ws.send_json(reply(call))
        assert ws.receive_json()["type"] == "assistant_message"
        assert ws.receive_json()["type"] == "completed"


@pytest.mark.parametrize("bad_arguments", [{"reason": "Read the active dataset"}, {"action": "get_application_state"}])
def test_no_argument_tools_reject_invented_fields_and_retry_with_empty_object(bad_arguments):
    requests, feedback = [], []
    async def function(messages, info):
        requests.append(messages)
        if len(requests) == 1:
            return ModelResponse(parts=[ToolCallPart("get_application_state", bad_arguments, tool_call_id="invalid")])
        if len(requests) == 2:
            feedback.extend(part.content for message in messages for part in message.parts
                            if isinstance(part, ToolReturnPart) and part.outcome == "retried")
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="corrected")])
        return ModelResponse(parts=[TextPart("State read")])
    with connection(FunctionModel(function)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE]))
        ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        call = ws.receive_json()
        assert call["type"] == "tool_call" and call["arguments"] == {}
        ws.send_json(reply(call))
        assert ws.receive_json()["text"] == "State read"
        assert ws.receive_json()["type"] == "completed"
    assert len(requests) == 3
    assert any(isinstance(text, str) and "exactly {}" in text and "reason, action" in text for text in feedback), feedback


def test_no_argument_feedback_does_not_disclose_argument_values():
    for arguments in ({"reason": "private text"}, {"action": "close_dataset"}):
        with pytest.raises(ProtocolError, match=r"exactly \{\}") as error:
            validate_arguments(ToolDefinition.model_validate(STATE), arguments)
        assert "private text" not in str(error.value) and "close_dataset" not in str(error.value)


@pytest.mark.parametrize("invalid", [
    [[0, 0, 0, 0], [0.7, 0, 0, 0, 0], [0.75, 255, 255, 255, 255]],
    [[0, 0, 0, 0], [179, 0, 0, 0, 0], [191, 255, 255, 255, 255]],
    [[0.5, 0.5, 0.5, 1.0]],
])
def test_tf_rejects_position_prefixed_or_float_rows_and_only_forwards_corrected_ramp(invalid):
    step, feedback = 0, []
    valid = [[0, 0, 0, 0], [255, 255, 255, 255]]

    async def model(messages, info):
        nonlocal step
        step += 1
        if step == 1:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="state")])
        if step == 2:
            return ModelResponse(parts=[ToolCallPart("set_transfer_function", {"channel": 0, "samples": invalid},
                                                    tool_call_id="bad-tf")])
        if step == 3:
            feedback.extend(part.content for message in messages for part in message.parts
                            if isinstance(part, ToolReturnPart) and part.outcome == "retried")
            return ModelResponse(parts=[ToolCallPart("set_transfer_function", {"channel": 0, "samples": valid},
                                                    tool_call_id="corrected-tf")])
        return ModelResponse(parts=[TextPart("TF applied")])

    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, TF]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json()))
        call = ws.receive_json()
        assert call["name"] == "set_transfer_function" and call["arguments"]["samples"] == valid
        ws.send_json(reply(call))
        assert ws.receive_json()["text"] == "TF applied"
        assert ws.receive_json()["type"] == "completed"
    assert step == 4
    assert any("EXACTLY four integer bytes" in item and "NOT [position,R,G,B,A]" in item for item in feedback)


def test_tf_feedback_never_echoes_invalid_values_or_drops_position_fields():
    with pytest.raises(ProtocolError, match="EXACTLY four") as error:
        validate_arguments(ToolDefinition.model_validate(TF), {"samples": [["private-value", 1, 2, 3, 4]]})
    assert "private-value" not in str(error.value)


def test_mutation_requires_current_state_read():
    model = model_steps(("rotate_view", {"axis": [0, 1, 0], "degrees": 10}),
                        ("get_application_state", {}), "Read state")
    with connection(model) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        assert call["name"] == "get_application_state"
        ws.send_json(reply(call))
        ws.receive_json()
        assert ws.receive_json()["type"] == "completed"


def test_cancel_propagates_and_blocks_unsafe_followup():
    with connection(model_steps(("get_application_state", {}))) as client, open_session(client) as ws:
        ws.send_json(hello([STATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        ws.send_json({"type": "cancel", "request_id": "turn-1"})
        assert ws.receive_json()["call_id"] == call["call_id"]
        cancelled = ws.receive_json()
        assert cancelled["type"] == "cancelled" and cancelled["requires_reconnect"]
        ws.send_json(user("turn-2"))
        assert ws.receive_json()["code"] == "invalid_message"


def test_tool_deadline_and_cancel_event():
    with connection(model_steps(("get_application_state", {})), replace(SETTINGS, tool_timeout=0.05)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        assert ws.receive_json()["call_id"] == call["call_id"]
        error = ws.receive_json()
        assert error["type"] == "error" and error["requires_reconnect"]


def test_absolute_run_deadline_without_a_tool():
    async def slow_model(messages, info):
        await asyncio.sleep(10)
        return ModelResponse(parts=[TextPart("too late")])

    with connection(FunctionModel(slow_model), replace(SETTINGS, run_timeout=0.05)) as client, open_session(client) as ws:
        ws.send_json(hello())
        ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        error = ws.receive_json()
        assert error["code"] == "run_failed" and not error["requires_reconnect"]


def test_hello_deadline():
    with connection(settings=replace(SETTINGS, hello_timeout=0.02)) as client, open_session(client) as ws:
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()


def test_send_deadline_includes_write():
    from borgvr_agent.app import Session

    class SlowSocket:
        async def send_text(self, text):
            await asyncio.sleep(10)

    async def check():
        session = Session(SlowSocket(), replace(SETTINGS, send_timeout=0.02), None, asyncio.Semaphore(1))
        with pytest.raises(TimeoutError):
            await session.send({"type": "test"})

    asyncio.run(check())


def test_stale_context_result_never_reaches_model():
    with connection(model_steps(("get_application_state", {}))) as client, open_session(client) as ws:
        ws.send_json(hello([STATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        call = ws.receive_json()
        ws.send_json(reply(call, context_id="previous-opening"))
        assert ws.receive_json()["code"] == "invalid_message"


def test_request_ids_not_replayed():
    with connection() as client, open_session(client) as ws:
        ws.send_json(hello())
        ws.receive_json()
        ws.send_json(user())
        for _ in range(3):
            ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["code"] == "invalid_message"


def test_context_change_clears_conversation():
    with connection() as client, open_session(client) as ws:
        ws.send_json(hello())
        ws.receive_json()
        ws.send_json(user())
        for _ in range(3):
            ws.receive_json()
        ws.send_json({"type": "context_changed", "dataset_id": "test-volume", "context_id": "opening-2"})
        assert ws.receive_json()["type"] == "context_updated"
        ws.send_json(user("turn-2"))
        for expected in ("started", "assistant_message", "completed"):
            assert ws.receive_json()["type"] == expected


def test_session_limit_and_release():
    with connection(settings=replace(SETTINGS, max_sessions=1)) as client:
        with open_session(client) as first:
            first.send_json(hello())
            first.receive_json()
            with pytest.raises(WebSocketDisconnect), open_session(client):
                pytest.fail("Session limit not enforced")
        with open_session(client) as second:
            second.send_json(hello())
            assert second.receive_json()["type"] == "ready"


def png(size=(2, 2)):
    output = io.BytesIO()
    Image.new("RGBA", size, (255, 0, 0, 255)).save(output, format="PNG")
    return base64.b64encode(output.getvalue()).decode()


def test_png_checks():
    assert decode_image(png()).startswith(b"\x89PNG")
    for value in ("http://127.0.0.1/private", "BAD", base64.b64encode(b"not png").decode(), png((2049, 1))):
        with pytest.raises(ProtocolError):
            decode_image(value)


@pytest.mark.parametrize("value", ['{"type":"hello","type":"cancel"}', '{"x":NaN}',
                                  '{"x":Infinity}', '{"x":1e999}', '[]', '{',
                                  '{"x":"' + 'a' * MAX_MESSAGE_BYTES + '"}'])
def test_strict_json(value):
    with pytest.raises(ProtocolError):
        decode_message(value)


def test_schema_limits_and_screenshot_no_files():
    selected = select_tools([ToolDefinition.model_validate(SCREENSHOT)])[0]
    validate_arguments(selected, {"include_alpha": False})
    with pytest.raises(ProtocolError):
        validate_arguments(selected, {"output_path": "/tmp/private.png"})
    for schema in ({"type": "object"},
                   {"type": "object", "additionalProperties": False, "$ref": "http://localhost/private"},
                   {"type": "object", "additionalProperties": False, "properties": {"x": {"pattern": ".*"}}},
                   {"type": "object", "additionalProperties": False, "required": "bad"}):
        with pytest.raises(ProtocolError):
            select_tools([ToolDefinition(name="rotate_view", description="test", inputSchema=schema)])
    with pytest.raises(ProtocolError):
        select_tools([ToolDefinition.model_validate(STATE)] * 2)


def test_history_keeps_only_two_images():
    from pydantic_ai.messages import ModelRequest
    message = ModelRequest(parts=[UserPromptPart([BinaryContent(b"image", media_type="image/png") for _ in range(4)])])
    result = asyncio.run(bounded_history([message]))
    assert sum(isinstance(value, BinaryContent) for value in result[0].parts[0].content) == 2


def test_progress_is_separate_from_final_answer():
    with connection(model_steps(("report_progress", {"text": "Checking the view."}), "Ready")) as client, open_session(client) as ws:
        ws.send_json(hello())
        ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["final"] is False
        assert ws.receive_json()["final"] is True
        assert ws.receive_json()["type"] == "completed"
