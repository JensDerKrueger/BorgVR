# Workflow research prototype

The research controls are only available in debug builds. The normal renderer
has no demonstration button and the assistant does not require a recording mode.
For an explicit research run, enable the assistant, open a dataset and expand
**Workflow research (debug)** inside the assistant window. Choose a goal from
the recording menu, work with the native controls, then finish and optionally rate
the outcome. Export the demonstration from the same menu. A
finished demonstration is held in memory until exported, queued, discarded,
or the app exits.

Standard exports (v1) contain the goal, consecutive manual command domains
(adjacent repeats are collapsed), outcome, completion status, and an episode ID.
Choose **Demonstrate with before and after view settings** to add a v2 pair:
normalized dataset-local clipping bounds and the view rotation at the start and
finish. The pair is omitted if a snapshot is unavailable, the demonstration is
interrupted, or another source changes the recorded state. The export and
upload actions indicate when settings are included. Neither version contains
microphone input, images, dataset IDs, file paths or a raw command log.
Starting a chat request or changing datasets ends the demonstration as
interrupted; the learner also excludes unfinished, limit-truncated and
unknown-goal demonstrations. No demonstration is automatically uploaded.

### Separate screenshot consent

To record images, choose **Demonstrate with before and after screenshots**.
Confirm the one-time prompt and wait for the recording indicator before
changing the view. BorgVR captures one new rendered frame at each end:
no app chrome, desktop, microphone or passthrough. Rendered content and
annotations may still reveal sensitive details. A missing, interrupted or
invalidated capture does not produce a partial pair. This is a frame
boundary check, not a guarantee that all bricks have streamed or that two
head poses on visionOS match.

**Export demonstration with screenshots** creates a separate JSON bundle
containing the ordinary demonstration and two bounded PNGs under
`screenshots.before_png_base64` and `screenshots.after_png_base64`.
The images stay on the device until this explicit export. The bundle is
not a workflow-upload format and the server does not accept it.

From the `BorgVRAgentServer` directory, pass explicitly selected exports from
**one person's isolated corpus**:

```sh
python3 -m borgvr_agent.workflow_learner first.json second.json third.json
```

The offline prototype has no accounts and must not be used as a shared
corpus. The JSON report is deterministic and separates distinct supporting
episodes, alternative beginnings and self-reported outcomes. It reports a
first step or two-step opening only if at least three distinct finished episodes
support it and it occurs in a majority of cases for the goal. This threshold is
an experimental filter, not an estimate of reliability. The tool cannot infer a
narrow Gaussian transfer function from a generic transfer-function event
and it does not assert which strategy works better. It writes no rules to the
agent and has no model dependency.

## Clipping experiment

Run the reproducible synthetic comparison from `BorgVRAgentServer`:

```sh
python3 -m borgvr_agent.workflow_experiment
```

The training examples have identical action sequences but different clipping
effects. Eight held-out views test the direction of the conditional change and
whether a method abstains on an unsupported condition. The category baseline
cannot make conditional predictions. The numeric baseline computes widths and
accepts a change only with three distinct supporting episodes and a strict
majority. This evaluates reconstruction of a numerical effect, not whether
the desired feature became visible.

Add `--agent-url https://HOST:PORT --ca /path/to/certificate --repeat 3` to
run the LLM comparison through an existing agent. Supply its chat token via
standard input or `--token-file /path/to/private/token` (never on the command
line). This route uses only the synthetic training records and offers no app
tools. A trusted direct vLLM endpoint can be selected with `--vllm-url`,
`--model` and the vLLM token instead. Only that direct route allows explicit
local exports via `--demonstrations` for a single person's corpus, and it
has no held-out score for those exports. Proceed only with consent for those
selected records to be sent to that model. The model receives no episode IDs,
only case aliases, and must cite consistent evidence. Nothing is executed,
published as a rule or added to the Task Agent's memory. The server worker
still runs only the CPU baseline.

## Visual visibility evaluation

The visibility experiment renders synthetic image pairs with a target and a
same-color distractor. The rendering fixture computes ground truth from
target and occluder masks independently of the model. The evaluated transitions
are newly visible, still hidden, still visible, and no longer visible.
Command and numeric evidence are identical across cases. Compare the old
category baseline, the same model with only text, and the model with text
plus before/after images. Counts separate wrong results, abstentions and
unscored replies. Use the agent chat token via standard input:

