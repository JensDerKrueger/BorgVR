import asyncio
import json
from dataclasses import replace
from types import SimpleNamespace

import httpx
import pytest
from pydantic_ai import Agent, BinaryContent
from pydantic_ai.exceptions import ModelContextWindowExceededError
from pydantic_ai.messages import (
    ModelMessagesTypeAdapter, ModelRequest, ModelResponse, SystemPromptPart,
    TextPart, ToolCallPart, ToolReturnPart, UserPromptPart,
)
from pydantic_ai.models import ModelRequestParameters
from pydantic_ai.models.function import FunctionModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.usage import RequestUsage

from borgvr_agent.context import (
    ContextBudgetExceeded, ContextMaintenance, SUMMARY_MARKER, VLLMChatModel,
    bounded_history, compact_history, keep_images,
)
from borgvr_agent.protocol import ProtocolError, json_bytes
from test_agent import EDIT, EDIT_STATUS, ROTATE, SETTINGS, STATE, connection, hello, open_session, reply, user


def history():
    return [ModelRequest(parts=[SystemPromptPart("System rules"), UserPromptPart("old user " * 500)]),
            ModelResponse(parts=[TextPart("old response " * 500)]),
            ModelRequest(parts=[UserPromptPart("Keep the head bones visible")]),
            ModelResponse(parts=[ToolCallPart("set_clipping", {"enabled": True}, tool_call_id="mutation")]),
            ModelRequest(parts=[ToolReturnPart("set_clipping", {"ok": True}, tool_call_id="mutation")])]


def parts(messages, kind):
    return [part for message in messages for part in message.parts if isinstance(part, kind)]


def test_compaction_preserves_active_prompt_system_and_tool_pairs():
    original = history()
    compact = compact_history(original)
    assert len(ModelMessagesTypeAdapter.dump_json(compact)) < len(ModelMessagesTypeAdapter.dump_json(original))
    assert parts(compact, SystemPromptPart)[0].content == "System rules"
    assert parts(compact, UserPromptPart)[0].content.startswith(SUMMARY_MARKER)
    assert parts(compact, UserPromptPart)[-1].content == "Keep the head bones visible"
    assert parts(compact, ToolCallPart) == parts(original, ToolCallPart)
    assert parts(compact, ToolReturnPart) == parts(original, ToolReturnPart)
    assert parts(original, UserPromptPart)[0].content.startswith("old user")


def test_active_result_compaction_retains_errors_and_receipts_and_tf_endpoints():
    rows = [[i, i, i, i] for i in range(256)]
    messages = [ModelRequest(parts=[UserPromptPart("current")]), ModelRequest(parts=[
        ToolReturnPart("get_application_state", {"old": "large" * 1000}, tool_call_id="old"),
        ToolReturnPart("get_application_state", {"ok": False, "error": "not committed"}, tool_call_id="failure"),
        ToolReturnPart("get_application_state", {"current": True}, tool_call_id="new"),
        ToolReturnPart("set_transfer_function", {"samples": rows}, tool_call_id="tf"),
        ToolReturnPart("set_clipping", "fix schema", tool_call_id="invalid", outcome="retried")])]
    result = parts(compact_history(messages, active_results=True), ToolReturnPart)
    assert [p.tool_call_id for p in result] == ["old", "failure", "new", "tf", "invalid"]
    assert result[0].content["result_received"] is True
    assert result[1].content == {"ok": False, "error": "not committed"}
    assert result[2].content == {"current": True}
    assert result[3].content["samplesArePreview"] is True
    assert result[3].content["originalSampleCount"] == 256
    assert len(result[3].content["samples"]) == 16
    assert result[3].content["samples"][0] == rows[0] and result[3].content["samples"][-1] == rows[-1]
    assert len(rows) == 256 and result[4].outcome == "retried"


