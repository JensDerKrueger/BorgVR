# BorgVR Agent Protocol 1

This is a BorgVR application protocol, **not an MCP transport**. A shared native client is
implemented for macOS, iOS and visionOS. Tool names and schemas come from
the app's existing MCP/Command definitions. Agent policy narrows annotation schemas and
projects bounded results; execution still uses the existing Command service, not a second
annotation implementation.

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

## Annotation capability

With a ready dataset, updated peers can negotiate `list_objects`, `upsert_sphere_marker`,
`upsert_stroke_marker`, `list_measurements`, `upsert_measurement` and
`set_annotation_visibility`. No protocol version change is needed; older peers intersect
their catalogs as before. Deletes, bulk deletes and mesh placement remain excluded.

Annotation upserts require a successful `get_application_state` and the matching list call
in the current turn. Replanning after a user intervention clears these read prerequisites.
Positions/direction origins use dataset-local normalized `[x,y,z]` in `[0,1]`, colors use
normalized RGBA, and radii use normalized volume units. Creation omits the top-level ID;
edits use an existing UUID of the matching marker kind. Upsert replaces the full item,
including fields the caller must preserve and stable measurement point IDs.

The list tools accept optional `offset` (default 0) and `limit` (default 32, maximum 64).
Results wrap arrays under `objects` or `measurements`, with `totalCount`, `returnedCount`,
`truncated` and `nextOffset` (null on the last page). Each page has a 200 KiB detail budget.
Individual records exceeding 64 KiB become explicit `detailsOmitted` summaries, never
complete editable replacements. Upserts accept at most 256 points and names of 128 characters.

Measurement records include `value`, `unit` (`m`, `m^2`, `m^3`), `physicalExtentAvailable`
and `geometry` (`polyline`, `planar_polygon`, `convex_hull`). Values are calculated by BorgVR
with the dataset's physical extent; absent scale or incomplete geometry gives null, not an
invented physical result. New/updated measurements require nondegenerate geometry with
at least 2/3/4 points respectively. Volume is not a segmented organ volume. An ambiguous
2D screenshot does not establish a precise 3D anatomical measurement.

Safe preflight failures return `ok: false`, `not_applied: true`, `code: invalid_annotation`
and a corrective error. They do not imply uncertain completion. Exceptions after a command
may have committed retain the existing stop-without-replay behavior.

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

### Optional execution limits

Hello may include `"execution_limits":{"max_calls":256,"timeout_seconds":1800}`.
The server confirms accepted limits in `ready`, capped by its configuration (at most
1024 native calls and 7200 seconds). Clients without this field retain 24 native calls
and the configured legacy timeout (180 seconds by default). Native settings default to
256 calls and 30 minutes. Internal tool/model budgets reserve capacity for a final answer.

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

For legacy dataset-bound sessions, when the renderer/dataset/edit-state context changes, generate a **new context ID even if
the same dataset UUID is reopened** and send:

```json
{"type":"context_changed","dataset_id":"NEW-DATASET-UUID","context_id":"NEW-UUID"}
```

This cancels active work and clears history. `context_updated` acknowledges the new context.
If it cancelled a pending tool, the uncertain-session rule still requires reconnecting.
Changed capabilities require a fresh connection/handshake. Stale/mismatched tool results
are rejected, not delivered to the model. On dataset close, disconnect the agent entirely.

## Application session extension

New clients send `application_session:true` in `hello` and require the same flag in `ready`.
Only this negotiated mode permits `dataset_id:null`; the property itself is still required.
It represents the start menu or another context without a render-ready dataset, never a
synthetic dataset ID. Both sides filter the native catalog to `get_application_state`, `search_datasets`
and, when explicitly negotiated, `open_dataset` in
this state. Text/speech interaction does not require a renderer or enable microphone recording.

