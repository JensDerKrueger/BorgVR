# BorgVR assistant core

The interactive assistant is an opt-in Swift module shared by macOS, iOS and visionOS. It coordinates requested work against the live application. It has no UI references and does not require a Python agent, WebSocket session, MCP listener or GSC interpreter. It does not observe or learn in the background.

## Authority and decision loop

- `BorgVRAssistantCore` builds the next model request from the user's goal, confirmed application state, selected guidance, recent outcomes, and relevant render images. A response proposes `investigate`, `apply`, `ask`, or `finish`. It does not have execution authority.
- `AssistantWorkspace` is the application interface. `VoiceAgentController` binds start, stop and local consent to that interface. `BorgVRVoiceAgentBridge` uses the in-process MCP router and existing command services, including file pickers and confirmations for consequential changes. Model arguments cannot grant consent.
- The workspace tracks the dataset opening and manual revisions. Old model output cannot execute against a later revision. Evidence is discarded when its revision is no longer current. A stopped task cannot start another command, and an uncertain mutation is never automatically replayed. Cancellation does not undo completed operations.
- A successful command receipt is not proof that the visual goal was met. The UI reports confirmed changes separately from the model's text. A clarification can continue the same in-memory work and receipts. An optional encrypted conversation archive contains text and confirmed tool receipts, not the working image evidence. Provider changes invalidate the local conversation owner.
- `VoiceAgentModelClient` uses structured HTTP requests. vLLM uses `/v1/models` and `/v1/chat/completions`; OpenAI uses `/v1/responses` with `store: false`. OpenAI uses system TLS and a separate Keychain key and image consent. Microphone audio, passthrough and camera images are not provided to either model. The application's local speech recognition setting remains independent of the model provider.

## Knowledge packages

The example is [`assistant-knowledge.json`](assistant-knowledge.json). An edited JSON file can be imported in **Settings > AI Assistant > Import knowledge package**. It replaces the bundled package for the next task, is validated before use, and can be reset without a rebuild. An in-progress task uses its original package.

Version 1 has two independent sections. `rules` are English guidance with unique IDs, optional `operations` and language-neutral tool names, `topics` for retrieval, and `text`. The selector filters by available operations and ranks a small number using the goal, current focus, and recent operation. It does not require a separate model call. Topic matching is lexical; the bundled English and German terms are examples, not a guarantee of multilingual retrieval. Selecting or importing a rule never grants permission.

`workflows` are data: a unique `inspect.*` ID, a description and a short list of typed read-only steps. Supported primitives are `screenshot` (a bounded width) and `intensityScan` (initial bands, maximum number of previews, minimum band width, difference threshold and palette). New compositions and options need no app rebuild; new primitives need Swift. No arbitrary source code, paths, network access, or loops from packages are executed.

The sweep makes isolated coarse projections of an unsigned scalar channel. It refines adjacent bands where enough pixel visibility differs, within the configured budget. Scores are not anatomy or noise recognition. The model can request actual previews two at a time and choose one it has seen. Applying a chosen band builds its opacity and palette at the live transfer function's existing resolution and uses the local Command path. The coarse preview is not the live render; inspect the live result as needed. No sweep is required when existing evidence suffices.

## Verification and scope

`sh Scripts/test-voice-agent.sh` covers schema validation, the native sweep loop with synthetic images and decisions, stale evidence, stop, and both provider payloads and replies. Pass the `macOSApp` Debug products directory for real BorgVR bridge/GSC/security tests. On a running GPU host `sudo ./setup.sh test` checks HTTPS, key enforcement, endpoint restrictions, vision and structured output using a synthetic image. Local tests do not establish how well a specific model recognizes anatomy or other structures.

Point 2 (target-directed visualization) is the first focus. Direct commands share the execution path. Learned personal routines and an exploratory collaborator are future work, not hidden modes in the current application.
