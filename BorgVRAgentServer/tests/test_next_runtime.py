"""Black-box tests for the independent implementation."""

import asyncio
import json

from fastapi.testclient import TestClient
import httpx
import pytest
from starlette.websockets import WebSocketDisconnect

from borgvr_next import session as session_runtime
from borgvr_next.app import create_app, from_env
from borgvr_next.evidence import Evidence
from borgvr_next.learner import process_one
from borgvr_next.model import Call, ContextLimit, ModelFailure, OutputLimit, VLLM

TOKEN = "synthetic-token" * 4
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def tool(name, properties=None):
    roles = {"get_application_state": "application_state", "search_datasets": "catalog_search",
             "capture_screenshot": "render_image"}
    transition = {"open_dataset": "open", "close_dataset": "close"}.get(name)
    execution = {"kind": "transition", "transition": transition} if transition else {
        "kind": "read", "role": roles[name]} if name in roles else {"kind": "mutation"}
    return {"name": name, "description": name,
            "inputSchema": {"type": "object", "additionalProperties": False, "properties": properties or {}},
            "execution": execution}


TOOLS = [tool("get_application_state"), tool("rotate_view", {"degrees": {"type": "number"}})]


def test_installed_agent_factory_uses_compose_settings(monkeypatch, tmp_path):
    agent_token = tmp_path / "agent_token"
    model_token = tmp_path / "vllm_token"
    agent_token.write_text(TOKEN + "\n")
    model_token.write_text("other-synthetic-token" * 2 + "\n")
    for name, value in {
        "BORGVR_TOKEN_FILE": str(agent_token), "BORGVR_VLLM_TOKEN_FILE": str(model_token),
        "BORGVR_VLLM_URL": "http://vllm:8000/v1", "BORGVR_MODEL": "fixture/model",
        "BORGVR_CONTEXT_LENGTH": "65536", "BORGVR_NEXT_MODEL_SLOTS": "1", "BORGVR_THINKING_MODE": "default",
    }.items():
        monkeypatch.setenv(name, value)

    def backend(request):
        assert str(request.url) == "http://vllm:8000/v1/models"
        assert request.headers["Authorization"] == "Bearer " + "other-synthetic-token" * 2
        return httpx.Response(200, json={"data": [{"id": "fixture/model"}]})

    client = httpx.AsyncClient(transport=httpx.MockTransport(backend))
    monkeypatch.setattr(httpx, "AsyncClient", lambda **_: client)
    with TestClient(from_env()) as app:
        assert app.get("/readyz").status_code == 401
        ready = app.get("/readyz", headers=AUTH)
        assert ready.status_code == 200 and ready.json()["model"] == "fixture/model"
        assert app.head("/healthz").headers["BorgVR-Tool-Types"] == "1"


class Steps:
    name = "fixture-model"

    def __init__(self, *steps):
        self.steps = iter(steps)

    async def ready(self):
        return True

    async def complete(self, messages, tools):
        return next(self.steps)


def hello(**additions):
    return {"type": "hello", "protocol": 1, "dataset_id": "sample", "context_id": "scope", "tools": TOOLS, **additions}


def receipt(call, data):
    return {"type": "tool_result", "result": data, **{key: call[key] for key in
            ("request_id", "call_id", "dataset_id", "context_id", "view_revision") if key in call}}


def turn(ws, name="turn", text="Rotate the view."):
    ws.send_json({"type": "user_message", "request_id": name, "text": text})
    assert ws.receive_json()["type"] == "started"


def test_protocol_v1_state_gate_and_receipt():
    model = Steps(Call("before-state", "rotate_view", '{"degrees":15}'),
                  Call("state", "get_application_state", "{}"),
                  Call("with-state", "rotate_view", '{"degrees":15}'), "Rotated.")
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        assert client.get("/readyz", headers=AUTH).json()["protocol"] == 1
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello())
            assert ws.receive_json()["tools"] == ["get_application_state", "rotate_view"]
            turn(ws)
            state = ws.receive_json()
            assert state["name"] == "get_application_state"
            ws.send_json(receipt(state, {"rendererReady": True}))
            rotate = ws.receive_json()
            assert rotate["name"] == "rotate_view" and rotate["arguments"] == {"degrees": 15}
            ws.send_json(receipt(rotate, {"ok": True}))
            assert ws.receive_json()["text"] == "Rotated."
            assert ws.receive_json()["type"] == "completed"


