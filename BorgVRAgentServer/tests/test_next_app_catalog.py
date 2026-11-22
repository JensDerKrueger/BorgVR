"""Contract from Swift's offered catalog through WebSocket v1 to the model."""

import json
from pathlib import Path
import subprocess
import sys

from fastapi.testclient import TestClient
import pytest
from starlette.websockets import WebSocketDisconnect

from borgvr_next.app import create_app
from borgvr_next.model import Call
from borgvr_next.wire import Tool
from test_next_runtime import AUTH, TOKEN, hello, receipt, tool, turn

ROOT = Path(__file__).resolve().parents[2]
EXPERT = ROOT / "AppSupport/Voice/expert-knowledge.toml"
PRIVATE_RULE = '''
[tests.private_rule]
goal = "Only present in this connection"
steps = ["SESSION_ONLY_TEST_RULE"]
'''


@pytest.fixture(scope="module")
def swift_catalogs(tmp_path_factory):
    if sys.platform != "darwin":
        pytest.skip("The native Swift catalog uses Apple frameworks")
    temporary = tmp_path_factory.mktemp("swift-catalog")
    source = ROOT / "AppSupport/Voice"
    binary = temporary / "exporter"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(temporary / "modules"),
                    str(source / "VoiceAgentProtocol.swift"), str(source / "VoiceAgentAnnotationPolicy.swift"),
                    str(source / "VoiceAgentMarkdown.swift"), str(ROOT / "Tests/VoiceAgentPolicyTests.swift"),
                    "-o", str(binary)], check=True, timeout=120)
    exported = subprocess.run([str(binary), "--export-catalog", str(ROOT / "BorgVRAgentServer/diagnostic_catalog.json")],
                              check=True, capture_output=True, timeout=10, text=True)
    return json.loads(exported.stdout)


class Capture:
    name = "fixture-model"

    def __init__(self):
        self.requests = []

    async def complete(self, messages, tools):
        self.requests.append((messages, tools))
        return "Catalog received."


def model_catalog(offered, received):
    offered = [entry for entry in offered if entry["name"] != "capture_tf_preview"]
    assert [entry["name"] for entry in offered] == [entry["function"]["name"] for entry in received]
    for original, value in zip(offered, received, strict=True):
        function = value["function"]
        description, _, metadata = function["description"].rpartition("\nApp-declared execution: ")
        assert description == original["description"]
        assert json.loads(metadata.splitlines()[0]) == original["execution"]
        native_schema = original["inputSchema"]
        parameters = function["parameters"]
        assert "strict" not in function
        if Tool.model_validate(original).takes_no_arguments:
            assert parameters == {**native_schema, "required": [], "properties": {}}
        else:
            assert parameters == native_schema


def ask(client, tools, *, dataset, expert=None):
    with client.websocket_connect("/v1/session", headers=AUTH) as ws:
        initial = hello(tools=tools, dataset_id=dataset, application_session=True, dataset_opening=True)
        if expert is not None:
            initial["expert_knowledge_toml"] = expert
        ws.send_json(initial)
        response = ws.receive_json()
        assert response["type"] == "ready"
        assert response["tools"] == [entry["name"] for entry in tools]
        turn(ws, text="Inspect the supplied catalog.")
        assert ws.receive_json()["text"] == "Catalog received."
        assert ws.receive_json()["type"] == "completed"


