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
from borgvr_agent.context import SUMMARY_MARKER
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
    latest = next((i for i in reversed(range(len(messages))) if any(
        isinstance(part, UserPromptPart) and isinstance(part.content, str) and
        not part.content.startswith(SUMMARY_MARKER) for part in messages[i].parts)), 0)
    messages = messages[latest:]
    returned = [part for message in messages for part in message.parts if isinstance(part, ToolReturnPart)]
    user = next((part.content for message in messages for part in message.parts
                 if isinstance(part, UserPromptPart) and isinstance(part.content, str)
                 and not part.content.startswith(SUMMARY_MARKER)), "")
    opening_receipt = any(isinstance(part, UserPromptPart) and isinstance(part.content, list) and
                          '"opening_completed":true' in str(part.content)
                          for message in messages for part in message.parts)
    if user == "slow-acknowledgement":
        await asyncio.sleep(1)
        return ModelResponse(parts=[TextPart("Slow request completed.")])
    elif user == "duplicate-response":
        text = "Repeated assistant answer."
        if len(returned) < 2:
            return ModelResponse(parts=[ToolCallPart("report_progress", {"text": text if not returned else "  " + text + "\n"})])
        return ModelResponse(parts=[TextPart(text)])
    elif user == "distinct-responses":
        if not returned:
            return ModelResponse(parts=[ToolCallPart("report_progress", {"text": "Distinct progress update."})])
        return ModelResponse(parts=[TextPart("Distinct final answer.")])
    elif user == "invalid-clipping-recovery":
        if len(returned) >= 3:
            assert returned[1].content["not_applied"] is True
            assert returned[1].content["code"] == "invalid_clipping"
            assert returned[0].content["clipMinimum"] == returned[2].content["clipMinimum"]
            assert returned[0].content["clipMaximum"] == returned[2].content["clipMaximum"]
        if len(returned) >= 4:
            return ModelResponse(parts=[TextPart("Clipping rejected safely and corrected.")])
        steps = [("get_application_state", {}),
                 ("set_clipping", {"minimum": [0.8, 0, 0], "maximum": [0.2, 1, 1]}),
                 ("get_application_state", {}),
                 ("set_clipping", {"minimum": [0.2, 0, 0], "maximum": [0.8, 1, 1]})]
    elif user == "annotation-roundtrip":
        spheres = [part.content for part in returned if part.tool_name == "upsert_sphere_marker"]
        strokes = [part.content for part in returned if part.tool_name == "upsert_stroke_marker"]
        lengths = [part.content for part in returned if part.tool_name == "upsert_measurement" and part.content.get("kind") == "length"]
        sphere_id = spheres[0]["marker"]["id"] if spheres else ""
        stroke_id = strokes[0]["marker"]["id"] if strokes else ""
        length_id = lengths[0]["id"] if lengths else ""
        length_points = [dict(point) for point in lengths[0]["points"]] if lengths else []
        if length_points:
            length_points[1]["position"] = [0.6, 0.1, 0.1]
        steps = [("get_application_state", {}), ("list_objects", {}), ("list_measurements", {}),
                 ("upsert_sphere_marker", {"name": "Agent sphere", "position": [0.25, 0.5, 0.5], "radius": 0.01, "color": [0, 1, 0, 1]}),
                 ("upsert_sphere_marker", {"id": sphere_id, "name": "Edited sphere", "position": [0.4, 0.5, 0.5], "radius": 0.01,
                                           "color": [0, 1, 0, 1], "shows_direction": True, "direction_origin": [0.2, 0.5, 0.5]}),
                 ("upsert_stroke_marker", {"name": "Agent stroke", "color": [1, 0, 0, 1], "points": [
                     {"position": [0.1, 0.1, 0.1], "radius": 0.002}, {"position": [0.2, 0.1, 0.1], "radius": 0.002}]}),
                 ("upsert_stroke_marker", {"id": stroke_id, "name": "Edited stroke", "color": [1, 0, 0, 1], "points": [
                     {"position": [0.1, 0.1, 0.1], "radius": 0.002}, {"position": [0.2, 0.1, 0.1], "radius": 0.002},
                     {"position": [0.3, 0.1, 0.1], "radius": 0.002}]}),
                 ("upsert_measurement", {"name": "Agent length", "kind": "length", "points": [
                     {"position": [0.1, 0.1, 0.1]}, {"position": [0.4, 0.1, 0.1]}]}),
                 ("upsert_measurement", {"id": length_id, "name": "Edited length", "kind": "length", "points": length_points}),
                 ("upsert_measurement", {"name": "Agent area", "kind": "area", "points": [
                     {"position": [0.1, 0.1, 0.1]}, {"position": [0.4, 0.1, 0.1]}, {"position": [0.1, 0.5, 0.1]}]}),
                 ("upsert_measurement", {"name": "Agent volume", "kind": "volume", "points": [
                     {"position": [0.1, 0.1, 0.1]}, {"position": [0.4, 0.1, 0.1]}, {"position": [0.1, 0.5, 0.1]},
                     {"position": [0.1, 0.1, 0.6]}]}),
                 ("set_annotation_visibility", {"objects": True, "measurements": True}),
                 ("list_objects", {}), ("list_measurements", {})]
        if len(returned) >= len(steps):
            assert len(returned[-2].content["objects"]) == 2
            assert len(returned[-1].content["measurements"]) == 3
            assert len(lengths) == 2 and lengths[0]["id"] == lengths[1]["id"]
            assert [point["id"] for point in lengths[0]["points"]] == [point["id"] for point in lengths[1]["points"]]
            assert all(row["value"] > 0 and row["physicalExtentAvailable"] for row in returned[-1].content["measurements"])
            return ModelResponse(parts=[TextPart("Agent annotations created, edited and verified.")])
    elif user == "annotation-delete-one":
        objects = next((part.content["objects"] for part in returned if part.tool_name == "list_objects"), [])
        measurements = next((part.content["measurements"] for part in returned if part.tool_name == "list_measurements"), [])
        marker_id = objects[0]["marker"]["id"] if objects else ""
        measurement_id = measurements[0]["id"] if measurements else ""
        steps = [("get_application_state", {}), ("list_objects", {}), ("list_measurements", {}),
                 ("remove_object", {"id": marker_id}), ("remove_measurement", {"id": measurement_id}),
                 ("list_objects", {}), ("list_measurements", {})]
        if len(returned) >= len(steps):
            assert len(returned[-2].content["objects"]) == 1
            assert len(returned[-1].content["measurements"]) == 2
            return ModelResponse(parts=[TextPart("Target annotations deleted and verified.")])
    elif user == "annotation-delete-all":
        steps = [("get_application_state", {}), ("list_objects", {}), ("list_measurements", {}),
                 ("clear_annotations", {"scope": "all", "confirm": True}),
                 ("list_objects", {}), ("list_measurements", {})]
        cleared = next((part.content for part in returned if part.tool_name == "clear_annotations"), None)
        if cleared is not None and cleared.get("code") == "user_declined":
            attempted_bypass = [part for part in returned if part.tool_name == "remove_object"]
            if not attempted_bypass:
                marker_id = next(part.content["objects"][0]["marker"]["id"] for part in returned if part.tool_name == "list_objects")
                return ModelResponse(parts=[ToolCallPart("remove_object", {"id": marker_id}, tool_call_id="decline-bypass")])
            assert attempted_bypass[-1].content["code"] == "user_declined"
            return ModelResponse(parts=[TextPart("Deletion declined safely.")])
        if len(returned) >= len(steps):
            assert returned[-2].content["objects"] == [] and returned[-1].content["measurements"] == []
            return ModelResponse(parts=[TextPart("All annotations deleted and verified.")])
    elif user == "catalog-search":
        steps = [("get_application_state", {}), ("search_datasets", {"query": "bone"})]
        if len(returned) >= 2:
            assert len(returned[-1].content["matches"]) == 1
            return ModelResponse(parts=[TextPart("One bone dataset found; not opened.")])
    elif user in {"catalog-open", "catalog-open-wait"}:
        if opening_receipt:
            if returned:
                assert returned[-1].content["rendererReady"] is True
                return ModelResponse(parts=[TextPart("Catalog dataset opened and fresh state verified.")])
            steps = [("get_application_state", {})]
        else:
            steps = [("get_application_state", {}), ("search_datasets", {"query": "bone"})]
            if len(returned) >= 2:
                target = returned[-1].content["matches"][0]["id"]
                steps.append(("open_dataset", {"id": target}))
    elif user == "application-state":
        if not returned:
            return ModelResponse(parts=[ToolCallPart("get_application_state", {}, tool_call_id="app-state")])
        state = returned[-1].content
        return ModelResponse(parts=[TextPart("Dataset ready." if state["rendererReady"] else "Start menu ready.")])
    elif user == "collaborate":
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