def test_unsuccessful_state_read_does_not_reset_tool_correction():
    model = Steps(Call("premature", "rotate_view", '{"degrees":15}'),
                  Call("read", "get_application_state", "{}"),
                  Call("still-premature", "rotate_view", '{"degrees":15}'))
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello())
            assert ws.receive_json()["type"] == "ready"
            turn(ws)
            state = ws.receive_json()
            assert state["name"] == "get_application_state"
            ws.send_json(receipt(state, {"ok": False, "not_applied": True, "code": "read_timeout"}))
            error = ws.receive_json()
            assert error["type"] == "error" and error["code"] == "run_failed" and not error["changes_applied"]


@pytest.mark.parametrize("cancel", [False, True])
def test_time_only_turn_continues_past_old_limits_and_can_be_cancelled(cancel):
    class Model(Steps):
        calls = 0

        async def complete(self, messages, tools):
            assert [tool["function"]["name"] for tool in tools] == ["get_application_state", "rotate_view"]
            if self.calls == 75:
                return "Inspected."
            self.calls += 1
            if self.calls % 2:
                return Call(str(self.calls), "get_application_state", "{}")
            return Call(str(self.calls), "rotate_view", '{"degrees":15}')

    model = Model()
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        assert client.head("/healthz").headers["BorgVR-Time-Only-Turns"] == "1"
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(execution_limits={"timeout_seconds": 300}))
            assert ws.receive_json()["execution_limits"] == {"timeout_seconds": 300}
            turn(ws, text="Inspect the view.")
            for index in range(30 if cancel else 75):
                call = ws.receive_json()
                expected = "rotate_view" if index % 2 else "get_application_state"
                assert call["type"] == "tool_call" and call["name"] == expected
                ws.send_json(receipt(call, {"ok": True, "rendererReady": True}))
            if cancel:
                pending = ws.receive_json()
                assert pending["type"] == "tool_call" and pending["name"] == "get_application_state"
                ws.send_json({"type": "cancel", "request_id": "turn"})
                cancelled_tool = ws.receive_json()
                assert cancelled_tool["type"] == "tool_cancel" and cancelled_tool["call_id"] == pending["call_id"]
                cancelled_turn = ws.receive_json()
                assert cancelled_turn["type"] == "cancelled" and cancelled_turn["requires_reconnect"] is False
                assert model.calls == 31
            else:
                assert ws.receive_json()["text"] == "Inspected."
                assert ws.receive_json()["type"] == "completed"


@pytest.mark.parametrize("requested,negotiated", [(None, 3600), (300, 300), (3600, 3600), (10800, 10800)])
def test_next_server_negotiates_full_turn_budget(requested, negotiated):
    limits = {} if requested is None else {"execution_limits": {"timeout_seconds": requested}}
    with TestClient(create_app(token=TOKEN, model=Steps())) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(**limits))
            assert ws.receive_json()["execution_limits"] == {"timeout_seconds": negotiated}


@pytest.mark.parametrize("requested", [299, 10801])
def test_time_only_turn_budget_rejects_out_of_range_values(requested):
    with TestClient(create_app(token=TOKEN, model=Steps())) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(execution_limits={"timeout_seconds": requested}))
            assert ws.receive_json()["code"] == "invalid_message"


def test_finished_long_turn_restarts_short_idle_deadline(monkeypatch):
    monkeypatch.setattr(session_runtime, "IDLE_SECONDS", 0.05)

    class Socket:
        def __init__(self):
            self.incoming = asyncio.Queue()
            self.outgoing = []

        async def receive(self):
            return {"type": "websocket.receive", "text": json.dumps(await self.incoming.get())}

        async def send_text(self, text):
            self.outgoing.append(json.loads(text))

    async def check():
        socket = Socket()
        socket.incoming.put_nowait(hello(execution_limits={"timeout_seconds": 10800}))
        socket.incoming.put_nowait({"type": "user_message", "request_id": "turn", "text": "Inspect the view."})
        session = session_runtime.Session(socket, Steps("Done."), asyncio.Semaphore(1))
        async with asyncio.timeout(2):
            with pytest.raises(TimeoutError):
                await session.run()
        assert [item["type"] for item in socket.outgoing] == ["ready", "started", "assistant_message", "completed"]

    asyncio.run(check())


