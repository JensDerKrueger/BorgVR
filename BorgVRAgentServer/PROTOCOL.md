# BorgVR agent protocol v1

The native app owns tool permissions, command execution and local approvals.
The agent submits proposals using only the session's advertised tools. It
does not invoke BorgVR's public MCP server.

## Transport

Use `wss://HOST:PORT/v1/session` and an `Authorization: Bearer TOKEN` header.
Verify TLS and the hostname; do not put tokens in URLs. Browser Origin
headers and query parameters are rejected. Frames are JSON text, at most
4 MiB. Unauthenticated connections are rejected before acceptance.
Ping/pong keeps the WebSocket healthy; idle sessions expire after five
minutes. `GET /healthz` is liveness. Authenticated `GET /readyz` checks
that vLLM lists the configured model.

`HEAD /healthz` advertises `BorgVR-Tool-Types: 1`,
`BorgVR-Expert-Knowledge: 1` and `BorgVR-Time-Only-Turns: 1`.

## Handshake

Send `hello` with `protocol: 1`, `dataset_id` (null for the start menu),
`context_id` and the active `tools`. Native clients use
`application_session: true` and request `dataset_opening` and
`collaboration`. Optional `knowledge` and `expert_knowledge_toml`
are advisory, not permission. The server responds with `ready`,
including the `session_id`, model, negotiated flags, accepted tool names
and `execution_limits`. Server messages carry the session ID.

For time-only turns send `execution_limits: {"timeout_seconds":3600}`.
The supported range is 300 to 10800 seconds. The default is 3600 seconds
when the field is absent. Older clients can include `max_calls`; it is
echoed and honored only when explicitly requested.

Each tool supplies its name, description, closed JSON `inputSchema` and
an `execution` object:

- `kind`: `read`, `mutation` or `transition`.
- `role`: optional read role (`application_state`, `catalog_search`,
  `render_image` or `edit_state`).
- `transition`: scope change (`open`, `close`, `select_edit` or
  `create_edit`), required for transitions.
- `approval_group`: optional group for local refusals.
- `timeout_seconds`: 5 through 330 seconds; defaults to 45.

The catalog may contain at most 48 tools and may not exceed 128 KiB.
Definitions failing validation are rejected instead of silently filtered.

## Turns and receipts

Send `user_message` with a unique `request_id` and `text`. The server
sends `started` before inference, then any `tool_call` messages. Finish
is a final `assistant_message` followed by `completed`. Errors have a
code and indicate confirmed changes or whether reconnecting is required.

A tool call carries its name and arguments, `request_id`, `call_id`,
`dataset_id` and `context_id`. Return `tool_result` with those same
identifiers and a structured `result` or `error`. Native receipts are
correlated before use; at most one call is in flight. Tool results are
bounded to 256 KiB. Only the render-image role may return optional
`image_png_base64` (up to 2 MiB decoded). Screenshots may be disabled
locally. The application validates arguments and requests any local
confirmation; the model cannot authorize or override it.

For a known, eligible tool with invalid arguments, the agent may request
one JSON-schema correction before sending any call to the app. The tool
cannot change, and a refusal or invalid correction dispatches nothing.
Corrected arguments are validated against the original schema and still
require normal state, revision and approval checks.

Operational logs distinguish rejected, dispatched and acknowledged calls.
They use server-generated session and call IDs, a server turn number,
advertised tool names and fixed categories. They do not print prompts,
model text, argument values, dataset identifiers or client result contents.
The turn summary distinguishes a completed answer from confirmed changes.

A state read is required before a mutation, including scope transitions.
The harness reuses a confirmed read in the current turn, scope and view
revision. Otherwise it calls a native tool with the `application_state`
role and valid empty arguments (`{}`) before dispatching the proposed
change, without another model request. If the catalog requires arguments
for the state read, the model must read it explicitly. A failed or stale
read does not authorize a change. Automatic reads count toward any
negotiated `max_calls` limit.

Opening a dataset requires a recent catalog search result.
Successful scope-transition receipts include
`dataset_transition` (new `dataset_id`, `context_id` and `tools`).
The agent verifies the receipt and replies with `context_updated` before
planning in the new scope. For unrelated scope changes, the idle client
sends `context_changed` with the new catalog.

## Cancellation and collaboration

Send `cancel` with the active request ID. The server cancels pending work
and emits `cancelled`; an in-flight native call may receive `tool_cancel`.
Closing the WebSocket also cancels the turn. Neither path undoes confirmed
changes. Uncertain mutations are never blindly replayed.

