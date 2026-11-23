# Modellserver unter Windows mit WSL 2

Installiere den NVIDIA-Treiber unter Windows. Nutze Docker mit GPU-Zugriff und Compose v2 in einer Ubuntu-Distribution unter WSL 2. Prüfe `nvidia-smi` und `docker compose version` **in WSL**. Lege den Checkout im Linux-Dateisystem ab, nicht unter `/mnt/c`. Dieses Setup unterstützt unter WSL NVIDIA/CUDA, nicht AMD/ROCm.

```sh
cd BorgVR/BorgVRAgentServer
sudo ./setup.sh install --backend cuda --gpu all --profile qwen38-27b
sudo ./setup.sh test
```

Die Installation kann in WSL keine NVIDIA-GPU per Index isolieren. `--gpu all` gibt ausdrücklich alle GPUs an den Container weiter; vLLM nutzt standardmäßig eine. Wähle Modellprofil und Kontext passend zum Speicher. Für den Zugriff von anderen Geräten müssen Windows-/WSL-Netzwerk und Windows-Firewall separat passen. Gib unter `--host` den von den Geräten verwendeten Namen oder die IP an und unter `--bind` die passende WSL-Listen-Adresse. Vermeide öffentliche Portweiterleitungen. Schlüssel, Zertifikat und Betrieb beschreibt die [Serveranleitung](README.de.md).
