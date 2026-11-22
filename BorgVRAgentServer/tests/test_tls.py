"""Real local TLS/WSS transport with a deterministic model, not a GPU benchmark."""

import asyncio
import socket
import ssl
import threading
import time
import urllib.request

import pytest
import uvicorn

from borgvr_next.app import create_app
from client import talk
from configure import create_configuration


def test_real_tls_websocket_and_hostname_verification(tmp_path, capsys):
    create_configuration(tmp_path, "localhost", "127.0.0.1", 8766, "0")
    cert, key = tmp_path / "runtime/tls/server.crt", tmp_path / "runtime/tls/server.key"
    token = (tmp_path / "runtime/secrets/agent_token").read_text().strip()

    class Model:
        name = "fixture"

        async def complete(self, messages, tools):
            return "TLS test ready"

    app = create_app(token=token, model=Model())
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, ssl_certfile=str(cert), ssl_keyfile=str(key),
                                         ws="websockets-sansio", ws_max_size=4194304,
                                         access_log=False, log_level="error"))
    thread = threading.Thread(target=lambda: server.run(sockets=[listener]), daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 5
        while not server.started and time.monotonic() < deadline:
            time.sleep(0.01)
        assert server.started
        context = ssl.create_default_context(cafile=str(cert))
        context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        with urllib.request.urlopen(f"https://127.0.0.1:{port}/healthz", context=context, timeout=5) as response:
            assert response.status == 200
        asyncio.run(talk(f"https://127.0.0.1:{port}", token, context, "Hello"))
        assert "TLS test ready" in capsys.readouterr().out
        with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
            with pytest.raises(ssl.SSLCertVerificationError):
                context.wrap_socket(raw, server_hostname="wrong.example.org")
    finally:
        server.should_exit = True
        thread.join(timeout=5)
        listener.close()
        assert not thread.is_alive()