When collaboration is negotiated, `user_change` carries the context IDs,
monotonic `revision`, affected `domains`, `active`, and a state
snapshot when the intervention ends. Calls and results carry
`view_revision`. Manual changes take precedence and can cause
`collaboration_paused` and `collaboration_resumed` events.

The application can expose `get_command_history` as a scoped read tool.
Its receipts are evidence, not live state or permission to replay.

An optional research deployment can provision an observer profile. Both
the chat bearer token and `X-BorgVR-Observer` are required for the
observer API; see [WORKFLOW_LEARNER.md](WORKFLOW_LEARNER.md).

## Packaged and learned procedures

The Workflow Learner may turn a recurring, evidence-backed workflow into a
versioned executable procedure. Approved procedures are internal tools made
available to the model by the agent on a per-session basis. They are not app
tools: their names do not become WebSocket `tool_call` messages. The base
v1 handshake and native tool and receipt formats remain unchanged for
clients that do not negotiate knowledge bundles.

- A procedure declares typed inputs and results, required app capabilities,
  observable effects and execution bounds. A version retains its approval
  and evaluation record separately from the executable definition. Drafts
  and pending hypotheses are not callable. Imported definitions are checked
  against the destination profile and session's capabilities before use.
- A procedure invocation runs its deterministic steps without intermediate
  model calls. It returns bounded results and selected evidence for the
  model to interpret, or an explicit partial, unavailable or cancelled
  outcome. If semantic judgment is needed during execution, return the
  evidence to the model rather than hiding a model call inside the tool.
- Native subcalls use the existing dispatcher, schemas, scope and revision
  checks, and local approvals. Procedures cannot grant permissions or turn
  a refusal into another execution path. The first version supports only
  computation and isolated previews; durable changes remain separate app
  calls. Cancellation or a user intervention stops the current procedure.
- Measure interactive model requests, model-input images and wall time on
  equivalent tasks with and without the procedure, alongside task quality.
  Count background learning and validation requests separately so reduced
  interactive load is not mistaken for reduced total model usage.

The learner can propose and test a draft without a live app session.
The [knowledge v1 schema](schemas/knowledge-v1.schema.json) defines two
JSON payloads: `knowledge_bundle` for offering entries to a session and
`learner_checkpoint` for returning and porting private learning state.

### Knowledge entries at hello

A knowledge entry has one ID, situation, goal, origin and entry revision.
It contains `guidance`, `procedure`, or both. The parts have separate
revisions and `review` values (`pending`, `approved`, `rejected`). The
client's approval records are bound to the exact part revision, content
and applicability; changing one part does not approve the other. A new
situation or scope requires rechecking both. Imported approval flags are
metadata, not proof of approval or authority on the receiving server.

The opt-in extension advertises `BorgVR-Knowledge-Bundles: 1` on
`HEAD /healthz`. If present, the client can include an `expert_knowledge_bundle`
field in `hello` with `{ "kind": "knowledge_bundle", "version": 1, "entries": [...] }`
alongside legacy `expert_knowledge_toml` during migration. Clients omit
the new field when the header is absent. The bundle is at most 128 KiB
of UTF-8 JSON and contains no evidence images or learner checkpoints. Any
`evidence_ids` here are provenance references only; the live session need
not resolve them.

The agent validates the bundle in the current session. Bundled
definitions and approved learned definitions share the same format and
interpreter, but keep distinct identities and provenance. A supplied
definition cannot replace a native tool or a profile's approved version,
grant permissions, or execute on receipt. Only eligible, approved guidance
is used as text, and only eligible, approved procedures are exposed as
model tools. Either part can be usable without the other. The optional
`knowledge_bundle_status.available_procedures` in `ready` lists eligible
names separately from `ready.tools`. An unsupported procedure does not
prevent the client from using native tools. Availability is re-evaluated
on scope changes using the bundle held in the session.

### Portable learner checkpoint

`GET /v1/observer/checkpoint` returns a consistent, committed
`learner_checkpoint` for the authenticated observer profile, even if the
worker is still processing. It contains draft and evaluated entries,
open hypotheses, their next steps, and actual evidence records. Each
hypothesis references supporting, contradicting or inconclusive evidence
by ID. All referenced entries and evidence must be included; a link into
the source server's database is not sufficient. Images require separate
capture and transfer consent and are optional PNG payloads, not file paths.
A checkpoint is at most 16 MiB of UTF-8 JSON; the server checks decoded
image format and size as well as record and reference bounds. It must not
silently drop referenced evidence to fit the limit.

