# Agent development over SSH

This opt-in mode is for a trusted development server. Update agent Python code without a
server-side Git pull, image build or registry download for each iteration. vLLM and the
loaded model remain running. BorgVR's HTTPS/WSS address, certificates and tokens do not change.

## Access and boundaries

Setup creates the dedicated password-locked system account `borgvr-agent-dev`, with no
supplementary groups, sudo or Docker permissions. Its root-managed SSH key uses `restrict`
and a forced command permitting only `deploy`, `status`, `logs` and `restart`. The key does
not provide a shell, SFTP/SCP, terminal, TCP/X11 forwarding or SSH agent forwarding.
No Docker socket or additional container network port is exposed.

**This access still permits arbitrary agent code inside the agent container.** That code
can read its tokens and TLS files, and text, visualization state and images sent by BorgVR.
Grant it only to trusted developers, avoid confidential datasets while others develop, and
revoke it afterwards. It is not a sandbox for untrusted third-party code.

## Prepare the Linux server

Start with a normally installed, running BorgVR server and the complete agent source tree.
A production deployment bundle alone does not contain editable agent sources; obtain the
matching full GitHub checkout or source archive as well. Update the setup tools once:

```sh
cd ~/BorgVR/BorgVRAgentServer
git pull
```

If you already log into the server over SSH, no additional SSH server is necessary.
Otherwise, an administrator can install/start OpenSSH on Ubuntu:

```sh
sudo apt update
sudo apt install openssh-server
sudo systemctl enable --now ssh
```

The existing SSH port must be reachable from the development machine. BorgVR setup does
not change SSH configuration or firewall rules for this. Standard Ubuntu PAM configuration
supports key authentication for the password-locked account. Administrators must review
existing `AllowUsers`, `DenyUsers` or custom authentication policies deliberately; do not
disable global protections to work around them.

## Create a dedicated client key

On the Mac/Linux machine where code is edited, **not on the server**:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/borgvr-ai1-dev -C BorgVR-agent-development
```

Do not overwrite an existing key. A passphrase is supported; unlock the key beforehand
with `ssh-add ~/.ssh/borgvr-ai1-dev` for unattended uploads. A key without a passphrase needs
particular care and must only be used for this restricted development access. Keep the
private key on the client machine. Before the first SSH/SCP connection to an unknown server
address, display its host-key fingerprint on the server and compare it with the client's prompt:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Transfer only its public `.pub` file using your existing
administrator login. Replace the example account/address as appropriate:

```sh
scp ~/.ssh/borgvr-ai1-dev.pub krueger@134.91.11.251:borgvr-ai1-dev.pub
```

The bootstrap copy uses the normal administrator account, not the restricted account.
Never copy the private file without `.pub` to the server.

## Enable development mode

On the server, in `BorgVRAgentServer`:

```sh
sudo ./setup.sh dev enable --ssh-key-file ~/borgvr-ai1-dev.pub
```

Setup validates the public key and installed image dependency snapshot, creates its account,
and recreates **only the agent container**. It never adopts an unrelated existing account or
group with the same name. SSH access is enabled only after successful startup. vLLM is not
stopped or recreated, and no image is built or pulled.
The bootstrap copy `~/borgvr-ai1-dev.pub` in the administrator's home can then be removed;
setup manages the installed public authorized-key file separately.

Development files reside in `/var/lib/borgvr-agent-dev`; the administrator-owned helper is
`/usr/local/libexec/borgvr-agent-development.py`. The container reads complete immutable
source snapshots through a read-only mount. A small supervisor stops the old agent worker
and then starts the selected snapshot. Active conversations are interrupted, never replayed.
The normal container restrictions remain enabled, with a separate writable development
control/log directory.

Existing `start`, `stop`, `restart`, `status`, `logs` and `test` commands retain the active
mode. Normal `restart` still restarts both services; use the development restart below for
agent-only iterations. Disable development before `install`, `configure`, `model` or `update`.

## Verify server identity and test SSH

Do not blindly accept an unknown SSH host key. On the server:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

From the development machine, explicitly establish the first connection and compare its
fingerprint with the server's output:

```sh
ssh -T -i ~/.ssh/borgvr-ai1-dev borgvr-agent-dev@134.91.11.251 status
```

Expect JSON with `phase: "ready"`, a release ID and a source checksum. Automated operations
require an already trusted host key and never prompt for a password or confirmation.
A bare `ssh user@host` is deliberately rejected because it requests a shell. For a custom
SSH port, add `-p PORT` to this initial command.

## Upload and inspect changes

From the local source `BorgVRAgentServer` directory, **without sudo**:

```sh
./setup.sh dev push --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
./setup.sh dev status --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
./setup.sh dev logs --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
./setup.sh dev restart --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
```

Add `--port PORT` for a custom SSH port. Push uploads only `borgvr_next/**/*.py`, `client.py`,
`model_config.py` and `requirements.txt`, never `.env`, credentials, certificates, datasets or
Git metadata. It waits for the new worker's startup acknowledgement. Uploads have byte,
entry and time limits. Links, path traversal, special files and dependencies differing from
the installed image are rejected. Historical snapshots and logs are bounded.

On failure inspect status/logs first. Failed snapshots are retained for diagnosis; no app
commands are rolled back or repeated automatically. Push a corrected or known-good local
version again. Local code remains available for tests, commits and a normal final release.
If `dev enable` itself fails, the normal agent is restored and the SSH key is not enabled.
Before restoration, supervisor state and Docker healthcheck output are saved to
`/var/lib/borgvr-agent-dev/startup-failure.json` (root-readable only). Read it with
`sudo cat /var/lib/borgvr-agent-dev/startup-failure.json`; worker output remains in
`/var/lib/borgvr-agent-dev/control/agent.log`. A running agent process is not sufficient:
Docker also checks `/readyz`, which verifies access to the configured model through vLLM.
HTTP 503 there concerns model readiness, not SSH authentication. Fix that underlying problem
before removing the incomplete development setup with `dev disable --remove` and enabling it again.
Changing `requirements.txt` requires a matching new image. Setup, SSH-helper or supervisor
changes need a new development installation, not just a source push.

## Disable and remove access

On the server:

```sh
sudo ./setup.sh dev disable --remove
```

This revokes the SSH key, restores only the agent to its configured normal image, and removes
the development account/group, helper and development files. It preserves vLLM, the model,
normal settings, certificates and tokens. Without `--remove`, files/account are retained for
diagnosis but the SSH key is still removed. Remove these retained resources before enabling
again. If account deletion reports active SSH processes, finish those operations and retry.

Normal `sudo ./setup.sh uninstall --yes` also previews/removes these development resources.
`uninstall --files-only` requires their removal first so a running container cannot reference
deleted snapshots. OpenSSH and unrelated accounts are not removed or modified. Remove the
dedicated private client key once no longer needed; do not delete other keys or SSH settings.
