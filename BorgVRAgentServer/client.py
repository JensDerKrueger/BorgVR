"""TLS-verifying server check; no simulated rendering or native app control."""

import argparse
import asyncio
import json
from pathlib import Path
import ssl
from urllib.parse import urlsplit, urlunsplit
import uuid

import httpx
from websockets.asyncio.client import connect


class DirectConnect(connect):
    def process_redirect(self, exc):
        return exc


async def ready(url, token, context):
    async with asyncio.timeout(8):
        async with httpx.AsyncClient(verify=context, timeout=5, follow_redirects=False, trust_env=False) as client:
            async with client.stream("GET", url + "/readyz", headers={"Authorization": f"Bearer {token}"}) as response:
                response.raise_for_status()
                body = bytearray()
                async for chunk in response.aiter_bytes():
                    body.extend(chunk)
                    if len(body) > 65536:
                        raise ValueError("Readiness response too large")
                result = json.loads(body)
                if result.get("status") != "ready":
                    raise ValueError("Model is not ready")
                print(json.dumps(result, ensure_ascii=False))


async def talk(url, token, context, text):
    parts = urlsplit(url)
    endpoint = urlunsplit(("wss", parts.netloc, "/v1/session", "", ""))
    async with asyncio.timeout(180):
        async with DirectConnect(endpoint, ssl=context, proxy=None, additional_headers={"Authorization": f"Bearer {token}"},
                           max_size=4 * 1024 * 1024, max_queue=4, open_timeout=10, close_timeout=5) as socket:
            await socket.send(json.dumps({"type": "hello", "protocol": 1,
                                          "dataset_id": "server-check", "context_id": uuid.uuid4().hex, "tools": []}))
            response = json.loads(await socket.recv())
            if response.get("type") != "ready":
                raise ValueError("Handshake failed")
            request_id = uuid.uuid4().hex
            await socket.send(json.dumps({"type": "user_message", "request_id": request_id, "text": text}))
            while True:
                response = json.loads(await socket.recv())
                if response.get("request_id") != request_id:
                    raise ValueError("Unexpected request ID")
                match response.get("type"):
                    case "assistant_message":
                        print(response["text"])
                    case "completed":
                        return
                    case "error" | "tool_call":
                        raise ValueError("Server check failed: " + response.get("code", "unexpected_tool_call"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://localhost:8766")
    parser.add_argument("--ca", required=True, type=Path)
    parser.add_argument("--token-file", required=True, type=Path)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--health", action="store_true")
    group.add_argument("--smoke", action="store_true")
    group.add_argument("--text")
    args = parser.parse_args()
    parts = urlsplit(args.url)
    if parts.scheme != "https" or parts.username or parts.password or parts.query or parts.fragment or parts.path not in ("", "/"):
        parser.error("Use an HTTPS origin without credentials, query or path")
    token = args.token_file.read_text().strip()
    context = ssl.create_default_context(cafile=str(args.ca))
    # A local self-signed server certificate is explicitly trusted; hostname verification stays on.
    context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
    asyncio.run(ready(args.url.rstrip("/"), token, context))
    if not args.health:
        asyncio.run(talk(args.url, token, context, args.text or "Reply briefly: BorgVR agent connection ready."))


if __name__ == "__main__":
    main()
