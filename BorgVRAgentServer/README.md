# BorgVR agent server

[Deutsch](README.de.md)

For **Windows 11 with an NVIDIA GPU**, start with the [WSL 2 guide](WINDOWS.md).
It covers Docker Desktop, Docker Engine inside Ubuntu and Windows network access.
The host preparation steps below apply to **native Linux**.

Self-hosted server for BorgVR's conversational assistant on macOS, iOS and visionOS.
The assistant accepts voice and text requests, controls the visualization of an open
dataset, interprets render images and provides text updates while working.

## Architecture and responsibilities

The server is needed **only for the AI assistant**. Normal BorgVR controls and rendering
work without it. The model runs on the Linux machine so its GPU and memory can handle
inference without installing the model on every iPhone, Mac or Vision Pro device.

Responsibilities are split between the app and two containers:

| Component | Responsibility |
| --- | --- |
| BorgVR app | Accepts voice or text, displays responses and executes permitted visualization commands. Datasets and rendering stay in the app. |
| BorgVR agent | Manages conversations, queries the model and relays validated tool calls between the model and the app. Provides the TLS- and token-protected client endpoint. |
| vLLM | Loads the selected vision-language model and uses the GPU to generate responses and proposed tool calls. |

**Why two containers?** vLLM needs the GPU runtime and model weights; the Pydantic AI agent
contains BorgVR-specific conversation and tool orchestration. Keeping these dependencies
separate allows independent updates or model changes without changing BorgVR's connection
protocol. Only the agent is reachable from the client network; vLLM stays on the private
container network.

A request follows this path:

1. BorgVR converts speech to text or accepts a typed request, then sends it to the agent
   over an encrypted WebSocket connection.
2. The agent queries the model through vLLM. The model can respond with text or request
   a tool, such as reading the current visualization state or rotating the volume.
3. The agent validates the call and forwards it to BorgVR. The app validates it again,
   executes it through its shared command layer and returns the result.
4. The agent can perform further steps or send the final response. BorgVR can read the
   response aloud locally.

With separate permission, the app can provide render images to the model. The agent does
not receive complete volume files or camera/passthrough access. It is distinct from the
BorgVR dataset server and does not provide dataset catalogs. Anatomical identifications
must be checked by the user; the assistant is not a medical diagnosis feature.

The steps below install and test the server first, then connect the app using the
certificate and access token created during installation.

## 1. Requirements

- Linux x86_64, or Windows 11 x86_64 with WSL 2 as described in the separate guide.
  On native Linux, the host package installer supports **Ubuntu 22.04, 24.04 and 26.04 LTS**.
  Other distributions need Docker,
  Compose and the matching GPU runtime installed by their administrator.
- A supported **NVIDIA/CUDA or AMD/ROCm GPU** with a matching working host driver.
  Weights, image encoder, KV/context cache and runtime overhead must fit
  the available GPU/host memory. Smaller or suitably quantized models can need much less.
- Free Docker storage: profile reserves are **200 GiB** for Qwen3.6-35B, **160 GiB** for
  Qwen3.8-27B and **80 GiB** for Qwen3.5-4B. These are adjustable conservative starting
  budgets (`--min-free-gib`), not measured model sizes or guarantees.
- Docker Engine and Compose v2; NVIDIA also requires NVIDIA Container Toolkit.
- Internet access for signed OS repositories, Docker Hub, PyPI and Hugging Face's model/CDN
  endpoints. The initial weights download is large; first startup and kernel compilation
  can take considerably longer than subsequent starts.
- Python 3 and OpenSSL on the host for configuration; Git only if cloning the repository.
  Python 3.12, inference libraries and CUDA user-space libraries run in containers.
  A host CUDA Toolkit installation is **not** necessary.
- One account with sudo privileges for setup and container operations. Ordinary BorgVR
  users need **no Docker account, shell access or root privileges**: they connect to the
  shared agent endpoint. No separate maintenance account or Docker group is required.

For NVIDIA, first verify the existing driver:

```
nvidia-smi
```

AMD needs a working ROCm-compatible driver exposing `/dev/kfd` and `/dev/dri`.
If the driver does not work, install the distribution/vendor-supported driver and reboot if required.
The installer deliberately does not select/replace drivers, change Secure Boot, or reboot.
The driver must support the CUDA/ROCm runtime of the chosen image; `doctor` allocates
a GPU tensor inside it using the selected dtype rather than guessing from version numbers.
Automated configuration and protocol tests do not guarantee that every model works on
every GPU. Run `doctor` and `test` on the target GPU host. AMD/ROCm has not been validated
on real hardware.

## 2. Copy the deployment

Clone the public repository over HTTPS, or copy the complete `BorgVRAgentServer` directory
to the server. HTTPS cloning requires no SSH key. Run each command separately:

```
git clone https://github.com/JensDerKrueger/BorgVR.git
```

Then enter the deployment directory:

```
cd BorgVR/BorgVRAgentServer
```

