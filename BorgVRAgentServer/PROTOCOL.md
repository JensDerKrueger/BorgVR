# BorgVR Agent Protocol 1

This is a BorgVR application protocol, **not an MCP transport**. The server foundation is
implemented; native clients still need implementing. Tool names and schemas come from
the app's existing MCP/Command definitions rather than a second handwritten tool catalog.

## Transport And Authentication

`wss://HOST:8766/v1/session`, with the HTTP upgrade header:

```http
Authorization: Bearer INSTALLATION_AGENT_TOKEN
```

Verify the certificate/hostname. Tokens in URLs and browser `Origin` headers are rejected.
Authentication and session capacity are checked **before** WebSocket acceptance. Use JSON
text frames only, no application-level binary frames. Transport ping/pong maintains connection
health; application inactivity still expires a session after five minutes.

`GET /healthz` is unauthenticated liveness only. `GET /readyz` requires the bearer token and
checks that the configured model is actually listed by vLLM. It returns 503 if unavailable.

## Handshake

Within 10 seconds of connection, the client sends:

```json
{
  "type": "hello",
  "protocol": 1,
  "dataset_id": "DATASET-UUID",
  "context_id": "NEW-UUID-FOR-THIS-RENDERER-OPENING",
  "tools": [
    {
      "name": "get_application_state",
      "description": "Return the active dataset and visualization state.",
      "inputSchema": {
        "type": "object",
        "properties": {},
        "additionalProperties": false
      }
    }
  ]
}
```

The app advertises only commands it supports in this session/platform and has permission
to expose. The example shows a single tool, not the complete catalog. The server intersects
these definitions with its own explicit visualization/read allowlist and replies:

```json
{
  "type": "ready",
  "session_id": "SERVER-GENERATED-ID",
  "protocol": 1,
  "model": "Qwen/Qwen3.6-35B-A3B",
  "capabilities": {"vision": true, "tool_calling": true},
  "tools": ["get_application_state"]
}
```

The same optional `capabilities` object is returned by authenticated `/readyz`. Model names
are informational, not client-side selectors. CUDA/ROCm, checkpoint revisions, quantization,
parsers and thinking settings stay on the server; clients keep using protocol 1 and the same
tool/image messages. Vision-language input and tool calling are minimum requirements, not
features the server silently drops for text-only models. Installation/update tests verify
the tool/image path with a synthetic image; this is not a guarantee of anatomical accuracy.

Every server event contains `session_id`. Tool names can include the current application
state, TF/background inspection and adjustment, transforms, clipping, lighting, rendering
mode, ISO, bounding box, screen projection, render completion and screenshot capture.
Opening/closing datasets, file paths, edits, deletion, exports, settings and arbitrary GSC
are excluded. `capture_screenshot` is narrowed to `include_alpha` only, even if the app's MCP
definition also permits saving a file. There is no shell, code execution or web-browsing tool.
If any visualization-changing tool is advertised, `get_application_state` must also be
available; the server enforces a successful state read before each turn's first change.

## User Requests And Responses

```json
{"type":"user_message","request_id":"UNIQUE-TURN-ID","text":"Rotate the volume a little to the left."}
```

The server emits `started`, zero or more `assistant_message` events with `final:false`,
tool calls/results as needed, then `assistant_message` with `final:true` and `completed`.
Only `assistant_message.text` should be spoken. Progress updates are explicit, complete
messages from the `report_progress` tool, not the model's hidden reasoning or partial JSON.

Only one request may run per session; another receives `error` with code `busy`.
Request IDs are unique for the connection and never replayed. A new connection starts a
new conversation; there is **no automatic reconnect/resend or persisted session recovery**.
The server allows at most 64 accepted turns per connection.

## Remote Tool Execution

```json
{
  "type": "tool_call",
  "session_id": "SERVER-GENERATED-ID",
  "request_id": "UNIQUE-TURN-ID",
  "call_id": "UNIQUE-CALL-ID",
  "dataset_id": "DATASET-UUID",
  "context_id": "RENDERER-OPENING-UUID",
  "name": "get_application_state",
  "arguments": {}
}
```

