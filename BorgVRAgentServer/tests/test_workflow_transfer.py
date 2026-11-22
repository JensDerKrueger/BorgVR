from dataclasses import replace
import json
from uuid import UUID

from fastapi.testclient import TestClient

from borgvr_agent.app import create_app
from borgvr_agent.learner_state import hypotheses_for
from borgvr_agent.workflow_learner import decode_episode
from borgvr_agent.workflow_store import WorkflowStore
from test_agent import SETTINGS, model_steps
from test_workflow_learner import snapshot
from test_workflow_service import PREFIX, auth, payload, send


def deployment(tmp_path, name):
    directory = tmp_path / name
    directory.mkdir(mode=0o700)
    store = WorkflowStore(directory / "workflow.sqlite3")
    device = store.create_profile()
    digest = store.authenticate(auth(device)["Authorization"])
    headers = {**auth(device), "X-BorgVR-Corpus": store.profile(digest)["corpus_id"]}
    return store, headers, TestClient(create_app(replace(SETTINGS, workflow_database=store.path), model_steps()))


def test_portable_state_keeps_pending_hypotheses_and_evidence(tmp_path):
    source, source_headers, source_client = deployment(tmp_path, "source")
    target, target_headers, target_client = deployment(tmp_path, "target")
    endpoint = PREFIX + "/state"
    pair = {"before": snapshot(), "after": snapshot(clip_minimum=[0.25, 0, 0])}
    with source_client as client:
        assert send(client, source_headers, source_headers["X-BorgVR-Corpus"],
                    {**payload(1), "version": 2, "evidence": pair}).status_code == 202
        assert client.get(endpoint, headers=source_headers).status_code == 202
    # A separate worker can finish after all clients disconnect.
    assert WorkflowStore(source.path).process_one()
    with source_client as client:
        state = client.get(endpoint, headers=source_headers).json()["state"]
        assert state["episodes"][0]["evidence"] == pair
        assert state["hypotheses"] and {h["status"] for h in state["hypotheses"]} == {"pending"}
        assert state["hypotheses"][0]["supporting_episode_ids"] == [str(UUID(int=1))]
    with target_client as client:
        assert client.put(endpoint, headers=source_headers, json=state).status_code == 401
        assert client.put(endpoint, headers=target_headers, json=state).json()["imported"] == 1
        assert client.put(endpoint, headers=target_headers, json=state).json()["imported"] == 0
        assert client.get(endpoint, headers=target_headers).status_code == 202
        assert target.process_one()
        assert client.get(endpoint, headers=target_headers).json()["state"] == state

        # Independently gathered examples merge; no overwrite and no premature approval.
        for number in (2, 3):
            assert send(client, target_headers, target_headers["X-BorgVR-Corpus"], payload(number)).status_code == 202
        assert target.process_one()
        merged = client.get(endpoint, headers=target_headers).json()["state"]
        assert len(merged["episodes"]) == 3
        assert {h["status"] for h in merged["hypotheses"]} == {"candidate"}

        state["episodes"][0]["outcome"] = "not_reached"
        assert client.put(endpoint, headers=target_headers, json=state).status_code == 400
        state["hypotheses"] = hypotheses_for(
            [decode_episode(json.dumps(episode).encode()) for episode in state["episodes"]])
        conflict = client.put(endpoint, headers=target_headers, json=state)
        assert conflict.status_code == 409 and conflict.json()["error"] == "episode_conflict"
        assert client.get(endpoint, headers=target_headers).json()["state"] == merged