def test_next_server_honors_legacy_clients_requested_tool_count():
    class Model(Steps):
        async def complete(self, messages, tools):
            calls = sum(message["role"] == "tool" for message in messages)
            if calls == 27:
                assert not tools
                return "Finished within the requested budget."
            assert tools
            return Call(str(calls), "get_application_state", "{}")

    with TestClient(create_app(token=TOKEN, model=Model())) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            limits = {"max_calls": 27, "timeout_seconds": 120}
            ws.send_json(hello(execution_limits=limits))
            assert ws.receive_json()["execution_limits"] == limits
            turn(ws, text="Inspect the view.")
            for _ in range(27):
                call = ws.receive_json()
                assert call["type"] == "tool_call"
                ws.send_json(receipt(call, {"rendererReady": True}))
            assert ws.receive_json()["text"] == "Finished within the requested budget."
            assert ws.receive_json()["type"] == "completed"


def test_repeated_model_call_never_dispatches_twice():
    change = Call("rotate", "rotate_view", '{"degrees":15}')
    model = Steps(Call("state", "get_application_state", "{}"), change, change)
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello())
            ws.receive_json()
            turn(ws)
            ws.send_json(receipt(ws.receive_json(), {"rendererReady": True}))
            dispatched = ws.receive_json()
            assert dispatched["name"] == "rotate_view"
            ws.send_json(receipt(dispatched, {"ok": True}))
            failure = ws.receive_json()
            assert failure["type"] == "error" and failure["changes_applied"]


def test_empty_tool_schema_is_explicit_and_rejection_never_logs_argument_values(caplog):
    class Model(Steps):
        async def complete(self, messages, tools, *, response_schema=None):
            if response_schema is not None:
                assert not tools
                assert response_schema["properties"]["arguments"]["anyOf"] == [TOOLS[0]["inputSchema"], {"type": "null"}]
                assert all("tool_calls" not in message for message in messages)
                assert json.loads(messages[-1]["content"].splitlines()[-1])["reason"] == "expected_empty_object"
                return '{"arguments":{}}'
            definition = tools[0]["function"]
            assert "strict" not in definition
            assert definition["parameters"] == {
                "type": "object", "properties": {}, "required": [], "additionalProperties": False,
            }
            assert "exactly {}" in definition["description"]
            if messages[-1]["role"] == "tool":
                assert messages[-2]["tool_calls"][0]["function"]["arguments"] == "{}"
                assert "SYNTHETIC_PRIVATE_VALUE" not in str(messages)
            return await super().complete(messages, tools)

    model = Model(Call("incorrect", "get_application_state", '{"reason":"SYNTHETIC_PRIVATE_VALUE"}'), "State read.")
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(tools=[TOOLS[0]]))
            ws.receive_json()
            turn(ws)
            dispatched = ws.receive_json()
            assert dispatched["name"] == "get_application_state" and dispatched["arguments"] == {}
            ws.send_json(receipt(dispatched, {"rendererReady": True}))
            assert ws.receive_json()["text"] == "State read."
            assert ws.receive_json()["type"] == "completed"
    assert "reason=expected_empty_object" in caplog.text
    assert "SYNTHETIC_PRIVATE_VALUE" not in caplog.text


@pytest.mark.parametrize("correction, reason", [
    ('{"arguments":{"extra":1}}', "invalid_argument_correction"),
    ('{"tool":"another_tool","arguments":{}}', "invalid_argument_correction"),
    ('{"arguments":null}', "argument_correction_declined"),
])
def test_failed_schema_correction_is_not_retried_or_dispatched(caplog, correction, reason):
    class Model(Steps):
        replies = 0

        async def complete(self, messages, tools, *, response_schema=None):
            if response_schema is not None:
                self.replies += 1
                return correction
            return await super().complete(messages, tools)

    model = Model(Call("invalid", "get_application_state", "not JSON"))
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(tools=[TOOLS[0]]))
            assert ws.receive_json()["type"] == "ready"
            turn(ws)
            error = ws.receive_json()
            assert error["type"] == "error" and error["code"] == "run_failed" and not error["changes_applied"]
    assert model.replies == 1
    assert f"reason={reason}" in caplog.text