def test_old_images_are_removed_without_touching_the_newest_or_original():
    images = [BinaryContent(bytes([i]), media_type="image/png") for i in range(4)]
    messages = [ModelRequest(parts=[UserPromptPart(images)])]
    assert [i for i in parts(keep_images(messages), UserPromptPart)[0].content if isinstance(i, BinaryContent)] == images[-2:]
    assert parts(messages, UserPromptPart)[0].content == images


def test_tokenizer_prepares_sdk_settings_deltas_before_mapping(monkeypatch):
    from openai import AsyncOpenAI
    from pydantic_ai.messages import ModelSettingsDeltaPart
    requests = []
    original = httpx.AsyncClient
    def handler(request):
        import json
        body = json.loads(request.content)
        requests.append(body)
        assert [message["role"] for message in body["messages"]] == ["system", "user"]
        return httpx.Response(200, json={"count": 32, "max_model_len": 32768})
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kwargs: original(**kwargs, transport=httpx.MockTransport(handler)))
    async def run():
        async with AsyncOpenAI(api_key="synthetic", base_url="http://model.invalid/v1") as client:
            model = VLLMChatModel("synthetic-model", provider=OpenAIProvider(openai_client=client),
                                  token_url="http://model.invalid/tokenize", token="synthetic")
            messages = [ModelRequest(parts=[SystemPromptPart("Policy"), UserPromptPart("Finish with a question."),
                                           ModelSettingsDeltaPart(settings={"max_tokens": 512})])]
            usage = await model.count_tokens(messages, {"max_tokens": 512}, ModelRequestParameters())
            assert usage.input_tokens == 32
            assert any(isinstance(part, ModelSettingsDeltaPart) for part in messages[0].parts)
    asyncio.run(run())
    assert len(requests) == 1


@pytest.mark.parametrize("passes", [1, 2, 3])
def test_merged_checkpoint_keeps_policy_first_for_tokenizer_and_generation(monkeypatch, passes):
    import httpx2
    from openai import AsyncOpenAI

    from borgvr_agent.continuation import TaskContinuation

    system, checkpoint = TaskContinuation().checkpoint(system_prompt="Trusted policy.", context_id="fixture",
                                                       renderer_ready=True, receipts=[], observations=[])
    # Reproduce the SDK grouping that hid the system prompt inside the preserved checkpoint.
    messages = [
        ModelRequest(parts=[*system.parts, *checkpoint.parts]),
        ModelRequest(parts=[UserPromptPart("Continue the synthetic task.")]),
        ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="fixture-call")]),
        ModelRequest(parts=[ToolReturnPart("get_application_state", {"ok": True}, tool_call_id="fixture-call")]),
    ]
    observed = []
    original = httpx.AsyncClient

    def handler(request):
        payload = json.loads(request.content)
        wire = payload["messages"]
        roles = [message["role"] for message in wire]
        response_type = httpx.Response if request.url.path == "/tokenize" else httpx2.Response
        if roles[:1] != ["system"] or roles.count("system") != 1:
            return response_type(400, json={"error": {"message": "System message must be at the beginning."}})
        assert wire[0]["content"] == "Trusted policy."
        assert "BorgVR task checkpoint." in json.dumps(wire)
        assert "Continue the synthetic task." in json.dumps(wire)
        assert roles[-2:] == ["assistant", "tool"]
        observed.append((request.url.path, wire))
        if request.url.path == "/tokenize":
            return httpx.Response(200, json={"count": 3500 if len(observed) <= passes else 1000,
                                             "max_model_len": 4096})
        assert request.url.path == "/v1/chat/completions"
        return httpx2.Response(200, json={"id": "fixture", "object": "chat.completion", "created": 1,
            "model": "synthetic-model", "choices": [
                {"index": 0, "message": {"role": "assistant", "content": "Verified."}, "finish_reason": "stop"}
            ]})

    class TokenClient(original):
        def __init__(self, **kwargs):
            super().__init__(**kwargs, transport=httpx.MockTransport(handler))

    monkeypatch.setattr(httpx, "AsyncClient", TokenClient)

    async def run():
        async with AsyncOpenAI(api_key="synthetic", base_url="http://model.invalid/v1",
                               http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler))) as client:
            model = VLLMChatModel("synthetic-model", provider=OpenAIProvider(openai_client=client),
                                  token_url="http://model.invalid/tokenize", token="synthetic")
            ctx = SimpleNamespace(messages=list(messages))
            request = SimpleNamespace(messages=messages, model=model, model_settings={},
                                      model_request_parameters=ModelRequestParameters())
            await ContextMaintenance(4096, 512).before_model_request(ctx, request)
            response = await model.request(model.prepare_messages(request.messages, request.model_request_parameters),
                                           request.model_settings, request.model_request_parameters)
            assert response.parts[0].content == "Verified."

    asyncio.run(run())
    assert [path for path, _ in observed] == ["/tokenize"] * (passes + 1) + ["/v1/chat/completions"]
    assert observed[-1][1] == observed[-2][1]


