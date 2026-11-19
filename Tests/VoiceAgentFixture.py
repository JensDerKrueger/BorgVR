"""Loopback-only native-client test: real agent/TLS, deterministic model, no microphone/GPU."""
import asyncio
from dataclasses import replace
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import sys
import threading
import time

from pydantic_ai import BinaryContent
from pydantic_ai.exceptions import ModelContextWindowExceededError
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import FunctionModel
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "BorgVRAgentServer"))
from configure import create_configuration
from borgvr_agent.app import Settings, create_app
from model_config import ModelConfig

root = Path(sys.argv[1])
create_configuration(root, "localhost", "127.0.0.1", 8766, "0")
token = (root / "runtime/secrets/agent_token").read_text().strip()


class ModelCatalog(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/v1/models" or self.headers.get("Authorization") != "Bearer " + "test-token-" * 8:
            self.send_error(403)
            return
        body = json.dumps({"data": [{"id": "Qwen/Qwen3.6-35B-A3B"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


catalog = ThreadingHTTPServer(("127.0.0.1", 0), ModelCatalog)
threading.Thread(target=catalog.serve_forever, daemon=True).start()


async def model(messages, info):
    returned = [part for message in messages for part in message.parts if isinstance(part, ToolReturnPart)]
    user = next((part.content for message in messages for part in message.parts
                 if isinstance(part, UserPromptPart) and isinstance(part.content, str)), "")
    if user == "collaborate":
        resumed = any(isinstance(part, UserPromptPart) and isinstance(part.content, list) and
                      '"current_state":{' in str(part.content) for message in messages for part in message.parts)
        names = [part.tool_name for part in returned]
        if "propose_visualization_rule" in names:
            return ModelResponse(parts=[TextPart("Collaborative task completed without undoing your change.")])
        if "ask_collaboration_feedback" in names:
            feedback = next(part.content for part in returned if part.tool_name == "ask_collaboration_feedback")
            assert feedback["user_feedback"] == "Yes, I wanted to show a better section."
            name, args = "propose_visualization_rule", {"rule": "When asked to inspect contents, consider a section perpendicular to the viewing direction."}
        elif resumed:
            name, args = "ask_collaboration_feedback", {"purpose": "intervention_intent", "language": "en"}
        elif "report_progress" in names:
            await asyncio.sleep(30)
            raise RuntimeError("Manual change did not cancel old planning")
        elif "get_application_state" in names:
            name, args = "report_progress", {"text": "Waiting for manual edit."}
        else:
            name, args = "get_application_state", {}
        return ModelResponse(parts=[ToolCallPart(name, args, tool_call_id=f"collaboration-{len(returned)}")])
    elif user == "long-run":
        if len(returned) >= 32:
            return ModelResponse(parts=[TextPart("Long native run passed.")])
        steps = [("get_application_state", {})] * 32
    elif user == "replace-source":
        if len(returned) >= 2:
            await asyncio.sleep(30)
            raise RuntimeError("Interrupted request was not cancelled")
        steps = [("get_application_state", {}), ("report_progress", {"text": "Old request waiting."})]
    elif user == "replace-at-tool":
        if len(returned) >= 2:
            return ModelResponse(parts=[TextPart("Old render wait completed.")])
        frame = returned[0].content["completedFrame"] if returned else 0
        steps = [("get_application_state", {}),
                 ("wait_until_rendered", {"after_frame": frame, "timeout_seconds": 5})]
    elif user == "wait":
        steps = [("get_application_state", {}), ("wait_until_rendered", {"after_frame": 999999, "timeout_seconds": 30})]
    elif user in {"context-before-change", "context-after-change", "verification-failed"}:
        steps = [("get_application_state", {})]
        if user != "context-before-change":
            steps.append(("rotate_view", {"axis": [0, 1, 0], "degrees": 10}))
        if len(returned) >= len(steps):
            if user == "verification-failed":
                raise RuntimeError("Synthetic verification failure")
            raise ModelContextWindowExceededError("test", "Synthetic context limit")
    else:
        steps = [("get_application_state", {}), ("report_progress", {"text": "Inspecting the synthetic volume."}),
                 ("rotate_view", {"axis": [0, 1, 0], "degrees": 30}),
                 ("set_transfer_function", {"channel": 0, "samples": [[0, 0, 0, 0], [255, 64, 32, 255]]}),
                 ("wait_until_rendered", {"after_frame": 0, "timeout_seconds": 1}),
                 ("capture_screenshot", {"include_alpha": False})]
    if len(returned) < len(steps):
        name, args = steps[len(returned)]
        return ModelResponse(parts=[ToolCallPart(name, args, tool_call_id=f"fixture-{len(returned)}")])
    assert any(isinstance(content, BinaryContent) for message in messages for part in message.parts
               if isinstance(part, UserPromptPart) and not isinstance(part.content, str) for content in part.content)
    return ModelResponse(parts=[TextPart("Native voice agent roundtrip passed.")])


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
port = listener.getsockname()[1]
server = uvicorn.Server(uvicorn.Config(create_app(Settings(token=token, vllm_token="test-token-" * 8,
    # FunctionModel estimates serialized SDK history, not real vLLM tokens. Keep
    # this execution-budget fixture separate from the dedicated context tests.
    inference=replace(ModelConfig.from_env({}), context=65536),
    vllm_url=f"http://127.0.0.1:{catalog.server_port}/v1"), FunctionModel(model)),
    ssl_certfile=str(root / "runtime/tls/server.crt"), ssl_keyfile=str(root / "runtime/tls/server.key"),
    ws="websockets-sansio", ws_max_size=4194304, access_log=False, log_level="error"))
thread = threading.Thread(target=lambda: server.run(sockets=[listener]), daemon=True)
thread.start()
deadline = time.monotonic() + 10
while not server.started and thread.is_alive() and time.monotonic() < deadline:
    time.sleep(0.01)
if not server.started:
    raise RuntimeError("Fixture did not start")
(root / "ready.json").write_text(json.dumps({"port": port}))
thread.join()
