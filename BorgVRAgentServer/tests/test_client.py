import asyncio
import ssl

import httpx
import pytest

import client as client_module


def test_no_websocket_redirects():
    async def check():
        connection = client_module.DirectConnect("wss://localhost:8766/v1/session", proxy=None)
        error = ValueError("test")
        assert connection.process_redirect(error) is error

    asyncio.run(check())


@pytest.mark.parametrize("status,body,error", [
    (302, b"", httpx.HTTPStatusError),
    (200, b"x" * 65537, ValueError),
])
def test_http_client_rejects_redirects_and_large_responses(monkeypatch, status, body, error):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(status, content=body, headers={"Location": "https://other.example.org/readyz"})

    original = httpx.AsyncClient

    def factory(**kwargs):
        assert kwargs["follow_redirects"] is False
        assert kwargs["trust_env"] is False
        return original(**kwargs, transport=httpx.MockTransport(handler))

    monkeypatch.setattr(client_module.httpx, "AsyncClient", factory)
    with pytest.raises(error):
        asyncio.run(client_module.ready("https://localhost:8766", "secret", ssl.create_default_context()))
    assert len(requests) == 1
