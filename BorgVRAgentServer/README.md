# BorgVR Agent Server

[Deutsch](README.de.md)

Self-hosted server foundation for BorgVR's planned conversational assistant. The stack runs
one multimodal model in vLLM and a small Pydantic AI agent, connected by a private Docker
network. Only the authenticated HTTPS/WSS agent endpoint is published.

**Current scope:** server installation, text interaction, external-tool orchestration,
PNG input, progress messages, cancellation and protocol tests. The macOS/iOS/visionOS
voice and outbound WebSocket clients are **not implemented yet**. Installing this stack
does not replace the existing visionOS speech commands. The smoke test talks to the actual
model but does not claim to exercise native rendering or anatomical recognition.

## 1. Requirements

- Linux x86_64. The target host is **Ubuntu 26.04.1 LTS (resolute)**. The root-only host
  package installer also accepts Ubuntu 22.04 and 24.04. Other distributions need Docker,
  Compose and NVIDIA Container Toolkit installed by their administrator.
- One available **H200 with its full 141 GB memory**, a working NVIDIA driver, and the stated
  256 GB host RAM. The conservative default uses one GPU, BF16, 16,384 context tokens,
  two concurrent inference sequences and an 85% GPU-memory budget. MIG partitions or other
  GPU workloads may not have sufficient space.
- At least **200 GiB free in Docker's storage filesystem**, preferably 250 GiB or more.
  This is an installation safety budget, not a measured final dataset/model size.
  Model weights, large container images, compilation/build caches and download staging use it.
- Internet access for signed OS repositories, Docker Hub, PyPI and Hugging Face's model/CDN
  endpoints. The initial weights download is large; first startup and kernel compilation
  can take considerably longer than subsequent starts.
- Python 3 and OpenSSL on the host for configuration; Git only if cloning the repository.
  Python 3.12, inference libraries and CUDA user-space libraries run in containers.
  A host CUDA Toolkit installation is **not** necessary.
- One account with sudo privileges for setup and container operations. Ordinary BorgVR
  users need **no Docker account, shell access or root privileges**: they connect to the
  shared agent endpoint. No separate maintenance account or Docker group is required.

First verify the existing driver:

```
nvidia-smi
```

If this fails, install the distribution/vendor-supported H200 driver and reboot if required.
The installer deliberately does not select/replace drivers, change Secure Boot, or reboot.
The exact driver must support the CUDA runtime of the pinned vLLM image; `doctor` allocates
a CUDA tensor inside that image rather than relying only on a version-number guess.

## 2. Copy The Deployment

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

## 3. Host Setup And Two-Container Deployment

There are **two runtime containers**: the upstream vLLM image and our agent image.
`compose.yaml` is pull-only: it contains no image build. Only image producers/developers
use `compose.build.yaml`. No privileged installer container or mounted Docker socket is needed.

Use the same sudo-capable account throughout. When already logged in as root, omit `sudo`.

### A. Check Prerequisites

If Docker is already installed, check it first:

```
nvidia-smi
sudo docker compose version
sudo docker ps
sudo docker info --format '{{json .Runtimes}}'
```

If Compose works and the runtimes include `nvidia`, proceed to B. Other containers are
retained. vLLM reserves 85% of the selected GPU's memory by default, which can affect
competing GPU workloads.

Only if prerequisites are missing, run a reviewed copy of the host script:

```
sudo ./setup-host.sh
```

This installs missing Docker,
Compose and NVIDIA Container Toolkit prerequisites from the official signed repositories.
It preserves installed drivers and refuses conflicting Docker packages instead of removing
them. Existing Docker is retained; install a missing Compose plugin from its existing source.

If the script reports that a Docker restart is required, arrange a maintenance window
for the existing containers before running `sudo ./setup-host.sh --allow-docker-restart`.
`--allow-docker-restart` explicitly permits NVIDIA runtime registration and a Docker restart
if needed, potentially interrupting other containers. Without it, an already configured
runtime is retained, but a required runtime change is refused. Host setup creates no app
configuration, access tokens, certificates, model downloads or app checkout. It never reads
the app's `.env`. No user is added to the Docker group by default.

If all host prerequisites already work, skip this step.

### B. Install And Start

For an initial local-only test, run in `BorgVRAgentServer`:

```
sudo ./setup.sh install
```

