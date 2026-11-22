# Agent runtime and deployment

`borgvr_next` is the agent installed by the Dockerfile and standard Compose
setup. The application sends the typed tool catalog and its expert knowledge
on each connection. The server does not maintain its own BorgVR tool list.

Use [setup.sh](README.md) from a Git checkout to build and install the
current image, or select a prebuilt `typed-v1` release with `--agent-image`.
Development shortcuts and their cleanup are documented in
[DEVELOPMENT.md](DEVELOPMENT.md).

The image runs `borgvr_next.app:from_env`. Compose supplies
`BORGVR_MODEL`, `BORGVR_VLLM_URL`, `BORGVR_CONTEXT_LENGTH`,
`BORGVR_THINKING_MODE`, `BORGVR_TOKEN_FILE` and `BORGVR_VLLM_TOKEN_FILE`.
Tokens and certificates are mounted, not copied into the image.
`BORGVR_NEXT_MODEL_SLOTS` sets the interactive model concurrency; Compose
takes it from the selected vLLM profile. Optional observer storage uses
`BORGVR_NEXT_EVIDENCE_DB`; it is not enabled in the standard setup.

The default work budget is 60 minutes (adjustable from 5 to 180 in BorgVR),
without a fixed tool count for current clients. Each model generation has
a separate 180-second deadline and may use the available context minus a
512-token reserve. Idle sessions expire after five minutes.

Tests cover TLS and authentication, client-to-model catalogs and advisory
knowledge, confirmed transitions, cancellation and tool checks. Automatic
continuation after a long current turn exhausts its context is not supported.
The optional observer is a separate research feature; see
[WORKFLOW_LEARNER.md](WORKFLOW_LEARNER.md).
