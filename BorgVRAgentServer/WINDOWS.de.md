# BorgVR-Agent unter Windows mit WSL 2

[English](WINDOWS.md) | [Server-Anleitung](README.de.md)

Dieser Weg betreibt die vorhandenen Linux-Container unter Windows 11 x86_64, WSL 2 und
Ubuntu 24.04. Er verwendet NVIDIA/CUDA sowie dasselbe Agenten-Image, Protokoll und dieselben
BorgVR-Clients. Die Setup-Tests sind automatisiert; ein Test auf einem echten Windows-Rechner
mit GPU steht noch aus.

## 1. Windows und Ubuntu vorbereiten

Einen passenden NVIDIA-**Windows-Treiber** installieren, keinen Linux-GPU-Treiber in WSL.
GPU, Treiber und Modell müssen zum festgelegten CUDA-/vLLM-Image passen; siehe
[NVIDIAs WSL-Voraussetzungen](https://docs.nvidia.com/cuda/wsl-user-guide/index.html).

In einer **PowerShell als Administrator**:

```powershell
wsl --install -d Ubuntu-24.04
```

Windows bei Aufforderung neu starten, Ubuntu öffnen und den Linux-Benutzer anlegen.
Danach in PowerShell:

```powershell
wsl --update
wsl --list --verbose
```

Bei Ubuntu muss Version **2** stehen. Siehe [Microsofts WSL-Installation](https://learn.microsoft.com/en-us/windows/wsl/install).

Im **Ubuntu-Terminal** die kleinen Host-Werkzeuge installieren und im Linux-Dateisystem
klonen, nicht unter `/mnt/c`. Damit funktionieren Dateirechte und eingebundene Verzeichnisse
wie für die privaten Dateien vorgesehen:

```sh
sudo apt-get update
sudo apt-get install -y git python3 openssl
cd ~
git clone https://github.com/JensDerKrueger/BorgVR.git
cd BorgVR/BorgVRAgentServer
```

WSL benötigt ausreichend RAM und virtuellen Plattenplatz für das gewählte Modell.
Das Budget lässt sich über WSL Settings oder `.wslconfig` anpassen; siehe
[Microsofts Ressourceneinstellungen](https://learn.microsoft.com/en-us/windows/wsl/wsl-config).

## 2. Eine Docker-Variante wählen

**Variante A: Docker Desktop.** Docker Desktop für Windows installieren und starten,
Linux-Container und die WSL-2-Engine wählen. Unter **Settings > Resources > WSL Integration**
Ubuntu-24.04 aktivieren. In dieser Distribution **weder `setup-host.sh` ausführen noch eine
zweite Docker Engine installieren**. Siehe [Dockers WSL-Integration](https://docs.docker.com/desktop/features/wsl/).

In Ubuntu genau den Socket und Administratorzugriff prüfen, den unsere Skripte verwenden:

```sh
sudo docker --host unix:///var/run/docker.sock info
sudo docker --host unix:///var/run/docker.sock compose version
```

Falls das scheitert, zuerst die Desktop-Integration korrigieren. `docker.exe` im Suchpfad
allein reicht nicht. Den Socket nicht weltweit beschreibbar machen und nicht auf einen
entfernten Docker-Kontext ausweichen.

**Variante B: Docker Engine direkt in Ubuntu.** Diese Variante statt der Desktop-Integration
in dieser Distribution verwenden. `ps -p 1 -o comm=` muss `systemd` melden. Falls nötig,
`[boot]` mit `systemd=true` in `/etc/wsl.conf` ergänzen und Ubuntu mit
`wsl --terminate Ubuntu-24.04` in PowerShell beenden und wieder öffnen. Das unterbricht
laufende Aufgaben. Siehe [Microsofts systemd-Anleitung](https://learn.microsoft.com/en-us/windows/wsl/systemd).

Im Ubuntu-Deployment-Verzeichnis:

```sh
sudo ./setup-host.sh --backend cuda
```

Falls die NVIDIA-Laufzeitregistrierung einen Docker-Neustart verlangt, zuerst ein
Wartungsfenster für andere Container vereinbaren und mit `--allow-docker-restart` wiederholen.

## 3. BorgVR installieren und testen

In Ubuntu für einen lokalen Test mit dem kleineren Modellprofil:

```sh
sudo ./setup.sh install --backend cuda --gpu all --profile qwen35-4b
sudo ./setup.sh doctor
sudo ./setup.sh test
```

Ein Modell wählen, das in den verfügbaren GPU-Speicher passt. `--gpu all` gibt ausdrücklich
**alle NVIDIA-GPUs** für den Inferenzcontainer frei, nicht einen isolierten GPU-Index.
WSL benötigt diesen Modus; normales Linux behält die Einzel-GPU-Voreinstellung.
Das Setup findet `nvidia-smi` auch unter WSLs Ersatzpfad `/usr/lib/wsl/lib/nvidia-smi`.

Für andere Geräte den erreichbaren Windows-Hostnamen oder dessen IP als Zertifikatsnamen
verwenden und innerhalb von WSL an alle Schnittstellen binden. Beispieladresse ersetzen:

```sh
sudo ./setup.sh install --backend cuda --gpu all --profile qwen35-4b --host 192.168.1.20 --bind 0.0.0.0
```

Ein anderer Zertifikatsname kann das Zertifikat ersetzen. Erst nach erfolgreichem Servertest
das erzeugte öffentliche Zertifikat und den Agentenschlüssel importieren, wie unter
[Native App verbinden](README.de.md#5-native-app-verbinden) beschrieben.

## 4. Netzwerkzugriff bewusst freigeben

Docker Desktop übernimmt veröffentlichte Ports selbst. Bei Docker Engine im normalen
WSL-NAT-Netz benötigen LAN-Clients zusätzlich eine Weiterleitung von Windows zu WSL.
In einer Administrator-PowerShell die IPv4-Adresse von Ubuntu ermitteln:

```powershell
wsl -d Ubuntu-24.04 hostname -I
```

Die WSL-Schnittstellenadresse verwenden, keine Docker-Bridge. Beide Beispieladressen
ersetzen (Windows-LAN: `192.168.1.20`, WSL: `172.28.12.34`):

```powershell
netsh interface portproxy add v4tov4 listenaddress=192.168.1.20 listenport=8766 connectaddress=172.28.12.34 connectport=8766
```

Die WSL-Adresse kann sich nach Neustarts ändern. Alternativ gibt es Mirrored Networking;
siehe [Microsofts WSL-Netzwerkanleitung](https://learn.microsoft.com/en-us/windows/wsl/networking).

Blockiert Windows Firewall den Port, kann der Administrator eine gezielte Ausnahme
einrichten. Dieses Beispiel erlaubt nur das lokale Subnetz im Netzwerkprofil **Privat**:

```powershell
New-NetFirewallRule -Name "BorgVR-Agent-WSL2-8766" -DisplayName "BorgVR agent WSL2" -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 192.168.1.20 -LocalPort 8766 -RemoteAddress LocalSubnet -Profile Private
```

Keine vorhandene Regel dieses Namens überschreiben. Hyper-V- oder Organisationsrichtlinien
können eine weitere portbezogene Freigabe erfordern. Niemals die Firewall abschalten oder
eingehenden Verkehr pauschal erlauben; siehe [Microsofts Hyper-V-Firewall-Anleitung](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall).
`setup.sh --open-firewall` verwaltet nur Linux-UFW/firewalld, keine Windows- oder Hyper-V-Regeln.

## 5. Betrieb und Entfernung

`setup.sh start`, `stop`, `update`, `test` und `uninstall` innerhalb von Ubuntu wie in der
[Server-Anleitung](README.de.md) verwenden. Das Skript funktioniert für beide Docker-Varianten,
sobald deren lokaler Socket verfügbar ist. Desktop muss laufen; bei Variante B müssen Ubuntu
und dessen Docker-Dienst laufen. Windows-Neustart, Ruhezustand oder WSL-Abschaltung unterbrechen
Sitzungen. Container-Neustartrichtlinien starten WSL oder Desktop nicht selbst nach dem
Windows-Boot. NAT-Weiterleitungen bei Bedarf aktualisieren.

Die BorgVR-Deinstallation entfernt keine Windows-Weiterleitungen oder Firewall-Regeln.
Nur selbst für diese Installation angelegte Regeln mit der ursprünglichen Windows-Abhöradresse entfernen:

```powershell
netsh interface portproxy delete v4tov4 listenaddress=192.168.1.20 listenport=8766
Remove-NetFirewallRule -Name "BorgVR-Agent-WSL2-8766"
```

Gemeinsam genutzte Docker-Installationen und WSL-Distributionen behalten. Ubuntu nicht nur
zum Entfernen von BorgVR deregistrieren: Das würde auch fremde Linux-Dateien löschen.

## Einschränkung bei AMD

Unser ROCm-Deployment verwendet unter nativem Linux `/dev/kfd` und `/dev/dri`, nicht WSLs
`/dev/dxg` mit seinen zusätzlichen Laufzeitanforderungen. AMD/WSL wird deshalb ausdrücklich
abgewiesen. Für AMD natives Linux verwenden; siehe [AMDs WSL-Architektur](https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/install/installryz/wsl/howto_wsl.html).
