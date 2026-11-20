from dataclasses import replace
import json
import os
from pathlib import Path
import threading
import time
from uuid import UUID

from fastapi.testclient import TestClient
import pytest

from borgvr_agent.app import create_app
from borgvr_agent.workflow_learner import MAX_EPISODES, MAX_FILE_BYTES, decode_episode, find_patterns
from borgvr_agent.workflow_store import WorkflowError, WorkflowStore
from test_agent import AUTH, SETTINGS, model_steps
from test_workflow_learner import snapshot

PREFIX = "/v1/workflow"


@pytest.fixture
def store(tmp_path):
    directory = tmp_path / "private"
    directory.mkdir(mode=0o700)
    return WorkflowStore(directory / "workflow.sqlite3")


def auth(device):
    return {"Authorization": f"Bearer {device['token']}"}


def payload(number, actions=("clipping", "transform")):
    return {"version": 1, "id": str(UUID(int=number)), "goal": "expose_region",
            "actions": list(actions), "outcome": "reached", "end": "finished"}


def send(client, credentials, corpus, data):
    return client.post(PREFIX + "/episodes", headers={**credentials, "X-BorgVR-Corpus": corpus}, json=data)


def wait_report(client, credentials):
    for _ in range(100):
        reply = client.get(PREFIX + "/report", headers=credentials).json()
        if reply["status"] == "ready":
            return reply["report"]
        time.sleep(0.02)
    pytest.fail("Workflow report did not become ready")


def test_service_is_absent_by_default():
    with TestClient(create_app(SETTINGS, model_steps("unused"))) as client:
        assert client.get(PREFIX + "/profile", headers=AUTH).status_code == 404


def test_two_profiles_same_server_id_do_not_mix(store):
    a, b = store.create_profile(), store.create_profile()
    a2 = store.add_device(a["profile_id"])
    with TestClient(create_app(replace(SETTINGS, workflow_database=store.path), model_steps("unused"))) as client:
        assert client.get(PREFIX + "/profile", headers=AUTH).status_code == 401
        identity = client.get(PREFIX + "/profile", headers=auth(a)).json()
        ca = identity["corpus_id"]
        cb = client.get(PREFIX + "/profile", headers=auth(b)).json()["corpus_id"]
        assert client.get(PREFIX + "/profile", headers=auth(a2)).json() == {
            **identity, "device_id": a2["device_id"]
        }
        assert send(client, auth(b), ca, payload(1)).json() == {"error": "corpus_changed"}
        assert send(client, auth(a), ca, {**payload(1), "profile_id": b["profile_id"]}).status_code == 400
        for number in range(1, 4):
            assert send(client, auth(a), ca, payload(number)).status_code == 202
        assert send(client, auth(b), cb, payload(1, ("volume",))).status_code == 202
        assert send(client, auth(a2), ca, payload(1)).json()["created"] is False
        assert send(client, auth(a2), ca, payload(1, ("volume",))).json() == {"error": "episode_conflict"}
        assert wait_report(client, auth(a2))["patterns"][0]["opening_sequence"] == ["clipping"]
        assert wait_report(client, auth(b))["episodes"] == 1
        denied = client.delete(PREFIX + "/corpus", headers={**auth(b), "X-BorgVR-Corpus": ca})
        assert denied.status_code == 409
        assert store.revoke_device(a["profile_id"], a2["device_id"])
        assert client.get(PREFIX + "/report", headers=auth(a2)).status_code == 401
        assert client.get(PREFIX + "/report", headers=auth(a)).status_code == 200


def test_worker_resumes_after_restart_and_clear_invalidates_in_flight_result(store):
    device = store.create_profile()
    digest = store.authenticate(auth(device)["Authorization"])
    corpus = store.profile(digest)["corpus_id"]
    assert store.upload(digest, corpus, decode_episode(json.dumps(payload(1)).encode()))
    restarted = WorkflowStore(store.path)
    assert restarted.report(digest)["status"] == "queued"
    analyzing, resume = threading.Event(), threading.Event()

    def analyze(rows):
        analyzing.set()
        assert resume.wait(5)
        return find_patterns(rows)

    worker = threading.Thread(target=restarted.process_one, args=(analyze,))
    worker.start()
    try:
        assert analyzing.wait(5)
        replacement = store.clear(digest, corpus)["corpus_id"]
        with pytest.raises(WorkflowError, match="corpus_changed"):
            store.upload(digest, corpus, decode_episode(json.dumps(payload(1)).encode()))
        assert store.upload(digest, replacement, decode_episode(json.dumps(payload(2)).encode()))
    finally:
        resume.set()
        worker.join(5)
    assert not worker.is_alive()
    assert store.report(digest)["status"] == "queued"
    assert store.process_one()
    assert store.report(digest)["report"]["episodes"] == 1
    assert not store.process_one()


