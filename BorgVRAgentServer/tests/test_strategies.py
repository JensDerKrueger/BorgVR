import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic_ai.messages import ModelResponse, SystemPromptPart, TextPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel

from borgvr_agent.app import create_app
from borgvr_agent.protocol import ToolDefinition
from borgvr_agent.strategies import MAX_STRATEGY_BYTES, STRATEGY_MARKER, MultilingualEncoder, StrategyIndex, parse_strategies
from test_agent import AUTH, SETTINGS, STATE, definition, hello, open_session, user

SOURCE = Path(__file__).resolve().parents[2] / "AppSupport/Voice/expert-knowledge.toml"


def catalog(*, width=True, image=True, tf=True):
    entries = [STATE, definition("search_datasets"), definition("set_clipping")]
    if image:
        properties = {"max_width": {"type": "integer"}} if width else {}
        entries.extend([definition("capture_screenshot", properties), definition("pick_screenshot_positions")])
    if tf:
        entries.extend([definition("get_transfer_function"), definition("set_transfer_function")])
    return [ToolDefinition.model_validate(entry) for entry in entries]


class CapturingEncoder:
    def __init__(self):
        self.batches = []

    def encode(self, texts):
        self.batches.append(texts)
        return [[1.0, 0.0] for _ in texts]


@pytest.mark.anyio
async def test_filter_context_and_parameters_before_encoding():
    encoder = CapturingEncoder()
    index = StrategyIndex(parse_strategies(SOURCE.read_text()), encoder)
    result = await index.select("find datasets", {"start_menu"}, catalog())
    assert [item["id"] for item in result] == ["dataset.catalog_search"]
    assert len(encoder.batches[-1]) == 2
    candidates = index.candidates({"dataset_ready"}, catalog(width=False, tf=False))
    assert "inspection.interior" in candidates and "inspection.preview" not in candidates
    assert "transfer_function.explore_range" not in candidates
    assert "inspection.interior" not in index.candidates({"dataset_ready"}, catalog(image=False))
    await index.select("find other datasets", {"start_menu"}, catalog())
    assert encoder.batches[-1] == ["query: find other datasets"]


@pytest.mark.parametrize("source", [
    'version = 2',
    'version = 1\n[my.rule]\nsteps = ["No situation or goal."]',
    'version = 1\n[my.rule]\ngoal = "Test"\nsteps = ["Test"]\nserver_command = "unused"',
    " " * (MAX_STRATEGY_BYTES + 1),
])
def test_invalid_bundle_is_rejected(source):
    with pytest.raises(ValueError):
        parse_strategies(source)


def test_negotiated_knowledge_stays_in_its_session_and_out_of_system_policy():
    seen = []
    async def model(messages, _):
        systems = [part.content for message in messages for part in message.parts if isinstance(part, SystemPromptPart)]
        references = [content for message in messages for part in message.parts
                      if isinstance(part, UserPromptPart) and not isinstance(part.content, str)
                      for content in part.content if isinstance(content, str) and content.startswith(STRATEGY_MARKER)]
        assert not any("SESSION_ONLY_RULE" in policy for policy in systems)
        seen.append(references)
        return ModelResponse(parts=[TextPart("Ready")])

    bundle = 'version = 1\n[dataset.look]\ngoal = "Check a dataset"\nsteps = ["SESSION_ONLY_RULE"]'
    app = create_app(SETTINGS, FunctionModel(model), strategy_encoder=CapturingEncoder())
    with TestClient(app) as client:
        assert client.head("/healthz").headers["BorgVR-Expert-Knowledge"] == "1"
        with open_session(client) as first, client.websocket_connect("/v1/session", headers=AUTH) as second:
            for ws, options in [(first, {"expert_knowledge_toml": bundle}), (second, {})]:
                ws.send_json({**hello([STATE]), **options})
                assert ws.receive_json()["type"] == "ready"
                ws.send_json(user())
                assert ws.receive_json()["type"] == "started"
                assert ws.receive_json()["text"] == "Ready"
                assert ws.receive_json()["type"] == "completed"
    assert len(seen[0]) == 1 and "SESSION_ONLY_RULE" in seen[0][0]
    assert seen[1] == []


@pytest.mark.anyio
async def test_real_multilingual_selection():
    directory = os.environ.get("BORGVR_STRATEGY_TEST_ENCODER")
    if not directory:
        pytest.skip("Set BORGVR_STRATEGY_TEST_ENCODER to the installed encoder directory")
    index = StrategyIndex(parse_strategies(SOURCE.read_text()), MultilingualEncoder(Path(directory)))
    pairs = [
        ("inspection.interior", "dataset_ready", "Zeige mir das Innere der Kiwi, ohne sie zu bearbeiten.",
         "Show me a cutaway view so I can see the contents of this fruit."),
        ("inspection.preview", "dataset_ready", "Mach einen kleinen Screenshot mit 100 Pixeln Breite.",
         "Take a low-resolution screenshot for a quick preview."),
        ("dataset.catalog_search", "start_menu", "Welche Datensätze haben wir zum Thema Knochen?",
         "Do we have any datasets of bones in the catalog?"),
        ("transfer_function.explore_range", "dataset_ready", "Hilf mir, unbekannte Wertebereiche mit einer schmalen Transferfunktion zu erkunden.",
         "Help me find the intensity range of this tissue with a narrow transfer function."),
        ("spatial.picking", "dataset_ready", "Wo liegt dieser Punkt im Datensatz in 3D?",
         "Get the 3D position of this visible landmark."),
    ]
    for expected, context, *queries in pairs:
        for query in queries:
            selected = await index.select(query, {context}, catalog())
            assert selected and selected[0]["id"] == expected, (query, selected)
    for query in ("Guten Morgen!", "Good morning!"):
        assert not await index.select(query, {"dataset_ready"}, catalog())
