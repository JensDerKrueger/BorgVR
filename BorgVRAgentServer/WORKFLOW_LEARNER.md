# Workflow research

BorgVR debug builds offer a local demonstration export. Open a dataset,
expand **Workflow research (debug)**, choose a goal and perform the actions
with the native controls. Finish or rate the demonstration, then export it.
Nothing is uploaded. Before and after view settings are optional; render
images require separate consent and are only included in a local export.

## Observer worker

The optional observer is separate from chat execution. It evaluates opted-in
episodes, then groups evidence and counterexamples into hypotheses. Each
profile is isolated. Candidates are not automatically approved rules and
cannot grant tool permissions. The worker can process queued episodes after
the client disconnects. It calls an LLM; it does not require direct GPU access.

The standard setup does not enable the observer. For a research instance,
configure a private directory for the SQLite database and set
`BORGVR_NEXT_EVIDENCE_DB` to that database in the agent. Provision a profile
and run the worker with the same database:

```sh
python -m borgvr_next.learner provision /private/path/observer.sqlite3
python -m borgvr_next.learner work /private/path/observer.sqlite3
```

Set `BORGVR_NEXT_LEARNER_URL`, `BORGVR_NEXT_LEARNER_MODEL` and
`BORGVR_NEXT_LEARNER_TOKEN_FILE` for the worker. The observer credential is
distinct from the chat bearer token. A consenting protocol client uses
`X-BorgVR-Observer`; the hypotheses endpoint requires both credentials.
The native app does not yet enroll observer profiles or move their state
between servers.
