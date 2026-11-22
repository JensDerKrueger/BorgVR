# Agent runtime

The native client uses the existing [version 1 WebSocket protocol](PROTOCOL.md).
The runtime owns no BorgVR dataset, rendering state, or filesystem tools.
The native app is responsible for applying commands and for human approvals.

| Component | Owns |
|---|---|
| `app.py`, `settings.py` | HTTPS/WSS endpoints, authentication, bounded admission, provider and service lifetime |
| `connection.py`, `protocol.py` | One connection, negotiated tools and dataset scope, wire validation and receipt correlation |
| `orchestrator.py`, `continuation.py` | Active request, resumption boundaries, confirmed mutations, terminal response and conversation history |
| `native_dispatch.py` | One tool in flight, native preconditions, timeout and result handling |
| `agent_factory.py`, `context.py` | Model adapter, per-request inference slots and model-context projection |
| `policies.py`, `strategies.py` | v1 compatibility guidance and advisory rules from the connected app |

Execution receipts and feedback are not conversation messages. A checkpoint
may drop model context, but does not drop confirmed mutations or the retained
conversation. Duplicate protection for reconstructed actions is conservative:
matching data from before a boundary can be blocked, but equal arguments for
new relative operations within the same segment are not execution identities.
The wire call ID still identifies exactly one dispatch. An unacknowledged
mutation is uncertain; an expired read only loses an observation.

The [optional workflow service](WORKFLOW_LEARNER.md) uses per-device credentials
unrelated to the chat key. Its worker runs separately and uses only the shared
private SQLite store. It has no network or GPU access. Portable profile state
holds explicit demonstrations and hypotheses, not credentials or session
traffic. Neither the worker nor an imported snapshot may change an interactive
prompt or grant a tool permission.
