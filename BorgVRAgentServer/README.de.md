# BorgVR-Agent: Installation Unter Linux

[English / vollständige Betriebsreferenz](README.md) | [Verbindungsprotokoll](PROTOCOL.md)

Dieses Verzeichnis enthält die erste Serverimplementierung für die geplante KI-Steuerung:
**vLLM mit Qwen3.6-35B-A3B** und unseren **BorgVR-Agenten auf Basis von Pydantic AI**.
Die Dienste laufen in Containern. Nur der mit TLS und Zugangsschlüssel abgesicherte
Agent ist von außen erreichbar; vLLM bleibt im privaten Container-Netz.

**Stand:** Server, Textanfragen, externe Werkzeugaufrufe, Bilder, Zwischenmeldungen und
Abbruch sind implementiert. Die Anbindung der nativen Apps und deren neues Sprachinterface
folgen separat. Die bisherige Vision-Sprachsteuerung wird hiermit noch nicht ersetzt.

## 1. Was Auf Dem Rechner Installiert Sein Muss

- Linux x86_64, Zielsystem **Ubuntu 26.04.1 LTS (resolute)**.
- Ein funktionierender NVIDIA-Treiber für die H200. Die komplette GPU mit 141 GB sollte
  verfügbar sein, keine zu kleine MIG-Partition. 256 GB Arbeitsspeicher sind passend.
- Mindestens **200 GiB freier Platz im Docker-Speicherverzeichnis**, besser 250 GiB oder
  mehr. Das ist eine konservative Installationsreserve für Modell, Container, Downloads
  und Build-Caches, keine gemessene endgültige Modellgröße.
- Docker Engine, Compose-v2-Plugin und NVIDIA Container Toolkit.
- Python 3 und OpenSSL für die Konfiguration, optional Git zum Klonen.
- Internetzugriff auf Paketquellen, Docker Hub, PyPI und Hugging Face samt Download-CDNs.
- Ein Administrator für Host-Vorbereitung und Containerbetrieb. Normale BorgVR-Nutzer
  brauchen weder Docker-Zugriff noch Root-Rechte oder ein Shell-Konto auf dem Server.

**CUDA Toolkit, PyTorch, vLLM und die Python-Agentenpakete musst du nicht auf dem Host
installieren.** Diese Komponenten kommen in die Container. Der NVIDIA-Treiber bleibt
dagegen eine Voraussetzung des Hosts.

Zuerst prüfen:

```bash
nvidia-smi
```

Falls das nicht funktioniert, zuerst den von Distribution/Hersteller unterstützten Treiber
installieren und gegebenenfalls neu starten. Das Skript verändert absichtlich keine
Treiber, Secure-Boot-Einstellungen oder GPU-Partitionen und startet den Rechner nicht neu.
Der Treiber muss die CUDA-Laufzeit des festgelegten Images unterstützen; das Skript prüft
das durch eine echte CUDA-Speicherallokation im Container.

## 2. Dateien Auf Den Server Bringen

Entweder das komplette Verzeichnis `BorgVRAgentServer` kopieren oder das Repository klonen,
falls der Server bereits SSH-Zugriff darauf hat:

```bash
git clone git@github.com:JensDerKrueger/BorgVR.git
cd BorgVR/BorgVRAgentServer
```

Keine `.env` oder `runtime`-Verzeichnisse einer anderen Installation mitkopieren. Jede
Installation erzeugt eigene Zugangsschlüssel. Für das voreingestellte öffentliche Modell
ist kein Hugging-Face-Account erforderlich.

## 3. Host Einrichten, Dann Zwei Container Starten

Der Server besteht aus **zwei laufenden Containern**: vLLM und unserem Agenten.
`compose.yaml` lädt nur fertige Images und enthält keinen Build-Schritt. Nur der
Image-Ersteller beziehungsweise Entwickler verwendet zusätzlich `compose.build.yaml`.
Ein privilegierter Installationscontainer mit Zugriff auf den Docker-Socket ist nicht nötig.

### A. Administrator: Einmalig Den Host Vorbereiten

