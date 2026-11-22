import asyncio
import base64
import io
import json
from pathlib import Path

from fastapi.testclient import TestClient
from PIL import Image, ImageDraw
import pytest

from borgvr_next.app import create_app
from borgvr_next.evidence import Evidence
from borgvr_next.learner import process_one
from borgvr_next.model import Call
from borgvr_next.procedures import PREVIEW_ARGS
from test_next_runtime import AUTH, TOKEN, Evaluator, hello, receipt, setup_profiles, turn


ROOT = Path(__file__).resolve().parents[2]
PREVIEW = {
    "name": "capture_tf_preview", "description": "Isolated test preview", "inputSchema": PREVIEW_ARGS,
    "execution": {"kind": "read", "role": "render_image"},
}


def bundle():
    return json.loads((ROOT / "AppSupport/Voice/knowledge-bundle.json").read_text())


def png_for_band(low, high, uniform=False):
    image = Image.new("RGBA", (64, 64))
    draw = ImageDraw.Draw(image)
    for value, rectangle in [(0.13, (0, 0, 31, 63)), (0.81, (32, 0, 63, 63))]:
        if uniform or low <= value < high:
            draw.rectangle(rectangle, fill=(160, 160, 160, 255))
    output = io.BytesIO()
    image.save(output, format="PNG")
    return base64.b64encode(output.getvalue()).decode("ascii")


class ScriptedModel:
    name = "fixture"

    def __init__(self, response=None):
        self.requests = []
        self.response = response

    async def complete(self, messages, tools):
        self.requests.append((messages, tools))
        if self.response is not None and len(self.requests) == 1:
            return self.response
        return "Analysis complete."


@pytest.mark.parametrize("uniform,language,announcement", [
    (True, "en", "I’ll compare a few intensity-band previews without changing your view."),
    (False, "de", "Ich vergleiche kleine Vorschauen verschiedener Intensitätsbereiche."),
])
def test_bundled_sweep_autonomously_compares_previews_and_announces_first(uniform, language, announcement):
    model = ScriptedModel(Call("sweep", "flow_intensity_sweep", json.dumps({"progress_message": announcement})))
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        assert client.head("/healthz").headers["BorgVR-Knowledge-Bundles"] == "1"
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json({**hello(tools=[PREVIEW]), "expert_knowledge_bundle": bundle()})
            ready = ws.receive_json()
            assert ready["tools"] == ["capture_tf_preview"]
            assert ready["knowledge_bundle_status"]["available_procedures"] == ["flow_intensity_sweep"]
            turn(ws, text="Wo tut sich etwas im Wertebereich?" if language == "de" else "Inspect the intensity bands.")
            progress = ws.receive_json()
            assert (progress["type"], progress["final"], progress["text"]) == ("assistant_message", False, announcement)
            previews = []
            while (event := ws.receive_json())["type"] == "tool_call":
                assert len(model.requests) == 1 and event["name"] == "capture_tf_preview"
                args = event["arguments"]
                previews.append((args["low"], args["high"]))
                ws.send_json({**receipt(event, {"width": 64, "height": 64}),
                              "image_png_base64": png_for_band(*previews[-1], uniform)})
            assert (event["type"], event["final"]) == ("assistant_message", True)
            assert ws.receive_json()["type"] == "completed"
    assert previews[:5] == [(i / 5, (i + 1) / 5) for i in range(5)]
    assert len(model.requests) == 2
    assert [item["function"]["name"] for item in model.requests[0][1]] == ["flow_intensity_sweep"]
    messages, _ = model.requests[-1]
    assert len([item for item in messages if isinstance(item["content"], list)]) == 1
    result = json.loads(next(item["content"] for item in messages if item["role"] == "tool"))
    assert result["rendered_previews"] == len(previews)
    if uniform:
        assert len(previews) == 5 and result["stop_reason"] == "stable"
        assert len(result["intervals"]) == 1
    else:
        assert 5 < len(previews) <= 32
        assert {round(value, 2) for low, high in previews for value in (low, high)} - {0, .2, .4, .6, .8, 1}
        assert len([row for row in result["intervals"] if row.get("preview")]) >= 2


