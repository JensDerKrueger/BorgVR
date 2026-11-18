import asyncio
import json
from pathlib import Path

from pydantic_ai.exceptions import UnexpectedModelBehavior
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.models.function import FunctionModel

from borgvr_agent.app import Settings
from borgvr_agent.protocol import ALLOWED_TOOLS
from diagnose_tools import diagnose, error_details


CATALOG = json.loads((Path(__file__).resolve().parents[1] / "diagnostic_catalog.json").read_text())
SETTINGS = Settings(token="a" * 64, vllm_token="b" * 64)


def test_diagnostic_catalog_matches_native_allowlist():
    assert {entry["name"] for entry in CATALOG} == ALLOWED_TOOLS


def test_synthetic_diagnostic_tests_both_catalogs_without_a_native_client(capsys):
    async def model(messages, info):
        if any(isinstance(part, ToolReturnPart) for message in messages for part in message.parts):
            return ModelResponse(parts=[TextPart("Synthetic tool diagnostic")])
        return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="state")])
    assert asyncio.run(diagnose(SETTINGS, FunctionModel(model), CATALOG))
    results = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [entry["test"] for entry in results if entry.get("passed")] == ["minimal_catalog", "native_catalog"]


def test_diagnostic_reports_real_tool_retry_failure_without_response_body(capsys):
    async def model(messages, info):
        return ModelResponse(parts=[ToolCallPart("get_application_state", {"unexpected": "synthetic"}, tool_call_id="bad")])
    assert not asyncio.run(diagnose(SETTINGS, FunctionModel(model), CATALOG))
    output = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    arguments = [entry for entry in output if entry.get("phase") == "tool_arguments"]
    assert arguments and all(json.loads(entry["arguments_json"]) == {"unexpected": "synthetic"} for entry in arguments)
    results = [entry for entry in output if "passed" in entry]
    assert len(results) == 2 and all(not entry["passed"] for entry in results)
    assert all(entry["errors"][0]["type"] == "UnexpectedModelBehavior" for entry in results)
    assert all(entry["successful_state_reads"] == 0 for entry in results)


def test_diagnostic_rejects_text_only_success(capsys):
    async def model(messages, info):
        return ModelResponse(parts=[TextPart("I did it")])
    assert not asyncio.run(diagnose(SETTINGS, FunctionModel(model), CATALOG))
    assert '"passed": true' not in capsys.readouterr().out


def test_diagnostic_error_output_omits_provider_bodies_and_generic_exception_text():
    error = UnexpectedModelBehavior("Tool retry limit reached", body="private response body")
    error.__cause__ = ValueError("private details")
    output = json.dumps(error_details(error))
    assert "Tool retry limit reached" in output and "ValueError" in output
    assert "private" not in output


def tf_model(samples):
    async def model(messages, info):
        returned = {part.tool_name for message in messages for part in message.parts
                    if isinstance(part, ToolReturnPart) and part.outcome != "retried"}
        if "get_application_state" not in returned:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="state")])
        if "set_transfer_function" not in returned:
            return ModelResponse(parts=[ToolCallPart("set_transfer_function", {"channel": 0, "samples": samples},
                                                    tool_call_id="tf")])
        return ModelResponse(parts=[TextPart("Synthetic TF applied")])
    return FunctionModel(model)


def test_tf_diagnostic_applies_only_synthetic_ramps_in_both_cases(capsys):
    samples = [[0, 0, 0, 0], [255, 255, 255, 255]]
    assert asyncio.run(diagnose(SETTINGS, tf_model(samples), CATALOG, "transfer-function"))
    output = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    results = [entry for entry in output if "passed" in entry]
    assert [entry["test"] for entry in results] == ["transfer_function", "compact_transfer_function"]
    assert all(entry["passed"] and entry["tf_sample_counts"] == [2] and
               entry["successful_state_reads"] == 1 and entry["elapsed_seconds"] >= 0 for entry in results)
    assert next(value for value in CATALOG if value["name"] == "set_transfer_function")[
        "inputSchema"]["properties"]["samples"]["maxItems"] == 65536


def test_tf_diagnostic_compares_full_table_with_enforced_compact_limit(capsys):
    assert not asyncio.run(diagnose(SETTINGS, tf_model([[255, 255, 255, 255]] * 64),
                                  CATALOG, "transfer-function"))
    output = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    full, compact = [entry for entry in output if "passed" in entry]
    assert full["passed"] and full["tf_sample_counts"] == [64]
    assert not compact["passed"] and compact["tf_sample_counts"] == []
    assert compact["errors"][0]["type"] == "UnexpectedModelBehavior"


def test_tf_diagnostic_requires_an_actual_synthetic_setter_not_just_state_or_text(capsys):
    async def model(messages, info):
        if any(isinstance(part, ToolReturnPart) for message in messages for part in message.parts):
            return ModelResponse(parts=[TextPart("I will set a bone TF")])
        return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="state")])
    assert not asyncio.run(diagnose(SETTINGS, FunctionModel(model), CATALOG, "transfer-function"))
    output = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert all(not entry["passed"] and entry["tf_sample_counts"] == [] for entry in output if "passed" in entry)