Eine geprüfte Kopie des Skripts mit Root-Rechten ausführen:

```bash
sudo bash setup-host.sh --allow-docker-restart
```

Wer schon als root angemeldet ist, lässt `sudo` weg. Auf Ubuntu 26.04.1 werden fehlende
Docker-/Compose-/NVIDIA-Container-Pakete eingerichtet; vorhandene GPU-Treiber bleiben
unverändert. Auch Ubuntu 22.04 und 24.04 werden akzeptiert. Bei bereits fertigem Host
entfällt dieser Schritt. Konfligierende vorhandene Docker-Pakete werden nicht entfernt.

`--allow-docker-restart` erlaubt ausdrücklich einen bei der NVIDIA-Einrichtung notwendigen
Docker-Neustart. Andere Container können dabei unterbrochen werden. Ohne diese Erlaubnis
wird eine notwendige Laufzeitänderung abgelehnt; eine bereits registrierte Laufzeit bleibt
unverändert. Das Root-Skript erzeugt keine App-Konfiguration, Zugangsschlüssel,
Zertifikate oder Modelldownloads und liest keine `.env` aus dem Benutzerverzeichnis.
Es vergibt standardmäßig auch keine Docker-Rechte an Benutzer.

### B. Konfiguration Ohne Root Vorbereiten

Im Verzeichnis des normalen Wartungskontos, ohne Docker-Zugriff erforderlich:

```bash
bash setup.sh init --host ai.example.org --bind 192.168.1.20 \
  --agent-image registry.example.org/borgvr-agent:3.9
```

**Die Registry-Adresse ist nur ein Beispiel, kein bereits veröffentlichtes Image.**
Für veröffentlichte GitHub-Images den festen Digest aus dem Deployment-Artefakt verwenden,
siehe Abschnitt 9. Alternativ kann der Image-Ersteller eine eigene Registry oder ein
Archiv verwenden. Für einen Quellcode-Build `--agent-image` weglassen.

Hostname und IP ersetzen. `--host` bestimmt den Zertifikatsnamen, `--bind` die
Abhöradresse. Ohne Angabe bleibt es bei localhost/`127.0.0.1`. `0.0.0.0` gibt alle
IPv4-Schnittstellen frei und braucht bewusste Netzabsicherung. Port ist **8766** (`--port`),
GPU **0** (`--gpu INDEX` oder NVIDIA-GPU-UUID).

Dabei entstehen zwei private zufällige Zugangsschlüssel und ein Testzertifikat. Für
den späteren nativen Betrieb ein vertrauenswürdiges CA-Zertifikat verwenden, siehe unten.

### C. Administrator: Fertige Images Laden Und Starten

Sobald unser vertrauenswürdiges Agenten-Image veröffentlicht und in `.env` eingetragen ist:

```bash
docker compose pull
docker compose up -d --no-build --pull never --wait --wait-timeout 3600
```

Diese Befehle führt der Administrator im Deployment-Verzeichnis aus. Für private
Registries meldet er sich vorher dort an. vLLM lädt das festgelegte Modell in seinen
persistent gespeicherten Cache; der Agent startet erst, wenn vLLM bereit ist. Der erste
Download und die Kernel-Kompilierung können dauern; maximal eine Stunde wird abgewartet.

**Die eigentlichen Nutzer verbinden sich danach nur aus BorgVR mit dem Server.** Sie
müssen nichts auf dem Linux-Server installieren und brauchen dort keine Docker-Rechte.

### Optional: Betrieb an einen vertrauenswürdigen Operator delegieren

Nur falls der Administrator einem bestehenden Wartungskonto bewusst Docker-Zugriff geben
will, kann er stattdessen ausführen:

```bash
sudo bash setup-host.sh --docker-user borgvr --allow-docker-restart
```

Danach als `borgvr` vollständig ab- und wieder anmelden. Der Operator kann ohne sudo starten:

```bash
bash setup.sh install --prebuilt-agent --host ai.example.org --bind 192.168.1.20 \
  --agent-image registry.example.org/borgvr-agent:3.9
bash setup.sh test
```