This creates `.env`, tokens and a test certificate, checks at least 200 GiB of free Docker
storage and CUDA access, pulls missing images, and starts both services. The public
[3.9.0 agent image](https://github.com/JensDerKrueger/BorgVR/pkgs/container/borgvr-agent)
is pinned by its verified digest by default. No registry login or local build is needed.
vLLM downloads the pinned model into its persistent cache; the agent starts only when
vLLM is healthy. First download/compilation can take up to the one-hour readiness limit.
Logs/caches are retained on failure.

For access from other devices, specify a hostname or IP and the local listen address:

```
sudo ./setup.sh install --host 192.168.1.20 --bind 192.168.1.20
```

Replace hostname/IP with the actual values. Without them the default is localhost/loopback.
`--bind 0.0.0.0` exposes all IPv4 interfaces and needs deliberate network restrictions.
Port defaults to **8766** (`--port`); GPU defaults to **0** (`--gpu INDEX` or `GPU-...` UUID).
Configuration creates two private random tokens and a development TLS certificate. For
native-device deployment, use a trusted CA certificate as described in section 5.

Ordinary BorgVR users only connect to the running endpoint and need no server account
or Docker privileges. These scripts target the local rootful
Docker socket at `/var/run/docker.sock`, not a remote Docker context.
`setup.sh` never installs host packages, restarts Docker, or invokes sudo itself.
Source builds require an explicit `--build-agent` and a local image tag. The free-space
probe uses a small pinned container. Check custom model volume/storage quotas separately.

Existing `.env`, credentials and certificates are never silently overwritten. Re-running
`install` reuses them; new `--host`, `--bind`, `--port` and `--gpu` arguments do not change an
existing configuration. Edit `.env` deliberately and renew the certificate when changing
hostnames. An interrupted configuration with `runtime` but no `.env` requires manual
inspection; setup refuses to discard potentially existing credentials.
If an old `.env` still selects `BORGVR_AGENT_IMAGE=borgvr-agent:3.9` and that local image
does not exist, use `sudoedit .env` to change only the image reference to
`ghcr.io/jensderkrueger/borgvr-agent:3.9.0` or the digest in section 10.
Do not regenerate credentials or certificates just to change images.

To generate configuration without starting or installing anything:

```
sudo ./setup.sh init --host ai.example.org --bind 192.168.1.20
```

## 4. Check The Server

In the same directory:

```
sudo ./setup.sh status
sudo ./setup.sh test
```

The smoke test checks the agent's authenticated `/readyz` endpoint, opens an authenticated TLS
WebSocket, and asks the **real model** for a short answer. A successful check reports the
model, a short response and exit status zero. It advertises no native tools: it does not
simulate a successful BorgVR operation.

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
.venv/bin/pip install websockets==17.4 httpx==0.28.1
.venv/bin/python client.py --url https://ai.example.org:8766 \
  --ca /secure/path/server.crt --token-file /secure/path/agent_token --smoke
```

The client requires Python 3.12+ and verifies certificate and hostname; it has no insecure
TLS switch. HTTP and WebSocket redirects and environment-configured proxies are disabled.
Never copy `server.key` or the internal `vllm_token` to clients. Treat the
agent token as a password. It is currently **one installation-wide token**, not a per-device
identity/user-management system. Devices sharing it have equal access to the allowed tools.

## 5. Configuration, TLS And Network Security

| File/setting | Purpose |
| --- | --- |
| `.env` | Pinned images/model revision, listen address, port, GPU, UID/GID, context/memory budget |
| `runtime/secrets/agent_token` | Agent authentication; generated randomly, mode 0600 |
| `runtime/secrets/vllm_token` | Separate internal inference credential, mode 0640; never returned to clients |
| `runtime/tls/server.crt` | Public server certificate, including chosen host, localhost and loopback SANs |
| `runtime/tls/server.key` | Private TLS key, mode 0600 |
| Docker volume `borgvr-ai_model-cache` | Downloaded weights and persistent Hugging Face cache |

`runtime` and its subdirectories are owner-only. New sudo/root installations keep `.env`
and the parent `runtime` directory root-owned; only the private container mounts are owned
by UID/GID 10001. The agent therefore remains unprivileged even with administrative setup.
Existing configurations retain their original UID/GID and file ownership. Non-root setup
with pre-existing Docker access remains supported using that account's UID/GID.
vLLM joins the supplementary `BORGVR_GID` group so it can read the shared inference token
without a capability that bypasses file permissions. `install`, `init` and `start` repair
that token's mode to 0640 in existing installations without replacing its contents.
Other private keys remain 0600.
The agent has a read-only root filesystem,
bounded temporary storage and dropped capabilities. The inference container uses the
upstream image's default user but has no privileged mode, host IPC, Docker socket, dataset
mounts or published ports. Only one selected GPU and its model cache are exposed to it.

The inference key is random by default. A host `VLLM_API_KEY` is never imported.
Optionally provide `VLLM_BORGVR_API_KEY` during **initial** configuration (32..512 ASCII
letters, digits, dots, underscores or hyphens); sudo requires explicitly preserving it
with `--preserve-env=VLLM_BORGVR_API_KEY`. Do not put the secret in command arguments or
`.env`. Existing configuration retains its key. Only inside the BorgVR vLLM container
does the launcher set vLLM's required `VLLM_API_KEY` from its private secret file.
Other containers have independent environments.

The generated self-signed certificate expires after 365 days and is for initial testing
with an explicitly trusted certificate. Before native-device deployment, use a certificate
from your organization's trusted CA or a public CA; install your organization's CA on the
devices where necessary. Replace `server.crt`/`server.key` with a matching PEM full chain/key,
retain the same ownership and key mode, and restart the agent. Certificate issuance/renewal
and device trust provisioning are not automated by this script. Never disable TLS validation.

Keep 8766 on a private network/VPN. No firewall rules are changed automatically.
**Docker-published ports can bypass UFW rules**; use upstream network rules and Docker-aware
filtering, not UFW alone. vLLM's port 8000 must never be published or forwarded. Browser
origins and URL query parameters are rejected; bearer tokens belong in the authorization header.

Prompts, screenshots, tool payloads and conversations are not persisted by the agent or
included in its logs. vLLM request logging and usage telemetry are disabled. Conversations
exist in RAM while connected and are discarded at disconnect. Downloads/builds contact
external package/model hosts; inference uses the local model. There is no configured cloud
fallback. Authenticated clients explicitly decide which screenshots/metadata to transmit.

## 6. Operations And Updates

The administrator controls the service; no Docker access is needed by application users:

```
sudo ./setup.sh logs
sudo ./setup.sh stop
sudo ./setup.sh start
```

Use `sudo ./setup.sh doctor` to repeat the CUDA probe.

Containers use `restart: unless-stopped`; enable the existing Docker daemon at boot if it
is not already enabled. Host setup enables newly installed Docker automatically. A single
Compose worker is used: do not add Uvicorn workers without redesigning session limits.

The initial snapshot pins vLLM **0.34.0** and the Python base by registry digest, model
revision **345d467b117d1fd5eda9b879a5988de9ae5f47a7**, and all Python dependency versions.
Host OS/Docker/NVIDIA packages follow their signed repositories and should receive regular
security updates; the entire host is not a frozen OS image. Keep the checked-out BorgVR
commit ID with an installation record (`git rev-parse HEAD`).

For an intentional update, back up `.env` and `runtime` securely, review the new pinned
versions and model license, update the checkout, then:

```
sudo docker compose pull
sudo ./setup.sh start
```

For source builds use `sudo docker compose -f compose.yaml -f compose.build.yaml build --pull agent`
instead of pulling the unpublished local agent image. Existing `.env` intentionally retains its
original vLLM image/model revision: migrate those entries explicitly when upgrading the
inference stack. Never update to `latest` silently. Stop the stack before restoring a
backup. Moving to a different Linux UID/GID requires updating `.env` and private-file ownership.
Restoring an older checkout and its corresponding `.env` permits rollback; model caches
can hold more than one revision.

To remove containers while retaining weights: `sudo docker compose down`. To intentionally
delete the model cache as well: `sudo docker compose down --volumes`. This does **not** remove
`runtime`, Docker, drivers or any other host workloads. Remove secrets only deliberately.

## 7. Troubleshooting

- **CUDA probe fails:** check the driver, container runtime, selected GPU/MIG partition,
  and the pinned image's CUDA requirements. Installing a host CUDA Toolkit is not a substitute
  for a compatible driver. Inspect errors before selecting another image/driver.
- **GPU out of memory:** verify no other workload occupies the H200, then deliberately lower
  `BORGVR_CONTEXT_LENGTH` or `BORGVR_GPU_MEMORY_FRACTION` in `.env`; `sudo docker compose up -d`
  recreates changed services. A different GPU may require a smaller or quantized model.
- **First startup takes too long:** follow `logs`; weight download/compilation can be slow.
  The setup exits after one hour rather than reporting a running model prematurely. Check
  disk/network conditions and restart; completed downloads remain cached.
- **Native model architecture/CLI error:** do not enable `--trust-remote-code` or privileged
  mode as a workaround. Check the pinned model/image combination and report the error.
- **Certificate error:** connect using the chosen SAN hostname/IP, trust the correct CA or
  explicitly configured test certificate, check expiry/chain, and verify device clocks.
- **Permission error:** `.env` UID/GID must match private-file ownership. Never solve this by
  making tokens/keys world-readable.
- **Tool result missing or timed out:** the server sends cancellation and refuses subsequent
  work in an uncertain session. Reconcile pending app commands/current state before reconnecting;
  it deliberately does not repeat mutations after a timeout.

## 8. Development And Protocol

```
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-test.txt
.venv/bin/python -m pytest -q
```

Tests use the real Pydantic AI tool loop with a deterministic **test model**, no GPU or cloud
access. They cover auth, schema validation, tool policy, image decoding, deadlines, cancellation,
stale contexts, request deduplication, progress, session limits and configuration preservation.
They do not substitute for the H200/model smoke test or eventual native end-to-end testing.

See [PROTOCOL.md](PROTOCOL.md) for protocol version 1 and the requirements on future native
clients. No new native application targets or old speech handlers were changed in this step.

## 9. Producing The Agent Image

Only the image producer needs the sources/build toolchain. Build for the Linux H200 host:

```
docker buildx build --platform linux/amd64 --load -t borgvr-agent:3.9 .
```

Publish to your chosen, authorized registry, for example:

```
docker tag borgvr-agent:3.9 registry.example.org/borgvr-agent:3.9
docker push registry.example.org/borgvr-agent:3.9
```

No image is automatically published by setup or by this repository change. Choose visibility
and registry access explicitly. For reproducible deployments select the resulting image
digest in `--agent-image`/`.env`, not only a mutable tag. Do not bundle model weights, tokens
or certificates into the image; `.dockerignore` excludes deployment secrets.

Without a registry, distribute the image archive through a trusted channel:

```
docker save --output borgvr-agent-3.9.tar borgvr-agent:3.9
```

Load it with `sudo docker load --input borgvr-agent-3.9.tar`. Set
`BORGVR_AGENT_IMAGE=borgvr-agent:3.9` in `.env` and run `sudo ./setup.sh install`.
The already loaded image is reused. Archives are excluded from Git and the build context.

## 10. Repeatable GitHub Builds And GHCR Publication

**Published: 3.9.0 for linux/amd64**, from commit
`54ad28148c9b1a95fb0f627f48b707a947919e15`.
[Build, tests and publication](https://github.com/JensDerKrueger/BorgVR/actions/runs/44091127267)
succeeded; anonymous registry access was verified. Immutable image reference:

```text
ghcr.io/jensderkrueger/borgvr-agent@sha256:729d464bf75d8b2fbf67c0733875d08db5cd121d6a15db01ef3d6679b4c1e053
```

The [BorgVR Agent Container workflow](https://github.com/JensDerKrueger/BorgVR/actions/workflows/borgvr-agent.yml)
runs on relevant main-branch pushes and pull requests. It installs the pinned dependencies,
runs the tests, validates Compose, builds **linux/amd64**, and starts the actual production
container to check TLS, authentication and read-only startup. The CPU runner deliberately
reports the model unavailable: GPU inference must still be checked on the H200 host.

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
select **main**, enable **publish**, and enter a new version such as **3.9.1**. Tests/build
run again, then a separate publication job loads the verified artifact and pushes that
exact image, without rebuilding, to:

```text
ghcr.io/jensderkrueger/borgvr-agent:3.9.1
ghcr.io/jensderkrueger/borgvr-agent:sha-FULL_SOURCE_COMMIT
```

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
administrator runs `sudo docker compose pull` and `sudo ./setup.sh start`.
Do not replace existing credentials or initialize a fresh deployment just to update the image.

## 11. Uninstall And Repeat Installation Tests

In the original deployment directory, first preview as the administrator:

```
sudo ./uninstall.py --remove-images --remove-checkout
```

Omit `sudo` when already root. Nothing is deleted without `--yes`. After reviewing the
concrete resource names and paths, confirm:

```
sudo ./uninstall.py --remove-images --remove-checkout --yes
```

This removes the `borgvr-ai` containers, project network and `borgvr-ai_model-cache`
volume containing the downloaded model and caches. Configured agent/vLLM image references
and the small Python probe image are removed when not used by foreign containers. Other
deployments are refused; a shared model volume/network blocks automatic deletion.

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

### Optional: Remove Docker On A Host Used Exclusively For BorgVR

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

## Upstream References

- [vLLM Docker deployment](https://docs.vllm.ai/en/stable/deployment/docker/)
- [Qwen3.6-35B-A3B serving recipe](https://recipes.vllm.ai/Qwen/Qwen3.6-35B-A3B)
- [Qwen model and license](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)
- [Docker on Ubuntu, including firewall caveats](https://docs.docker.com/engine/install/ubuntu/)
- [Docker group privileges](https://docs.docker.com/engine/install/linux-postinstall/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [Pydantic AI](https://ai.pydantic.dev/)
- [GHCR authentication, visibility and digest pinning](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
