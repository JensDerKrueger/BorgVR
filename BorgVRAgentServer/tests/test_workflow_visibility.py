import io
import json
from collections import Counter

from PIL import Image
import pytest

from borgvr_agent.workflow_visibility import (
    UNKNOWN, fixture, metrics, panel, predictions, prompt, single_pair_fixtures,
)


def test_rendered_mask_ground_truth_and_hidden_labels():
    color = (47, 237, 245)
    visible, visible_label = panel(23, False)
    hidden, hidden_label = panel(23, True)
    assert (visible_label, hidden_label) == ("visible", "hidden")
    # Both images contain the same-color decoy. The target adds a separate region.
    assert 0 < hidden.get_flattened_data().count(color) < visible.get_flattened_data().count(color)
    expected, image = fixture(0)
    assert fixture(0) == (expected, image)
    assert Image.open(io.BytesIO(image)).size == (612, 566)
    assert Counter(expected.values()) == {
        ("hidden", "visible"): 3, ("visible", "visible"): 1, ("hidden", "hidden"): 1,
        ("visible", "hidden"): 1,
    }
    cases = list(single_pair_fixtures())
    assert len(cases) == 6 and all(len(labels) == 1 for labels, _ in cases)
    assert all(set(labels).isdisjoint(expected) for labels, _ in cases)
    assert "capture_screenshot" not in prompt(expected, False)
    assert "capture_screenshot" in prompt(expected, True)


def test_visibility_scoring_distinguishes_abstention_and_missing_rows():
    expected, _ = fixture(0)
    answer = {**expected, "A1": UNKNOWN, "A2": ("hidden", "visible")}
    del answer["A3"]
    assert metrics(answer, expected) == {
        "cases": 6, "correct_pairs": 3, "newly_visible_detected": 2,
        "false_newly_visible": 1, "correct_not_newly_visible": 1, "abstained": 1, "unscored": 1,
    }
    assert predictions("```json\n" + json.dumps(expected) + "\n```", expected) == expected


@pytest.mark.parametrize("raw", [
    '{"C1":["visible","hidden"],"C1":["hidden","visible"]}',
    '{"C2":["visible","hidden"]}',
    '{"C1":["maybe","visible"]}',
    '{"C1":["visible"]}',
    '{"C1":["visible","hidden"],"confidence":1}',
])
def test_visibility_parser_rejects_invalid_or_unexpected_responses(raw):
    with pytest.raises(ValueError):
        predictions(raw, {"C1"})
