# Independent agent rebuild

`borgvr_next` is a runnable development implementation. It does not import
`borgvr_agent`, and it is not wired into production Compose or setup. The old
implementation and all BorgVR code remain available for comparison.

## Boundaries

- `wire.py` validates v1 packets, tool schemas and the action types declared by
  the Swift app. The app provides the full catalog for its current scope.
  The server has no BorgVR tool allowlist. The app continues to execute
  commands and to own local authorization.
- `session.py` correlates native receipts and coordinates dataset scopes and
  manual intervention. `agent.py` orchestrates a request through a small port.
- `model.py` calls the configured vLLM endpoint. Only model requests use the
  interactive inference slots, not local dialogs or render waits.
- `expert_knowledge.py` validates the app's bounded TOML bundle per connection.
  It supplies rules relevant to the current scope and available tools as
  advisory input, never as server policies or authorization.
- `learner.py` is an independent process. It evaluates observed interactions
  with an LLM, then proposes broader strategies with supporting and
  contradicting evidence. There is no tool execution interface in the worker.

The experimental observation interface is opt-in. In addition to the chat
bearer token, a test client can supply an explicitly provisioned
`X-BorgVR-Observer` profile token. Disconnected clients are not required for
processing evidence. The service will not infer user intent from unobserved
activity or count a manual change by itself as a correction. Suspect, incomplete
or uncertain evidence must not become a rule. Hypotheses based on fewer than
three separate sessions remain pending. Candidates are not automatically
trusted by the interactive agent.

## Development use

Use a private, service-owned directory for a new SQLite database, not the
database of the existing workflow service. Provision a test profile with
`python -m borgvr_next.learner provision /private/path/observer.sqlite3`.
Keep the returned profile token private. Run the evaluation worker with
`python -m borgvr_next.learner work /private/path/observer.sqlite3` and set
`BORGVR_NEXT_LEARNER_URL`, `BORGVR_NEXT_LEARNER_TOKEN_FILE` and
`BORGVR_NEXT_LEARNER_MODEL`. The worker does not need a GPU device; inference
runs on the GPU of the configured vLLM service. Use a separate endpoint until
shared inference priority is implemented.

For an isolated development listener use `borgvr_next.app:from_env --factory`
as the Uvicorn entry point. Configure TLS on the test listener, set a 4 MiB
WebSocket frame limit, and set the model URL, model name, token file and chat
token file using `BORGVR_NEXT_MODEL_URL`, `BORGVR_NEXT_MODEL`,
`BORGVR_NEXT_MODEL_TOKEN_FILE` and `BORGVR_NEXT_TOKEN_FILE`. The optional
`BORGVR_NEXT_EVIDENCE_DB` points to the same private database used by the worker.
Interactive generation may use the remaining token budget reported by vLLM,
bounded by `BORGVR_NEXT_CONTEXT` (default 65536) and a 512-token reserve.
Each interactive generation has a 180-second deadline, within the overall
turn budget. The background learner keeps a separate 60-second deadline and
4096-token ceiling per generation.
Current BorgVR clients negotiate a time budget without a tool-call count.
The default overall budget is 60 minutes, adjustable in BorgVR from 5 to 180
minutes. It bounds the entire turn and does not change the model or tool deadlines.
Idle connections still expire after five minutes.
Older clients can still request a finite count through the existing protocol.

## Before switching the native app

The runtime expects the negotiated typed catalog. Updated clients still send
the untyped v1 catalog to older servers. The macOS TLS roundtrip is exercised
with `Scripts/test-voice-agent-catalog.sh`; the Python catalog tests also
check the actual Swift-projected tool schemas in several capability variants.
This does not yet cover full behavioral parity or context continuation.
Observation currently requires a test client; the native consent and
profile UI, portable learner state, and shared model priority are still open.
Do not deploy it as a replacement for the current server until the existing
black-box and native compatibility suites pass against this entry point.
