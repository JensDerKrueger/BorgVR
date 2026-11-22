from copy import deepcopy

import pytest
from pydantic_ai.exceptions import OutputTokenLimitExceeded, UnexpectedModelBehavior
from pydantic_ai.messages import ModelResponse, ToolCallPart
from pydantic_ai.models.function import FunctionModel

from test_agent import EDIT, ROTATE, STATE, connection, hello, open_session, user

PRIVATE = "private_diagnostic_sentinel"


@pytest.mark.parametrize("tool,arguments,category,logged_tool", [
    ("get_application_state", {"extra": PRIVATE}, "tool_arguments_rejected", "get_application_state"),
    ("get_application_state", "{ " + PRIVATE, "tool_json_invalid", "get_application_state"),
    ("report_progress", {"activity": {"private": PRIVATE}, "language": "en"}, "tool_arguments_invalid", "report_progress"),
    ("rotate_view", {"axis": [0, 1, 0], "degrees": 12}, "tool_application_state_required", "rotate_view"),
    (PRIVATE, {}, "tool_unknown", "-"),
])
def test_terminal_tool_failure_logs_only_category_and_known_name(caplog, tool, arguments, category, logged_tool):
    attempts = 0

    async def bad_tool(messages, info):
        nonlocal attempts
        attempts += 1
        return ModelResponse(parts=[ToolCallPart(tool, arguments, tool_call_id=f"fixture-{attempts}")])

    with connection(FunctionModel(bad_tool)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, ROTATE, EDIT]))
        ws.receive_json()
        ws.send_json({**user(), "text": PRIVATE})
        assert ws.receive_json()["type"] == "started"
        result = ws.receive_json()
        assert result["type"] == "error" and result["code"] == "run_failed"
        assert result["changes_applied"] is False
    assert attempts == 2
    assert f"category={category} tool={logged_tool}" in caplog.text
    assert PRIVATE not in caplog.text


@pytest.mark.parametrize("schema_has_sample_limit", [False, True])
def test_edit_validation_logs_both_rejection_reasons_without_values(caplog, schema_has_sample_limit):
    definition = deepcopy(EDIT)
    if schema_has_sample_limit:
        definition["inputSchema"]["properties"]["samples"]["maxItems"] = 256
    sample = {"center_meters": [0.123456789, 0.3, 0.2], "radius_meters": 0.005}
    attempts = [
        {"mode": "erase", "samples": [sample] * 257},
        {"mode": "erase", "samples": [{**sample, "radius_meters": PRIVATE}]},
    ]
    calls = 0

    async def bad_edit(messages, info):
        nonlocal calls
        arguments = attempts[calls]
        calls += 1
        return ModelResponse(parts=[ToolCallPart("edit_volume", arguments, tool_call_id=f"fixture-{calls}")])

    with connection(FunctionModel(bad_edit)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE, definition]))
        ws.receive_json()
        ws.send_json({**user(), "text": PRIVATE})
        assert ws.receive_json()["type"] == "started"
        result = ws.receive_json()
        assert result["type"] == "error" and result["changes_applied"] is False

    assert calls == 2
    assert "tool=edit_volume reason=too_many_items field=samples" in caplog.text
    assert "tool=edit_volume reason=wrong_type field=samples.item.radius_meters" in caplog.text
    assert "category=tool_arguments_rejected tool=edit_volume" in caplog.text
    assert PRIVATE not in caplog.text and "0.123456789" not in caplog.text


@pytest.mark.parametrize("category", [
    "model_output_empty", "model_output_token_limit", "provider_response_invalid", "duplicate_tool_call_id",
])
def test_terminal_model_failure_keeps_provider_details_private(caplog, category):
    async def bad_output(messages, info):
        if category == "model_output_token_limit":
            raise OutputTokenLimitExceeded(PRIVATE)
        if category == "provider_response_invalid":
            raise UnexpectedModelBehavior(
                "Invalid response from synthetic chat completions endpoint: " + PRIVATE,
                body="data:image/png;base64," + PRIVATE,
            )
        if category == "duplicate_tool_call_id":
            return ModelResponse(parts=[
                ToolCallPart("get_application_state", {}, tool_call_id=PRIVATE),
                ToolCallPart("get_application_state", {}, tool_call_id=PRIVATE),
            ])
        return ModelResponse(parts=[])

    with connection(FunctionModel(bad_output)) as client, open_session(client) as ws:
        ws.send_json(hello([STATE]))
        ws.receive_json()
        ws.send_json({**user(), "text": PRIVATE})
        assert ws.receive_json()["type"] == "started"
        assert ws.receive_json()["type"] == "error"
    assert f"category={category} tool=-" in caplog.text
    assert PRIVATE not in caplog.text and "data:image" not in caplog.text