Das Benutzerskript installiert keine Systempakete und fragt nie nach Root-Rechten. Es
prüft Speicherplatz/GPU und verwendet ein vorhandenes Image beziehungsweise lädt das
angegebene Image, ohne es zu bauen. Für einen Entwickler-Build `--prebuilt-agent` und
die Beispiel-Image-Adresse weglassen. Die Speicherplatzprüfung verwendet einen kleinen
Container, keine geschützten Hostverzeichnisse; besondere Volume-Quotas separat prüfen.

**Die Docker-Gruppe ist praktisch gleichbedeutend mit Root-Rechten.** Sie ist nur für
vertrauenswürdige Operatoren gedacht, nicht für die normalen BorgVR-Nutzer. Rootless
Docker wird hier nicht eingerichtet. Die Skripte verwenden den lokalen rootful
Docker-Socket `/var/run/docker.sock`, keinen entfernten Docker-Kontext.

Vorhandene Konfiguration, Schlüssel, Zertifikate und Modell-Caches bleiben erhalten.
Wiederholte Aufrufe ersetzen diese nicht; neue Host-/Port-/GPU-Argumente ändern eine
bestehende `.env` nicht. Änderungen bewusst in `.env` vornehmen, bei Namensänderung auch
das Zertifikat erneuern. Ein nach einem Fehler vorhandenes `runtime` ohne `.env` muss
manuell geprüft werden, damit keine Schlüssel versehentlich verloren gehen.

Nur Konfiguration erzeugen, ohne Dienste zu starten:

```bash
bash setup.sh init --host ai.example.org --bind 192.168.1.20
```

## 4. Funktion prüfen

Als Administrator beziehungsweise autorisierter Docker-Operator:

```bash
docker compose ps
docker compose exec -T agent python client.py --url https://127.0.0.1:8766 \
  --ca /run/tls/server.crt --token-file /run/secrets/agent_token --smoke
```

Der Test prüft Modellbereitschaft, Authentifizierung und die verschlüsselte Verbindung und
fordert eine kurze Antwort vom **echten Modell** an. Er simuliert keinen erfolgreichen
Renderbefehl: Die native App ist in diesem Schritt noch nicht angeschlossen.

Ein Test von einem anderen Rechner ist ebenfalls möglich; siehe den englischen Leitfaden.
Der Testclient prüft Zertifikat und Hostname, es gibt keinen unsicheren TLS-Schalter.

## 5. Sicherheit Und Zertifikate

- `.env` enthält Image-/Modellrevision, GPU, Speicherbudget, Adresse, Port und Benutzer-IDs.
- `runtime/secrets/agent_token` ist der Zugangsschlüssel für Clients, wie ein Passwort
  behandeln. Er gilt aktuell für **die gesamte Installation**, noch nicht separat pro Gerät.
- `runtime/secrets/vllm_token` ist nur für die interne Modellkommunikation.
- `runtime/tls/server.crt` ist das öffentliche Zertifikat.
- `runtime/tls/server.key` ist der private Schlüssel und gehört niemals auf einen Client.
- Verzeichnisse sind nur für den Besitzer zugänglich, Schlüsseldateien haben Modus 0600.
  Diese Rechte nicht durch weltweite Lesbarkeit umgehen.

Das automatisch erzeugte, selbstsignierte Zertifikat gilt 365 Tage und dient dem ersten
Test mit ausdrücklich vertrautem Zertifikat. Für den späteren nativen Betrieb ein
Zertifikat einer auf den Geräten vertrauten internen oder öffentlichen CA verwenden.
Die Zertifikatsausstellung, Erneuerung und Einrichtung des CA-Vertrauens auf den Geräten
sind noch nicht automatisiert. TLS-Prüfungen niemals abschalten.

Der Dienst sollte im privaten Netz oder VPN bleiben. Das Skript ändert keine Firewall.
**Docker-Portfreigaben können UFW-Regeln umgehen**; Netzfreigaben daher zusätzlich am
Netzrand beziehungsweise mit Docker-tauglichen Regeln absichern. vLLM-Port 8000 bleibt
ungeöffnet. Zugangsschlüssel werden im Authorization-Header übertragen, nicht in URLs.

