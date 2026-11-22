import asyncio
import json

import httpx
import pytest

from borgvr_next.model import ModelFailure
from diagnose_model import DiagnosticModel


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
                                    thinking_mode="on", reasoning_parser="mistral")
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
