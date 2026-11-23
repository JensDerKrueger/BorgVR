# Model server on Windows with WSL 2

Keep the Windows NVIDIA driver up to date, and run Docker with GPU access and Compose v2 in an Ubuntu WSL 2 distribution. Verify `nvidia-smi` and `docker compose version` **inside WSL**. Use a checkout in the Linux filesystem, not `/mnt/c`. This setup supports NVIDIA/CUDA on WSL, not ROCm on WSL.

```sh
cd BorgVR/BorgVRAgentServer
sudo ./setup.sh install --backend cuda --gpu all --profile qwen38-27b
sudo ./setup.sh test
```

On WSL this deployment cannot isolate one NVIDIA GPU by index; `--gpu all` is explicit. It exposes all GPUs to the container, but vLLM uses one by default. Use a profile and context that fit. For another device to connect, configure Windows/WSL networking and Windows Firewall separately, then set `--host` to the DNS name/IP the clients actually use and `--bind` to the appropriate WSL listen address. Avoid public port forwarding. See [the setup guide](README.md) for key and certificate import and operation commands.