Do not copy another installation's `.env` or `runtime` directory. Each installation should
generate its own credentials. No Hugging Face login is required for the default public model.

## 3. Host setup and two-container deployment

There are **two runtime containers**: the upstream vLLM image and our agent image.
`compose.yaml` is pull-only: it contains no image build. Only image producers/developers
use `compose.build.yaml`. No privileged installer container or mounted Docker socket is needed.
The script selects `compose.cuda.yaml` or `compose.rocm.yaml` automatically. Use the script
for startup/update, not a bare `docker compose up` without the backend overlay.

Use the same sudo-capable account throughout. When already logged in as root, omit `sudo`.

### A. Check prerequisites

If Docker is already installed, check it first:

```
sudo docker compose version
sudo docker ps
sudo docker info
```

These checks apply to both backends: Compose v2 must be available and the local Docker
daemon must be running. Then check the GPU access for the backend you intend to use.

**NVIDIA / CUDA:** Check the driver and Docker's registered GPU runtime:

```
nvidia-smi
sudo docker info --format '{{json .Runtimes}}'
```

`nvidia-smi` must list the GPU, and Docker's runtimes must include `nvidia`.

**AMD / ROCm:** Check that the driver exposes the required device nodes:

```
ls -l /dev/kfd
ls -l /dev/dri
```

`/dev/kfd` must be a character device and `/dev/dri` must contain the GPU device nodes.
No NVIDIA runtime or NVIDIA Container Toolkit is required for this backend. Device nodes
alone do not prove model compatibility; installation tests GPU allocation in the selected image.

If Docker and the selected backend's prerequisites are ready, proceed to B. Existing
containers are retained. vLLM reserves 85% of the selected GPU's memory by default, which
can affect competing GPU workloads.

Only if prerequisites are missing, run a reviewed copy of the host script for your backend.
For NVIDIA:

```
sudo ./setup-host.sh --backend cuda
```

For AMD:

```
sudo ./setup-host.sh --backend rocm
```

Both paths prepare Docker and Compose using official signed repositories. Only the CUDA
path additionally installs NVIDIA Container Toolkit and configures its runtime. The ROCm
path uses the existing AMD driver and does not restart Docker. Neither path installs or
replaces GPU drivers. Conflicting Docker packages are refused rather than removed; for
existing Docker installations, install a missing Compose plugin from its existing source.

If the script reports that a Docker restart is required, arrange a maintenance window
for the existing containers before running `sudo ./setup-host.sh --allow-docker-restart`.
`--allow-docker-restart` explicitly permits NVIDIA runtime registration and a Docker restart
if needed, potentially interrupting other containers. Without it, an already configured
runtime is retained, but a required runtime change is refused. Host setup creates no app
configuration, access tokens, certificates, model downloads or app checkout. It never reads
the app's `.env`. No user is added to the Docker group by default.

If all host prerequisites already work, skip this step.

### B. Install and start

For an initial local-only installation, run in `BorgVRAgentServer` and select your backend.
For NVIDIA:

```
sudo ./setup.sh install --backend cuda
```

For AMD:

```
sudo ./setup.sh install --backend rocm
```

`setup-host.sh` does not save the backend selection for `setup.sh`; select it explicitly
when creating the deployment. Subsequent commands retain the backend stored in `.env`.

