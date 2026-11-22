# Agent runtime

BorgVR owns its datasets, renderer state and local approvals. It sends the
active tool schemas, execution types and expert rules over the
[version 1 WebSocket protocol](PROTOCOL.md). The agent is not an MCP client
and does not own a second BorgVR tool catalog.

| Component | Responsibility |
|---|---|
| `borgvr_next/app.py`, `wire.py` | TLS listener, authentication, bounded admission and wire validation |
| `session.py`, `agent.py` | Scope, active turn, tool execution gates and confirmed receipts |
| `model.py` | Timed vLLM requests, token budgets and response validation |
| `expert_knowledge.py` | Per-connection advisory rules filtered by the active catalog |
| `evidence.py`, `learner.py` | Optional, separate observer store and inference worker |

Compose installs this runtime as its sole agent. vLLM remains a separate
inference container. The agent has no GPU device or filesystem tools; only
the app executes commands, handles file selection and grants permission.