@pytest.mark.parametrize("status", [400, 413, 503])
def test_tokenize_failure_logs_only_status_and_structure(monkeypatch, caplog, status):
    from borgvr_agent.continuation import TaskContinuation

    original = httpx.AsyncClient
    seen = []

    def response(request):
        seen.append(request)
        return httpx.Response(status, json={"error": {"message": "private provider response"}})

    monkeypatch.setattr(httpx, "AsyncClient", lambda **kwargs: original(**kwargs, transport=httpx.MockTransport(response)))
    model = VLLMChatModel("test", provider=OpenAIProvider(api_key="private-api-key"),
                          token_url="http://vllm:8000/tokenize", token="private-token")
    checkpoint = TaskContinuation().checkpoint(system_prompt="private policy", context_id="private context",
                                                renderer_ready=False, receipts=[], observations=[])
    messages = [*checkpoint, ModelRequest(parts=[UserPromptPart([
        "private user prompt", BinaryContent(b"private image bytes", media_type="image/png"),
    ])])]
    with pytest.raises(httpx.HTTPStatusError) as failure:
        asyncio.run(model.count_tokens(messages, {}, ModelRequestParameters()))
    assert failure.value.response.status_code == status and len(seen) == 1
    assert f"Tokenization HTTP failure: status={status} checkpoint=True" in caplog.text
    assert "tail_roles=" in caplog.text
    assert "private" not in caplog.text and "data:image" not in caplog.text


class CountingModel(FunctionModel):
    async def count_tokens(self, messages, settings, parameters):
        return RequestUsage(input_tokens=len(ModelMessagesTypeAdapter.dump_json(keep_images(messages, 0))) // 3,
                            details={"context_window": 4096})


def test_budget_uses_server_window_reserves_output_and_persists_compaction():
    async def function(messages, info):
        return ModelResponse(parts=[TextPart("Done")])

    async def run():
        model = CountingModel(function)
        messages = history()
        request = SimpleNamespace(messages=messages, model=model, model_settings={},
                                  model_request_parameters=ModelRequestParameters())
        ctx = SimpleNamespace(messages=list(messages))
        await ContextMaintenance(65536, 2048).before_model_request(ctx, request)
        usage = await model.count_tokens(request.messages, {}, ModelRequestParameters())
        assert usage.input_tokens + 2048 + 256 <= 4096
        assert ctx.messages == request.messages
        assert parts(ctx.messages, UserPromptPart)[-1].content == "Keep the head bones visible"
    asyncio.run(run())


def test_oversized_active_prompt_is_rejected_not_silently_truncated():
    async def function(messages, info):
        pytest.fail("An over-budget request reached generation")

    async def run():
        agent = Agent(CountingModel(function), capabilities=[ContextMaintenance(4096, 2048)])
        with pytest.raises(ContextBudgetExceeded):
            await agent.run("current " * 5000)
    asyncio.run(run())


