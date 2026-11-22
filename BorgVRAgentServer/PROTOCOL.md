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

A state read is required before a mutation. Opening a dataset requires a
recent catalog search result. Successful scope-transition receipts include
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