BorgVR stores the newest complete checkpoint by lineage and revision and
can send it to `POST /v1/observer/checkpoint/import` on another server.
Both endpoints require the chat and observer credentials. The destination
binds the import to its authenticated profile, not to an ID or credential
in the document. Import into an empty profile is atomic. Repeating an
identical import is a no-op; an import that conflicts with existing state
returns `409` and never replaces state while the worker is running. On
ordinary reconnect to a server that still owns the state, continue there
and fetch a fresh checkpoint rather than uploading an old copy. Imported
drafts and open hypotheses are learner state, not callable tools or
active guidance; the import does not carry forward execution authority.

### Callable capabilities

The harness supplies a machine-readable operation catalog to both the
learner and the procedure validator. The catalog is the callable API,
not a list of installed packages. Each operation has a stable namespaced
ID, a contract version, typed input and output schemas, an effect class,
and enforced resource bounds. Procedures reference operation IDs and
versions; they cannot import packages or use arbitrary function names.

- `compute.*`: pure computation in the harness, independent of a live
  app. The initial image comparisons use Pillow. More numerical and image
  operators may be added with libraries such as NumPy or headless OpenCV.
  Provider implementations belong to the deployment, not to procedures.
- `app.*`: bindings to specific abilities advertised by the connected
  BorgVR client, such as rendering an isolated preview. These calls
  remain subject to the existing dispatch and permission checks. Offline
  tests may bind a synthetic implementation, never a live user session.
- `procedure.*`: approved, versioned procedures may be composed. The
  validator checks their dependencies and effective permissions and
  budgets transitively; nesting cannot expand any of them.

At validation time, resolve every dependency against the catalog and
report unavailable or incompatible operations. At invocation time, check
again against the active session and local grants. Image inputs and
outputs can be passed as temporary, session-scoped handles between steps;
only selected images are sent to the model. No catalog entry grants host
filesystem, network, subprocess, or arbitrary code access. A future
isolated runner for generated numerical code is a separate design, not an
implicit capability of installing Python packages.

### Procedure encoding

`borgvr-flow-v1` is a JSON program, not Python source. Its blocks contain
ordered steps and a `yield` expression. `call` invokes an exact catalog
operation version, and `as` binds its result locally. An `if` reads a
Boolean and binds the selected block's result. A `for_each` reads a list,
binds a fresh loop variable per element, and returns the list of body
results. Exceeding the `for_each` limit is an explicit error. `iterate`
updates a state value up to a fixed limit and may stop sooner when a
Boolean condition on the new state is true. Values are JSON literals or references to `input`
and previously bound values. A reference reads object fields; it is not
a Python expression or attribute lookup. For example:

```json
{
  "steps": [{
    "kind": "call", "operation": "compute.image_difference", "version": 1,
    "args": { "left": { "ref": "input.before" }, "right": { "ref": "input.after" } },
    "as": "difference"
  }],
  "yield": { "ref": "difference" }
}
```

The structural schema alone is not an execution permit. Before offering a
procedure, the interpreter must validate local schemas (no remote schema
references), dataflow and operation types, cap nesting and worst-case
work, reject recursive dependencies, and derive effects from the resolved
catalog. During execution it enforces time, call and memory bounds and app
checks. Python can implement the interpreter and operators, but a bundled
or learned procedure cannot import, evaluate or dispatch arbitrary code.

An optional `announcement_hint` asks the model to supply a short
`progress_message` in the user's language. The hint is not rendered or
spoken verbatim. The agent sends the model's announcement before the
first step in a non-final `assistant_message`; inconspicuous procedures
may omit the announcement. No separate inference request is needed.

### Bundled intensity sweep

`flow_intensity_sweep` is supplied by BorgVR and only offered when the
client advertises `capture_tf_preview` and image sharing is enabled. It
starts with five equally spaced bands; by default it splits neighboring
bands where at least 20% of image pixels differ in alpha. The search is
bounded by minimum band width, render count, and procedure runtime. It
returns normalized intervals and at most one contact sheet, rather than
placing every preview into model context. BorgVR renders a fixed coarse
Z projection of unsigned scalar data. It uses a gray or rainbow ramp
with binary per-band opacity; it does not change the live TF or camera.
The projection can miss fine or occluded features and is not a segmentation.