This creates `.env`, tokens and a test certificate, checks the profile's storage reserve
and GPU, pulls missing images, and starts both services. The public
[agent image 3.9.2](https://github.com/JensDerKrueger/BorgVR/pkgs/container/borgvr-agent)
supports model profiles. No registry login or local build is needed.
vLLM downloads the pinned model into its persistent cache; the agent starts only when
vLLM is healthy. First download/compilation can take up to the one-hour readiness limit.
Logs/caches are retained on failure.
Startup then tests an actual model response, tool calling and image input.

For access from other devices, specify a hostname or IP and the local listen address:

```
sudo ./setup.sh install --host 192.168.1.20 --bind 192.168.1.20
```

Replace hostname/IP with the actual values. Without them the default is localhost/loopback.
For a first installation on AMD, also add `--backend rocm` to this command.
`--bind 0.0.0.0` exposes all IPv4 interfaces and needs deliberate network restrictions.
Port defaults to **8766** (`--port`); GPU defaults to **0** (`--gpu INDEX` or `GPU-...` UUID).
CUDA also accepts `--gpu all`, explicitly exposing every NVIDIA GPU, as required by WSL.
Configuration creates two private random tokens and a development TLS certificate. For
native-device deployment, explicitly import its public certificate or use trusted CA certificates as described in section 6.

### Select models and GPUs

The **vLLM image** provides inference software and CUDA/ROCm. The **model and revision**
select a separate checkpoint. Changing a model does not necessarily require a different
image; architecture, parser and hardware support determine that. The BorgVR client protocol
stays unchanged. Vision and tool calling are mandatory, not optional text-only fallbacks.

```
./setup.sh profiles
sudo ./setup.sh install --backend cuda --profile qwen35-4b
```

Profiles `qwen36-35b`, `qwen35-4b` and `qwen38-27b` use separate fixed checkpoint revisions
and initial parser/resource settings. For a new AMD installation use, for example,
`sudo ./setup.sh install --backend rocm --profile qwen35-4b`. CUDA and ROCm images are pinned
independently. These presets do not guarantee every model fits or has kernels for every GPU.

Switch an existing deployment while keeping credentials and caches:

```
sudo ./setup.sh update --agent-image ghcr.io/jensderkrueger/borgvr-agent:3.9.2
sudo ./setup.sh configure --profile qwen38-27b
sudo ./setup.sh doctor
sudo ./setup.sh update
```

`configure` validates and backs up `.env`, but does not restart containers. `--backend rocm`
also selects the ROCm image and detected device groups. Override a compatible runtime with
`--vllm-image REF`. Changes take effect at the next `update` or `start`.

For another **vision-language model with tool calling**, replace the placeholders below
using its model card and vLLM documentation:

```
sudo ./setup.sh configure --profile custom \
  --model ORGANIZATION/MODEL --model-revision COMMIT \
  --tool-parser PARSER --reasoning-parser none --thinking default
```

A different checkpoint never silently reuses the old model's commit. `--thinking default`
omits model-specific request options; Qwen presets explicitly disable thinking.
Other controls: `--dtype auto|float16|bfloat16|float32`, `--quantization NAME`,
`--context-length N`, `--max-seqs N`, `--max-output-tokens N`, `--gpu-memory-fraction F`,
`--enforce-eager true|false` and `--cpu-offload-gb N`. Older GPUs may need float16 rather
than bfloat16. Quantization requires a matching checkpoint/method and hardware kernels;
an arbitrary flag does not make every model smaller. Context/concurrency reductions save
memory but can limit tasks. MoE active parameter counts are not total weight-storage sizes.

Sources: [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B),
[Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B),
[vLLM tool parsers](https://docs.vllm.ai/en/latest/features/tool_calling/),
[vLLM GPU requirements](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/).

Ordinary BorgVR users only connect to the running endpoint and need no server account
or Docker privileges. These scripts target the local rootful
Docker socket at `/var/run/docker.sock`, not a remote Docker context.
`setup.sh` never installs host packages, restarts Docker, or invokes sudo itself.
Source builds require an explicit `--build-agent` and a local image tag. The free-space
probe uses a small pinned container. Check custom model volume/storage quotas separately.

Re-running `install` first removes existing BorgVR containers and the project network with
`down`, **without deleting volumes or images**. This also releases the old model's GPU memory.
Access tokens and the model cache are retained. Explicit options update existing settings;
omitted options keep their current values, including host/IP, listen address and port:

```
sudo ./setup.sh install --host ai.example.org --bind 0.0.0.0 --port 8766
```

A fixed IP can replace `ai.example.org`. If the existing certificate does not match the supplied host,
it is renewed and privately backed up under `runtime/tls-before-install-*`. Clients must
trust the replacement certificate; their tokens remain unchanged. A matching certificate
is retained. Changes to `.env` create private `runtime/env-before-update-*` backups.
Invalid options are rejected before `down`. The separate `init` command never
overwrites existing configuration. An interrupted configuration with `runtime` but no `.env` requires manual
inspection; setup refuses to discard potentially existing credentials.

### Switch models with one command

```
sudo ./setup.sh model
sudo ./setup.sh model qwen35-4b
sudo ./setup.sh model qwen36-35b
sudo ./setup.sh model qwen38-27b
```

Without a profile, `model` lists the configured model and available profiles without changing
services. With a profile, it backs up and updates the model configuration, pulls missing
images, starts services with the selected model, and tests image understanding and tool calls.
Downloaded model revisions remain cached, so switching back does not download them again.
Loading GPU memory still takes time, and hardware/model compatibility requirements still apply.
Network settings, credentials and certificates remain unchanged. Extra model options are
accepted, for example `sudo ./setup.sh model qwen35-4b --context-length 4096`.
If startup fails, the configuration and backup remain available for troubleshooting.

To generate configuration without starting or installing anything:

```
sudo ./setup.sh init --host ai.example.org --bind 192.168.1.20
```

## 4. Check the server

In the same directory:

```
sudo ./setup.sh status
sudo ./setup.sh test
```

The test checks authenticated readiness/TLS and asks the **real model** for a short answer.
It then advertises two harmless synthetic tools and requires both calls plus recognition
of a red test image. No actual dataset is opened or modified. A failure can mean missing
compatibility or unreliable task completion, not necessarily broken hardware.
No open dataset or connected native app is required for this test.

To ask your own question:

```
sudo docker compose exec -T agent python client.py --url https://127.0.0.1:8766 \
  --ca /run/tls/server.crt --token-file /run/secrets/agent_token \
  --text "What is a Mandelbulb? Answer briefly."
```

To test from another machine, copy only the public certificate and agent token through
a secure channel, install the pinned client dependency, and run:

```
python3 -m venv .venv
.venv/bin/pip install websockets==17.4 httpx==0.28.1 pillow==13.0.0
.venv/bin/python client.py --url https://ai.example.org:8766 \
  --ca /secure/path/server.crt --token-file /secure/path/agent_token --smoke
```

The client requires Python 3.12+ and verifies certificate and hostname; it has no insecure
TLS switch. HTTP and WebSocket redirects and environment-configured proxies are disabled.
Never copy `server.key` or the internal `vllm_token` to clients. Treat the
agent token as a password. It is currently **one installation-wide token**, not a per-device
identity/user-management system. Devices sharing it have equal access to the allowed tools.
Use `--capabilities` instead of `--smoke` for the tool/image check when calling the client directly.

## 5. Connect the native app

First complete the server test and ensure the server is reachable from the device.
Installation creates the public certificate `runtime/tls/server.crt` and the client token
`runtime/secrets/agent_token`. If using your own CA, configure its trust chain instead,
as described in the next section.

1. In BorgVR, enable the assistant under **Settings > AI Assistant**.
2. Enter the server's HTTPS address, for example `https://ai.example.org:8766`, or the IP
   matching the certificate. `localhost` refers to the app device itself, not another computer.
3. Import the public certificate, then import `runtime/secrets/agent_token` or enter its
   contents as the access token.
4. Run the server test in Settings. No dataset needs to be open.
5. Open a dataset and choose **AI Assistant** in the render controls. Type a request or
   speak using the microphone.

**Never copy `server.key` or the internal `vllm_token` to devices.** The client token is
stored in the device Keychain. Transfer it only to trusted devices and remove transfer
copies after import.

Responses and progress updates appear in the conversation and can be spoken locally.
Render-image sharing requires separate permission; camera and passthrough are never sent.
Speech recognition is on-device by default; optional Apple processing requires separate
permission. Cancel closes the connection but does not undo committed changes. Assistant
configuration and keys remain device-local and are excluded from SharePlay/GSC.
See the [native user guide](../html/mcp.html#voice-agent) for more information.

## 6. Configuration, TLS and network security

| File/setting | Purpose |
| --- | --- |
| `.env` | Pinned images/model revision, listen address, port, GPU, UID/GID, context/memory budget |
| `runtime/secrets/agent_token` | Agent authentication; generated randomly; 0640 with sudo-installer access, otherwise 0600 |
| `runtime/secrets/vllm_token` | Separate internal inference credential, mode 0640; never returned to clients |
| `runtime/tls/server.crt` | Public server certificate, including chosen host, localhost and loopback SANs |
| `runtime/tls/server.key` | Private TLS key; 0640 with sudo-installer access, otherwise 0600 |
| Docker volume `borgvr-ai_model-cache` | Downloaded weights and persistent Hugging Face cache |

With sudo setup, `runtime` belongs to the invoking account, mode
0700. That user can read and manage its contents without sudo. The `secrets` and `tls`
directories use 0750 and their mounted files 0640, with group `BORGVR_GID`, preserving
the agent's read access through its group. Container UID/GID settings are unchanged
(10001 for a new administrative setup); the agent remains unprivileged. vLLM joins that
group only for its internal token. Other users gain no access; backup directories stay
0700 and backup files 0600. A newly generated `.env` remains root-owned and 0600.
Non-root setup with pre-existing Docker access still uses that account's UID/GID.

`install`, `init`, `start`, `restart` and `update` automatically prepare these runtime
permissions without changing keys, container IDs or models. An existing non-root runtime
owner is retained on later invocations, even by root or a different administrator.
A first installation directly as root without a sudo caller remains restricted to root
and the container user. Symlinks, multiply linked files and nonregular runtime
entries are rejected before the ownership changes are applied.
The agent has a read-only root filesystem,
bounded temporary storage and dropped capabilities. The inference container uses the
upstream image's default user but has no privileged mode, host IPC, Docker socket, dataset
mounts or published ports. It receives the selected GPU (or every GPU when explicitly
using `--gpu all`) and its model cache.

The inference key is random by default. A host `VLLM_API_KEY` is never imported.
Optionally provide `VLLM_BORGVR_API_KEY` during **initial** configuration (32..512 ASCII
letters, digits, dots, underscores or hyphens); sudo requires explicitly preserving it
with `--preserve-env=VLLM_BORGVR_API_KEY`. Do not put the secret in command arguments or
`.env`. Existing configuration retains its key. Only inside the BorgVR vLLM container
does the launcher set vLLM's required `VLLM_API_KEY` from its private secret file.
Other containers have independent environments.

The generated self-signed certificate expires after 365 days. The native assistant can
explicitly trust the imported public certificate while still verifying hostname/IP and validity.
For managed deployments, use a certificate from your organization's trusted CA or a public CA;
install your organization's CA on devices where necessary. Replace `server.crt`/`server.key` with a matching PEM full chain/key,
retain the same ownership and key mode, and restart the agent. Certificate issuance/renewal
and device trust provisioning are not automated by this script. Never disable TLS validation.

Keep 8766 on a private network/VPN. No firewall rules are changed without explicit opt-in.

### Optional host firewall exception

`install`, `start`, `restart`, `update`, `status` and `doctor` inspect active UFW/firewalld
managers. Inspection does not prove remote reachability. To explicitly allow the configured
agent port for an existing deployment without reloading a healthy running model:

```
sudo ./setup.sh start --open-firewall
```

Or include the flag when installing on a host that owns the specified address:

```
sudo ./setup.sh install --host 192.168.1.20 --bind 192.168.1.20 --open-firewall
```

Only IPv4 TCP to the configured port (8766 by default) and bind address is allowed,
from any IPv4 source. No firewall is installed/enabled, no default policy, SSH rule or
Docker chain is changed, and no global reload is performed. firewalld receives targeted
runtime and permanent rich rules in its default zone. Select another client-facing zone
explicitly if needed:

```
sudo ./setup.sh start --open-firewall --firewall-zone internal
```

The zone must match the clients' interface/source network. Multiple active or uncertain
managers cause a refusal to modify rules. Custom nftables/iptables policies are left alone.
If no supported firewall is active, only a notice is printed. A loopback-only bind must
be changed before requesting a firewall exception.

**Docker caveat:** published container ports can bypass UFW/firewalld host-input rules.
This exception is **not a restriction to trusted source addresses**. Use a Docker-aware
forwarding policy or an upstream firewall/VPN for that. firewalld `StrictForwardPorts`
or custom forwarding rules can require additional administrative configuration. Router,
provider and institutional firewalls can still block access and cannot be inspected or
opened by this setup. See [Docker firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

Only newly added BorgVR rules are tracked in `runtime/firewall-rules.json` and removed
by confirmed uninstall. Pre-existing exceptions are never claimed or deleted. Rules
persist across host reboots; the flag need not be repeated on each start. Old port
exceptions remain until uninstall when changing the configured port. Omitting
`--open-firewall` later does not close previously opened ports.
**Docker-published ports can bypass UFW rules**; use upstream network rules and Docker-aware
filtering, not UFW alone. vLLM's port 8000 must never be published or forwarded. Browser
origins and URL query parameters are rejected; bearer tokens belong in the authorization header.

Prompts, screenshots, tool payloads and conversations are not persisted by the agent or
included in its logs. vLLM request logging and usage telemetry are disabled. Conversations
exist in RAM while connected and are discarded at disconnect. Downloads/builds contact
external package/model hosts; inference uses the local model. There is no configured cloud
fallback. Authenticated clients explicitly decide which screenshots/metadata to transmit.

## 7. Operations and updates

The administrator controls the service; no Docker access is needed by application users:

```
sudo ./setup.sh status
sudo ./setup.sh logs
sudo ./setup.sh stop
sudo ./setup.sh start
sudo ./setup.sh restart
sudo ./setup.sh test
```

`start` starts missing/stopped services, applies changed Compose configuration and waits for
readiness. `stop` keeps containers, cached weights, keys and configuration. `restart` checks
the private mounts first, stops just the BorgVR services and starts them again; vLLM must
reload the model onto the GPU. Ctrl+C ends `logs`, not the services. Other Docker projects
are not stopped. Run these commands from the deployment directory.
Stopping, restarting or replacing containers can interrupt active sessions. Conversations
are in RAM only and are not restored after a restart.

Use `sudo ./setup.sh doctor` to repeat the CUDA/ROCm probe.

### Host reboots

Containers use `restart: unless-stopped`. If Docker starts at boot, previously running
services return automatically. Manually stopped services stay stopped, including after a
host reboot; use `sudo ./setup.sh start` to resume them. Check with `status` and `test`.
The model weights remain in the volume but must be reloaded into GPU/RAM; readiness takes
time. The checkout, `.env`, launcher and TLS files must remain available at the same path.
Budget GPU memory for any other services that also start automatically.

Check Docker's boot setting and enable it if needed (without restarting the daemon):

```
sudo systemctl is-enabled docker
sudo systemctl enable docker
```

See [Docker restart policies](https://docs.docker.com/engine/containers/start-containers-automatically/).
Host setup enables newly installed Docker automatically. A single
Compose worker is used: do not add Uvicorn workers without redesigning session limits.

The configuration pins vLLM **0.34.0** and the Python base by registry digest, each model
profile's checkpoint revision, and all Python dependency versions.
Host OS/Docker/NVIDIA packages follow their signed repositories and should receive regular
security updates; the entire host is not a frozen OS image. Keep the checked-out BorgVR
commit ID with an installation record (`git rev-parse HEAD`).

### Updates

Back up `.env` and `runtime` securely and review new versions/licenses. Update the scripts
and Compose file with Git as the checkout owner, then update the containers with sudo:

```
git pull
sudo ./setup.sh update
```

`update` pulls the images **selected in `.env`**, checks private mounts, applies changed
images/configuration with `up`, waits for readiness and runs the actual-model smoke test.
It does not build, run Git, upgrade host packages or automatically replace pinned digests
with newer versions. An unchanged digest still selects the same image after pulling.

To explicitly select another published agent image, use `sudo ./setup.sh update --agent-image REF`,
replacing `REF` with its tag or preferably registry digest. The override is first used only
for pulling and mount checks. Once those succeed, `.env` is replaced atomically and its old
contents are backed up privately in `runtime/env-before-update-*`. Keys and cached weights
are preserved. Failed pulling/probing leaves the previous running deployment unchanged.
A subsequent startup/model-test failure is reported, not automatically rolled back. After
review, restore the printed backup with `sudo cp /PATH/TO/BACKUP .env`, then run
`sudo ./setup.sh start` and `sudo ./setup.sh test`.

For source builds use `sudo ./setup.sh install --build-agent` with a deliberately selected local image tag
instead of pulling the unpublished local agent image. Existing `.env` intentionally retains its
original vLLM image/model revision: migrate those entries explicitly when upgrading the
inference stack. Never update to `latest` silently. Stop the stack before restoring a
backup. Moving to a different Linux UID/GID requires updating `.env` and private-file ownership.
Restoring an older checkout and its corresponding `.env` permits rollback; model caches
can hold more than one revision.

To remove containers while retaining weights: `sudo docker compose down`. To intentionally
delete the model cache as well: `sudo docker compose down --volumes`. This does **not** remove
`runtime`, Docker, drivers or any other host workloads. Remove secrets only deliberately.

## 8. Troubleshooting

- **GPU probe fails:** check the driver, container runtime, selected GPU/MIG partition,
  and the selected image's CUDA/ROCm requirements. Installing a host toolkit is not a substitute
  for a compatible driver. Inspect errors before selecting another image/driver.
- **GPU out of memory:** check competing workloads; reduce context/concurrency, use an
  appropriate smaller/quantized model or test eager mode/offload. Apply deliberate changes
  with `configure`, then `update`. Lowering the memory fraction alone cannot make oversized weights fit.
- **First startup takes too long:** follow `logs`; weight download/compilation can be slow.
  The setup exits after one hour rather than reporting a running model prematurely. Check
  disk/network conditions and restart; completed downloads remain cached.
- **Native model architecture/CLI error:** do not enable `--trust-remote-code` or privileged
  mode as a workaround. Check the pinned model/image combination and report the error.
- **Certificate error:** connect using the chosen SAN hostname/IP, trust the correct CA or
  explicitly configured test certificate, check expiry/chain, and verify device clocks.
- **Permission error:** run `sudo ./setup.sh init` as the installer to prepare runtime access
  without restarting containers or replacing existing configuration. The agent must
  retain read access as owner or through `BORGVR_GID`. Never make tokens/keys world-readable.
- **Tool result missing or timed out:** the server sends cancellation and refuses subsequent
  work in an uncertain session. Reconcile pending app commands/current state before reconnecting;
  it deliberately does not repeat mutations after a timeout.

## 9. Development and protocol

### Diagnose tool calls without native data

The agent requests `strict: true` for no-argument tools such as `get_application_state`
and for `set_transfer_function`.
The pinned vLLM 0.34 can constrain these calls during generation, preventing invented
fields such as `reason` or `action`. Both server and native argument validation remain
enabled. Invalid arguments are not silently dropped; the model receives precise feedback
to retry with exactly `{}`. The model-facing TF setter requires an explicit channel and
exactly four integer bytes `[R,G,B,A]` per sample, never a prefixed position. Sample positions
are uniformly spaced; short ramps are interpolated to the native table resolution. Invalid
TF arguments receive specific correction feedback, not an automatic reinterpretation.
The native/MCP setter retains its optional channel default. Other tools with optional
properties are not marked strict, preserving the meaning of omitted parameters.
Custom vLLM images/tool parsers must support strict
tool calls; the bundled model compatibility check exercises the full path.

If plain text works but tool requests fail with `UnexpectedModelBehavior`, the log's
exception class alone is insufficient to identify the cause. After `git pull`, run from
the deployment directory, using the already running container (no rebuild/restart):

```
sudo docker compose exec -T agent python - --catalog-json "$(cat diagnostic_catalog.json)" < diagnose_tools.py
```

This compares a minimal state-reading catalog with the native app's tool catalog.
Only a synthetic `get_application_state` result is returned; other tools are refused.
No native client, real dataset, screenshot or previous conversation is accessed or modified.
JSON output contains test results, the arguments of these exclusively synthetic tool calls
(at most 4096 characters per call), retry/validation error categories and diagnostic exception
messages, not credentials or provider response bodies. A nonzero exit means at least one
test failed. The catalog snapshot is checked against the native catalog by the native
voice-agent integration test.

For failures specifically while generating a transfer function, run the synthetic TF test:

```
sudo docker compose exec -T agent python - --scenario transfer-function --catalog-json "$(cat diagnostic_catalog.json)" < diagnose_tools.py
```

It compares the normal TF interface with a ramp limited to 16 uniformly spaced RGBA
entries, reporting elapsed time, accepted sample counts and error chains. TF changes
exist only in the test's memory: no native client is connected and no real dataset is
modified. Each case has a 90-second deadline. The script is read from the checkout;
this diagnostic does not require a new agent image.

```
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-test.txt
.venv/bin/python -m pytest -q
```

Tests use the real Pydantic AI tool loop with a deterministic **test model**, no GPU or cloud
access. They cover auth, schema validation, tool policy, image decoding, deadlines, cancellation,
stale contexts, request deduplication, progress, session limits and configuration preservation.
They do not substitute for the deployed model smoke test or microphone testing on target devices.

The shared native client is tested with `Scripts/test-voice-agent.sh` against the actual local
TLS/WSS agent and deterministic model, including PNG delivery, Command/GSC roundtrip and
context cancellation. See [PROTOCOL.md](PROTOCOL.md) for protocol version 1 and native limits.

## 10. Producing the agent image

The normal release path is the GitHub workflow below; it already produces tested image
and deployment archives. No local build or manual registry tagging is required for users.
For local development on an existing configured machine, explicitly select a writable tag:

```
sudo ./setup.sh configure --agent-image borgvr-agent:dev
sudo ./setup.sh install --build-agent
```

`compose.build.yaml` is only the developer build overlay. Production uses the tested GHCR
image. Model weights, secrets, certificates and Python caches are excluded from the image;
setup never publishes an image or changes registry visibility.

## 11. Repeatable GitHub builds and GHCR publication

**Published: 3.9.2 for linux/amd64**, from commit
`715aabfd7fd041d32504e1da77db6abfc43cb30c`.
[Build, tests and publication](https://github.com/JensDerKrueger/BorgVR/actions/runs/44290118756)
succeeded; anonymous registry access was verified. Immutable image reference:

```text
ghcr.io/jensderkrueger/borgvr-agent@sha256:3bd3833ef37e2e013ac7d18502a0901d7c0c854faa95fb367242b29a43162b63
```

To upgrade an existing installation, run `git pull`, then
`sudo ./setup.sh update --agent-image ghcr.io/jensderkrueger/borgvr-agent:3.9.2`.
`git pull` alone does not replace the running container, and `update` without
`--agent-image` retains the previously configured image. Model, tokens and certificates
are preserved.

The [BorgVR Agent Container workflow](https://github.com/JensDerKrueger/BorgVR/actions/workflows/borgvr-agent.yml)
runs on relevant main-branch pushes and pull requests. It installs the pinned dependencies,
runs the tests, validates Compose, builds **linux/amd64**, and starts the actual production
container to check TLS, authentication and read-only startup. The CPU runner deliberately
reports the model unavailable: GPU inference must still be checked on the target GPU host.

Pushes and pull requests produce build artifacts, not registry images. Publication requires
a manual run and successful tests. Published images are not automatically deployed to servers.

Every successful build attaches an artifact containing:

- `borgvr-agent-linux-amd64.tar.gz`: the tested Docker image, tagged `borgvr-agent:ci`.
- `borgvr-agent-deployment.tar.gz`: only the deployment files, bilingual guides and `INSTALL.md`.
- `release.json`: source commit, platform, image ID and image archive checksum.
- `SHA256SUMS`: checksums of the attached files.

The bundle excludes runtime credentials, certificates, `.env`, tests and model weights.
Verify checksums before loading an archive. The generated `INSTALL.md` has commands matching
that artifact's image reference. Download artifacts from the trusted workflow run; checksums
alone do not authenticate an archive from an unrelated source. Build artifacts are retained
for 14 days, published deployment artifacts for 90 days; they are not a permanent release archive.

To publish a new image version, open **Actions > BorgVR Agent Container > Run workflow**,
select **main**, enable **publish**, and enter a previously unused version number. Tests/build
run again, then a separate publication job loads the verified artifact and pushes that
exact image, without rebuilding, to:

```text
ghcr.io/jensderkrueger/borgvr-agent:VERSION
ghcr.io/jensderkrueger/borgvr-agent:sha-FULL_SOURCE_COMMIT
```

Replace `VERSION` with the version number entered in the workflow.

The workflow uses the repository's temporary `GITHUB_TOKEN` with package-write permission
only in the manual main-branch publication job. No personal publishing token is required.
Automatic/PR builds have read-only repository permissions, and all external actions are pinned
by commit SHA. Publication refuses to overwrite an existing version pointing to another image.
It does not create a public GitHub Release, move `latest`, deploy to a server, or change package
visibility. A successful publish attaches a second deployment bundle pinned to the registry
digest; use it for installations and updates.

GitHub initially creates new GHCR packages as **private**. For a private package, administrators
log in with a classic token with `read:packages` (not a write token). Package access must cover
their account. If anonymous distribution is desired, the owner must deliberately change the
package visibility under **Packages > borgvr-agent > Package settings**. A public source
repository does not automatically make the container package public.

For updates, publish a new version, back up private deployment state, and change only the
`BORGVR_AGENT_IMAGE` reference in the existing `.env` to the new published digest. Then the
administrator runs `sudo ./setup.sh update`. Alternatively pass `update --agent-image REF`
to change just the agent image with an automatic backup of the previous `.env`.
Do not replace existing credentials or initialize a fresh deployment just to update the image.

## 12. Uninstall and repeat installation tests

`sudo ./setup.sh uninstall` alone previews removal of the deployment. The options below
also plan removal of unused images and the clean checkout. Calling `./uninstall.py`
directly remains supported.

In the original deployment directory, first preview as the administrator:

```
sudo ./setup.sh uninstall --remove-images --remove-checkout
```

Omit `sudo` when already root. Nothing is deleted without `--yes`. After reviewing the
concrete resource names and paths, confirm:

```
sudo ./setup.sh uninstall --remove-images --remove-checkout --yes
```

This removes the `borgvr-ai` containers, project network and `borgvr-ai_model-cache`
volume containing the downloaded model and caches. Configured agent/vLLM image references
and the small Python probe image are removed when not used by foreign containers. Other
deployments are refused; a shared model volume/network blocks automatic deletion.
Recorded, newly created firewall exceptions are also removed, including with `--files-only`.
If their removal fails, local configuration is retained for a retry. Pre-existing rules
are not removed.

`--remove-checkout` also deletes the **entire BorgVR Git clone**, including `.git`, runtime
tokens/certificates, configuration and ignored files. For an extracted deployment bundle,
only that bundle directory is deleted. Git clones with local changes/untracked nonignored
files, other repositories, home directories and system directories are protected. Back up
personal data first. Shared images retained by the tool are explicitly listed.

Omit `--remove-checkout` to retain source files for another test. New initialization then
creates new keys/certificates; the model downloads again. Global Docker build caches are
not pruned on a shared host. Download archives outside the project directory must be removed
separately at their actual locations.
Before cloning again, leave the deleted current directory, for example with `cd /home/borgvr`.

To undo only cloning before Docker was installed:

```
./uninstall.py --files-only --remove-checkout --yes
```

This explicitly skips Docker checks/removal. Do not use it to claim a running deployment
has been removed. The uninstaller never purges system packages automatically.

### Optional: Remove Docker on a host used exclusively for BorgVR

**Only do this when Docker, containerd and NVIDIA Container Toolkit were newly installed
for BorgVR and are not used by anything else.** First finish the BorgVR cleanup above.
Check for foreign containers, images, volumes and networks:

```
unset DOCKER_CONTEXT
export DOCKER_HOST=unix:///var/run/docker.sock
docker ps -a
docker image ls
docker volume ls
docker network ls
```

Default networks `bridge`, `host`, `none` are normal. Stop if anything unrelated remains.
Skip host removal if Docker was present before BorgVR. Leave a potentially deleted current
directory, log out of the registry, stop services and remove only the dedicated packages:

```
cd /
docker logout ghcr.io
sudo systemctl stop docker.service docker.socket containerd.service
sudo apt-get purge docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1
```

Review apt's confirmation and abort if it would remove other applications. Do not run
a global `autoremove`. **Only under the same exclusivity condition**, remove the complete
Docker/containerd data stores (including image layers/build cache), runtime configuration
and the repositories/key files created by our host installer:

```
sudo rm -rf -- /var/lib/docker /var/lib/containerd /etc/docker /etc/nvidia-container-runtime
sudo rm -f -- /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/nvidia-container-toolkit.list /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
sudo apt-get update
```

If host setup newly granted `borgvr` Docker-group membership, revoke it with
`sudo gpasswd -d borgvr docker` (substitute the correct account). Do not revoke preexisting
membership. The user account itself is retained. GPU drivers, general Python/OpenSSL/Git
packages, system updates and global package/system logs are not removed or rolled back.
If the Docker group was newly created only for this installation and is now empty, inspect
it with `getent group docker` before optionally deleting it with `sudo groupdel docker`.
If this account's Docker client configuration was also newly created solely for the test,
remove it with `rm -rf -- "$HOME/.docker"`. Never do that with preexisting contexts or other
registry credentials.

## Upstream references

- [vLLM Docker deployment](https://docs.vllm.ai/en/stable/deployment/docker/)
- [Qwen3.6-35B-A3B serving recipe](https://recipes.vllm.ai/Qwen/Qwen3.6-35B-A3B)
- [Qwen model and license](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)
- [Docker on Ubuntu, including firewall caveats](https://docs.docker.com/engine/install/ubuntu/)
- [Docker group privileges](https://docs.docker.com/engine/install/linux-postinstall/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [Pydantic AI](https://ai.pydantic.dev/)
- [GHCR authentication, visibility and digest pinning](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
