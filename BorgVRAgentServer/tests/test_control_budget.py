import asyncio
from dataclasses import replace
import time
from types import SimpleNamespace

import pytest
from pydantic_ai import ModelRetry
from pydantic_ai.messages import ModelRequest, ModelResponse, SystemPromptPart, TextPart, ToolCallPart
from pydantic_ai.models.function import FunctionModel

from borgvr_agent.app import Session
from borgvr_agent.budget import BUDGET_MARKER, ControlBudget, MAX_NATIVE_CALLS
from borgvr_agent.protocol import ToolDefinition
from test_agent import STATE, ROTATE, SCREENSHOT, SETTINGS, connection, hello, open_session, png, reply, user


@pytest.mark.parametrize("native,tools,requests,elapsed,phase", [
    (0, 0, 0, 0, "investigate"), (18, 18, 18, 0, "wrap_up"),
    (1, 24, 24, 0, "wrap_up"), (1, 1, 1, 110, "wrap_up"),
    (24, 24, 24, 0, "answer"), (1, 40, 40, 0, "answer"),
    (1, 1, 44, 0, "answer"), (1, 1, 1, 150, "answer"),
])
def test_budget_reserves_calls_and_time_for_a_final_answer(native, tools, requests, elapsed, phase):
    session = SimpleNamespace(native_calls=native, settings=SETTINGS, run_started=time.monotonic() - elapsed)
    ctx = SimpleNamespace(usage=SimpleNamespace(tool_calls=tools, requests=requests))
    budget = ControlBudget(session)
    assert budget.phase(ctx) == phase
    assert f"phase={phase}" in budget.instructions(ctx)
    assert len(budget.instructions(ctx)) < 180


def test_budget_stops_advertising_tools_and_restricts_final_output_tokens():
    session = SimpleNamespace(native_calls=18, settings=SETTINGS, run_started=None)
    budget = ControlBudget(session)
    ctx = SimpleNamespace(usage=SimpleNamespace(tool_calls=18, requests=18))
    tools = [SimpleNamespace(name=name) for name in ("rotate_view", "set_transform", "set_clipping",
                                                    "wait_until_rendered", "capture_screenshot", "report_progress")]

    async def check():
        allowed = await budget.prepare_tools(ctx, tools)
        assert {tool.name for tool in allowed} == {"set_transform", "set_clipping", "wait_until_rendered", "capture_screenshot"}
        session.native_calls = MAX_NATIVE_CALLS
        assert await budget.prepare_tools(ctx, tools) == []
        request = SimpleNamespace(model_settings={"max_tokens": 2048, "temperature": 0.2},
                                  messages=[ModelRequest(parts=[SystemPromptPart("Trusted policy")])])
        ctx.messages = list(request.messages)
        await budget.before_model_request(ctx, request)
        assert request.model_settings == {"max_tokens": 512, "temperature": 0.2}
        assert request.messages == ctx.messages
    asyncio.run(check())


def test_budget_updates_one_system_message_without_accumulating_instructions():
    session = SimpleNamespace(native_calls=0, settings=SETTINGS, run_started=None)
    ctx = SimpleNamespace(usage=SimpleNamespace(tool_calls=0, requests=0), messages=[])
    budget = ControlBudget(session)
    request = SimpleNamespace(messages=[ModelRequest(parts=[SystemPromptPart("Trusted static rules")])], model_settings={})

    async def check():
        for count in range(25):
            session.native_calls = count
            await budget.before_model_request(ctx, request)
            parts = [part for message in request.messages for part in message.parts if isinstance(part, SystemPromptPart)]
            assert len(parts) == 1 and parts[0].content.count(BUDGET_MARKER) == 1
            assert parts[0].content.startswith("Trusted static rules" + BUDGET_MARKER)
            assert f"BorgVR calls remaining={24-count}" in parts[0].content
            assert len(parts[0].content) < 250
    asyncio.run(check())


def test_actual_loop_finishes_before_exceeding_the_native_client_limit():
    requests = 0

    async def model(messages, info):
        nonlocal requests
        requests += 1
        if not info.function_tools:
            assert requests == 25
            return ModelResponse(parts=[TextPart("Investigation complete within the call budget; the total remains uncertain.")])
        if requests >= 19:
            assert "rotate_view" not in {tool.name for tool in info.function_tools}
        return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id=str(requests))])

    # Isolate the call limit from FunctionModel's conservative JSON-based token estimate.
    settings = replace(SETTINGS, inference=replace(SETTINGS.inference, context=32768))
    with connection(FunctionModel(model), settings) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        for _ in range(MAX_NATIVE_CALLS):
            call = ws.receive_json()
            assert call["type"] == "tool_call" and call["name"] == "get_application_state"
            ws.send_json(reply(call))
        result = ws.receive_json()
        assert result["type"] == "assistant_message" and result["final"]
        assert ws.receive_json()["type"] == "completed"


def test_internal_evidence_notes_do_not_consume_native_call_budget():
    requests = 0

    async def model(messages, info):
        nonlocal requests
        requests += 1
        if requests == 1:
            return ModelResponse(parts=[ToolCallPart("capture_screenshot", {}, tool_call_id="image")])
        if not info.function_tools:
            assert requests == 41
            return ModelResponse(parts=[TextPart("The evidence is limited; no exact count established.")])
        return ModelResponse(parts=[ToolCallPart("record_visual_observation", {"observation": "One object visible; others may be hidden."},
                                                tool_call_id=str(requests))])

    settings = replace(SETTINGS, inference=replace(SETTINGS.inference, context=32768))
    with connection(FunctionModel(model), settings) as client, open_session(client) as ws:
        ws.send_json(hello([SCREENSHOT]))
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        ws.send_json(reply(ws.receive_json(), image_png_base64=png()))
        result = ws.receive_json()
        assert result["type"] == "assistant_message" and result["final"]
        assert ws.receive_json()["type"] == "completed"


def test_native_call_guard_never_sends_an_excess_call_even_if_model_bypasses_filter():
    async def check():
        session = Session(None, SETTINGS, None, asyncio.Semaphore(1))
        session.native_calls = MAX_NATIVE_CALLS
        with pytest.raises(ModelRetry, match="budget exhausted"):
            await session.call_tool(ToolDefinition.model_validate(STATE), {})
        assert session.native_calls == MAX_NATIVE_CALLS and session.pending is None
    asyncio.run(check())