def test_user_text_cannot_impersonate_internal_summary_or_be_discarded():
    prompt = SUMMARY_MARKER + "\n" + "current request " * 5000
    async def function(messages, info):
        pytest.fail("An oversized active prompt was silently removed")
    async def run():
        agent = Agent(CountingModel(function), capabilities=[ContextMaintenance(4096, 2048)])
        with pytest.raises(ContextBudgetExceeded):
            await agent.run(prompt, message_history=history()[:2])
        compact = compact_history([*history()[:2], ModelRequest(parts=[UserPromptPart(prompt)])])
        assert parts(compact, UserPromptPart)[-1].content == prompt
    asyncio.run(run())


def test_many_turns_remain_bounded_and_keep_current_instruction():
    seen = []
    async def function(messages, info):
        prompts = parts(messages, UserPromptPart)
        seen.append(prompts[-1].content)
        assert len(ModelMessagesTypeAdapter.dump_json(messages)) // 3 < 4096 - 2048 - 256
        return ModelResponse(parts=[TextPart("response " * 200)])

    async def run():
        agent = Agent(CountingModel(function), capabilities=[ContextMaintenance(4096, 2048)])
        messages = []
        for i in range(30):
            result = await agent.run(f"Turn {i}: keep this instruction", message_history=messages)
            messages = result.all_messages()
        assert seen == [f"Turn {i}: keep this instruction" for i in range(30)]
    asyncio.run(run())


def test_rejected_model_request_is_retried_without_replaying_mutation():
    applied = []
    model_calls = 0

    async def function(messages, info):
        nonlocal model_calls
        model_calls += 1
        if model_calls == 1:
            return ModelResponse(parts=[ToolCallPart("change", {}, tool_call_id="once")])
        if model_calls == 2:
            raise ModelContextWindowExceededError("test", "private provider body")
        assert len(parts(messages, ToolCallPart)) == 1
        assert parts(messages, ToolReturnPart)[0].tool_call_id == "once"
        return ModelResponse(parts=[TextPart("Verified")])

    async def change():
        applied.append(True)
        return {"ok": True}

    class PressureModel(CountingModel):
        async def count_tokens(self, messages, settings, parameters):
            if any(isinstance(p, UserPromptPart) and p.content.startswith(SUMMARY_MARKER)
                   for p in parts(messages, UserPromptPart) if isinstance(p.content, str)):
                return RequestUsage(input_tokens=500)
            return RequestUsage(input_tokens=1500)

    async def run():
        agent = Agent(PressureModel(function), tools=[change], capabilities=[ContextMaintenance(4096, 1024)])
        result = await agent.run("Current request", message_history=history()[:2])
        assert result.output == "Verified"
    asyncio.run(run())
    assert applied == [True] and model_calls == 3