When **idle**, send a new `context_id`, the nullable dataset ID and the complete, current
`tools` array in `context_changed`. The server validates the catalog again and acknowledges
with `context_updated`, `context_id` and the accepted `tools` names. The client waits for
this acknowledgement before allowing requests. State-read receipts, screenshots, visual
notes, collaboration state and pending rule proposals are cleared. The server retains at
most eight bounded text excerpts as untrusted historical conversation, not current dataset
evidence or instructions. Native tool calls/results and images are not retained. The next
request must read fresh state before any mutation. Reopening the same dataset UUID still
requires a new context ID and a new catalog.

An active request, pending command, uncertain completion or overlapping transition instead
requires disconnecting and negotiating a fresh session; no request is replayed. The visible
conversation and assistant window survive this disconnect, but server-side context starts
fresh on the next explicit request. A server rejects an in-flight `context_changed` in app
mode. Legacy sessions retain their original dataset-bound behavior. Existing clients can
connect to the new server; app-wide clients require a server implementing this extension.

## Catalog and requested dataset opening

`search_datasets` accepts an optional query (maximum 256 characters, up to twelve AND-linked
terms), limit (1...20) and opaque cursor (maximum 128 characters). It matches case/accent-insensitive
description and bounded metadata/provenance text, not voxel contents. Results contain IDs,
descriptions, up to three short evidence excerpts, metadata availability, source kinds and
pagination. URLs, paths and recognizable secrets are redacted from text. Source addresses,
credentials and raw errors are not exposed. `coverage: available_catalog_metadata_only`
explicitly does not assert that configured remote sources were reachable. Cursors refer to
a stable five-minute result snapshot; at most two snapshots and 512 cursors are retained.

New clients additionally negotiate `dataset_opening:true` in hello/ready. Both sides allow
opening only an ID actually returned by a search within five minutes, and require a current
state read first. Search alone is not permission to open; the model must obtain selection
intent from the user and ask about ambiguous choices. At most one opening is permitted per
request. App guards are rechecked after asynchronous preparation, before replacing the dataset.

For an authorized open call only, the native `tool_result` uses the **old** dataset/context IDs
for correlation and adds `dataset_transition: {dataset_id, context_id, tools}`. The result
must confirm `rendererReady:true` and `dataset.id` matching the requested target. The native
adapter waits for the specific opening identity to become ready; a foreign switch cancels
continuation. Opening takes at most 300 seconds, with 330-second transport guards (search: 75
seconds, including the underlying 60-second catalog deadline), also bounded by the request budget.
Cancellation does not undo an already started load or automatically retry it.

The server validates the target/new context/catalog and acknowledges with `context_updated`
before any new call. A new catalog is only published after this acknowledgement. The old
model run's remaining tool plan, including other batched calls, is discarded. Planning resumes
within the original request and usage/deadline budget, using bounded historical text and
verified operation receipts, never old images or executable calls. The rebuilt agent must
read fresh application state before visualization changes. Unknown IDs, unexpected transition
receipts, stale results and unnegotiated transitions are rejected. Ordinary user-driven context
changes retain the stop/reconnect rules above.

## Collaborative editing extension

Hello may advertise `"collaboration":true` and `"knowledge":["An approved user preference"]`.
`ready.collaboration:true` confirms support. Without negotiation no collaboration messages
are sent. Knowledge contains at most 16 strings of 1 to 500 characters and is untrusted
contextual preference data, not system instructions or permission to use additional tools.

The app observes successful relevant Command events independently of GSC recording, plus
begin/failure lifecycle events for asynchronous manual actions. It filters its own agent
origin and coalesces changes into these domains: `transform`, `clipping`, `transfer_function`,
`lighting`, `rendering`, `annotations`, `volume`. No raw Command/GSC, file path, credentials,
voxel buffers or edit history are included. State uses the existing bounded application
state response without `volumeEditing` details.

```json
{"type":"user_change","dataset_id":"DATASET-UUID","context_id":"RENDERER-OPENING-UUID","revision":1,"active":true,"domains":["transform"]}
{"type":"user_change","dataset_id":"DATASET-UUID","context_id":"RENDERER-OPENING-UUID","revision":2,"active":false,"domains":["transform"],"state":{"transform":{"rotation":[0,0,0,1]}}}
```