Der Agent speichert keine Gespräche, Bilder oder Werkzeugdaten auf Platte und protokolliert
deren Inhalte nicht. vLLM-Request-Logging und Nutzungs-Telemetrie sind abgeschaltet.
Gespräche liegen während der Verbindung im RAM; nach Trennung werden sie verworfen.
Es gibt keinen Cloud-Fallback. Externe Verbindungen entstehen für Paket-/Modelldownloads,
nicht für die eigentliche Inferenz.

## 6. Betrieb Und Updates

Der Administrator betreibt den Dienst; normale App-Nutzer brauchen keine Docker-Rechte:

```bash
docker compose logs --tail 100 -f
docker compose stop
docker compose up -d --no-build --pull never --wait --wait-timeout 3600
```

Autorisierte nicht-root Operatoren können alternativ `setup.sh logs|stop|start|doctor|test`
verwenden.

Container starten mit Docker automatisch wieder, sofern sie nicht bewusst gestoppt wurden.
Bei bereits installiertem Docker gegebenenfalls dessen Autostart aktivieren; neu installiertes
Docker wird automatisch aktiviert. Der Modell-Cache liegt im Docker-Volume
`borgvr-ai_model-cache`.

vLLM **0.34.0**, Container-Digests, Modellrevision und alle Python-Abhängigkeiten sind
festgelegt. Hostpakete stammen dagegen aus den signierten Paketquellen und sollen regulär
Sicherheitsupdates erhalten. Die verwendete BorgVR-Commit-ID für die Installation notieren.

Vor Updates `.env` und `runtime` sicher sichern. Nach geprüfter Aktualisierung der Quellen:

```bash
docker compose pull
docker compose up -d --no-build --pull never --wait --wait-timeout 3600
```

Bei einem Quellcode-Build statt Pull den Build-Overlay verwenden:
`docker compose -f compose.yaml -f compose.build.yaml build --pull agent`.
Eine bestehende `.env` behält bewusst ihre alte
vLLM-/Modellrevision; diese bei einem Inferenz-Update ausdrücklich anpassen. Keine
stillschweigende Umstellung auf `latest`. Details zur Rückkehr auf alte Versionen,
Zertifikatswechsel, Fehlerbehebung und Deinstallation stehen im englischen Leitfaden.

## 7. Tests und nächster Schritt

Die Entwicklertests laufen ohne GPU mit einem deterministischen Testmodell durch die echte
Pydantic-AI-Schleife. Getestet werden unter anderem Anmeldung, Eingabevalidierung,
Werkzeugbeschränkungen, Bilder, Abbruch, Zeitlimits und veraltete Antworten. Den Test auf
der echten H200 und die spätere native Ende-zu-Ende-Prüfung ersetzen sie nicht.

Der nächste Schritt ist der gemeinsame native Client: Text und später Sprache zum Server,
Werkzeugaufrufe durch unser vorhandenes Command-Modul, Screenshots als Rückmeldung und
lokale Sprachausgabe. Das Protokoll dafür ist in [PROTOCOL.md](PROTOCOL.md) beschrieben.

## 8. Agenten-Image Einmal Bauen Und Verteilen

Nur der Image-Ersteller braucht den Quellcode/Build-Schritt, nicht jeder Serverbetreiber:

```bash
docker buildx build --platform linux/amd64 --load -t borgvr-agent:3.9 .
docker tag borgvr-agent:3.9 registry.example.org/borgvr-agent:3.9
docker push registry.example.org/borgvr-agent:3.9
```

Die Registry muss gewählt und der Upload autorisiert sein. Ein Build allein veröffentlicht
noch kein Image. Für reproduzierbare Installationen den entstandenen Image-Digest statt
nur eines veränderbaren Tags verwenden. Modellgewichte, Token und Zertifikate gehören
nicht ins Image. Weitere Details stehen im englischen Leitfaden.