def test_opening_requires_catalog_receipt_and_replaces_tool_scope(caplog):
    caplog.set_level("INFO", logger="uvicorn.error.borgvr")
    model = Steps(Call("start", "get_application_state", "{}"),
                  Call("guess", "open_dataset", '{"id":"PRIVATE_GUESSED_ARGUMENT"}'),
                  Call("search", "search_datasets", "{}"),
                  Call("target", "open_dataset", '{"id":"PRIVATE_DATASET_ID"}'),
                  Call("opened", "get_application_state", "{}"), "Dataset opened.")
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(application_session=True, dataset_opening=True, dataset_id=None,
                               tools=[TOOLS[0], tool("search_datasets"), tool("open_dataset", {"id": {"type": "string"}})]))
            assert ws.receive_json()["dataset_opening"]
            turn(ws, name="PRIVATE_REQUEST_ID", text="Find and open PRIVATE_PROMPT.")
            state = ws.receive_json()
            assert state["dataset_id"] is None
            ws.send_json(receipt(state, {"rendererReady": False}))
            search = ws.receive_json()
            assert search["name"] == "search_datasets"
            ws.send_json(receipt(search, {"matches": [{"id": "PRIVATE_DATASET_ID", "description": "PRIVATE_DATASET_NAME"}]}))
            call = ws.receive_json()
            assert call["name"] == "open_dataset" and call["arguments"] == {"id": "PRIVATE_DATASET_ID"}
            ws.send_json({**receipt(call, {"dataset": {"id": "PRIVATE_DATASET_ID"}, "rendererReady": True}),
                          "dataset_transition": {"dataset_id": "PRIVATE_DATASET_ID", "context_id": "new-scope", "tools": TOOLS}})
            event = ws.receive_json()
            assert event["type"] == "context_updated" and event["context_id"] == "new-scope"
            current = ws.receive_json()
            assert current["name"] == "get_application_state" and current["context_id"] == "new-scope"
            ws.send_json(receipt(current, {"rendererReady": True}))
            assert ws.receive_json()["text"] == "Dataset opened."
            assert ws.receive_json()["type"] == "completed"
    opening_logs = [record.getMessage() for record in caplog.records if "tool=open_dataset" in record.getMessage()]
    correlation = f"session={call['session_id']} turn=1"
    assert opening_logs == [
        f"Agent tool: {correlation} event=rejected tool=open_dataset call=- reason=search_required",
        f"Agent tool: {correlation} event=dispatched tool=open_dataset call={call['call_id']} reason=-",
        f"Agent tool: {correlation} event=receipt tool=open_dataset call={call['call_id']} reason=confirmed",
    ]
    assert f"Agent turn finished: {correlation} outcome=completed tool_calls=4 changes_applied=True" in caplog.text
    assert "PRIVATE_" not in caplog.text and "Dataset opened." not in caplog.text


@pytest.mark.parametrize("values, status", [
    ({"error": "PRIVATE_CLIENT_ERROR"}, "client_error"),
    ({"result": {"not_applied": True, "code": "PRIVATE_CLIENT_CODE", "note": "PRIVATE_NOTE"}}, "not_applied"),
    ({"result": {"not_applied": True, "code": "user_declined"}}, "user_declined"),
    ({"result": None}, "unconfirmed"),
])
def test_receipt_diagnostics_do_not_log_native_error_contents(caplog, values, status):
    caplog.set_level("INFO", logger="uvicorn.error.borgvr")
    model = Steps(Call("model-id", "get_application_state", "{}"), "Finished.")
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello())
            assert ws.receive_json()["type"] == "ready"
            turn(ws)
            call = ws.receive_json()
            ws.send_json({**receipt(call, {}), **values})
            assert ws.receive_json()["text"] == "Finished."
            assert ws.receive_json()["type"] == "completed"
    assert f"event=receipt tool=get_application_state call={call['call_id']} reason={status}" in caplog.text
    assert "PRIVATE_" not in caplog.text


def test_completed_text_without_tools_does_not_log_confirmed_changes(caplog):
    caplog.set_level("INFO", logger="uvicorn.error.borgvr")
    with TestClient(create_app(token=TOKEN, model=Steps("PRIVATE_ASSISTANT_CLAIM"))) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello())
            assert ws.receive_json()["type"] == "ready"
            turn(ws, text="PRIVATE_PROMPT")
            assert ws.receive_json()["type"] == "assistant_message"
            assert ws.receive_json()["type"] == "completed"
    assert "outcome=completed tool_calls=0 changes_applied=False uncertain=False" in caplog.text
    assert "Agent tool:" not in caplog.text and "PRIVATE_" not in caplog.text


