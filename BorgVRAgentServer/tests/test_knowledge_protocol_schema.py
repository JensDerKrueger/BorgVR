"""Shape checks for the proposed wire format, not its future runtime policy."""

import json
from pathlib import Path

from jsonschema import Draft202012Validator
import pytest


SCHEMA = Path(__file__).resolve().parents[1] / "schemas/knowledge-v1.schema.json"
VALIDATOR = Draft202012Validator(json.loads(SCHEMA.read_text(encoding="utf-8")))


@pytest.fixture
def entry():
    return {
        "id": "intensity.inspect_bands", "revision": 1, "source": "learner",
        "situation": "The visible intensity intervals are unknown.",
        "goal": "Compare isolated previews.",
        "guidance": {"revision": 1, "review": "approved", "text": "Keep the camera fixed."},
        "procedure": {
            "revision": 1, "review": "pending", "language": "borgvr-flow-v1",
            "input_schema": {"type": "object"}, "output_schema": {"type": "array"},
            "limits": {"max_calls": 10, "timeout_seconds": 30},
            "program": {
                "steps": [{
                    "kind": "for_each", "items": {"ref": "input.bands"}, "item": "band", "limit": 5,
                    "body": {
                        "steps": [{
                            "kind": "if", "test": {"ref": "band.enabled"}, "as": "result",
                            "then": {
                                "steps": [{
                                    "kind": "call", "operation": "app.render_preview", "version": 1,
                                    "args": {"band": {"ref": "band"}}, "as": "preview",
                                }],
                                "yield": {"ref": "preview"},
                            },
                            "else": {"steps": [], "yield": {"literal": None}},
                        }],
                        "yield": {"ref": "result"},
                    },
                    "as": "previews",
                }],
                "yield": {"ref": "previews"},
            },
        },
    }


def bundle(entry):
    return {"kind": "knowledge_bundle", "version": 1, "entries": [entry]}


def test_protocol_schema_is_valid():
    Draft202012Validator.check_schema(VALIDATOR.schema)


@pytest.mark.parametrize("guidance,procedure", [(True, True), (True, False), (False, True)])
def test_parts_are_optional_and_reviewed_separately(entry, guidance, procedure):
    if not guidance:
        del entry["guidance"]
    if not procedure:
        del entry["procedure"]
    assert VALIDATOR.is_valid(bundle(entry))


def test_entry_needs_at_least_one_part(entry):
    del entry["guidance"]
    del entry["procedure"]
    assert not VALIDATOR.is_valid(bundle(entry))


def test_whole_entry_approval_cannot_replace_part_review(entry):
    del entry["procedure"]["review"]
    entry["review"] = "approved"
    assert not VALIDATOR.is_valid(bundle(entry))


@pytest.mark.parametrize("key,value", [("language", "python"), ("program", "import cv2")])
def test_procedures_do_not_carry_python(entry, key, value):
    entry["procedure"][key] = value
    assert not VALIDATOR.is_valid(bundle(entry))


def test_loop_requires_a_bound(entry):
    del entry["procedure"]["program"]["steps"][0]["limit"]
    assert not VALIDATOR.is_valid(bundle(entry))


def test_checkpoint_carries_unfinished_hypotheses_and_evidence(entry):
    checkpoint = {
        "kind": "learner_checkpoint", "version": 1, "lineage_id": "study-01", "revision": 3,
        "entries": [entry],
        "hypotheses": [{
            "id": "bands-need-refining", "revision": 2, "claim": "A local difference preserves small details.",
            "status": "testing", "next_steps": ["Compare on a held-out volume."],
            "entry": {"id": entry["id"], "revision": entry["revision"]},
            "evidence": [{"id": "case-01", "relation": "supports"}, {"id": "case-02", "relation": "contradicts"}],
        }],
        "evidence": [
            {"id": "case-01", "episode_id": "volume-01", "kind": "fixture_result",
             "summary": "The small feature remained visible.", "observation": {"found": True}},
            {"id": "case-02", "episode_id": "volume-02", "kind": "fixture_result",
             "summary": "The small feature was missed.", "observation": {"found": False}},
        ],
    }
    assert VALIDATOR.is_valid(checkpoint)
    del checkpoint["evidence"]
    assert not VALIDATOR.is_valid(checkpoint)