def test_small_context_resumes_same_request_without_reapplying_confirmed_commands(caplog):
    caplog.set_level("INFO", logger="uvicorn.error.borgvr")
    calls = 0
    large_edit = {"mode": "erase", "samples": [
        {"center_meters": [0.123456789, index / 987.0, 0.023456789], "radius_meters": 0.0123456789}
        for index in range(256)
    ]}
    rotate = {"axis": [0, 1, 0], "degrees": 20}
    replay = {"degrees": 20.0, "axis": [0.0, 1.0, 0.0]}  # Different serialization, same command.
    new_rotation = {"axis": [0, 1, 0], "degrees": 5}
    steps = [
        ("get_application_state", {}), ("rotate_view", rotate), ("get_volume_edit_state", {}),
        ("edit_volume", large_edit), ("get_application_state", {}), ("rotate_view", replay),
        ("edit_volume", large_edit),
        ("rotate_view", new_rotation), ("rotate_view", new_rotation), "Verified from fresh state.",
        ("get_application_state", {}), ("rotate_view", rotate), "New request applied.",
    ]

    async def function(messages, info):
        nonlocal calls
        prompts = [str(part.content) for part in parts(messages, UserPromptPart)]
        if calls == 4:
            assert not parts(messages, ToolCallPart), "A checkpoint retained the previous executable plan"
            assert any("BorgVR task checkpoint." in text for text in prompts)
            assert any("Turn the test volume." in text for text in prompts)
            assert "BorgVR calls remaining=20" in parts(messages, SystemPromptPart)[0].content
        if calls in (6, 7, 9):
            result = parts(messages, ToolReturnPart)[-1].content
            assert result["code"] == "already_applied_in_request"
        if calls == 7:
            assert parts(messages, ToolCallPart)[-1].args == {}
            assert any("BorgVR task checkpoint." in text for text in prompts)
        if calls == 10:
            assert not any("BorgVR task checkpoint." in text for text in prompts)
        step = steps[calls]
        calls += 1
        if isinstance(step, str):
            return ModelResponse(parts=[TextPart(step)])
        return ModelResponse(parts=[ToolCallPart(*step, tool_call_id=f"call-{calls}")])

    class SmallContextModel(FunctionModel):
        async def count_tokens(self, messages, settings, parameters):
            # Deterministic substitute for vLLM tokenization; actual argument size drives pressure.
            argument_bytes = sum(len(json_bytes(part.args)) for part in parts(messages, ToolCallPart))
            return RequestUsage(input_tokens=850 + argument_bytes // 3, details={"context_window": 4096})

    settings = replace(SETTINGS, inference=replace(SETTINGS.inference, context=4096, output_tokens=512))
    with connection(SmallContextModel(function), settings) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE, EDIT_STATUS, EDIT]))
        ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        dispatched = []
        for expected in ["get_application_state", "rotate_view", "get_volume_edit_state", "edit_volume",
                         "get_application_state", "rotate_view"]:
            call = ws.receive_json()
            assert call["type"] == "tool_call" and call["name"] == expected and call["request_id"] == "turn-1"
            dispatched.append((call["name"], call["arguments"]))
            result = ({"available": True, "shared": False} if expected == "get_volume_edit_state" else
                      {"ok": True, "private_result": "SECRET_SYNTHETIC_RESULT"})
            ws.send_json(reply(call, result=result))
        assert dispatched[-1] == ("rotate_view", new_rotation)
        assert dispatched.count(("rotate_view", rotate)) == dispatched.count(("edit_volume", large_edit)) == 1
        assert ws.receive_json()["text"] == "Verified from fresh state."
        assert ws.receive_json()["type"] == "completed"
        ws.send_json(user("turn-2"))
        assert ws.receive_json()["type"] == "started"
        ws.send_json(reply(ws.receive_json()))
        new_call = ws.receive_json()
        assert new_call["name"] == "rotate_view" and new_call["arguments"] == rotate
        ws.send_json(reply(new_call))
        assert ws.receive_json()["text"] == "New request applied."
        assert ws.receive_json()["type"] == "completed"
    assert "phase=preflight outcome=checkpoint" in caplog.text
    assert caplog.text.count("Context continuation:") == 1
    assert "'window': 4096" in caplog.text and "'input_tokens':" in caplog.text
    assert "confirmed_mutation_tools=['edit_volume', 'rotate_view']" in caplog.text
    assert ("outcome=completed checkpoints=1 confirmed={'rotate_view': 2, 'edit_volume': 1} "
            "repeated_confirmed={} blocked_replays={'rotate_view': 2, 'edit_volume': 1} uncertain=False") in caplog.text
    assert "SECRET_SYNTHETIC_RESULT" not in caplog.text and "Turn the test volume." not in caplog.text
    assert "center_meters" not in caplog.text


@pytest.mark.parametrize("mutation,error,expected_code", [
    (False, ContextBudgetExceeded("private"), "context_limit"),
    (True, ModelContextWindowExceededError("test", "private"), "context_limit"),
    (True, RuntimeError("private"), "run_failed"),
])
def test_error_receipt_distinguishes_applied_changes_and_context_limit(mutation, error, expected_code, caplog):
    count = 0
    async def function(messages, info):
        nonlocal count
        count += 1
        if count == 1:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="s")])
        if mutation and count == 2:
            return ModelResponse(parts=[ToolCallPart("rotate_view", {"axis": [0, 1, 0], "degrees": 20}, tool_call_id="m")])
        raise error

    with connection(FunctionModel(function)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE]))
        ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        ws.send_json(reply(ws.receive_json()))
        if mutation:
            ws.send_json(reply(ws.receive_json()))
        event = ws.receive_json()
        if mutation:
            assert event["type"] == "assistant_message" and event["final"]
            assert event["partial"] == {"reason": expected_code, "confirmed_volume_edits": 0}
            assert ws.receive_json()["type"] == "completed"
        else:
            assert event["type"] == "error" and event["code"] == expected_code
            assert not event["changes_applied"] and not event["requires_reconnect"]
        assert "private" not in str(event) and "private" not in caplog.text