Revisions increase for relevant events within the connection (1 through 2^53-1). A final
snapshot requires `active:false` and state of at most 256 KiB. The native client waits for
800 ms of quiet and all manual operations to end. Stale revisions cannot reopen a finished
intervention. The server cancels only unexecuted model generation, not pending native tools.
It emits `collaboration_paused`, waits for the final user snapshot, then
`collaboration_resumed` with `request_id` and `view_revision`. The original goal, cumulative
usage and absolute task deadline remain unchanged. Superseded state/images are invalidated;
tool execution receipts remain. No commands are replayed. The latest user state replaces
any earlier view-restoration baseline. A failed manual action is not proof of a useful edit:
the final snapshot describes the actual resulting state and generalization requires feedback.

Every negotiated `tool_call` and `tool_result` carries `view_revision` (initially 0).
Before dispatch the client rejects outdated calls or calls during manual activity using
`result:{"ok":false,"not_applied":true,"code":"user_changed_view"}` and the current revision.
Such a response never counts as a committed mutation. Results of already dispatched tools
finish normally; stale images are not supplied as current evidence. Dataset closure/reopening
still disconnects during active work (idle app sessions use the extension above). A user-initiated edit may update the edit-state ID within the same dataset
opening; an unrelated edit-state/context switch still invalidates the session.

The server can use an internal `ask_collaboration_feedback` tool to ask what an intervention
meant, or request specific help when an investigation is inconclusive:

```json
{"type":"collaboration_question","session_id":"SERVER-ID","request_id":"TURN-ID","question_id":"QUESTION-ID","text":"Was that rotation intended to help?"}
{"type":"collaboration_feedback","request_id":"TURN-ID","question_id":"QUESTION-ID","text":"Yes, inspect a section perpendicular to this view."}
```

Questions are at most 500 characters, answers 2000. A correlated reply continues the same
task, unlike an ordinary new prompt. The internal tool accepts only `purpose`
(`intervention_intent`, `view_change`, `help`) and `language` (`de`, `en`). The server supplies
a single-purpose question from localized templates; the model cannot bundle several decisions
into a generated yes/no question. Explanations belong in a separate progress message.
Each purpose is available once per intervention per task, so help intent and permission
can be answered separately. Replies retain the exact question and purpose in model context.
A yes to help intent never grants additional permissions or saves a rule. A no or conditional
answer to `view_change` makes the task read-only; only an unconditional `Ja` or `Yes` to that
permission question allows further mutations. Reads, render waits and screenshots remain
available. Tool filtering and the execution guard both enforce this restriction; no native
command is sent for a denied mutation. The overall deadline and explicit cancellation
remain active while waiting. This extension requires only a server update, not an app update.

Only after explicit feedback may `propose_visualization_rule` emit `rule_proposal` with
`request_id`, `proposal_id`, and `text` (1 to 500 characters, at most eight pending proposals).
The client asks for separate explicit approval and sends
`{"type":"rule_decision","proposal_id":"PROPOSAL-ID","accepted":true}` (or false).
Only approved rules are persisted by the client, per device. The server keeps them only
in this session; future Hello messages supply the device's approved rules. No weight updates,
training, autonomous permanent memory or server-side rule files are involved. Deleted local
rules take effect in new conversations; an existing context can still contain older copies.

## Bounds and errors

- Maximum 4 authenticated sessions; concurrent agent runs follow the configured model's
  `BORGVR_MAX_SEQS` (default 2, small-model profile 1).
- JSON frame: 4 MiB; catalog: 32 tools/128 KiB; schema: depth 16/4096 nodes.
- Closed object schemas required. No schema references or regex patterns; no remote schema
  resolution. Unknown message fields, duplicate JSON keys and NaN/infinite values are rejected.
- User text: 8192 characters; result/arguments: 256 KiB; PNG: 2 MiB, one frame, at most
  2048 pixels per axis. No externally fetched image URLs.
