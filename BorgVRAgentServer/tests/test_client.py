import asyncio
import base64
import io
import json
import ssl

import httpx
import pytest
from PIL import Image

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


@pytest.mark.parametrize("color,omit_tool,alpha,success", [("red", False, False, True),
    ("red", False, True, True), ("blue", False, False, False), ("red", True, False, False)])
def test_real_capability_check_requires_tools_png_and_correct_color(monkeypatch, color, omit_tool, alpha, success):
    class Socket:
        async def send(self, raw):
            data = json.loads(raw)
            match data["type"]:
                case "hello":
                    self.context = data["context_id"]
                    assert {tool["name"] for tool in data["tools"]} == {"get_application_state", "capture_screenshot"}
                    self.queue = [{"type": "ready", "capabilities": {"vision": True}}]
                case "user_message":
                    self.request = data["request_id"]
                    self.queue = self.final() if omit_tool else [self.tool("get_application_state")]
                case "tool_result":
                    if "image_png_base64" in data:
                        image = Image.open(io.BytesIO(base64.b64decode(data["image_png_base64"])))
                        assert image.getpixel((0, 0)) == ((255, 0, 0, 255) if alpha else (255, 0, 0))
                        self.queue = self.final()
                    else:
                        self.queue = [self.tool("capture_screenshot")]

        def final(self):
            return [{"type": "assistant_message", "request_id": self.request, "final": True, "text": color},
                    {"type": "completed", "request_id": self.request}]

        def tool(self, name):
            return {"type": "tool_call", "request_id": self.request, "call_id": name, "name": name,
                    "arguments": {"include_alpha": True} if name == "capture_screenshot" and alpha else {},
                    "context_id": self.context, "dataset_id": "server-check"}

        async def recv(self):
            return json.dumps(self.queue.pop(0))

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

    monkeypatch.setattr(client_module, "DirectConnect", lambda *args, **kwargs: Socket())
    coroutine = client_module.talk("https://localhost:8766", "secret", ssl.create_default_context(), "test", True)
    if success:
        asyncio.run(coroutine)
    else:
        with pytest.raises(ValueError, match="compatibility"):
            asyncio.run(coroutine)
