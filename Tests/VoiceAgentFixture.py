"""Loopback-only native-client test: real agent/TLS, deterministic model, no microphone/GPU."""
import asyncio
from dataclasses import replace
import json
import os
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
from borgvr_agent.learner_worker import work as run_learner
from borgvr_agent.strategies import STRATEGY_MARKER, MultilingualEncoder
from borgvr_agent.workflow_store import WorkflowStore
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
    resumed = any(isinstance(part, UserPromptPart) and not isinstance(part.content, str) and
                  "explicitly chose to continue" in str(part.content)
                  for message in messages for part in message.parts)
    created_state = any(isinstance(part, UserPromptPart) and isinstance(part.content, list) and
                        '"tool":"create_edit_state"' in str(part.content) and '"transition_completed":true' in str(part.content)
                        for message in messages for part in message.parts)
    latest = next((i for i in reversed(range(len(messages))) if any(
        isinstance(part, UserPromptPart) and isinstance(part.content, str) and
        not part.content.startswith(SUMMARY_MARKER) for part in messages[i].parts)), 0)
    strategy_hints = [value for message in messages for part in message.parts
                      if isinstance(part, UserPromptPart) and not isinstance(part.content, str)
                      for value in part.content if isinstance(value, str) and value.startswith(STRATEGY_MARKER)]
    messages = messages[latest:]
    returned = [part for message in messages for part in message.parts if isinstance(part, ToolReturnPart)]
    user = next((part.content for message in messages for part in message.parts
                 if isinstance(part, UserPromptPart) and isinstance(part.content, str)
                 and not part.content.startswith(SUMMARY_MARKER)), "")
    opening_receipt = any(isinstance(part, UserPromptPart) and isinstance(part.content, list) and
                          '"opening_completed":true' in str(part.content)
                          for message in messages for part in message.parts)
    if user in {"Mach einen kleinen Screenshot mit 100 Pixeln Breite.", "Take a low-resolution screenshot for a quick preview."}:
        assert len(strategy_hints) == 1
        assert json.loads(strategy_hints[0].removeprefix(STRATEGY_MARKER))[0]["id"] == "inspection.preview"
        return ModelResponse(parts=[TextPart("Preview strategy selected.")])
    if user == "slow-acknowledgement":
        await asyncio.sleep(1)
        return ModelResponse(parts=[TextPart("Slow request completed.")])
    elif user == "duplicate-response":
        text = "I'm checking the current state."
        if len(returned) < 2:
            return ModelResponse(parts=[ToolCallPart("report_progress", {"activity": "read_state", "language": "en"})])
        return ModelResponse(parts=[TextPart("  " + text + "\n")])
    elif user == "distinct-responses":
        if not returned:
            return ModelResponse(parts=[ToolCallPart("report_progress", {"activity": "verify_result", "language": "en"})])
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
    elif user in {"volume-edit-erase", "volume-edit-restore", "volume-edit-declined"}:
        steps = [("get_application_state", {}), ("get_volume_edit_state", {})]
        restoring = user == "volume-edit-restore"
        if len(returned) >= 2:
            status = returned[1].content
            assert status["available"] and not status["shared"]
            if restoring:
                steps.append(("get_command_history", {"source": "chat", "limit": 4}))
            else:
                extent = status["physicalExtentMeters"]
                sample = {"center_meters": [size / 2 for size in extent], "radius_meters": min(extent) / 5}
                steps.append(("edit_volume", {"mode": "erase", "samples": [sample]}))
        if restoring and len(returned) >= 3:
            assert any(row.get("text") == "volume-edit-erase" for row in returned[2].content["chat"])
            steps.append(("get_command_history", {"tool": "edit_volume", "limit": 1}))
        if restoring and len(returned) >= 4:
            history = returned[3].content["history"]
            assert len(history) == 1 and history[0]["arguments"]["mode"] == "erase"
            assert history[0]["result"]["hasEdits"] is True
            steps.append(("edit_volume", {"mode": "restore", "samples": history[0]["arguments"]["samples"]}))
        edit_result = 4 if restoring else 2
        if len(returned) > edit_result:
            receipt = returned[edit_result].content
            if user == "volume-edit-declined":
                assert receipt["code"] == "user_declined"
                return ModelResponse(parts=[TextPart("Volume edit declined safely.")])
            assert not receipt.get("not_applied")
            steps.append(("wait_volume_edits", {"timeout_seconds": 8}))
        if len(returned) > edit_result + 1:
            waited = returned[edit_result + 1].content
            assert waited["bricksReady"] and not waited["timedOut"]
            return ModelResponse(parts=[TextPart("Edited bricks are ready.")])
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
    elif user == "pick-position":
        if not returned:
            return ModelResponse(parts=[ToolCallPart("capture_screenshot", {"max_width": 100}, tool_call_id="image")])
        if len(returned) == 1:
            assert (returned[0].content["width"], returned[0].content["height"]) == (100, 75)
            capture_id = returned[0].content["screenshotId"]
            return ModelResponse(parts=[ToolCallPart("pick_screenshot_positions",
                {"screenshot_id": capture_id, "points": [{"x": 0.5, "y": 0.5}]}, tool_call_id="pick")])
        assert returned[1].content == {"available": True, "positions": [[0.5, 0.5, 0]]}
        return ModelResponse(parts=[TextPart("Screenshot position verified.")])
    elif user in {"load-view", "cancel-load-view"}:
        steps = [("get_application_state", {}), ("load_visualization_state", {})]
        if len(returned) >= 2:
            result = returned[-1].content
            if user == "cancel-load-view":
                assert result["code"] == "user_declined"
                return ModelResponse(parts=[TextPart("View selection cancelled.")])
            assert result == {"loaded": True}
            return ModelResponse(parts=[TextPart("View loaded.")])
    elif user in {"edit-state-create", "edit-state-duplicate"}:
        duplicate = user == "edit-state-duplicate"
        target = "Assistant duplicate" if duplicate else "Assistant empty"
        if created_state:
            steps = [("get_application_state", {}), ("get_volume_edit_state", {})]
            if len(returned) >= 2:
                state = returned[-1].content
                assert any(item["id"] == state["activeStateID"] and item["name"] == target for item in state["savedStates"])
                return ModelResponse(parts=[TextPart("New edit state active.")])
        else:
            steps = [("get_application_state", {}), ("get_volume_edit_state", {}),
                     ("create_edit_state", {"name": target, "duplicate": duplicate})]
    elif user in {"edit-state-rename", "edit-state-delete", "edit-state-decline-delete"}:
        steps = [("get_application_state", {}), ("get_volume_edit_state", {})]
        renaming = user == "edit-state-rename"
        if len(returned) >= 2:
            target = next(row["id"] for row in returned[1].content["savedStates"] if
                          row["name"] == ("Assistant empty" if renaming else "Assistant delete target"))
            command = ("rename_edit_state", {"id": target, "name": "Assistant renamed"}) if renaming else (
                "delete_edit_state", {"id": target})
            steps.append(command)
            if user == "edit-state-decline-delete":
                steps.append(command)
                if len(returned) >= 4:
                    assert all(part.content["code"] == "user_declined" for part in returned[-2:])
                    return ModelResponse(parts=[TextPart("Edit state deletion declined.")])
            elif len(returned) >= 3:
                states = returned[-1].content["savedStates"]
                assert any(row["id"] == target and row["name"] == "Assistant renamed" for row in states) is renaming
                if not renaming:
                    assert not any(row["id"] == target for row in states)
                return ModelResponse(parts=[TextPart("Edit state renamed." if renaming else "Edit state deleted.")])
    elif user == "collaborate":
        supplied_view = any(isinstance(part, UserPromptPart) and isinstance(part.content, list) and
                            '"user_supplied_requested_view":true' in str(part.content)
                            for message in messages for part in message.parts)
        if supplied_view:
            assert "ask_collaboration_feedback" not in {tool.name for tool in info.function_tools}
            return ModelResponse(parts=[TextPart("Collaborative task completed without undoing your change.")])
        return ModelResponse(parts=[ToolCallPart("ask_collaboration_feedback",
            {"purpose": "help", "language": "en"}, tool_call_id="collaboration-help")])
    elif user == "long-run":
        if len(returned) >= 32:
            return ModelResponse(parts=[TextPart("Long native run passed.")])
        steps = [("get_application_state", {})] * 32
    elif user == "replace-source":
        if len(returned) >= 2:
            await asyncio.sleep(30)
            raise RuntimeError("Interrupted request was not cancelled")
        steps = [("get_application_state", {}), ("report_progress", {"activity": "wait_for_render", "language": "en"})]
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
            if resumed:
                assert returned[-1].content["code"] == "already_applied_in_request"
                return ModelResponse(parts=[TextPart("Continued without repeating the change.")])
            if user == "verification-failed":
                raise RuntimeError("Synthetic verification failure")
            raise ModelContextWindowExceededError("test", "Synthetic context limit")
    else:
        steps = [("get_application_state", {}), ("report_progress", {"activity": "inspect_view", "language": "en"}),
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
workflow_path = root / "workflow.sqlite3"
workflow = WorkflowStore(workflow_path)
(root / "workflow-fixture.json").write_text(json.dumps([workflow.create_profile(), workflow.create_profile()]))
learner_stop = threading.Event()
threading.Thread(target=run_learner, args=(WorkflowStore(workflow_path), learner_stop), daemon=True).start()
encoder_dir = os.environ.get("BORGVR_STRATEGY_TEST_ENCODER")
server = uvicorn.Server(uvicorn.Config(create_app(Settings(token=token, vllm_token="test-token-" * 8,
    # FunctionModel estimates serialized SDK history, not real vLLM tokens. Keep
    # this execution-budget fixture separate from the dedicated context tests.
    inference=replace(ModelConfig.from_env({}), context=65536),
    vllm_url=f"http://127.0.0.1:{catalog.server_port}/v1", workflow_database=workflow_path), FunctionModel(model),
    strategy_encoder=MultilingualEncoder(Path(encoder_dir)) if encoder_dir else None),
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
try:
    thread.join()
finally:
    learner_stop.set()
