# BorgVR model server

[Deutsch](README.de.md) · [Windows with WSL 2](WINDOWS.md)

The AI assistant runs in BorgVR. This optional GPU deployment serves a vision-capable model through vLLM. Container `vllm` performs inference. `model-gateway` provides HTTPS and only forwards `GET /v1/models` and `POST /v1/chat/completions`. It has no prompts, tools or BorgVR sessions. If you select **OpenAI** in BorgVR, no local model server is required.

## Check prerequisites

Use Linux x86-64 with a working NVIDIA/CUDA or AMD/ROCm driver, Docker Engine, Docker Compose v2, Python 3 and OpenSSL. Available VRAM and disk space depend on the model profile and context. Run `./setup.sh profiles` to list the presets. If Docker or GPU integration is missing on Ubuntu, `sudo ./setup-host.sh --backend cuda` (or `--backend rocm`) prepares it. Registering the NVIDIA runtime requires explicit `--allow-docker-restart` and can interrupt other containers. Don't add it on a shared host without a maintenance window.

From the BorgVR checkout:

```sh
cd BorgVR/BorgVRAgentServer
sudo ./setup.sh install --backend cuda --profile qwen38-27b --host ai1 --bind 192.168.1.50 --port 8766
sudo ./setup.sh test
```

Substitute the LAN address of the server. `--host` is the DNS name or IP **used by the clients**, and goes into the certificate; it need not be an OS hostname. If you have only an IP, pass it for both `--host` and `--bind`. Without `--bind`, a fresh installation listens only on `127.0.0.1`. Prefer a private network/VPN or an explicitly restricted network, particularly for sensitive volumes. `--open-firewall` optionally adds a local TCP exception. Docker ports can bypass host-input firewall rules; this flag is not a source-IP restriction. Do not publish raw vLLM port 8000.

The first start downloads the model and may take time. The test checks TLS, a missing key, the blocked `/invocations` endpoint, and structured vision output using a synthetic red image. Existing port, model settings, tokens and cache are retained unless explicitly changed. Changing `--host` can replace the certificate; reimport it in the app.

## Connect BorgVR

In **Settings > AI Assistant**, enable the assistant. Choose **+** and create a **vLLM** profile, for example `ai1`. Enter `https://ai1:8766` (or the real DNS name or IP and port) and import `runtime/secrets/vllm_token` as the access token. Import the public `runtime/tls/server.crt` if the certificate is not already trusted. Never copy `server.key`. Enable **Share render images** for the intensity sweep. **Test connection** tests the draft; **OK** saves it. Select one profile in the list. Edit and remove act on the corresponding row. With an existing compatible vLLM endpoint, the host setup scripts are not required.

For **OpenAI**, set the model ID and enter an API key for that provider. Render sharing with OpenAI must be enabled separately. The app requests `store: false`; this does not change the provider's own data handling policies. Don't send sensitive images or metadata to a provider that is not approved for them.

## Operate and switch models

```sh
sudo ./setup.sh status
sudo ./setup.sh logs
sudo ./setup.sh stop
sudo ./setup.sh start
sudo ./setup.sh restart
sudo ./setup.sh update
sudo ./switch-model.sh
```

`sudo ./setup.sh model qwen38-27b --context-length 131072` sets a profile and context without restating the host, bind address, or port. `./switch-model.sh` offers an interactive selection and attempts to restore the old configuration if its health test fails. vLLM is restarted when changing models. Containers configured with `unless-stopped` resume when Docker restarts unless you stopped them explicitly. Run `doctor` for a GPU and Compose configuration check. Advanced CUDA, ROCm, multi-GPU and custom model flags are listed with `./setup.sh --help`.

## Migrate an old deployment

If you enabled the former SSH development mode, run `sudo ./setup.sh dev disable --remove` **from the previous checkout** before upgrading. Update the checkout. With a healthy vLLM and a running legacy agent, `sudo ./migrate-endpoint.sh` switches the existing HTTPS port without restarting vLLM. If the new endpoint test fails, the script tries to restore the previous agent. Otherwise, use `sudo ./setup.sh install` for a full service reinstall. Both paths retain the model cache and reuse the TLS files and `vllm_token`. The old `agent_token` is not accepted by the new app. A separate upstream TLS reverse proxy must forward the two model API paths, not `/v1/session`.

## Uninstall

`sudo ./setup.sh uninstall` previews the project containers, network, model cache, firewall exceptions and local files. Add `--yes` to apply, `--remove-images` to remove unused deployment image references, and `--remove-checkout` to delete a clean clone too. Other workloads and Docker Engine are left alone. If Docker was installed solely for BorgVR and no other workloads use it, remove Docker and the GPU container toolkit separately using your distribution's package manager. The uninstall script does not make that decision for you.
