# Modellserver für BorgVR

[English](README.md) · [Windows mit WSL 2](WINDOWS.de.md)

Der KI-Assistent läuft in BorgVR. Diese optionale Installation stellt ein bildfähiges Modell über vLLM bereit. Der Container `vllm` rechnet auf der GPU, `model-gateway` stellt HTTPS bereit. Er leitet nur `GET /v1/models` und `POST /v1/chat/completions` weiter und führt keine BorgVR-Aufträge aus. Für **OpenAI** braucht BorgVR diesen Server nicht.

## Voraussetzungen prüfen

Benötigt werden Linux x86-64, ein funktionierender NVIDIA/CUDA- oder AMD/ROCm-Treiber, Docker Engine, Docker Compose v2, Python 3 und OpenSSL. VRAM und Plattenplatz hängen von Modell und Kontextlänge ab. `./setup.sh profiles` zeigt die Modellprofile. Fehlt auf Ubuntu Docker oder die GPU-Anbindung, hilft `sudo ./setup-host.sh --backend cuda` beziehungsweise `--backend rocm`. Die Registrierung der NVIDIA-Laufzeit braucht ausdrücklich `--allow-docker-restart`. Dabei können andere Container unterbrochen werden.

Im BorgVR-Checkout:

```sh
cd BorgVR/BorgVRAgentServer
sudo ./setup.sh install --backend cuda --profile qwen38-27b --host ai1 --bind 192.168.1.50 --port 8766
sudo ./setup.sh test
```

Ersetze die Beispiel-IP durch die LAN-Adresse des Servers. `--host` ist der Name oder die IP, **die du auf den Geräten einträgst**. Der Wert kommt ins TLS-Zertifikat und muss nicht der Betriebssystem-Hostname sein. Hat der Rechner nur eine IP, gib sie sowohl bei `--host` als auch bei `--bind` an. Ohne `--bind` lauscht eine neue Installation nur auf `127.0.0.1`. Nutze möglichst ein privates Netz oder VPN. `--open-firewall` fügt auf Wunsch eine lokale TCP-Ausnahme hinzu. Docker kann Regeln für eingehende Host-Verbindungen umgehen; die Option begrenzt keine Quell-IP. Stelle den internen vLLM-Port 8000 nicht direkt ins Netz.

Der erste Modell-Download kann länger dauern. Der Test prüft TLS, Schlüsselpflicht, den gesperrten Pfad `/invocations` und strukturiertes Bildverständnis mit einem künstlichen roten Bild. Bindung, Port, Modell, Schlüssel und Cache bleiben erhalten, sofern sie nicht ausdrücklich geändert werden. Bei Änderung von `--host` kann ein neues Zertifikat nötig werden.

## BorgVR verbinden

Unter **Einstellungen → KI-Assistent** den Assistenten einschalten. Über **+** ein Profil vom Typ **vLLM** anlegen, zum Beispiel `ai1`. `https://ai1:8766` (oder tatsächlichen Namen/IP und Port) eintragen und `runtime/secrets/vllm_token` als Zugangsschlüssel importieren. Wird dem Zertifikat nicht bereits vertraut, das öffentliche `runtime/tls/server.crt` importieren. Niemals `server.key` übertragen. Für den Sweep **Renderbilder teilen** aktivieren. **Testen** prüft den Entwurf, **OK** speichert ihn. In der Liste wird genau ein Profil ausgewählt; Bearbeiten und Entfernen gelten jeweils nur für die betreffende Zeile. Ein vorhandener kompatibler vLLM-Endpunkt braucht dieses Setup nicht.

Für **OpenAI** die Modell-ID und einen eigenen API-Schlüssel hinterlegen. Renderbilder an OpenAI werden separat freigegeben. Die App setzt `store: false`; das ersetzt nicht die Regeln des Anbieters zum Umgang mit Daten. Sensible Datensätze oder Metadaten nur an dafür freigegebene Dienste übermitteln.

## Betrieb und Modellwechsel

```sh
sudo ./setup.sh status
sudo ./setup.sh logs
sudo ./setup.sh stop
sudo ./setup.sh start
sudo ./setup.sh restart
sudo ./setup.sh update
sudo ./switch-model.sh
```

`sudo ./setup.sh model qwen38-27b --context-length 131072` wählt das Modellprofil und die Kontextlänge. Host, Bind-Adresse und Port musst du nicht erneut angeben. `./switch-model.sh` bietet eine interaktive Auswahl und versucht bei fehlgeschlagenem Test, die bisherige Konfiguration wiederherzustellen. Ein Modellwechsel startet vLLM neu. Nach einem Docker-Neustart starten die Dienste automatisch, außer sie wurden ausdrücklich gestoppt. `doctor` prüft die GPU und die Compose-Konfiguration. Weitere Optionen für CUDA, ROCm, mehrere GPUs und eigene Modelle stehen in `./setup.sh --help`.

## Bestehende Installation umstellen

Falls der frühere SSH-Entwicklungsmodus aktiv ist, führe **im alten Checkout** zuerst `sudo ./setup.sh dev disable --remove` aus. Aktualisiere dann den Checkout. Ist vLLM bereits gesund und läuft der alte Agent noch, wechselt `sudo ./migrate-endpoint.sh` auf dem bestehenden HTTPS-Port zum Modellendpunkt, ohne vLLM neu zu starten. Bei einem fehlgeschlagenen Test versucht das Skript, den alten Agenten wieder zu starten. Andernfalls nutze `sudo ./setup.sh install` für eine vollständige Neuinstallation der Dienste. Modell-Cache, TLS-Dateien und `vllm_token` bleiben. Der alte `agent_token` gilt für die neue App nicht. Ein vorgeschalteter TLS-Proxy muss die beiden Modellpfade weiterleiten, nicht `/v1/session`.

## Deinstallieren

`sudo ./setup.sh uninstall` zeigt zunächst, welche Container, Netzwerke, Modellcache, Firewall-Ausnahmen und lokalen Dateien betroffen sind. `--yes` führt die Löschung aus. Optional entfernt `--remove-images` unbenutzte Images dieser Installation, `--remove-checkout` auch den sauberen Git-Checkout. Andere Container und die Docker-Engine bleiben. Wurden Docker und das GPU-Container-Toolkit nur für BorgVR installiert und werden nicht anderweitig benutzt, kannst du sie anschließend separat über den Paketmanager deinstallieren.