The native client must validate session/request/call/context IDs and arguments **before**
dispatching through the same Command service used by MCP/UI/GSC recording. Keep executed
call IDs until the session closes: a repeated ID must return the prior result, never
execute the action again. Do not dispatch directly to renderer state. Commands are serialized;
do not introduce speculative mutations. Server-side checks do not replace app-side policy.

Once complete, send:

```json
{
  "type": "tool_result",
  "request_id": "UNIQUE-TURN-ID",
  "call_id": "UNIQUE-CALL-ID",
  "dataset_id": "DATASET-UUID",
  "context_id": "RENDERER-OPENING-UUID",
  "result": {"example": "Actual structured command result"}
}
```

Results are JSON values, not pre-encoded JSON strings. For screenshots, additionally send
`image_png_base64` containing raw PNG bytes encoded as base64, **not a data URL**. Only
`capture_screenshot` may supply it. Resize the render image on the client if required to
fit the stated image limits. Do not capture passthrough, other app windows or physical
surroundings. The server validates the PNG and passes actual image content to the model,
not an uninterpreted base64 string or a server-fetchable URL.

On a definitely failed, **uncommitted** command, supply `error` instead of a successful
result. If a mutation's commit status is unknown, reconcile it locally and terminate the
session rather than claiming clean failure and encouraging a retry. A command being accepted
is not the same as a finished render: `wait_until_rendered` should finish before capturing
the verification frame. Geometry, voxel/world coordinates and patient orientation must
follow the original command definitions; the agent must not invent missing orientation.

## Cancellation And Context Changes

```json
{"type":"cancel","request_id":"UNIQUE-TURN-ID"}
```

The server cancels its model run and emits `cancelled`. If a remote tool is pending, it
also emits `tool_cancel` with the target `request_id` and `call_id`. The client must stop
that exact pending operation if still cancellable, suppress late replies and reconcile
any already committed effects. Cancellation does not undo committed visualization changes.

With a pending tool, cancellation/deadline expiry yields `requires_reconnect:true` and the
server refuses further requests in that session. This deliberately avoids uncertain repeated
mutations. Inspect/reconcile the app state before starting a new session.

When the renderer/dataset/edit-state context changes, generate a **new context ID even if
the same dataset UUID is reopened** and send:

```json
{"type":"context_changed","dataset_id":"NEW-DATASET-UUID","context_id":"NEW-UUID"}
```

This cancels active work and clears history. `context_updated` acknowledges the new context.
If it cancelled a pending tool, the uncertain-session rule still requires reconnecting.
Changed capabilities require a fresh connection/handshake. Stale/mismatched tool results
are rejected, not delivered to the model. On dataset close, disconnect the agent entirely.

## Bounds And Errors

- Maximum 4 authenticated sessions; concurrent agent runs follow the configured model's
  `BORGVR_MAX_SEQS` (default 2, small-model profile 1).
- JSON frame: 4 MiB; catalog: 32 tools/128 KiB; schema: depth 16/4096 nodes.
- Closed object schemas required. No schema references or regex patterns; no remote schema
  resolution. Unknown message fields, duplicate JSON keys and NaN/infinite values are rejected.
- User text: 8192 characters; result/arguments: 256 KiB; PNG: 2 MiB, one frame, at most
  2048 pixels per axis. No externally fetched image URLs.
- History: 8 MiB serialized; only the newest two images remain in context. The model's
  configured token context (default 16K, small profile 8K) may require a new conversation earlier.
- Initial hello: 10 s; application inactivity: 300 s; send: 10 s; tool completion: 45 s;
  one model HTTP call: 60 s without SDK retries; complete user request including queue: 180 s.
- One user request: at most 16 model requests/24 tool calls; output tokens are configured
  with `BORGVR_MAX_OUTPUT_TOKENS` (default 2048). Invalid arguments may be corrected once; dispatched actions have no
  transport-level automatic retries.

Errors contain stable codes (`busy`, `run_failed`, `invalid_message`) and generic text,
not internal exceptions or confidential payloads. Protocol violations close with code 1008.
Disconnect cancels the active run and drops conversation data. The framework tests exercise
this protocol with a deterministic test model; the installation smoke test uses actual vLLM.
