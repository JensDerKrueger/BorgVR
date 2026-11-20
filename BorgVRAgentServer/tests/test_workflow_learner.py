import json
import os
from pathlib import Path
import subprocess
import sys
from uuid import UUID

import pytest

from borgvr_agent.workflow_learner import MAX_FILE_BYTES, Episode, find_patterns, load_episode


def payload(**fields):
    return {"version": 1, "id": str(UUID(int=1)).upper(), "goal": "expose_region",
            "actions": ["clipping", "transform"], "outcome": "reached", "end": "finished", **fields}


@pytest.mark.parametrize("overrides", [
    {"version": True}, {"id": "bad"}, {"goal": "unlisted"}, {"actions": ["clipping", "clipping"]},
    {"actions": ["screenshot"]}, {"dataset_id": "private"}, {"end": "interrupted"},
    {"outcome": {}}, {"actions": []},
])
def test_rejects_invalid_exports(tmp_path, overrides):
    path = tmp_path / "episode.json"
    path.write_text(json.dumps(payload(**overrides)))
    with pytest.raises(ValueError):
        load_episode(path)


def test_rejects_duplicate_keys_and_large_files(tmp_path):
    path = tmp_path / "episode.json"
    path.write_text('{"version": 1, "version": 1}')
    with pytest.raises(ValueError, match="Duplicate"):
        load_episode(path)
    path.write_bytes(b" " * (MAX_FILE_BYTES + 1))
    with pytest.raises(ValueError, match="size"):
        load_episode(path)


def test_one_case_and_repeated_import_do_not_become_a_pattern(tmp_path):
    path = tmp_path / "episode.json"
    path.write_text(json.dumps(payload()))
    case = load_episode(path)
    assert find_patterns([case])["patterns"] == []
    with pytest.raises(ValueError, match="duplicate"):
        find_patterns([case, case, case])


def snapshot(**fields):
    return {"clip_minimum": [0, 0, 0], "clip_maximum": [1, 1, 1], "rotation": [0, 0, 0, 1], **fields}


def test_v2_evidence_requires_two_allowed_snapshots(tmp_path):
    path = tmp_path / "episode.json"
    before, after = snapshot(), snapshot(clip_minimum=[0.25, 0, 0])
    pair = {"before": before, "after": after}
    path.write_text(json.dumps(payload(version=2, evidence=pair)))
    assert load_episode(path).evidence == pair
    for fields in [
        {"version": 1, "evidence": pair},
        {"version": 2},
        {"version": 2, "evidence": {"before": before}},
        {"version": 2, "evidence": pair, "end": "interrupted", "outcome": "unknown"},
        *({"version": 2, "evidence": {"before": before, "after": invalid}} for invalid in [
            snapshot(dataset_id="private"), snapshot(screenshot="private"),
            snapshot(clip_minimum=[0, 0, float("nan")]), snapshot(clip_maximum=[1, True, 1]),
            snapshot(clip_minimum=[1, 0, 0], clip_maximum=[0.5, 1, 1]),
            snapshot(rotation=[0, 0, 0, 0]),
        ]),
    ]:
        path.write_text(json.dumps(payload(**fields)))
        with pytest.raises(ValueError):
            load_episode(path)


def test_scope_alternatives_and_outcomes_remain_separate():
    c, t, f = "clipping", "transform", "transfer_function"
    cases = [
        Episode("1", "expose_region", (c, t), "reached", "finished"),
        Episode("2", "expose_region", (c, t, f), "unknown", "finished"),
        Episode("3", "expose_region", (c, t), "not_reached", "finished"),
        Episode("4", "expose_region", (c,), "reached", "finished"),
        Episode("5", "expose_region", (t, c), "reached", "finished"),
        Episode("6", "inspect_values", (f,), "reached", "finished"),
        Episode("7", "expose_region", (c, t), "unknown", "interrupted"),
        Episode("8", "unspecified", (c, t), "unknown", "finished"),
        Episode("9", "expose_region", (c, t), "unknown", "limit"),
    ]
    report = find_patterns(cases)
    assert report["ignored"] == {"interrupted": 1, "unknown_goal": 1, "limit": 1}
    first, opening = report["patterns"]
    assert first["opening_sequence"] == [c] and first["support"] == 4
    assert opening == {
        "goal": "expose_region", "opening_sequence": [c, t], "support": 3, "total": 5,
        "examples": ["1", "2", "3"], "counterexamples": ["4", "5"],
        "self_reported_outcomes": {
            "matching": {"reached": 1, "not_reached": 1, "unknown": 1},
            "other": {"reached": 2, "not_reached": 0, "unknown": 0},
        },
    }
    assert report == find_patterns(list(reversed(cases)))


def test_cli_emits_standalone_json_and_does_not_modify_corpus(tmp_path):
    paths = [tmp_path / f"{index}.json" for index in range(3)]
    for index, path in enumerate(paths):
        path.write_text(json.dumps(payload(id=str(UUID(int=index + 10)).upper())))
    originals = [path.read_bytes() for path in paths]
    root = Path(__file__).resolve().parents[1]
    run = subprocess.run([sys.executable, "-m", "borgvr_agent.workflow_learner", *paths],
                         cwd=root, capture_output=True, check=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
    assert len(json.loads(run.stdout)["patterns"]) == 2
    assert [path.read_bytes() for path in paths] == originals
    assert sorted(tmp_path.iterdir()) == paths