def test_unavailable_or_unapproved_flow_cannot_use_preview():
    for tools in ([], [PREVIEW]):
        knowledge = bundle()
        knowledge["entries"][0]["guidance"] = {"revision": 1, "review": "approved", "text": "Review marker."}
        if tools:
            knowledge["entries"][0]["procedure"]["review"] = "pending"
        model = ScriptedModel()
        with TestClient(create_app(token=TOKEN, model=model)) as client:
            with client.websocket_connect("/v1/session", headers=AUTH) as ws:
                ws.send_json({**hello(tools=tools), "expert_knowledge_bundle": knowledge})
                assert ws.receive_json()["knowledge_bundle_status"]["available_procedures"] == []
                turn(ws)
                assert ws.receive_json()["type"] == "assistant_message"
                assert ws.receive_json()["type"] == "completed"
        assert model.requests[0][1] == []
        assert any("Review marker." in message["content"] for message in model.requests[0][0])


def test_short_automation_may_omit_announcement():
    knowledge = bundle()
    flow = knowledge["entries"][0]["procedure"]
    del flow["announcement_hint"]
    flow["program"] = {"steps": [], "yield": {"literal": {"intervals": [], "rendered_previews": 0, "stop_reason": "none"}}}
    model = ScriptedModel(Call("a", "flow_intensity_sweep", "{}"))
    with TestClient(create_app(token=TOKEN, model=model)) as client:
        with client.websocket_connect("/v1/session", headers=AUTH) as ws:
            ws.send_json({**hello(tools=[]), "expert_knowledge_bundle": knowledge})
            assert ws.receive_json()["knowledge_bundle_status"]["available_procedures"] == ["flow_intensity_sweep"]
            turn(ws)
            assert ws.receive_json()["final"] is True
            assert ws.receive_json()["type"] == "completed"
    assert len(model.requests) == 2


def test_announcement_hint_is_not_spoken_and_cancellation_stops_the_sweep():
    for copy_hint in (True, False):
        knowledge = bundle()
        cue = knowledge["entries"][0]["procedure"]["announcement_hint"]
        text = cue if copy_hint else "Ich untersuche die Helligkeitsbereiche."
        model = ScriptedModel(Call("sweep", "flow_intensity_sweep", json.dumps({"progress_message": text})))
        with TestClient(create_app(token=TOKEN, model=model)) as client:
            with client.websocket_connect("/v1/session", headers=AUTH) as ws:
                ws.send_json({**hello(tools=[PREVIEW]), "expert_knowledge_bundle": knowledge})
                assert ws.receive_json()["type"] == "ready"
                turn(ws)
                notice = ws.receive_json()
                assert notice["type"] == "assistant_message" and notice["text"] != cue
                if copy_hint:
                    assert notice["final"] and ws.receive_json()["type"] == "completed"
                    continue
                assert not notice["final"]
                pending = ws.receive_json()
                ws.send_json({"type": "cancel", "request_id": pending["request_id"]})
                assert ws.receive_json()["type"] == "tool_cancel"
                stopped = ws.receive_json()
                assert stopped["type"] == "cancelled" and not stopped["requires_reconnect"]
                assert len(model.requests) == 1


def test_composition_requires_an_approved_matching_version():
    knowledge = bundle()
    child = knowledge["entries"][0]
    first = child["procedure"]
    del first["announcement_hint"]
    first["program"] = {"steps": [], "yield": {"literal": {"intervals": [], "rendered_previews": 0, "stop_reason": "stable"}}}
    parent = {**child, "id": "intensity.compose", "procedure": {**first, "program": {
        "steps": [{"kind": "call", "operation": "procedure.flow_intensity_sweep", "version": 1,
                   "args": {}, "as": "compiled"}], "yield": {"ref": "compiled"}}}}
    knowledge["entries"] = [parent, child]
    for approved in (True, False):
        first["review"] = "approved" if approved else "pending"
        model = ScriptedModel(Call("call", "flow_intensity_compose", "{}") if approved else None)
        with TestClient(create_app(token=TOKEN, model=model)) as client:
            with client.websocket_connect("/v1/session", headers=AUTH) as ws:
                ws.send_json({**hello(tools=[]), "expert_knowledge_bundle": knowledge})
                assert set(ws.receive_json()["knowledge_bundle_status"]["available_procedures"]) == (
                    {"flow_intensity_compose", "flow_intensity_sweep"} if approved else set())
                turn(ws)
                assert ws.receive_json()["final"] and ws.receive_json()["type"] == "completed"
        if approved:
            receipt = next(msg for msg in model.requests[-1][0] if msg["role"] == "tool")
            assert json.loads(receipt["content"])["stop_reason"] == "stable"