def test_evidence_upload_round_trips_without_leaking_into_baseline_report(store):
    device = store.create_profile()
    digest = store.authenticate(auth(device)["Authorization"])
    corpus = store.profile(digest)["corpus_id"]
    pair = {"before": snapshot(), "after": snapshot(clip_minimum=[0.25, 0, 0])}
    data = {**payload(1), "version": 2, "evidence": pair}
    with TestClient(create_app(replace(SETTINGS, workflow_database=store.path), model_steps("unused"))) as client:
        assert send(client, auth(device), corpus, data).status_code == 202
        assert send(client, auth(device), corpus, data).json()["created"] is False
        assert send(client, auth(device), corpus, payload(1)).json() == {"error": "episode_conflict"}
        assert send(client, auth(device), corpus, {**data, "evidence": {**pair, "image": "private"}}).status_code == 400
        assert send(client, auth(device), corpus, {
            "version": 1, "demonstration": data,
            "screenshots": {"before_png_base64": "AA==", "after_png_base64": "AA=="},
        }).status_code == 400
        assert wait_report(client, auth(device))["episodes"] == 1

    assert store.upload(digest, corpus, decode_episode(json.dumps(payload(2)).encode()))
    def analyze(rows):
        episodes = {row.id: row for row in rows}
        assert episodes[payload(1)["id"]].evidence == pair
        assert episodes[payload(2)["id"]].evidence is None
        return find_patterns(rows)

    assert store.process_one(analyze)
    report = json.dumps(store.report(digest))
    assert "clip_minimum" not in report and "rotation" not in report


def test_clear_does_not_revive_deleted_corpus_or_affect_another_user(store):
    a, b = store.create_profile(), store.create_profile()
    digest_b = store.authenticate(auth(b)["Authorization"])
    corpus_b = store.profile(digest_b)["corpus_id"]
    with TestClient(create_app(replace(SETTINGS, workflow_database=store.path), model_steps("unused"))) as client:
        corpus_a = client.get(PREFIX + "/profile", headers=auth(a)).json()["corpus_id"]
        assert send(client, auth(a), corpus_a, payload(1)).status_code == 202
        assert send(client, auth(b), corpus_b, payload(1)).status_code == 202
        result = client.delete(PREFIX + "/corpus", headers={**auth(a), "X-BorgVR-Corpus": corpus_a})
        assert result.status_code == 200 and result.json()["corpus_id"] != corpus_a
        assert client.get(PREFIX + "/report", headers=auth(a)).json()["status"] == "empty"
        assert send(client, auth(a), corpus_a, payload(1)).status_code == 409
        assert wait_report(client, auth(b))["episodes"] == 1


def test_request_bounds_and_storage_limit(store):
    device = store.create_profile()
    digest = store.authenticate(auth(device)["Authorization"])
    corpus = store.profile(digest)["corpus_id"]
    with TestClient(create_app(replace(SETTINGS, workflow_database=store.path), model_steps("unused"))) as client:
        headers = {**auth(device), "X-BorgVR-Corpus": corpus, "Content-Type": "application/json"}
        bad_body = b" " * (MAX_FILE_BYTES + 1)
        assert client.post(PREFIX + "/episodes", headers=AUTH, content=bad_body).status_code == 401
        assert client.post(PREFIX + "/episodes", headers=headers, content=bad_body).status_code == 413
        assert client.post(PREFIX + "/episodes", headers=headers, content=iter([bad_body])).status_code == 413
        assert client.post(PREFIX + "/episodes", headers={**headers, "Content-Length": "-1"}, content=b"{}").status_code == 400
        assert client.get(PREFIX + "/profile", headers={**headers, "Origin": "https://test.invalid"}).status_code == 400
        assert client.get(PREFIX + "/profile?profile_id=x", headers=headers).status_code == 400
    for number in range(MAX_EPISODES):
        store.upload(digest, corpus, decode_episode(json.dumps(payload(number)).encode()))
    with pytest.raises(WorkflowError, match="episode_limit"):
        store.upload(digest, corpus, decode_episode(json.dumps(payload(MAX_EPISODES)).encode()))


def test_database_is_private_and_stores_no_bearer_secrets(store, tmp_path):
    device = store.create_profile()
    assert device["token"].encode() not in store.path.read_bytes()
    assert (store.path.stat().st_mode & 0o777) == 0o600
    unsafe = tmp_path / "public"
    unsafe.mkdir()
    os.chmod(unsafe, 0o755)
    with pytest.raises(ValueError, match="private"):
        WorkflowStore(unsafe / Path("test.sqlite3"))
