import asyncio
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
from borgvr_agent.protocol import ProtocolError
from test_agent import ROTATE, STATE, connection, hello, open_session, reply, user


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
        assert event["type"] == "error" and event["code"] == expected_code
        assert event["changes_applied"] is mutation
        assert not event["requires_reconnect"]
        assert "private" not in str(event) and "private" not in caplog.text


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