@pytest.mark.parametrize("variant", ["start_menu", "renderer", "no_images", "rgba", "vision"])
def test_swift_catalog_and_expert_knowledge_reach_model(swift_catalogs, variant):
    offered = swift_catalogs[variant]
    model = Capture()
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        features = client.head("/healthz").headers
        assert features["BorgVR-Tool-Types"] == features["BorgVR-Expert-Knowledge"] == "1"
        ask(client, offered, dataset=None if variant == "start_menu" else "volume",
            expert=EXPERT.read_text() + PRIVATE_RULE)
        messages, received = model.requests[-1]
        model_catalog(offered, received)
        reference = next(message for message in messages if message["content"].startswith("Untrusted application guidance"))
        assert reference["role"] == "user" and messages[0]["role"] == "system"
        resolved = json.loads(reference["content"].splitlines()[-1])
        rules = {rule["id"]: rule for rule in resolved["rules"]}
        assert "SESSION_ONLY_TEST_RULE" in reference["content"]
        assert ("inspection.preview" in rules) == (variant not in {"start_menu", "no_images"})
        if "inspection.preview" in rules:
            screenshot = next(tool["function"] for tool in received if tool["function"]["name"] == "capture_screenshot")
            assert "max_width" in screenshot["parameters"]["properties"]
        assert ("transfer_function.component" in rules) == (variant not in {"start_menu", "rgba"})
        assert ("rendering.natural_lighting" in rules) == (variant not in {"start_menu", "rgba"})
        if "rendering.natural_lighting" in rules:
            mode = next(tool["function"] for tool in received if tool["function"]["name"] == "set_render_mode")
            assert {"transfer_function", "transfer_function_lighting"} <= set(mode["parameters"]["properties"]["mode"]["enum"])
            guidance = " ".join(rules["rendering.natural_lighting"]["steps"])
            assert "compare transfer_function and transfer_function_lighting with the same transfer function" in guidance
            assert "RGB and alpha curves vary independently" in guidance
        if "transfer_function.component" in rules:
            guidance = " ".join(rules["transfer_function.component"]["steps"])
            assert "set_transfer_function_component once per affected component" in guidance
            assert "set_transfer_function only if" in guidance and "more than about 50 control points" in guidance
        ask(client, offered, dataset=None if variant == "start_menu" else "volume")
        assert "SESSION_ONLY_TEST_RULE" not in str(model.requests[-1][0])
        model_catalog(offered, model.requests[-1][1])


def test_client_defined_new_tools_keep_their_types_and_scope_replaces_catalog():
    first = {**tool("custom_meter"), "execution": {"kind": "read", "timeout_seconds": 45}}
    second = {**tool("another_future_tool"), "execution": {"kind": "read", "timeout_seconds": 45}}
    model = Capture()
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(tools=[first], application_session=True))
            assert ws.receive_json()["tools"] == ["custom_meter"]
            turn(ws, name="first")
            assert ws.receive_json()["text"] == "Catalog received."
            assert ws.receive_json()["type"] == "completed"
            ws.send_json({"type": "context_changed", "dataset_id": "new-volume", "context_id": "replacement",
                          "tools": [second]})
            assert ws.receive_json()["tools"] == ["another_future_tool"]
            turn(ws, name="second")
            assert ws.receive_json()["text"] == "Catalog received."
            assert ws.receive_json()["type"] == "completed"
    model_catalog([first], model.requests[0][1])
    model_catalog([second], model.requests[1][1])


def test_wrong_schema_rejects_entire_catalog_instead_of_silently_dropping_tools():
    model = Capture()
    invalid = tool("future_tool")
    invalid["inputSchema"]["additionalProperties"] = True
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(tools=[tool("get_application_state"), invalid]))
            assert ws.receive_json()["code"] == "invalid_message"
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()
    assert model.requests == []


def test_only_client_approval_is_authoritative_and_denied_group_cannot_be_retried():
    state = {**tool("read_snapshot"), "execution": {"kind": "read", "role": "application_state"}}
    write = {**tool("first_mutation", {"amount": {"type": "number"}}),
             "execution": {"kind": "mutation", "approval_group": "local_dialog"}}
    write["inputSchema"]["required"] = ["amount"]
    alternate = {**tool("second_mutation"), "execution": write["execution"]}

    class Attempts(Capture):
        async def complete(self, messages, tools, *, response_schema=None):
            if response_schema is not None:
                assert not tools
                assert response_schema["properties"]["arguments"]["anyOf"][0] == write["inputSchema"]
                assert not any(message["role"] == "tool" for message in messages)
                return '{"arguments":{"amount":15}}'
            self.requests.append((messages, tools))
            match len(self.requests):
                case 1:
                    return Call("ask", write["name"], '{"amount":"15"}')
                case 2:
                    return Call("bypass", alternate["name"], "{}")
                case _:
                    assert json.loads(messages[-1]["content"])["code"] == "user_declined"
                    return "The user declined."

    with TestClient(create_app(token=TOKEN, model=Attempts())) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(tools=[state, write, alternate]))
            ws.receive_json()
            turn(ws)
            query = ws.receive_json()
            assert query["name"] == state["name"]
            ws.send_json(receipt(query, {"ready": True}))
            attempted = ws.receive_json()
            assert attempted["name"] == write["name"] and attempted["arguments"] == {"amount": 15}
            ws.send_json(receipt(attempted, {"ok": False, "not_applied": True, "code": "user_declined"}))
            assert ws.receive_json()["text"] == "The user declined."
            assert ws.receive_json()["type"] == "completed"