- History: 8 MiB serialized; at most the newest two images remain. Before each model request,
  the agent uses vLLM's authenticated `/tokenize` endpoint with the same chat messages, tools,
  image inputs and template options as generation. The smaller of the configured and reported
  context limits applies, with room reserved for the configured answer length and a safety margin.
  Above 85% of that input budget, completed older turns become bounded, explicitly untrusted
  excerpts. Older screenshots and superseded tool-result details can be omitted; large TF
  results become marked previews. Active user text, tool-call arguments, call/result IDs and
  failures remain intact. This changes conversation memory, not the actual TF or app state.
  If necessary the older-turn summary is discarded. An oversized active request fails safely.
  Token counting has a 15-second absolute timeout and a 4 MiB response limit; counting failures
  do not silently disable the budget check. A rejected context-overflow model request can be
  retried once with a smaller history, without rerunning completed tools.
- Initial hello: 10 s; application inactivity: 300 s; send: 10 s; tool completion: 45 s;
  one model HTTP call: 60 s without SDK retries; complete user request including queue: 180 s.
- Legacy requests permit 24 native calls, up to 48 total internal/native tool calls and
  48 model requests; negotiated native budgets increase internal capacity proportionally.
  Output tokens are configured
  with `BORGVR_MAX_OUTPUT_TOKENS` (default 2048). Invalid arguments may be corrected once; dispatched actions have no
  transport-level automatic retries.

Errors contain stable codes (`busy`, `run_failed`, `context_limit`, `invalid_message`) and generic text,
not internal exceptions or confidential payloads. Run errors include `changes_applied`, true
only after at least one successful mutation result in that turn. It does not mean the visual
goal was verified, or that a later pending command completed. `requires_reconnect` still takes
precedence when a tool's completion is uncertain. Native clients use their own local mutation
receipts to distinguish context exhaustion before changes, confirmed changes with a failed
final check, and uncertain completion. They must not trust remote success claims or repeat
mutations to recover from these errors. Older clients may show their generic error text.
Protocol violations close with code 1008.
Disconnect cancels the active run and drops conversation data. The framework tests exercise
this protocol with a deterministic test model; the installation smoke test uses actual vLLM.

## Native Client

Configure **Settings > AI Assistant** with an HTTPS origin, installation token and, for a
self-signed server, the imported public `runtime/tls/server.crt`. The token is held in the
device Keychain; server trust and credentials are not shared through SharePlay or GSC.
Enabling the assistant is explicit. The render controls open a shared conversation view
with microphone, text input, progress replies, optional local speech output and cancellation.
There is no passive listening or wake-word command table. Microphone audio stays on the
device by default; the user can separately allow system recognition that may use Apple's servers. The agent
receives transcribed text, never audio.

Native tools reuse `BorgVRMCPToolRouter`, without starting an MCP listener. The client
further narrows the catalog by platform, RGB/RGBA support and screenshot consent. Local
schema checks, context fences, a connection-scoped bounded call ledger and state-read gating
run before dispatch. Accepted commands enter the existing session/Command/GSC path.
Render-only PNGs are reduced to at most 1024 pixels per axis and 2 MiB. No window, camera
or passthrough capture is used. TF tool results include at most 256 uniformly spaced preview
samples, `originalSampleCount`, and `samplesArePreview`; the advertised description explicitly
marks this approximation. Actual TF resolution and recorded commands remain unchanged.
Current native bounds also include `4 * accepted_native_call_budget + 128` events per turn,
8192 unique call IDs per connection and 8 MiB cached replies. Signatures are hashes. Evicted
replies leave tombstones and are rejected rather than executing a command again.

Native cancellation conservatively disconnects the session and cancels the pending command;
it never retries an uncertain mutation. Dataset opening IDs and edit-state IDs are checked
before dispatch and again after async commands, including reopening the same dataset UUID.
Changing connection settings also disconnects. Native idle sessions close after 240 seconds;
connection/send/tool deadlines are 15/10/40 seconds; the turn deadline is the negotiated
task timeout plus five seconds. There is no automatic reconnect
or request replay. `Scripts/test-voice-agent.sh` exercises actual local TLS/WSS against the
agent with a deterministic model, including render-image delivery and GSC roundtrip.
