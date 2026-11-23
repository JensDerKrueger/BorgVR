"""Test the TLS endpoint with an image and structured output; no external dependencies."""

import base64
import http.client
import json
import socket
import ssl
import struct
import zlib

from configure import ROOT, read_configuration


def red_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    size = 64
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    rows = (b"\x00" + b"\xff\x00\x00" * size) * size
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def test(root=ROOT):
    values = read_configuration(root)
    bind = values["BORGVR_BIND_ADDRESS"]
    address = "127.0.0.1" if bind == "0.0.0.0" else bind
    port = int(values["BORGVR_PORT"])
    context = ssl.create_default_context(cafile=str(root / "runtime/tls/server.crt"))
    token = (root / "runtime/secrets/vllm_token").read_text().strip()

    class LocalConnection(http.client.HTTPSConnection):
        def connect(self):
            self.sock = context.wrap_socket(socket.create_connection((address, port), self.timeout),
                                            server_hostname="localhost")

    def request(path, payload=None, *, authenticated=True, expected=200):
        connection = LocalConnection("localhost", port, timeout=185)
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = "Bearer " + token
        try:
            connection.request("GET" if payload is None else "POST", path,
                               json.dumps(payload) if payload is not None else None, headers)
            response = connection.getresponse()
            if response.status != expected:
                raise ValueError(f"{path}: unexpected HTTP status {response.status} (expected {expected})")
            if expected == 200:
                return json.loads(response.read(1024 * 1024))
        finally:
            connection.close()

    request("/v1/models", authenticated=False, expected=401)
    request("/invocations", {}, authenticated=False, expected=404)
    models = request("/v1/models")
    model = models["data"][0]["id"]
    image = "data:image/png;base64," + base64.b64encode(red_png()).decode("ascii")
    body = {
        "model": model, "temperature": 0, "max_tokens": 512,
        "messages": [{"role": "system", "content": "Identify the dominant color of the image."},
                     {"role": "user", "content": [{"type": "text", "text": "Which color is shown?"},
                                                  {"type": "image_url", "image_url": {"url": image}}]}],
        "response_format": {"type": "json_schema", "json_schema": {"name": "color_test", "schema": {
            "type": "object", "required": ["color"], "additionalProperties": False,
            "properties": {"color": {"type": "string", "enum": ["red", "green", "blue"]}},
        }}},
    }
    result = request("/v1/chat/completions", body)["choices"][0]
    if result.get("finish_reason") == "length" or json.loads(result["message"]["content"]) != {"color": "red"}:
        raise ValueError("Model did not return the expected structured result for the synthetic image")
    print(f"{model}: TLS, authentication, endpoint restrictions, vision and structured JSON OK.")


if __name__ == "__main__":
    try:
        test()
    except (OSError, ValueError, IndexError, KeyError, TypeError, http.client.HTTPException) as error:
        # Do not print upstream bodies, credentials or request data.
        detail = str(error) if isinstance(error, ValueError) and str(error).startswith(("/", "Model did not")) else type(error).__name__
        raise SystemExit(f"Model check failed: {detail}") from None
