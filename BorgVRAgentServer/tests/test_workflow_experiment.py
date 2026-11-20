import json

import pytest

from borgvr_agent.workflow_experiment import (
    direct_endpoint, evidence_baseline, model_hypotheses, model_prompt, score, synthetic_cases,
)


def hypothesis(condition, effect, *cases):
    return {"condition": condition, "effect": effect, "cases": [f"case-{i}" for i in cases]}


def response(*rows):
    return json.dumps({"hypotheses": rows})


def test_benchmark_keeps_test_examples_and_ids_out_of_prompt():
    training, test = synthetic_cases()
    prompt = model_prompt(training)
    data = json.loads(prompt.split("Evidence records to analyze follow:\n")[1])
    assert len(data) == len(training)
    assert all(case.id not in prompt for case in training)
    assert all(row["before"] not in [before for before, _ in test] for row in data)
    assert score({}, test)["missed_effects"] == 4
    numeric = evidence_baseline(training)
    assert numeric == {"unclipped": "tighten_x", "z_clipped": "release_z"}
    assert score(numeric, test) == dict(total=8, correct_effects=4, correct_abstentions=4,
                                       wrong_or_unsupported_effects=0, missed_effects=0)


def test_model_proposals_require_consistent_repeated_evidence():
    training, _ = synthetic_cases()
    raw = response(hypothesis("unclipped", "tighten_x", 1, 2, 3),
                   hypothesis("z_clipped", "release_z", 4, 5, 6),
                   hypothesis("y_clipped", "tighten_y", 7, 8))
    assert model_hypotheses("```json\n" + raw + "\n```", training) == ({
        "unclipped": "tighten_x", "z_clipped": "release_z",
    }, 1)
    assert model_hypotheses(response(hypothesis("unclipped", "tighten_y", 1, 2, 3)), training) == ({}, 1)
    assert model_hypotheses(response(hypothesis("z_clipped", "release_z", 1, 2, 3)), training) == ({}, 1)


@pytest.mark.parametrize("raw", [
    response(hypothesis("unclipped", "tighten_x", 1, 1, 1)),
    response(hypothesis("unclipped", "tighten_x", 1, 2, 9)),
    response(hypothesis("unclipped", "tighten_x", 1, 2, 3),
             hypothesis("unclipped", "tighten_y", 1, 2, 3)),
    '{"hypotheses":[],"hypotheses":[]}',
    '{"hypotheses":[],"commands":[]}',
    "explanation before {}".format(response()),
])
def test_rejects_ambiguous_or_out_of_scope_model_results(raw):
    training, _ = synthetic_cases()
    with pytest.raises(ValueError):
        model_hypotheses(raw, training)


@pytest.mark.parametrize("url", [
    "http://example.invalid/v1", "https://user@example.invalid/v1",
    "https://example.invalid/v2", "https://example.invalid/v1?key=value",
])
def test_model_credentials_only_go_to_explicit_direct_endpoint(url):
    with pytest.raises(ValueError):
        direct_endpoint(url)
    assert direct_endpoint("http://vllm:8000/v1") == "http://vllm:8000/v1/chat/completions"
    assert direct_endpoint("https://model.example.invalid/v1/") == "https://model.example.invalid/v1/chat/completions"