@pytest.mark.parametrize("followup", [False, True])
def test_scope_handoff_keeps_confirmed_receipt_and_only_unfinished_work(followup):
    open_tool = tool("open_dataset", {"id": {"type": "string"}})
    start_tools = [TOOLS[0], tool("search_datasets"), open_tool]
    new_tools = [*TOOLS, open_tool]
    opened = {"dataset": {"id": "sample", "description": "Fixture Volume"}, "rendererReady": True}
    goal = "Open Fixture Volume and rotate it by 15 degrees." if followup else "Open Fixture Volume."
    calls = [
        Call("premature-open", "open_dataset", '{"id":"sample"}'),
        Call("state", "get_application_state", "{}"),
        Call("search", "search_datasets", "{}"),
        Call("open", "open_dataset", '{"id":"sample"}'),
    ]
    if followup:
        calls += [Call("premature", "rotate_view", '{"degrees":15}'),
                  Call("new-state", "get_application_state", "{}"),
                  Call("rotate", "rotate_view", '{"degrees":15}')]

    class Model(Steps):
        saw_handoff = False

        async def complete(self, messages, tools):
            if messages[-1]["role"] == "user" and messages[-1]["content"].startswith("The application changed scope."):
                instruction, evidence = messages[-1]["content"].split("\n", 1)
                assert "If they satisfy the request, answer now." in instruction
                assert "Read current state before any further change." in instruction
                assert json.loads(evidence) == [{
                    "tool": "open_dataset", "outcome": "confirmed", "context_id": "scope", "transition": "open",
                    "arguments": {"id": "sample"}, "result": opened,
                }]
                assert [definition["function"]["name"] for definition in tools] == [
                    "get_application_state", "rotate_view", "open_dataset"]
                assert messages[-2] == {"role": "user", "content": goal}
                assert not any(message["role"] == "tool" or "tool_calls" in message for message in messages)
                self.saw_handoff = True
            if messages[-1]["role"] == "tool" and messages[-1]["tool_call_id"] in {"premature-open", "premature"}:
                correction = json.loads(messages[-1]["content"])
                assert correction["code"] == "state_required" and "get_application_state" in correction["note"]
            return await super().complete(messages, tools)

    answer = "Opened and rotated." if followup else "Opened Fixture Volume."
    model = Model(*calls, answer)
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello(dataset_id=None, application_session=True, dataset_opening=True, tools=start_tools))
            assert ws.receive_json()["type"] == "ready"
            turn(ws, text=goal)
            state = ws.receive_json()
            assert state["name"] == "get_application_state"
            ws.send_json(receipt(state, {"rendererReady": False}))
            search = ws.receive_json()
            assert search["name"] == "search_datasets"
            ws.send_json(receipt(search, {"matches": [{"id": "sample"}]}))
            opening = ws.receive_json()
            assert opening["name"] == "open_dataset"
            ws.send_json({**receipt(opening, opened), "dataset_transition": {
                "dataset_id": "sample", "context_id": "new-scope", "tools": new_tools,
            }})
            assert ws.receive_json()["type"] == "context_updated"
            if followup:
                state = ws.receive_json()
                assert state["name"] == "get_application_state" and state["context_id"] == "new-scope"
                ws.send_json(receipt(state, opened))
                rotation = ws.receive_json()
                assert rotation["name"] == "rotate_view" and rotation["context_id"] == "new-scope"
                ws.send_json(receipt(rotation, {"ok": True}))
            assert ws.receive_json()["text"] == answer
            assert ws.receive_json()["type"] == "completed"
    assert model.saw_handoff


def setup_profiles(tmp_path):
    directory = tmp_path / "observer"
    directory.mkdir(mode=0o700)
    store = Evidence(directory / "next.sqlite3")
    profile, secret = store.provision()
    other, other_secret = store.provision()
    return store, profile, other, {**AUTH, "x-borgvr-observer": secret}, {**AUTH, "x-borgvr-observer": other_secret}


