"""TLS-verifying server check; no simulated rendering or native app control."""

import argparse
import asyncio
import base64
import io
import json
import re
from pathlib import Path
import ssl
from urllib.parse import urlsplit, urlunsplit
import uuid

import httpx
from PIL import Image
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


async def talk(url, token, context, text, capabilities=False):
    parts = urlsplit(url)
    endpoint = urlunsplit(("wss", parts.netloc, "/v1/session", "", ""))
    async with asyncio.timeout(180):
        async with DirectConnect(endpoint, ssl=context, proxy=None, additional_headers={"Authorization": f"Bearer {token}"},
                           max_size=4 * 1024 * 1024, max_queue=4, open_timeout=10, close_timeout=5) as socket:
            context_id = uuid.uuid4().hex
            tools = [{"name": name, "description": description,
                      "inputSchema": {"type": "object", "properties": {}, "required": [], "additionalProperties": False}}
                     for name, description in (("get_application_state", "Read synthetic test state."),
                                               ("capture_screenshot", "Read a synthetic test image, not a real dataset."))] if capabilities else []
            await socket.send(json.dumps({"type": "hello", "protocol": 1,
                                          "dataset_id": "server-check", "context_id": context_id, "tools": tools}))
            response = json.loads(await socket.recv())
            if response.get("type") != "ready":
                raise ValueError("Handshake failed")
            if capabilities:
                if response.get("capabilities", {}).get("vision") is not True:
                    raise ValueError("This agent image does not advertise the required image support; update the agent image")
                text = ("Run this synthetic compatibility check: call get_application_state, then capture_screenshot. "
                        "Inspect the returned image and name its dominant color in English. Do not guess without the image. "
                        "Reply briefly after both calls. No real BorgVR dataset is open.")
            request_id = uuid.uuid4().hex
            called = set()
            call_count = 0
            output = ""
            await socket.send(json.dumps({"type": "user_message", "request_id": request_id, "text": text}))
            while True:
                response = json.loads(await socket.recv())
                if response.get("request_id") != request_id:
                    raise ValueError("Unexpected request ID")
                match response.get("type"):
                    case "assistant_message":
                        print(response["text"])
                        if response.get("final"):
                            output = response["text"]
                    case "completed":
                        if capabilities:
                            if called != {"get_application_state", "capture_screenshot"} or not re.search(r"\bred\b", output, re.IGNORECASE):
                                raise ValueError("Model failed tool calling/image compatibility check (expected both tools and recognition of red)")
                            print("Vision and tool-calling compatibility check passed with a synthetic red image.")
                        return
                    case "tool_call" if capabilities:
                        call_count += 1
                        name = response.get("name")
                        if (call_count > 4 or name not in ("get_application_state", "capture_screenshot")
                            or response.get("arguments") != {} or response.get("context_id") != context_id
                            or response.get("dataset_id") != "server-check"):
                            raise ValueError("Unexpected tool in model compatibility check")
                        called.add(name)
                        result = {"type": "tool_result", "request_id": request_id, "call_id": response["call_id"],
                                  "dataset_id": "server-check", "context_id": context_id,
                                  "result": {"synthetic_compatibility_check": True}}
                        if name == "capture_screenshot":
                            png = io.BytesIO()
                            Image.new("RGB", (64, 64), (255, 0, 0)).save(png, format="PNG")
                            result["image_png_base64"] = base64.b64encode(png.getvalue()).decode()
                        await socket.send(json.dumps(result))
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
    group.add_argument("--capabilities", action="store_true")
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
        asyncio.run(talk(args.url, token, context, args.text or "Reply briefly: BorgVR agent connection ready.", args.capabilities))


if __name__ == "__main__":
    main()