```sh
python3 -m borgvr_agent.workflow_visibility --agent-url https://HOST:PORT \
  --ca /path/to/certificate --layout single-pair
```

The alternative `--layout contact-sheet` runs two six-pair batches. The
single-pair run uses new cases, not crops of those batches. The script only
serves the generated PNGs through a synthetic read-only screenshot tool; it
never reads demonstration files or app state. This tests a controlled visual
comparison, not scientific or clinical interpretation. The results do not
automatically become learner rules.

## Optional shared-server trial

The normal installation does not enable the workflow API. For an isolated trial,
run the current source/image with `BORGVR_WORKFLOW_DB` set to a database path
in a dedicated persistent directory. The directory must be owned by the agent's
UID with mode `0700`; the service creates a `0600` database. Do not place it in
an upload or deployment directory, or add it to Git.

For Compose, create the directory on the host using the numeric `BORGVR_UID`
and `BORGVR_GID` from the installation's `.env`, and set
`BORGVR_WORKFLOW_DATA` to its absolute path in that file. Append
`-f compose.workflow.yaml` after the installed GPU backend overlay in each
Compose command. For example, on a CUDA development checkout using an agent
image tag that can be built locally:

```sh
sudo docker compose -f compose.yaml -f compose.cuda.yaml -f compose.workflow.yaml \
  -f compose.build.yaml up -d --no-deps --build agent
```

The regular setup commands do not manage this experimental overlay. Keep the
directory when stopping the service; remove it deliberately after stopping the
workflow service if its data is no longer needed. It is outside the uninstaller's
managed directories. Use the appropriate CUDA-all or ROCm options if applicable.

Inside the running agent container (as the normal container user), provision
one profile per person and one device token per device:

```sh
python -m borgvr_agent.workflow_store --database /var/lib/borgvr-workflow/workflow.sqlite3 create-profile
python -m borgvr_agent.workflow_store --database /var/lib/borgvr-workflow/workflow.sqlite3 add-device PROFILE_ID
```

A new token is shown only at creation. Treat it as a secret and transfer it
privately. It is distinct from the chat token. In a BorgVR debug build, set the
HTTPS address and certificate, then expand **Workflow research (debug)** in the
assistant settings, enter the new token under **Workflow profile**, and link.
Linking enables the separate **Send demonstration for analysis** action for
demonstrations started under this profile. No recording or upload is started
by linking, and manually exported files are not uploaded. A failed send
leaves the entry on disk; retry explicitly in settings. The app never retags
the queue when a different profile is linked. A draft that has not yet been
queued or exported is discarded when its linked profile changes. If a server collection was
cleared, relink the same token to see the new collection; old entries can be
deleted locally but will not be sent into it.

The server keeps a bounded corpus and the latest durable analysis job for
each profile. It can finish the descriptive analysis after BorgVR quits
and resume queued work after a service restart. There are no model or GPU
calls in this phase. The HTTP API is separate from chat:

| Request | Behavior |
|---|---|
| `GET /v1/workflow/profile` | Profile, device and corpus IDs for this bearer token. |
| `POST /v1/workflow/episodes` | Accept a single v1 or v2 episode with `X-BorgVR-Corpus` set to the capture's corpus ID; duplicate receipt is safe. |
| `GET /v1/workflow/report` | Empty, queued or ready report for the caller's profile. No foreign profile selector. |
| `DELETE /v1/workflow/corpus` | Delete episodes and report, invalidating queued work and uploads for the old `X-BorgVR-Corpus` ID. |

For devices you no longer trust, use `revoke-device PROFILE_ID DEVICE_ID`
with the same admin command. To remove the server-side profile and its
data and revoke every device, use `delete-profile PROFILE_ID --yes`.
Storage is capped at 128 episodes per profile; there is no automatic expiry
in this trial. Do not use real clinical data in the demonstration trial.
Use **Fetch workflow report** in the workflow profile settings to see whether
analysis is queued and, once ready, view opening patterns and their support.
The report does not change the interactive assistant.