class Evaluator:
    def __init__(self):
        self.requests = []

    async def complete(self, messages, tools):
        assert tools == []
        evidence = json.loads(messages[-1]["content"].splitlines()[-1])
        self.requests.append(evidence)
        if "audit" in messages[0]["content"]:
            event_ids = [i for i, item in enumerate(evidence) if item["kind"] in {"goal", "manual_change", "receipt"}]
            return json.dumps({"label": "corrected", "description": "The human chose a better view.", "evidence": event_ids})
        return json.dumps({"hypotheses": [{
            "situation": "The prior rotation obscures the relevant structure.",
            "recommendation": "Use a complementary inspection angle before concluding.",
            "support": [entry["id"] for entry in evidence["observations"]], "counterexamples": [],
        }]})


def test_observer_is_opt_in_and_detached_with_profile_local_hypotheses(tmp_path):
    store, profile, other, headers, other_headers = setup_profiles(tmp_path)

    class Model:
        name = "fixture-model"

        async def complete(self, messages, tools):
            if any(message["role"] == "tool" for message in messages):
                return "I saw the view."
            return Call("fresh", "get_application_state", "{}")

    with TestClient(create_app(token=TOKEN, model=Model(), evidence=store)) as client:
        for credentials in [AUTH, headers, headers, headers]:
            with client.websocket_connect("/v1/session", headers=credentials) as ws:
                ws.send_json(hello(collaboration=True))
                assert ws.receive_json()["collaboration"]
                turn(ws)
                state = ws.receive_json()
                ws.send_json({"type": "user_change", "dataset_id": "sample", "context_id": "scope",
                              "revision": 1, "domains": ["transform"], "state": {"rotation": "synthetic"},
                              "active": False})
                ws.send_json(receipt(state, {"rendererReady": True}))
                assert ws.receive_json()["type"] == "collaboration_paused"
                assert ws.receive_json()["type"] == "collaboration_resumed"
                assert ws.receive_json()["type"] == "assistant_message"
                assert ws.receive_json()["type"] == "completed"
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect("/v1/session", headers={**AUTH, "x-borgvr-observer": "invalid"}):
                pytest.fail("Invalid observer profile was accepted")

    # Simulate a worker restart with no connected devices.
    worker_store = Evidence(store.path)
    evaluator = Evaluator()
    for expected in ["pending", "pending", "candidate"]:
        assert asyncio.run(process_one(worker_store, evaluator))
        assert worker_store.read_proposals(profile)["hypotheses"][0]["status"] == expected
    assert not asyncio.run(process_one(worker_store, evaluator))
    assert len(evaluator.requests) == 6
    assert worker_store.read_proposals(other)["hypotheses"] == []
    with TestClient(create_app(token=TOKEN, model=Model(), evidence=store)) as client:
        route = "/v1/observer/hypotheses"
        assert client.get(route, headers=AUTH).status_code == 401
        assert client.get(route, headers=other_headers).json()["hypotheses"] == []
        assert client.get(route, headers=headers).json()["hypotheses"][0]["status"] == "candidate"


def test_induction_after_restart_and_stale_worker_cannot_publish(tmp_path):
    store, profile, _, _, _ = setup_profiles(tmp_path)
    verdict = {"label": "aligned", "description": "Confirmed with evidence.", "evidence": [0, 1]}
    for index in range(2):
        assert store.submit(profile, str(index), "turn", [{"kind": "goal"}, {"kind": "receipt"}])
        assert store.settle(store.claim(), verdict)
        if index == 0:
            old_job = store.claim_induction()
    assert not store.finish_induction(old_job, [])
    assert asyncio.run(process_one(Evidence(store.path), Evaluator()))
    assert store.read_proposals(profile)["hypotheses"][0]["status"] == "pending"


@pytest.mark.parametrize("configured,reported,count,cap,expected,seconds", [
    (65536, 32768, 500, None, 31756, 180),
    (8192, 65536, 500, None, 7180, 180),
    (8192, 65536, 500, 4096, 4096, 60),
    (8192, 65536, 7616, 4096, 64, 60),
])
def test_vllm_uses_same_payload_and_bounds_generation_by_available_context(configured, reported, count, cap, expected, seconds):
    observed = []

    def handler(request):
        body = json.loads(request.content)
        observed.append((request.url.path, body))
        assert request.headers["Authorization"] == "Bearer synthetic"
        timeout = request.extensions["timeout"]
        assert timeout["connect"] == 5
        if request.url.path == "/tokenize":
            assert timeout["read"] == 15
            return httpx.Response(200, json={"count": count, "max_model_len": reported})
        assert timeout["read"] == seconds
        assert body["max_tokens"] == expected
        return httpx.Response(200, json={"choices": [{"finish_reason": "stop", "message": {"content": "Done."}}]})

    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            overrides = {"generation_timeout": 60} if cap is not None else {}
            model = VLLM(client, "http://fixture.invalid/v1", "synthetic", "fixture",
                         context=configured, max_output_tokens=cap, **overrides)
            tools = [{"type": "function", "function": {"name": "get_application_state"}}]
            messages = [{"role": "system", "content": "Policy."}]
            assert await model.complete(messages, tools) == "Done."
        assert [item[0] for item in observed] == ["/tokenize", "/v1/chat/completions"]
        for _, body in observed:
            assert body["tools"] == tools and body["messages"] == messages

    asyncio.run(check())