def test_observer_checkpoint_transfers_open_hypotheses_and_resumes(tmp_path):
    source_dir, target_dir = tmp_path / "source", tmp_path / "target"
    source_dir.mkdir()
    target_dir.mkdir()
    store, profile, _, headers, other = setup_profiles(source_dir)
    target, target_profile, _, access, target_other = setup_profiles(target_dir)
    events = [{"kind": "goal"}, {"kind": "receipt", "outcome": "confirmed"},
              {"kind": "manual_change", "active": False, "domains": ["transform"]}]
    assert store.submit(profile, "one", "first", events)
    assert asyncio.run(process_one(store, Evaluator()))
    assert store.submit(profile, "two", "second", events)
    assert store.claim() is not None  # Export is permitted while work is leased on the original server.
    route = "/v1/observer/checkpoint"
    with TestClient(create_app(token=TOKEN, model=ScriptedModel(), evidence=store)) as client:
        assert client.get(route, headers=AUTH).status_code == 401
        checkpoint = client.get(route, headers=headers).json()
        assert client.get(route, headers=other).json()["evidence"] == []
    hypothesis = checkpoint["hypotheses"][0]
    assert hypothesis["status"] == "collecting" and len(hypothesis["evidence"]) == 1
    assert len(checkpoint["evidence"]) == 2 and checkpoint["entries"][0]["guidance"]["review"] == "pending"
    with TestClient(create_app(token=TOKEN, model=ScriptedModel(), evidence=target)) as client:
        unlinked = {**checkpoint, "evidence": []}
        assert client.post(route + "/import", headers=access, json=unlinked).status_code == 422
        assert client.post(route + "/import", headers=access, json=checkpoint).json()["status"] == "imported"
        assert client.post(route + "/import", headers=access, json=checkpoint).json()["status"] == "unchanged"
        assert client.post(route + "/import", headers=access, json={**checkpoint, "revision": 99}).status_code == 409
        assert client.get(route, headers=target_other).json()["evidence"] == []
    assert asyncio.run(process_one(Evidence(target.path), Evaluator()))
    resumed = target.read_checkpoint(target_profile)
    assert resumed["lineage_id"] == checkpoint["lineage_id"] and resumed["revision"] > checkpoint["revision"]
    assert {item["id"] for item in resumed["evidence"]} == {item["id"] for item in checkpoint["evidence"]}
    assert len(resumed["hypotheses"][0]["evidence"]) == 2


def test_learner_can_return_a_procedure_but_cannot_approve_it(tmp_path):
    store, profile, _, _, _ = setup_profiles(tmp_path)

    class Author(Evaluator):
        async def complete(self, messages, tools):
            answer = await super().complete(messages, tools)
            if "audit" not in messages[0]["content"]:
                data = json.loads(answer)
                data["hypotheses"][0]["procedure"] = bundle()["entries"][0]["procedure"]
                assert data["hypotheses"][0]["procedure"]["review"] == "approved"
                return json.dumps(data)
            return answer

    events = [{"kind": "goal"}, {"kind": "receipt", "outcome": "confirmed"},
              {"kind": "manual_change", "active": False, "domains": ["transform"]}]
    assert store.submit(profile, "source", "request", events)
    assert asyncio.run(process_one(store, Author()))
    entry = store.read_checkpoint(profile)["entries"][0]
    assert entry["procedure"]["review"] == entry["guidance"]["review"] == "pending"
    assert entry["procedure"]["language"] == "borgvr-flow-v1"