Ohne Registry kann der Ersteller `docker save --output borgvr-agent-3.9.tar borgvr-agent:3.9`
verwenden. Der Administrator lädt das vertrauenswürdig übertragene Archiv mit
`docker load --input borgvr-agent-3.9.tar`. In `.env` bleibt dann
`BORGVR_AGENT_IMAGE=borgvr-agent:3.9`; nur vLLM mit `docker compose pull vllm` laden und
danach wie oben starten. Image-Archive sind von Git und Build-Kontext ausgeschlossen.

## 9. Wiederholbare Builds Und Veröffentlichung Über GitHub

Der Workflow [BorgVR Agent Container](https://github.com/JensDerKrueger/BorgVR/actions/workflows/borgvr-agent.yml)
baut und testet nach relevanten Änderungen auf `main` sowie bei Pull Requests automatisch
ein Image für **linux/amd64**. Zusätzlich zu den Tests startet er den echten Container mit
TLS, Authentifizierung und schreibgeschütztem Dateisystem. Der CPU-Runner testet dabei
bewusst keine GPU-Inferenz; diese Prüfung bleibt auf dem H200-Rechner erforderlich.

Ein erfolgreicher Build stellt als Workflow-Artefakt bereit:

- `borgvr-agent-linux-amd64.tar.gz`: das getestete Docker-Image mit Tag `borgvr-agent:ci`.
- `borgvr-agent-deployment.tar.gz`: Deployment-Dateien und zweisprachige Anleitungen.
- `release.json`: Quellcode-Commit, Plattform, Image-ID und Archiv-Prüfsumme.
- `SHA256SUMS`: Prüfsummen der Dateien.

Das Installationspaket enthält keine Zugangsschlüssel, Zertifikate, `.env` oder Modellgewichte.
Die enthaltene `INSTALL.md` nennt die passenden Befehle für das jeweilige Image. Archive nur
aus dem vertrauenswürdigen Workflow laden und Prüfsummen vergleichen. Build-Artefakte bleiben
14 Tage verfügbar, veröffentlichte Deployment-Artefakte 90 Tage; sie sind kein dauerhaftes
Release-Archiv.

Für eine neue Registry-Version unter **Actions > BorgVR Agent Container > Run workflow**
den Branch **main** wählen, **publish** aktivieren und eine neue Version wie **3.9.0**
eintragen. Nach erneut erfolgreichen Tests wird exakt das geprüfte Image ohne weiteren
Build veröffentlicht:

```text
ghcr.io/jensderkrueger/borgvr-agent:3.9.0
ghcr.io/jensderkrueger/borgvr-agent:sha-VOLLSTÄNDIGER_QUELLCODE_COMMIT
```

Der Workflow verwendet GitHubs temporären Repository-Token. Schreibrechte auf Packages
erhält nur der manuell gestartete Veröffentlichungsjob auf `main`. Automatische Builds und
Pull Requests haben nur Leserechte. Eine bestehende Versionsnummer wird nicht mit einem
anderen Image überschrieben. Es werden weder `latest` verschoben noch Server aktualisiert
oder öffentliche GitHub-Releases freigegeben.

Neue GHCR-Pakete sind bei GitHub zunächst **privat**, auch bei öffentlichem Quellcode.
Für private Images benötigt der Administrator einen klassischen Token mit `read:packages`
und die entsprechenden Paket-Leserechte. Soll das Image ohne Anmeldung herunterladbar sein,
muss der Besitzer unter **Packages > borgvr-agent > Package settings** die Sichtbarkeit
bewusst auf öffentlich ändern. Das macht der Workflow nicht automatisch.

Nach einer Veröffentlichung gibt es ein weiteres Deployment-Artefakt mit festem
Registry-Digest. Für Updates die privaten Konfigurationsdateien sichern und in der bestehenden
`.env` nur `BORGVR_AGENT_IMAGE` auf den neuen Digest setzen. Danach lädt und startet der
Administrator mit `docker compose pull` und dem üblichen `up --no-build --pull never` neu.
Zugangsschlüssel und Zertifikate bleiben erhalten; eine Neuinitialisierung ist nicht nötig.