def test_vllm_read_timeout_is_classified_before_generic_transport_errors():
    def handler(request):
        if request.url.path == "/tokenize":
            return httpx.Response(200, json={"count": 42, "max_model_len": 8192})
        raise httpx.ReadTimeout("private provider message", request=request)

    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            model = VLLM(client, "http://fixture.invalid/v1", "synthetic", "fixture")
            with pytest.raises(ModelFailure) as failure:
                await model.complete([{"role": "user", "content": "Synthetic question."}], [])
            assert (failure.value.phase, failure.value.code) == ("generation", "timeout")
            assert "private provider message" not in str(failure.value)

    asyncio.run(check())


def test_vllm_does_not_generate_when_context_is_full():
    def handler(request):
        assert request.url.path == "/tokenize"
        return httpx.Response(200, json={"count": 7680, "max_model_len": 8192})

    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            model = VLLM(client, "http://fixture.invalid/v1", "synthetic", "fixture")
            with pytest.raises(ContextLimit) as failure:
                await model.complete([{"role": "user", "content": "Synthetic question."}], [])
            assert (failure.value.input_tokens, failure.value.window) == (7680, 8192)

    asyncio.run(check())


@pytest.mark.parametrize("finish_reason", ["stop", "length", "content_filter"])
def test_vllm_sends_correction_schema_without_native_tools(finish_reason):
    schema = {"type": "object", "properties": {"arguments": TOOLS[0]["inputSchema"]},
              "required": ["arguments"], "additionalProperties": False}
    requests = []

    def handler(request):
        requests.append(request.url.path)
        body = json.loads(request.content)
        assert "tools" not in body
        assert body["response_format"] == {"type": "json_schema", "json_schema": {
            "name": "corrected_arguments", "schema": schema,
        }}
        if request.url.path == "/tokenize":
            return httpx.Response(200, json={"count": 500, "max_model_len": 8192})
        assert body["max_tokens"] == 7180
        return httpx.Response(200, json={"choices": [{"finish_reason": finish_reason,
                                                     "message": {"content": '{"arguments":{}}'}}]})

    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            model = VLLM(client, "http://fixture.invalid/v1", "synthetic", "fixture")
            messages = [{"role": "user", "content": "Correct the arguments."}]
            if finish_reason == "stop":
                assert await model.complete(messages, [], response_schema=schema) == '{"arguments":{}}'
            else:
                with pytest.raises(ModelFailure) as failure:
                    await model.complete(messages, [], response_schema=schema)
                assert failure.value.code == ("output_token_limit" if finish_reason == "length" else "incomplete_argument_correction")
        assert requests == ["/tokenize", "/v1/chat/completions"]

    asyncio.run(check())


