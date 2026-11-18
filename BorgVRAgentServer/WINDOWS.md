# BorgVR agent on Windows with WSL 2

[Deutsch](WINDOWS.de.md) | [Server guide](README.md)

This path runs the existing Linux containers under Windows 11 x86_64, WSL 2 and Ubuntu
24.04. It uses NVIDIA/CUDA and the same agent image, protocol and native BorgVR clients.
It has automated setup tests, but has not been verified on a physical Windows/GPU host.

## 1. Prepare Windows and Ubuntu

Install a compatible NVIDIA **Windows** driver. Do not install a Linux GPU driver in WSL.
The chosen GPU, driver and model must support the pinned CUDA/vLLM image; see
[NVIDIA's WSL requirements](https://docs.nvidia.com/cuda/wsl-user-guide/index.html).

In **administrator PowerShell**:

```powershell
wsl --install -d Ubuntu-24.04
```

Restart Windows if requested, launch Ubuntu and create its Linux user. Then in PowerShell:

```powershell
wsl --update
wsl --list --verbose
```

Ubuntu must show version **2**. See [Microsoft's WSL installation guide](https://learn.microsoft.com/en-us/windows/wsl/install).

In the **Ubuntu terminal**, install the small host utilities and clone into the Linux filesystem,
not `/mnt/c`, so private-file permissions and bind mounts behave as expected:

```sh
sudo apt-get update
sudo apt-get install -y git python3 openssl
cd ~
git clone https://github.com/JensDerKrueger/BorgVR.git
cd BorgVR/BorgVRAgentServer
```

WSL also needs enough RAM and virtual-disk capacity for the selected model. Adjust its
budget through WSL Settings or `.wslconfig`; see [Microsoft's resource settings](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).

## 2. Choose one Docker installation

**Option A: Docker Desktop.** Install/start Docker Desktop for Windows, select Linux
containers and the WSL 2 engine, and enable **Settings > Resources > WSL Integration**
for Ubuntu-24.04. Do **not** run `setup-host.sh` or install a second Docker Engine in
this distribution. See [Docker's WSL integration guide](https://docs.docker.com/desktop/features/wsl/).

In Ubuntu, verify the exact socket and administrator access used by our scripts:

```sh
sudo docker --host unix:///var/run/docker.sock info
sudo docker --host unix:///var/run/docker.sock compose version
```

If these fail, fix Desktop's integration first. Merely having `docker.exe` on PATH is not
sufficient. Do not make the socket world-writable or switch to a remote Docker context.

**Option B: Docker Engine inside Ubuntu.** Use this instead of Desktop integration in
this distribution. Check `ps -p 1 -o comm=`: it must report `systemd`. If needed, merge
`[boot]` with `systemd=true` into `/etc/wsl.conf`, terminate Ubuntu with
`wsl --terminate Ubuntu-24.04` in PowerShell, then reopen it. This stops its workloads.
See [Microsoft's systemd instructions](https://learn.microsoft.com/en-us/windows/wsl/systemd).

In the Ubuntu deployment directory:

```sh
sudo ./setup-host.sh --backend cuda
```

If NVIDIA runtime registration requires a Docker restart, first arrange downtime for
other containers, then rerun with `--allow-docker-restart`.

## 3. Install and test BorgVR

In Ubuntu, for a local test with the smaller model profile:

```sh
sudo ./setup.sh install --backend cuda --gpu all --profile qwen35-4b
sudo ./setup.sh doctor
sudo ./setup.sh test
```

Choose a model that fits the available VRAM. `--gpu all` deliberately exposes **all NVIDIA
GPUs** to the inference container, not an isolated GPU index. WSL requires this mode;
normal Linux installations retain their single-GPU default. The setup also finds
`nvidia-smi` at WSL's `/usr/lib/wsl/lib/nvidia-smi` fallback path.

For access from other devices, use the Windows machine's reachable hostname/IP for the
certificate, and a wildcard bind inside WSL. Replace this example address:

```sh
sudo ./setup.sh install --backend cuda --gpu all --profile qwen35-4b --host 192.168.1.20 --bind 0.0.0.0
```

Changing the certificate host can replace the certificate; import the resulting public
certificate and agent token only after the server test succeeds, as described in the
[native app setup](README.md#5-connect-the-native-app).

## 4. Allow network access deliberately

With Docker Desktop, published ports are handled by Desktop. With Docker Engine inside
WSL's default NAT network, LAN clients also need Windows-to-WSL port forwarding. In
administrator PowerShell, obtain Ubuntu's IPv4 address:

```powershell
wsl -d Ubuntu-24.04 hostname -I
```

Use the WSL interface address, not a Docker bridge. Replace both example addresses below
(Windows LAN: `192.168.1.20`, WSL: `172.28.12.34`):

```powershell
netsh interface portproxy add v4tov4 listenaddress=192.168.1.20 listenport=8766 connectaddress=172.28.12.34 connectport=8766
```

The WSL address can change after restart. Mirrored networking is an alternative; see
[Microsoft's WSL networking guide](https://learn.microsoft.com/en-us/windows/wsl/networking).

If Windows Firewall blocks the port, an administrator can create a scoped exception.
The following example permits only the local subnet on a **Private** network profile:

```powershell
New-NetFirewallRule -Name "BorgVR-Agent-WSL2-8766" -DisplayName "BorgVR agent WSL2" -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 192.168.1.20 -LocalPort 8766 -RemoteAddress LocalSubnet -Profile Private
```

Do not overwrite an existing rule with that name. Hyper-V or organizational policies may
also need a port-specific exception; never disable the firewall or globally allow inbound
traffic. See [Microsoft's Hyper-V firewall guide](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall).
`setup.sh --open-firewall` manages Linux UFW/firewalld only, not Windows or Hyper-V rules.

## 5. Operation and removal

Use `setup.sh start`, `stop`, `update`, `test` and `uninstall` inside Ubuntu as in the
[server guide](README.md). The same script works for both Docker choices once their local
socket is available. Desktop must be running; for Option B, Ubuntu and its Docker service
must be running. Windows restart, sleep or WSL shutdown interrupts sessions; container restart
policies alone do not start WSL or Desktop after Windows boot. Refresh NAT forwarding if needed.

The BorgVR uninstaller does not remove Windows forwarding/firewall rules. Remove only
rules created for this installation, using the original Windows listen address:

```powershell
netsh interface portproxy delete v4tov4 listenaddress=192.168.1.20 listenport=8766
Remove-NetFirewallRule -Name "BorgVR-Agent-WSL2-8766"
```

Keep shared Docker installations and WSL distributions. Do not unregister Ubuntu just to
remove BorgVR: that deletes unrelated Linux files too.

## AMD limitation

Our ROCm deployment targets native Linux `/dev/kfd` and `/dev/dri`, not WSL's `/dev/dxg`
and its additional runtime requirements. It rejects AMD/WSL rather than claiming support.
Use native Linux for AMD; see [AMD's WSL architecture](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/wsl/howto_wsl.html).