def test_continue_after_partial_result_never_resends_confirmed_or_regrouped_edits(caplog):
    original = "Edit the two regions and verify the result."
    a, b, c = [
        {"center_meters": [x, 0.02, 0.03], "radius_meters": 0.005} for x in [0.01, 0.02, 0.03]
    ]
    def erase(*samples):
        return {"mode": "erase", "samples": list(samples)}
    steps = iter([
        ("get_application_state", {}), ("get_volume_edit_state", {}), ("edit_volume", erase(a, b)),
        ContextBudgetExceeded("provider supplied private data"),
        ("get_application_state", {}), ("get_volume_edit_state", {}),
        ("edit_volume", erase(b, a)), ("edit_volume", erase(b, c)),
        ("edit_volume", erase(c)), "Verification finished.",
    ])
    calls = 0

    async def function(messages, info):
        nonlocal calls
        calls += 1
        if calls == 5:
            prompts = [part.content for part in parts(messages, UserPromptPart)]
            assert original in prompts and "Weiter" not in prompts
            assert any("explicitly chose to continue" in str(prompt) for prompt in prompts)
            assert not parts(messages, ToolCallPart), "Old executable calls were injected into the resumed attempt"
        if calls in (8, 9):
            blocked = parts(messages, ToolReturnPart)[-1].content
            assert blocked["code"] == "already_applied_in_request"
            assert blocked["confirmed_sample_indices"] == ([0, 1] if calls == 8 else [0])
        step = next(steps)
        if isinstance(step, Exception):
            raise step
        if isinstance(step, str):
            return ModelResponse(parts=[TextPart(step)])
        return ModelResponse(parts=[ToolCallPart(*step, tool_call_id=f"c-{calls}")])

    status = {"available": True, "shared": False, "channels": [1]}
    with connection(FunctionModel(function)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, EDIT_STATUS, EDIT]))
        ws.receive_json()
        ws.send_json({**user(), "text": original})
        assert ws.receive_json()["type"] == "started"
        for name in ["get_application_state", "get_volume_edit_state", "edit_volume"]:
            call = ws.receive_json()
            assert call["name"] == name
            ws.send_json(reply(call, result=status))
        event = ws.receive_json()
        assert event["partial"] == {"reason": "context_limit", "confirmed_volume_edits": 1}
        completed = ws.receive_json()
        assert completed["type"] == "completed" and completed["outcome"] == "partial"
        ws.send_json({**user("turn-2"), "text": "Weiter."})
        assert ws.receive_json()["type"] == "started"
        for name in ["get_application_state", "get_volume_edit_state", "edit_volume"]:
            call = ws.receive_json()
            assert call["name"] == name and call["request_id"] == "turn-2"
            if name == "edit_volume":
                assert call["arguments"] == erase(c)
            ws.send_json(reply(call, result=status))
        assert ws.receive_json()["text"] == "Verification finished."
        assert ws.receive_json()["type"] == "completed"
        ws.send_json({**user("turn-3"), "text": "Weiter"})
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["resume_unavailable"] is True
        assert ws.receive_json()["type"] == "completed"
    assert "provider supplied private data" not in caplog.text