@pytest.mark.parametrize("finish_reason", ["tool_calls", "length"])
def test_long_generation_requests_full_budget_once_and_rejects_truncation(finish_reason):
    requests = []
    ramp = [[index % 256, 127, 255, index // 4] for index in range(1024)]
    arguments = json.dumps({"channel": 0, "samples": ramp})
    call = Call("tf", "set_transfer_function", arguments)

    def handler(request):
        requests.append(request.url.path)
        body = json.loads(request.content)
        if request.url.path == "/tokenize":
            return httpx.Response(200, json={"count": 500, "max_model_len": 16384})
        assert body["max_tokens"] == 15372
        return httpx.Response(200, json={
            "choices": [{"finish_reason": finish_reason, "message": call.as_message()}],
            "usage": {"completion_tokens": 9500 if finish_reason == "tool_calls" else body["max_tokens"]},
        })

    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            model = VLLM(client, "http://fixture.invalid/v1", "synthetic", "fixture")
            messages = [{"role": "user", "content": "Synthetic question."}]
            tools = [{"type": "function", "function": {"name": "set_transfer_function"}}]
            if finish_reason == "length":
                with pytest.raises(OutputLimit) as failure:
                    await model.complete(messages, tools)
                assert failure.value.limit == failure.value.completion_tokens == 15372
            else:
                assert await model.complete(messages, tools) == call
        assert requests == ["/tokenize", "/v1/chat/completions"]

    asyncio.run(check())


def test_input_compaction_keeps_active_goal_and_confirmed_command_without_replay():
    class TightContext:
        name = "fixture-model"
        requests = 0

        async def complete(self, messages, tools, *, response_schema=None):
            if response_schema is not None:
                assert not any(message["content"] == "Historical prompt." for message in messages)
                assert sum(message.get("tool_call_id") == "mutation" for message in messages) == 1
                return '{"arguments":{}}'
            self.requests += 1
            if self.requests == 1:
                return "Older answer."
            if self.requests == 2:
                return Call("state", "get_application_state", "{}")
            if self.requests == 3:
                return Call("mutation", "rotate_view", '{"degrees":15}')
            assert messages[0]["role"] == "system"
            assert any(message["content"] == "Rotate 15 degrees." for message in messages)
            assert sum(message.get("tool_call_id") == "mutation" for message in messages) == 1
            old_prompt = any(message["content"] == "Historical prompt." for message in messages)
            if self.requests == 4:
                assert old_prompt
                raise ContextLimit("input_token_budget", input_tokens=65500, window=65536)
            assert not old_prompt
            if self.requests == 5:
                return Call("state-after-compaction", "get_application_state", '{"extra":1}')
            return "Rotation confirmed."

    with TestClient(create_app(token=TOKEN, model=TightContext())) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json(hello())
            ws.receive_json()
            turn(ws, "old-turn", "Historical prompt.")
            assert ws.receive_json()["text"] == "Older answer."
            assert ws.receive_json()["type"] == "completed"
            turn(ws, "edit-turn", "Rotate 15 degrees.")
            assert (call := ws.receive_json())["name"] == "get_application_state"
            ws.send_json(receipt(call, {"rendererReady": True}))
            assert (call := ws.receive_json())["name"] == "rotate_view"
            ws.send_json(receipt(call, {"ok": True}))
            assert (call := ws.receive_json())["name"] == "get_application_state" and call["arguments"] == {}
            ws.send_json(receipt(call, {"rendererReady": True}))
            assert ws.receive_json()["text"] == "Rotation confirmed."
            assert ws.receive_json()["type"] == "completed"


@pytest.mark.parametrize("tool_name, advertised", [
    ("client_defined_tool", True), ("unadvertised_tool", False), (None, False),
])
def test_truncated_output_logs_generic_metrics_without_logging_values(caplog, tool_name, advertised):
    hidden_text = "SYNTHETIC_PRIVATE_TEXT"
    hidden_reasoning = "SYNTHETIC_PRIVATE_REASONING"
    hidden_arguments = '{"example": "SYNTHETIC_PRIVATE_ARGUMENT'
    message = {"content": hidden_text, "reasoning_content": hidden_reasoning}
    if tool_name is not None:
        message["tool_calls"] = [{"id": "truncated", "function": {"name": tool_name, "arguments": hidden_arguments}}]
    result = {
        "choices": [{"finish_reason": "length", "message": message}],
        "usage": {"completion_tokens": 1024, "completion_tokens_details": {"reasoning_tokens": 100}},
    }
    tools = [{"function": {"name": "client_defined_tool"}}]
    with caplog.at_level("INFO", logger="uvicorn.error.borgvr"):
        with pytest.raises(OutputLimit):
            VLLM.response(result, tools, 1024)
    assert "output_tokens=1024 reasoning_tokens=100" in caplog.text
    assert f"reasoning_chars={len(hidden_reasoning)} text_chars={len(hidden_text)}" in caplog.text
    assert f"tool_calls={int(tool_name is not None)} tools={tool_name if advertised else '-'} " in caplog.text
    assert f"argument_chars={len(hidden_arguments) if tool_name is not None else 0}" in caplog.text
    assert "unadvertised_tool" not in caplog.text
    assert hidden_text not in caplog.text
    assert hidden_reasoning not in caplog.text
    assert "SYNTHETIC_PRIVATE_ARGUMENT" not in caplog.text
