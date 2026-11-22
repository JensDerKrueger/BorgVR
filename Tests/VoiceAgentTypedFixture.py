"""Loopback fixture for the native client's typed catalog and knowledge negotiation."""

import json
from pathlib import Path
import socket
import sys
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "BorgVRAgentServer"))
from borgvr_next.app import create_app
from borgvr_next.evidence import Evidence
from borgvr_next.model import Call
from borgvr_next.wire import Tool
from configure import create_configuration


class Model:
    name = "catalog-fixture"

    async def ready(self):
        return True

    async def complete(self, messages, tools):
        request = next(message["content"] for message in reversed(messages) if message["role"] == "user" and
                       isinstance(message["content"], str) and message["content"].startswith("scope-"))
        if request == "scope-sweep":
            names = {tool["function"]["name"] for tool in tools}
            assert "flow_intensity_sweep" in names and "capture_tf_preview" not in names
            results = [json.loads(msg["content"]) for msg in messages if msg["role"] == "tool"]
            if not results:
                return Call("band-sweep", "flow_intensity_sweep", '{"progress_message":"Ich vergleiche die Intensitätsbereiche."}')
            assert 5 <= results[-1]["rendered_previews"] <= 32, results[-1]
            assert results[-1]["intervals"] and any(isinstance(msg["content"], list) for msg in messages)
            return "Sweep completed without changing the view."
        assert request in {"scope-start", "scope-renderer"}
        expected = json.loads((root / (request + ".json")).read_text())
        names = {tool["name"] for tool in expected}
        required = {"get_application_state", "open_dataset"}
        required |= ({"import_volume", "fuse_volumes"} if request == "scope-start"
                     else {"capture_screenshot", "upsert_sphere_marker", "edit_volume", "save_visualization_state"})
        assert required <= names, sorted(required - names)
        assert tools == [Tool.model_validate(tool).as_model_function() for tool in expected]
        guidance = [message["content"] for message in messages
                    if message["role"] == "user" and message["content"].startswith("Untrusted application guidance")]
        assert len(guidance) == 1 and request.upper() in guidance[0]
        other = "SCOPE-RENDERER" if request == "scope-start" else "SCOPE-START"
        assert other not in guidance[0]
        assert ("inspection.preview" in guidance[0]) == (request == "scope-renderer")
        if request == "scope-renderer":
            reads = sum(message["role"] == "tool" for message in messages)
            if reads < 270:
                return Call(f"state-{reads}", "get_application_state", "{}")
            if reads == 270:
                return Call("rotation", "rotate_view", '{"axis":[0,1,0],"degrees":15}')
        return "Catalog and rules received."


root = Path(sys.argv[1])
create_configuration(root, "localhost", "127.0.0.1", 8766, "0")
token = (root / "runtime/secrets/agent_token").read_text().strip()
observer_dir = root / "observer"
observer_dir.mkdir(mode=0o700)
store = Evidence(observer_dir / "test.sqlite3")
profile, observer = store.provision()
assert store.submit(profile, "fixture", "observation", [{"kind": "goal"}, {"kind": "receipt", "outcome": "confirmed"}])
assert store.settle(store.claim(), {"label": "aligned", "description": "The intensity previews are useful.", "evidence": [0, 1]})
job = store.claim_induction()
bundle = json.loads((Path(__file__).resolve().parents[1] / "AppSupport/Voice/knowledge-bundle.json").read_text())
assert store.finish_induction(job, [{"situation": "An intensity band is unclear.", "recommendation": "Compare nearby bands.",
                                    "support": [job["rows"][0]["id"]], "counterexamples": [], "status": "pending",
                                    "procedure": bundle["entries"][0]["procedure"]}])
(root / "observer-token.txt").write_text(observer)
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
port = listener.getsockname()[1]
server = uvicorn.Server(uvicorn.Config(create_app(token=token, model=Model(), evidence=store),
    ssl_certfile=str(root / "runtime/tls/server.crt"), ssl_keyfile=str(root / "runtime/tls/server.key"),
    ws="websockets-sansio", ws_max_size=4194304, access_log=False, log_level="error"))
runner = threading.Thread(target=lambda: server.run(sockets=[listener]), daemon=True)
runner.start()
deadline = time.monotonic() + 10
while not server.started and runner.is_alive() and time.monotonic() < deadline:
    time.sleep(0.01)
if not server.started:
    raise RuntimeError("Typed catalog fixture did not start")
(root / "ready.json").write_text(json.dumps({"port": port}))
runner.join()