def test_continue_discards_paused_task_after_dataset_change():
    class FailedAfterEdits:
        calls = 0
        async def __call__(self, messages, info):
            self.calls += 1
            if self.calls == 1:
                return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="s")])
            if self.calls == 2:
                return ModelResponse(parts=[ToolCallPart("rotate_view", {"axis": [0, 1, 0], "degrees": 20}, tool_call_id="r")])
            raise ContextBudgetExceeded("test")
    model = FailedAfterEdits()
    with connection(FunctionModel(model), SETTINGS) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE]))
        ws.receive_json()
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        for name in ("get_application_state", "rotate_view"):
            call = ws.receive_json()
            assert call["name"] == name
            ws.send_json(reply(call))
        assert ws.receive_json()["partial"]["reason"] == "context_limit"
        assert ws.receive_json()["type"] == "completed"
        ws.send_json({"type": "context_changed", "dataset_id": "test-volume", "context_id": "new-opening"})
        assert ws.receive_json()["type"] == "context_updated"
        ws.send_json({**user("turn-2"), "text": "weiter"})
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["resume_unavailable"] is True
        assert ws.receive_json()["type"] == "completed"
    assert model.calls == 3


@pytest.mark.parametrize("body", [{"count": True, "max_model_len": 4096},
    {"count": -1, "max_model_len": 4096}, {"count": 1, "max_model_len": 0},
    {"count": 1.2, "max_model_len": 4096}, {"count": 1},
    {"count": 1, "max_model_len": 4096, "oversized": "x" * (4 * 1024 * 1024)}])
def test_invalid_or_oversized_token_response_fails_closed(monkeypatch, body):
    original = httpx.AsyncClient
    class TokenClient(original):
        def __init__(self, **kwargs):
            assert kwargs == {"timeout": 15, "follow_redirects": False, "trust_env": False}
            super().__init__(**kwargs, transport=httpx.MockTransport(lambda _: httpx.Response(200, json=body)))
    monkeypatch.setattr(httpx, "AsyncClient", TokenClient)
    model = VLLMChatModel("test", provider=OpenAIProvider(api_key="internal"),
                          token_url="http://vllm:8000/tokenize", token="internal")
    with pytest.raises(ProtocolError):
        asyncio.run(model.count_tokens([ModelRequest(parts=[UserPromptPart("test")])], {}, ModelRequestParameters()))


def test_history_storage_limit():
    with pytest.raises(ContextBudgetExceeded):
        asyncio.run(bounded_history([ModelRequest(parts=[UserPromptPart("x" * (9 * 1024 * 1024))])]))


@pytest.mark.parametrize("failure", ["redirect", "timeout", "unavailable"])
def test_token_count_network_failure_does_not_bypass_budget_or_leak_credentials(monkeypatch, failure):
    requests = []
    def handler(request):
        requests.append(request)
        if failure == "timeout":
            raise httpx.ReadTimeout("test timeout", request=request)
        if failure == "redirect":
            return httpx.Response(302, headers={"Location": "https://other.example/steal"})
        return httpx.Response(503)

    original = httpx.AsyncClient
    class TokenClient(original):
        def __init__(self, **kwargs):
            super().__init__(**kwargs, transport=httpx.MockTransport(handler))
    monkeypatch.setattr(httpx, "AsyncClient", TokenClient)
    model = VLLMChatModel("test", provider=OpenAIProvider(api_key="internal"),
                          token_url="http://vllm:8000/tokenize", token="internal")
    with pytest.raises(httpx.HTTPError):
        asyncio.run(model.count_tokens([ModelRequest(parts=[UserPromptPart("test")])], {}, ModelRequestParameters()))
    assert len(requests) == 1 and requests[0].url.host == "vllm"


def test_uncommitted_tool_error_does_not_claim_changes_applied():
    count = 0
    async def function(messages, info):
        nonlocal count
        count += 1
        if count == 1:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="s")])
        if count == 2:
            return ModelResponse(parts=[ToolCallPart("rotate_view", {"axis": [0, 1, 0], "degrees": 20}, tool_call_id="r")])
        raise ContextBudgetExceeded("test")
    with connection(FunctionModel(function)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json()))
        ws.send_json(reply(ws.receive_json(), error="Rejected without committing"))
        event = ws.receive_json()
        assert event["code"] == "context_limit" and event["changes_applied"] is False
