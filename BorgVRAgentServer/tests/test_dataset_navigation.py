import pytest
from pydantic import ValidationError
from pydantic_ai.models.function import FunctionModel
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart

from borgvr_agent.protocol import Hello
from test_agent import STATE, ROTATE, connection, definition, hello, model_steps, open_session, reply, user


SEARCH = definition("search_datasets", {"query": {"type": "string", "maxLength": 256},
                                      "limit": {"type": "integer", "minimum": 1, "maximum": 20}})
OPEN = definition("open_dataset", {"id": {"type": "string"}}, ["id"])
TOOLS = [STATE, SEARCH, OPEN, ROTATE]


def navigation_hello():
    return {**hello(TOOLS), "dataset_id": None, "application_session": True, "dataset_opening": True}


def search_reply(call):
    return reply(call, result={"matches": [{"id": "head", "description": "Bone head test",
                                           "evidence": [{"field": "description", "excerpt": "Bone head test"}]}]})


def opening_reply(call, **transition_overrides):
    return reply(call, result={"rendererReady": True, "dataset": {"id": "head"}},
                 dataset_transition={"dataset_id": "head", "context_id": "opened-head", "tools": TOOLS,
                                     **transition_overrides})


def read_and_search(ws):
    assert ws.receive_json()["type"] == "started"
    state = ws.receive_json()
    assert state["name"] == "get_application_state"
    ws.send_json(reply(state, result={"dataset": None, "rendererReady": False}))
    search = ws.receive_json()
    assert search["name"] == "search_datasets"
    ws.send_json(search_reply(search))


def test_search_without_dataset_never_opens_and_opening_requires_negotiation():
    with connection(model_steps(("search_datasets", {"query": "bone"}), "One metadata match.")) as client, open_session(client) as ws:
        ws.send_json({**navigation_hello(), "dataset_opening": False})
        ready = ws.receive_json()
        assert ready["tools"] == ["get_application_state", "search_datasets"]
        ws.send_json(user())
        assert ws.receive_json()["type"] == "started"
        call = ws.receive_json()
        assert call["name"] == "search_datasets" and call["dataset_id"] is None
        ws.send_json(search_reply(call))
        assert ws.receive_json()["text"] == "One metadata match."
        assert ws.receive_json()["type"] == "completed"


def test_opening_rebuilds_tools_and_continues_the_original_request_without_replay():
    steps = [("get_application_state", {}), ("search_datasets", {"query": "bone"}),
             ("open_dataset", {"id": "head"}), ("get_application_state", {}),
             ("rotate_view", {"axis": [0, 1, 0], "degrees": 10}), "Opened and turned."]
    with connection(model_steps(*steps)) as client, open_session(client) as ws:
        ws.send_json(navigation_hello())
        assert ws.receive_json()["tools"] == ["get_application_state", "search_datasets", "open_dataset"]
        ws.send_json(user())
        read_and_search(ws)
        call = ws.receive_json()
        assert call["name"] == "open_dataset" and call["arguments"] == {"id": "head"}
        ws.send_json(opening_reply(call))
        updated = ws.receive_json()
        assert updated["type"] == "context_updated" and "rotate_view" in updated["tools"]
        current = ws.receive_json()
        assert current["name"] == "get_application_state" and current["dataset_id"] == "head"
        assert current["context_id"] == "opened-head"
        ws.send_json(reply(current, result={"dataset": {"id": "head"}, "rendererReady": True}))
        rotate = ws.receive_json()
        assert rotate["name"] == "rotate_view" and rotate["context_id"] == "opened-head"
        ws.send_json(reply(rotate))
        assert ws.receive_json()["text"] == "Opened and turned."
        assert ws.receive_json()["type"] == "completed"


def test_unseen_ids_cannot_be_opened_even_if_the_model_guesses_one():
    with connection(model_steps(("get_application_state", {}), ("open_dataset", {"id": "guessed"}))) as client, open_session(client) as ws:
        ws.send_json(navigation_hello())
        ws.receive_json()
        ws.send_json(user())
        ws.receive_json()
        state = ws.receive_json()
        ws.send_json(reply(state))
        assert ws.receive_json()["type"] == "error"  # No native open call.


@pytest.mark.parametrize("override", [{"dataset_id": "wrong"}, {"context_id": "opening-1"}])
def test_wrong_opening_receipt_is_rejected(override):
    with connection(model_steps(("get_application_state", {}), ("search_datasets", {}),
                                ("open_dataset", {"id": "head"}))) as client, open_session(client) as ws:
        ws.send_json(navigation_hello())
        ws.receive_json()
        ws.send_json(user())
        read_and_search(ws)
        ws.send_json(opening_reply(ws.receive_json(), **override))
        assert ws.receive_json()["code"] == "invalid_message"


def test_dataset_opening_extension_requires_application_session():
    with pytest.raises(ValidationError):
        Hello.model_validate({**hello(TOOLS), "dataset_opening": True})


def test_old_batched_tool_plan_is_not_executed_after_opening():
    calls = 0

    async def model(messages, info):
        nonlocal calls
        calls += 1
        if calls == 3:
            return ModelResponse(parts=[ToolCallPart("open_dataset", {"id": "head"}, "open"),
                                        ToolCallPart("rotate_view", {"axis": [0, 1, 0], "degrees": 90}, "old-plan")])
        if calls == 5:
            return ModelResponse(parts=[TextPart("Fresh context, no old rotation.")])
        name, args = ("search_datasets", {}) if calls == 2 else ("get_application_state", {})
        return ModelResponse(parts=[ToolCallPart(name, args, str(calls))])

    with connection(FunctionModel(model)) as client, open_session(client) as ws:
        ws.send_json({**navigation_hello(), "dataset_id": "old-volume"})
        ws.receive_json()
        ws.send_json(user())
        read_and_search(ws)
        opening = ws.receive_json()
        assert opening["name"] == "open_dataset"
        ws.send_json(opening_reply(opening))
        assert ws.receive_json()["type"] == "context_updated"
        fresh = ws.receive_json()
        assert fresh["name"] == "get_application_state" and fresh["dataset_id"] == "head"
        ws.send_json(reply(fresh))
        assert ws.receive_json()["text"] == "Fresh context, no old rotation."
        assert ws.receive_json()["type"] == "completed"
