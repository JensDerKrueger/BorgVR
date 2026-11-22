import asyncio
import json
import importlib.util
from pathlib import Path

import httpx
import pytest

from borgvr_next.model import ModelFailure
from diagnose_model import DiagnosticModel, active_runtime_source


def test_synthetic_diagnostic_reports_http_error_without_exposing_token(capsys):
    observed = []
    def handler(request):
        body = json.loads(request.content)
        observed.append(body)
        assert request.headers["Authorization"] == "Bearer synthetic-secret"
        if request.url.path == "/tokenize":
            return httpx.Response(200, json={"count": 42, "max_model_len": 16384})
        return httpx.Response(400, json={"error": {"message": "Rejected parameter; synthetic-secret"}})
    async def check():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
            model = DiagnosticModel(http, "http://fixture.invalid/v1", "synthetic-secret", "fixture", max_output_tokens=128,
                                    thinking_mode="on")
            with pytest.raises(ModelFailure) as failure:
                await model.complete([{"role": "user", "content": "Synthetic test."}], [])
            assert failure.value.status == 400 and failure.value.phase == "generation"
    asyncio.run(check())
    output = capsys.readouterr().out
    assert "Rejected parameter" in output and "[REDACTED]" in output
    assert "synthetic-secret" not in output
    assert observed[-1]["max_tokens"] == 128


def test_diagnostic_never_prints_successful_model_content(capsys):
    async def check():
        def handler(request):
            return httpx.Response(200, json={"private": "not-for-log"})
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
            model = DiagnosticModel(http, "http://fixture.invalid/v1", "synthetic-secret", "fixture")
            await model.exchange("POST", "http://fixture.invalid/v1/chat/completions", phase="generation", seconds=10, body={})
    asyncio.run(check())
    assert "not-for-log" not in capsys.readouterr().out


def test_diagnostic_runs_with_older_agent_constructor(monkeypatch, tmp_path, capsys):
    import borgvr_next.model as runtime
    class LegacyVLLM:
        def __init__(self, http, base_url, token, name, context=65536, *, max_output_tokens=None,
                     generation_timeout=180, thinking_mode="off"):
            self.http, self.token = http, token
        async def complete(self, messages, tools):
            return await self.exchange("POST", "http://fixture.invalid/v1/chat/completions",
                                       phase="generation", seconds=10, body={"messages": messages})
    monkeypatch.setattr(runtime, "VLLM", LegacyVLLM)
    spec = importlib.util.spec_from_file_location("legacy_diagnostic", Path(__file__).resolve().parents[1] / "diagnose_model.py")
    diagnostic = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(diagnostic)
    token = tmp_path / "token"
    token.write_text("synthetic-secret")
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda request:
        httpx.Response(400, json={"error": "Synthetic rejected option"})))
    monkeypatch.setattr(diagnostic.httpx, "AsyncClient", lambda **kwargs: client)
    result = asyncio.run(diagnostic.diagnose({"BORGVR_VLLM_TOKEN_FILE": str(token),
        "BORGVR_VLLM_URL": "http://fixture.invalid/v1", "BORGVR_MODEL": "fixture"}))
    assert result is False
    output = capsys.readouterr().out
    assert "Synthetic rejected option" in output
    assert "synthetic-secret" not in output


@pytest.mark.parametrize("phase,release", [("ready", "a" * 32), ("starting", "a" * 32), ("ready", "../../etc")])
def test_diagnostic_selects_only_ready_development_source(tmp_path, phase, release):
    control, releases = tmp_path / "control", tmp_path / "releases"
    control.mkdir()
    source = releases / ("a" * 32)
    (source / "borgvr_next").mkdir(parents=True)
    (source / "borgvr_next/model.py").write_text("# active model\n")
    record = {"request": "b" * 32, "release": release, "phase": phase}
    for name in ("request.json", "status.json"):
        (control / name).write_text(json.dumps(record))
    if phase == "ready" and release == "a" * 32:
        assert active_runtime_source(control, releases) == source
    else:
        with pytest.raises(ValueError):
            active_runtime_source(control, releases)
