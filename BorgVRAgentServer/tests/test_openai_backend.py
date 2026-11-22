import base64
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from openai import AsyncOpenAI
from pydantic_ai.messages import BinaryContent, ModelRequest, SystemPromptPart, UserPromptPart
from pydantic_ai.models import ModelRequestParameters
from pydantic_ai.models.openai import OpenAIResponsesModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.tools import ToolDefinition

from borgvr_agent import app
from model_config import OpenAIConfig


def openai_settings(monkeypatch, tmp_path):
    token, key = tmp_path / "token", tmp_path / "openai_key"
    token.write_text("a" * 64)
    key.write_text("sk-test-" + "b" * 64)
    monkeypatch.setenv("BORGVR_LLM_BACKEND", "openai")
    monkeypatch.setenv("BORGVR_TOKEN_FILE", str(token))
    monkeypatch.setenv("BORGVR_OPENAI_KEY_FILE", str(key))
    monkeypatch.setenv("BORGVR_VLLM_TOKEN_FILE", str(tmp_path / "no-vllm-token"))
    monkeypatch.delenv("BORGVR_OPENAI_MODEL", raising=False)
    return app.Settings.from_env()


def test_default_backend_does_not_require_openai_key(monkeypatch, tmp_path):
    token = tmp_path / "token"
    token.write_text("a" * 64)
    monkeypatch.delenv("BORGVR_LLM_BACKEND", raising=False)
    monkeypatch.setenv("BORGVR_TOKEN_FILE", str(token))
    monkeypatch.setenv("BORGVR_VLLM_TOKEN_FILE", str(token))
    monkeypatch.setenv("BORGVR_OPENAI_KEY_FILE", str(tmp_path / "no-openai-key"))
    monkeypatch.setenv("BORGVR_OPENAI_REASONING_EFFORT", "low")
    settings = app.Settings.from_env()
    assert settings.backend == "vllm"
    assert "openai_reasoning_effort" not in settings.inference.request_settings()
    assert settings.inference.request_settings()["extra_body"]["chat_template_kwargs"] == {"enable_thinking": False}


@pytest.mark.parametrize("status", (200, 401, 404))
def test_openai_model_ready_uses_only_official_api(monkeypatch, tmp_path, status):
    monkeypatch.setenv("BORGVR_OPENAI_REASONING_EFFORT", "low")
    settings = openai_settings(monkeypatch, tmp_path)
    assert settings.vllm_token == ""
    assert settings.openai_key not in repr(settings)
    seen = []

    def handle(request):
        seen.append(request)
        return httpx.Response(status, json={"id": settings.model, "object": "model", "owned_by": "openai", "created": 0})

    def mock_client(**kwargs):
        assert kwargs["base_url"] == "https://api.openai.com/v1"
        assert kwargs["api_key"] == settings.openai_key
        return AsyncOpenAI(**{**kwargs, "http_client": httpx.AsyncClient(transport=httpx.MockTransport(handle))})

    monkeypatch.setattr(app, "AsyncOpenAI", mock_client)
    with TestClient(app.create_app(settings)) as client:
        assert client.get("/readyz").status_code == 401
        assert not seen
        response = client.get("/readyz", headers={"Authorization": f"Bearer {settings.token}"})
        if status == 200:
            assert response.status_code == 200
            assert response.json()["agent_context_tokens"] == settings.inference.context
            assert response.json()["reasoning_effort"] == "low"
            assert "model_context_tokens" not in response.json()
        else:
            assert response.status_code == 503
            assert response.json() == {"status": "model_unavailable"}
        assert [str(request.url) for request in seen] == [f"https://api.openai.com/v1/models/{settings.model}"]


def test_openai_reasoning_effort_configuration():
    assert "openai_reasoning_effort" not in OpenAIConfig.from_env({}).request_settings()
    assert "openai_reasoning_effort" not in OpenAIConfig.from_env(
        {"BORGVR_OPENAI_REASONING_EFFORT": ""}).request_settings()
    with pytest.raises(ValueError, match="Expected one of"):
        OpenAIConfig.from_env({"BORGVR_OPENAI_REASONING_EFFORT": "fast"})


@pytest.mark.anyio
@pytest.mark.parametrize("effort", ("low", "medium"))
async def test_responses_use_same_image_tools_and_effort_for_token_count_and_generation(effort):
    config = OpenAIConfig.from_env({"BORGVR_OPENAI_MODEL": "gpt-6.2-sol",
                                    "BORGVR_OPENAI_REASONING_EFFORT": effort})
    seen = {}

    def handle(request):
        body = seen[request.url.path] = json.loads(request.content)
        if request.url.path == "/v1/responses/input_tokens":
            return httpx.Response(200, json={"object": "response.input_tokens", "input_tokens": 42})
        assert request.url.path == "/v1/responses"
        return httpx.Response(200, json={"id": "resp_test", "object": "response", "created_at": 0,
                                        "model": body["model"], "status": "completed", "output": [{
                                            "type": "function_call", "id": "fc_test", "call_id": "call_test",
                                            "name": "get_application_state", "arguments": "{}",
                                        }]})

    async with AsyncOpenAI(api_key="unused", http_client=httpx.AsyncClient(transport=httpx.MockTransport(handle))) as client:
        model = OpenAIResponsesModel(config.model, provider=OpenAIProvider(openai_client=client))
        png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jVn0AAAAASUVORK5CYII=")
        messages = [ModelRequest(parts=[SystemPromptPart("test policy"),
                                        UserPromptPart(["read the synthetic image", BinaryContent(png, media_type="image/png")])])]
        parameters = ModelRequestParameters(function_tools=[ToolDefinition(
            name="get_application_state", parameters_json_schema={"type": "object", "properties": {}})])
        settings = config.request_settings()
        assert (await model.count_tokens(messages, settings, parameters)).input_tokens == 42
        response = await model.request(messages, settings, parameters)
        assert response.parts[0].tool_name == "get_application_state"

    count, generation = (seen[path] for path in ("/v1/responses/input_tokens", "/v1/responses"))
    assert count["input"] == generation["input"]
    assert count["tools"] == generation["tools"]
    assert count["reasoning"] == generation["reasoning"]
    assert generation["reasoning"]["effort"] == effort
    assert "data:image/png;base64," in json.dumps(count["input"])
    assert generation["store"] is False
    assert generation["parallel_tool_calls"] is False
    assert "temperature" not in generation
    assert "chat_template_kwargs" not in generation
