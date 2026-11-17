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
- Ein Benutzer mit sudo-Rechten für Einrichtung und Containerbetrieb. Normale BorgVR-Nutzer
  brauchen weder Docker-Zugriff noch Root-Rechte oder ein Shell-Konto auf dem Server.

**CUDA Toolkit, PyTorch, vLLM und die Python-Agentenpakete musst du nicht auf dem Host
installieren.** Diese Komponenten kommen in die Container. Der NVIDIA-Treiber bleibt
dagegen eine Voraussetzung des Hosts.

Zuerst prüfen:

```
nvidia-smi
```

Falls das nicht funktioniert, zuerst den von Distribution/Hersteller unterstützten Treiber
installieren und gegebenenfalls neu starten. Das Skript verändert absichtlich keine
Treiber, Secure-Boot-Einstellungen oder GPU-Partitionen und startet den Rechner nicht neu.
Der Treiber muss die CUDA-Laufzeit des festgelegten Images unterstützen; das Skript prüft
das durch eine echte CUDA-Speicherallokation im Container.

## 2. Dateien Auf Den Server Bringen

Entweder das komplette Verzeichnis `BorgVRAgentServer` kopieren oder das öffentliche
Repository über HTTPS klonen. Dafür ist kein SSH-Schlüssel erforderlich.
Die folgenden Befehle einzeln ausführen:

```
git clone https://github.com/JensDerKrueger/BorgVR.git
```

Danach in das Deployment-Verzeichnis wechseln:

```
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

Alle folgenden Schritte führt dasselbe Konto mit sudo-Rechten aus. Wer bereits als root
angemeldet ist, lässt `sudo` weg. Eine Docker-Gruppenmitgliedschaft ist nicht nötig.

### A. Voraussetzungen Prüfen

Bei bereits installiertem Docker zunächst prüfen:

```
nvidia-smi
sudo docker compose version
sudo docker ps
sudo docker info --format '{{json .Runtimes}}'
```

Wenn Compose funktioniert und `nvidia` in den Runtimes steht, direkt mit B weitermachen.
Andere Container bleiben bestehen. vLLM reserviert standardmäßig 85 % des Speichers der
ausgewählten GPU; konkurrierende GPU-Anwendungen können dadurch beeinträchtigt werden.

Nur bei fehlenden Voraussetzungen eine geprüfte Kopie des Host-Skripts ausführen:

```
sudo ./setup-host.sh
```

Auf Ubuntu 26.04.1 werden fehlende
Docker-/Compose-/NVIDIA-Container-Pakete eingerichtet; vorhandene GPU-Treiber bleiben
unverändert. Auch Ubuntu 22.04 und 24.04 werden akzeptiert. Bei bereits fertigem Host
entfällt dieser Schritt. Konfligierende vorhandene Docker-Pakete werden nicht entfernt.

Falls das Skript einen notwendigen Docker-Neustart meldet, erst ein Wartungsfenster
für die anderen Container vereinbaren. Dann `sudo ./setup-host.sh --allow-docker-restart`
ausführen. `--allow-docker-restart` erlaubt ausdrücklich einen bei der NVIDIA-Einrichtung notwendigen
Docker-Neustart. Andere Container können dabei unterbrochen werden. Ohne diese Erlaubnis
wird eine notwendige Laufzeitänderung abgelehnt; eine bereits registrierte Laufzeit bleibt
unverändert. Das Root-Skript erzeugt keine App-Konfiguration, Zugangsschlüssel,
Zertifikate oder Modelldownloads und liest keine `.env` aus dem Benutzerverzeichnis.
Es vergibt standardmäßig auch keine Docker-Rechte an Benutzer.

### B. Installieren Und Starten

Im Verzeichnis `BorgVRAgentServer` für den ersten lokalen Test:

```
sudo ./setup.sh install
```

Dieser eine Befehl erzeugt `.env`, Zugangsschlüssel und Testzertifikat, prüft mindestens
200 GiB freien Platz und CUDA, lädt fehlende Images und startet beide Dienste. Das fertige
[Agenten-Image 3.9.0](https://github.com/JensDerKrueger/BorgVR/pkgs/container/borgvr-agent)
ist standardmäßig per geprüftem Digest festgelegt und ohne Anmeldung herunterladbar.
Es wird nichts lokal gebaut. vLLM lädt das Modell in seinen persistenten Cache;
der Agent startet erst, wenn vLLM bereit ist. Der erste Download und die
Kernel-Kompilierung können dauern; maximal eine Stunde wird abgewartet.

Für Zugriff von anderen Geräten Hostname oder IP und lokale Abhöradresse angeben:

```
sudo ./setup.sh install --host 192.168.1.20 --bind 192.168.1.20
```

Hostname und IP ersetzen. `--host` bestimmt den Zertifikatsnamen, `--bind` die
Abhöradresse. Ohne Angabe bleibt es bei localhost/`127.0.0.1`. `0.0.0.0` gibt alle
IPv4-Schnittstellen frei und braucht bewusste Netzabsicherung. Port ist **8766** (`--port`),
GPU **0** (`--gpu INDEX` oder NVIDIA-GPU-UUID).

Dabei entstehen zwei private zufällige Zugangsschlüssel und ein Testzertifikat. Für
den späteren nativen Betrieb ein vertrauenswürdiges CA-Zertifikat verwenden, siehe unten.

**Die eigentlichen Nutzer verbinden sich danach nur aus BorgVR mit dem Server.** Sie
müssen nichts auf dem Linux-Server installieren und brauchen dort keine Docker-Rechte.

Die Skripte verwenden den lokalen rootful
Docker-Socket `/var/run/docker.sock`, keinen entfernten Docker-Kontext.
`setup.sh` installiert keine Systempakete, startet Docker nicht neu und ruft nicht selbst
sudo auf. Für einen Entwickler-Build ausdrücklich `--build-agent` mit einem lokalen
Image-Tag verwenden. Besondere Volume-Quotas separat prüfen.

Vorhandene Konfiguration, Schlüssel, Zertifikate und Modell-Caches bleiben erhalten.
Wiederholte Aufrufe ersetzen diese nicht; neue Host-/Port-/GPU-Argumente ändern eine
bestehende `.env` nicht. Änderungen bewusst in `.env` vornehmen, bei Namensänderung auch
das Zertifikat erneuern. Ein nach einem Fehler vorhandenes `runtime` ohne `.env` muss
manuell geprüft werden, damit keine Schlüssel versehentlich verloren gehen.
Wenn eine alte `.env` noch `BORGVR_AGENT_IMAGE=borgvr-agent:3.9` enthält und dieses lokale
Image nicht existiert, mit `sudoedit .env` nur die Image-Adresse auf
`ghcr.io/jensderkrueger/borgvr-agent:3.9.0` beziehungsweise den Digest aus Abschnitt 9 ändern.
Schlüssel und Zertifikate müssen dafür nicht neu erzeugt werden.

Nur Konfiguration erzeugen, ohne Dienste zu starten:

```
sudo ./setup.sh init --host ai.example.org --bind 192.168.1.20
```

## 4. Funktion prüfen

Im gleichen Verzeichnis:

```
sudo ./setup.sh status
sudo ./setup.sh test
```

Der Test prüft Modellbereitschaft, Authentifizierung und die verschlüsselte Verbindung und
fordert eine kurze Antwort vom **echten Modell** an. Er simuliert keinen erfolgreichen
Renderbefehl: Die native App ist in diesem Schritt noch nicht angeschlossen.

Ein Test von einem anderen Rechner ist ebenfalls möglich; siehe den englischen Leitfaden.
Der Testclient prüft Zertifikat und Hostname, es gibt keinen unsicheren TLS-Schalter.

Eine eigene Frage stellen:

```
sudo docker compose exec -T agent python client.py --url https://127.0.0.1:8766 \
  --ca /run/tls/server.crt --token-file /run/secrets/agent_token \
  --text "Was ist ein Mandelbulb? Antworte kurz auf Deutsch."
```

## 5. Sicherheit Und Zertifikate

- `.env` enthält Image-/Modellrevision, GPU, Speicherbudget, Adresse, Port und Benutzer-IDs.
- `runtime/secrets/agent_token` ist der Zugangsschlüssel für Clients, wie ein Passwort
  behandeln. Er gilt aktuell für **die gesamte Installation**, noch nicht separat pro Gerät.
- `runtime/secrets/vllm_token` ist nur für die interne Modellkommunikation, Modus 0640.
- `runtime/tls/server.crt` ist das öffentliche Zertifikat.
- `runtime/tls/server.key` ist der private Schlüssel und gehört niemals auf einen Client.
- Verzeichnisse sind nur für den Besitzer zugänglich, sonstige private Schlüssel haben Modus 0600.
  Diese Rechte nicht durch weltweite Lesbarkeit umgehen.

Bei neuer Einrichtung mit sudo bleiben `.env` und das übergeordnete `runtime`-Verzeichnis
root-eigen. Nur die privaten Container-Mounts erhalten UID/GID 10001; damit läuft der
Agent trotz administrativer Einrichtung nicht als root. vLLM erhält die zusätzliche
Gruppe `BORGVR_GID`, um ausschließlich den gemeinsamen internen Token lesen zu können,
auch ohne Rechte zum Umgehen von Dateiberechtigungen. `install`, `init` und `start`
korrigieren dessen Modus bei bestehenden Installationen auf 0640, ohne den Schlüssel
zu ändern. Die übrigen Benutzer-IDs und privaten Dateirechte bleiben erhalten.

Standardmäßig wird ein eigener interner Schlüssel zufällig erzeugt. Ein auf dem Host
gesetztes `VLLM_API_KEY` wird niemals übernommen. Optional kann bei der **ersten**
Einrichtung `VLLM_BORGVR_API_KEY` vorgegeben werden (32 bis 512 ASCII-Buchstaben, Ziffern,
Punkte, Unter- oder Bindestriche); bei sudo muss diese Variable gezielt mit
`--preserve-env=VLLM_BORGVR_API_KEY` weitergereicht werden. Nicht in die Befehlszeile
schreiben oder in `.env` ablegen. Bei vorhandener Konfiguration bleibt der alte Schlüssel.
Nur innerhalb des BorgVR-vLLM-Containers setzt der Starter aus der privaten Schlüsseldatei
den von vLLM vorgeschriebenen Namen `VLLM_API_KEY`. Andere Container bleiben unabhängig.

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

```
sudo ./setup.sh status
sudo ./setup.sh logs
sudo ./setup.sh stop
sudo ./setup.sh start
sudo ./setup.sh restart
sudo ./setup.sh test
```

`start` startet fehlende/gestoppte Dienste, übernimmt geänderte Compose-Einstellungen und
wartet auf deren Bereitschaft. `stop` stoppt nur BorgVR, behält aber Container, Modell-Cache,
Konfiguration und Schlüssel. `restart` prüft erst die privaten Mounts, stoppt dann beide
BorgVR-Dienste und startet sie wieder; dabei muss vLLM das Modell erneut in die GPU laden.
`logs` zeigt laufende Meldungen; Ctrl+C beendet nur die Anzeige. Andere Docker-Projekte
werden nicht gestoppt. Für alle Befehle im Deployment-Verzeichnis bleiben.
Stoppen, Neustarten und das Ersetzen eines Containers können aktive Sitzungen unterbrechen;
Gespräche werden nur im RAM gehalten, nicht nach einem Neustart wiederhergestellt.

Mit `sudo ./setup.sh doctor` lässt sich der CUDA-Zugriff erneut prüfen.

### Nach Einem Rechner-Neustart

Beide Container verwenden `restart: unless-stopped`. Wenn Docker beim Booten startet,
kommen vorher laufende Dienste automatisch wieder. Die Modellgewichte bleiben im Volume
`borgvr-ai_model-cache`, müssen aber erneut in GPU/RAM geladen werden. Währenddessen kann
der Agent noch nicht bereit sein. Der Deployment-Ordner muss mit `.env`, Starter und
Zertifikaten unverändert an seinem bisherigen Ort verfügbar sein.

Docker-Autostart prüfen und bei Bedarf ohne Neustart aktivieren:

```
sudo systemctl is-enabled docker
sudo systemctl enable docker
```

Nach `sudo ./setup.sh stop` bleiben die Dienste auch nach einem Rechner-Neustart aus.
Zum Wiederanlaufen `sudo ./setup.sh start`, danach `sudo ./setup.sh test` verwenden.
Eine erneute Installation oder ein erneuter Modelldownload ist normalerweise nicht nötig.
Wenn andere GPU-Dienste ebenfalls automatisch starten, deren Speicherbedarf mit einplanen.
Siehe [Docker-Neustartrichtlinien](https://docs.docker.com/engine/containers/start-containers-automatically/).

vLLM **0.34.0**, Container-Digests, Modellrevision und alle Python-Abhängigkeiten sind
festgelegt. Hostpakete stammen dagegen aus den signierten Paketquellen und sollen regulär
Sicherheitsupdates erhalten. Die verwendete BorgVR-Commit-ID für die Installation notieren.

### Updates

Vor Updates `.env` und `runtime` sicher sichern. Skripte und Compose-Datei als normaler
Benutzer aktualisieren, danach Container als Administrator:

```
git pull
sudo ./setup.sh update
```

`update` lädt die **in `.env` konfigurierten** Images, prüft die privaten Mounts, übernimmt
Änderungen durch erneutes `up` und führt anschließend den echten Modelltest aus. Es baut
keine Images und führt kein Git-Update oder Systemupdate aus. Bei unveränderten Digests
bleiben die Image-Versionen unverändert; ein Pull bedeutet nicht automatisch eine neue Version.

Für eine ausdrücklich gewählte neue Agenten-Version `sudo ./setup.sh update --agent-image REF`
verwenden; `REF` durch die veröffentlichte Image-Adresse mit Tag oder besser Digest ersetzen.
Zuerst wird die neue Adresse nur vorübergehend für Download und Leseprüfungen verwendet.
Erst wenn beides gelingt, wird `.env` atomar umgestellt und die alte Datei privat unter
`runtime/env-before-update-*` gesichert. Die Schlüssel und der Modell-Cache bleiben erhalten.
Schlägt bereits Download/Prüfung fehl, laufen die bisherigen Container unverändert weiter.
Scheitert der anschließende Start oder Modelltest, meldet das Skript einen Fehler; es führt
keinen automatischen Rollback aus. Die ausgegebene Sicherung kann nach Prüfung mit
`sudo cp /PFAD/ZUR/SICHERUNG .env` zurückgespielt werden, danach `sudo ./setup.sh start`.

Bei einem Quellcode-Build statt Pull den Build-Overlay verwenden:
`sudo docker compose -f compose.yaml -f compose.build.yaml build --pull agent`.
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

```
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
`sudo docker load --input borgvr-agent-3.9.tar`. In `.env` dann
`BORGVR_AGENT_IMAGE=borgvr-agent:3.9` setzen und `sudo ./setup.sh install` ausführen.
Das bereits geladene Image wird wiederverwendet. Image-Archive sind von Git und
Build-Kontext ausgeschlossen.

## 9. Wiederholbare Builds Und Veröffentlichung Über GitHub

**Veröffentlicht: 3.9.0 für linux/amd64**, aus Commit
`54ad28148c9b1a95fb0f627f48b707a947919e15`.
[Build, Tests und Veröffentlichung](https://github.com/JensDerKrueger/BorgVR/actions/runs/44091127267)
sind erfolgreich; der anonyme Registry-Zugriff wurde geprüft. Unveränderliche Image-Adresse:

```text
ghcr.io/jensderkrueger/borgvr-agent@sha256:729d464bf75d8b2fbf67c0733875d08db5cd121d6a15db01ef3d6679b4c1e053
```

Der Workflow [BorgVR Agent Container](https://github.com/JensDerKrueger/BorgVR/actions/workflows/borgvr-agent.yml)
baut und testet nach relevanten Änderungen auf `main` sowie bei Pull Requests automatisch
ein Image für **linux/amd64**. Zusätzlich zu den Tests startet er den echten Container mit
TLS, Authentifizierung und schreibgeschütztem Dateisystem. Der CPU-Runner testet dabei
bewusst keine GPU-Inferenz; diese Prüfung bleibt auf dem H200-Rechner erforderlich.

### Was Der Workflow Genau Macht

1. **Auslösen:** Änderungen unter `BorgVRAgentServer` oder am Workflow starten den Lauf
   bei einem Push auf `main` oder einem Pull Request. Ein manueller Start ist ebenfalls möglich.
2. **Isolierter Build-Rechner:** GitHub stellt einen temporären Ubuntu-24.04-Rechner mit
   Python 3.12 bereit und lädt genau den auslösenden Quellcode-Commit. Dein Linux-Server
   wird dabei nicht kontaktiert. Mehrere Läufe desselben Branches werden nacheinander ausgeführt.
3. **Metadaten und Tests:** Repository, Commit, Plattform und optionale Versionsnummer
   werden validiert. Die festgelegten Test-Abhängigkeiten werden installiert und die
   Unit-, Protokoll-, Installer-, Rechte-, TLS- und Deinstallationstests ausgeführt.
4. **Compose prüfen:** Eine temporäre Testkonfiguration wird erzeugt und sowohl die normale
   Compose-Datei als auch das Entwickler-Build-Overlay auf gültige Konfiguration geprüft.
5. **Image bauen:** Docker Buildx baut nur unseren Agenten für `linux/amd64`, zunächst lokal
   als `borgvr-agent:ci`. Basis-Image und Python-Pakete sind festgelegt. Build-Caches beschleunigen
   Wiederholungen. OCI-Labels enthalten unter anderem Quellcode-Commit und Version.
6. **Echten Container prüfen:** Das gebaute Image wird wirklich gestartet, mit TLS,
   schreibgeschütztem Dateisystem und reduzierten Rechten. Die Tests laufen nach normaler
   und nach Root-Einrichtung. Sie prüfen auch den gemeinsamen Token ohne zusätzliche
   Root-Capabilities sowie die gezielte Deinstallation unter Schutz fremder Container.
   Der Container hat absichtlich kein Modell und meldet es als nicht bereit. Nur die
   Unit-Tests verwenden deterministische Testmodelle; echte Inferenz wird nicht vorgetäuscht.
7. **Artefakte sichern:** Das getestete Image wird mit `docker save` archiviert. Ein separates
   Deployment-Paket enthält Skripte, Compose-Datei, Anleitungen und Lizenz. `release.json`
   und SHA-256-Prüfsummen verbinden die Archive mit Quellcode und Image-ID. Installationspakete
   enthalten keine produktiven Schlüssel, Zertifikate oder Modellgewichte.
8. **Normaler Lauf endet hier:** Pushes und Pull Requests veröffentlichen kein Registry-Image.
   Der Image-Upload erfolgt nur nach manuellem Start mit `publish=true`, expliziter neuer
   Version und Branch `main`, und nur nach erfolgreichem Build samt Tests.
9. **Veröffentlichen ohne Neubau:** Der zweite Job lädt exakt das zuvor getestete Artefakt,
   prüft Commit/Repository/Prüfsummen und die Docker-Image-ID und lädt es in Docker.
   GitHubs temporärer Token erhält nur hier Schreibrechte auf Packages. Das gleiche Image
   wird mit Versions- und Commit-Tag nach GHCR geschoben. Eine vorhandene Versionsnummer
   darf nicht auf ein anderes Image umgebogen werden.
10. **Ergebnis:** Ein weiteres Deployment-Paket enthält den festen Registry-Digest für die
    Installation. Danach meldet sich der Job von der Registry ab. Er ändert weder
    Paketsichtbarkeit noch `latest`, erzeugt kein GitHub-Release und aktualisiert keinen Server.

**Wichtige Trennung:** `git pull` aktualisiert Skripte und Compose-Dateien. Ein neuer
Workflow-Build erzeugt ein neues Image, installiert es aber nirgends. Erst eine bewusste
Veröffentlichung macht es in GHCR verfügbar; erst `setup.sh update` auf deinem Server
mit passender Image-Auswahl setzt es dort ein. vLLM und Modellgewichte werden nicht von
unserem Workflow gebaut oder mitgeliefert, sondern vom Server aus ihren jeweiligen Quellen geladen.

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
den Branch **main** wählen, **publish** aktivieren und eine neue Version wie **3.9.1**
eintragen. Nach erneut erfolgreichen Tests wird exakt das geprüfte Image ohne weiteren
Build veröffentlicht:

```text
ghcr.io/jensderkrueger/borgvr-agent:3.9.1
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
Administrator mit `sudo ./setup.sh update` neu. Alternativ `update --agent-image REF`
verwenden, um die Agenten-Adresse mit Sicherung der bisherigen `.env` umzustellen.
Zugangsschlüssel und Zertifikate bleiben erhalten; eine Neuinitialisierung ist nicht nötig.

## 10. Deinstallation und erneuter Test

### BorgVR samt Modell und Git-Download entfernen

Auch `sudo ./setup.sh uninstall` ohne weitere Optionen zeigt nur eine Vorschau. Die
folgenden zusätzlichen Optionen planen außerdem das Entfernen ungenutzter Images und des
gesamten sauberen Git-Clones. Der direkte Aufruf von `./uninstall.py` bleibt unterstützt.

Im bisherigen Deployment-Verzeichnis zunächst als Administrator die **Vorschau** aufrufen:

```
sudo ./setup.sh uninstall --remove-images --remove-checkout
```

Bereits als root angemeldet: `sudo` weglassen. Das Skript zeigt konkrete Ressourcen und
Verzeichnisse an und löscht ohne `--yes` nichts. Die vollständige Entfernung bestätigen:

```
sudo ./setup.sh uninstall --remove-images --remove-checkout --yes
```

Dabei werden die Container des Projekts `borgvr-ai`, dessen Netzwerk und Modell-Volume
`borgvr-ai_model-cache` entfernt. Im Volume liegen die heruntergeladenen Modellgewichte
und deren Caches. Außerdem werden die zugehörigen konfigurierten Images und das kleine
Python-Prüfimage entfernt, sofern keine fremden Container sie verwenden.

`--remove-checkout` löscht anschließend den **gesamten geklonten BorgVR-Ordner**, inklusive
`.git`, lokaler Konfiguration, Token, Zertifikaten und ignorierter Dateien. Bei einem
entpackten Deployment-Paket wird nur dessen Ordner gelöscht. Das Skript verweigert die
automatische Löschung eines Git-Clones mit lokalen Änderungen oder nicht ignorierten,
unversionierten Dateien sowie von anderen Repositories, Home- und Systemverzeichnissen.
Eigene Daten vorab sichern; gemeinsam genutzte Images werden ausdrücklich als behalten gemeldet.

Soll der Quellcode für den nächsten Test bleiben, `--remove-checkout` weglassen.
Für einen frischen Test entstehen neue Zugangsschlüssel und Zertifikate; Modellgewichte
werden erneut geladen. Andere Docker-Projekte und globale Build-Caches werden nicht
pauschal bereinigt. Download-Archive, die außerhalb des Projektordners liegen, separat
an ihrem tatsächlichen Speicherort löschen.
Vor dem nächsten Klonen zuerst in ein noch vorhandenes Verzeichnis wechseln, zum Beispiel
mit `cd /home/borgvr`; die Shell kann noch im gerade gelöschten Projektordner stehen.

Falls bisher nur geklont wurde und Docker noch nicht installiert ist:

```
./uninstall.py --files-only --remove-checkout --yes
```

`--files-only` prüft oder entfernt bewusst keine Docker-Ressourcen. Nicht verwenden,
wenn noch laufende BorgVR-Container oder Modell-Volumes übrig sein könnten.

### Auch Docker entfernen, aber nur auf einem ausschließlich für BorgVR eingerichteten Host

**Diesen Abschnitt nur verwenden, wenn Docker, containerd und NVIDIA Container Toolkit
für BorgVR neu installiert wurden und nicht von anderen Anwendungen genutzt werden.**
Vorher die obige BorgVR-Deinstallation abschließen. Als Administrator prüfen, dass keine
fremden Container, Images, Volumes oder eigenen Netzwerke übrig sind:

```
unset DOCKER_CONTEXT
export DOCKER_HOST=unix:///var/run/docker.sock
docker ps -a
docker image ls
docker volume ls
docker network ls
```

Die Standardnetzwerke `bridge`, `host` und `none` sind normal. Bei fremden Ressourcen
hier abbrechen und Docker installiert lassen. War Docker schon vor BorgVR vorhanden,
diesen Abschnitt ebenfalls überspringen.

Den eventuell bereits gelöschten Projektordner verlassen und eine Registry-Anmeldung lösen:

```
cd /
docker logout ghcr.io
```

Dann die Dienste stoppen und die ausschließlich für diesen Zweck installierten Pakete
entfernen. Die Paketverwaltung fragt nach Bestätigung; falls sie weitere, fremde Anwendungen
entfernen möchte, abbrechen. Kein pauschales `autoremove` ausführen.

```
sudo systemctl stop docker.service docker.socket containerd.service
sudo apt-get purge docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io docker-buildx-plugin docker-compose-plugin nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1
```

**Nur unter der obigen Exklusivitätsbedingung** auch die Docker-Daten einschließlich aller
Image-Layer und Build-Caches sowie die Docker-/Container-Runtime-Konfiguration entfernen:

```
sudo rm -rf -- /var/lib/docker /var/lib/containerd /etc/docker /etc/nvidia-container-runtime
```

Die von unserem Host-Skript hinzugefügten Paketquellen und Schlüssel entfernen:

```
sudo rm -f -- /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/nvidia-container-toolkit.list /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
sudo apt-get update
```

Falls das Wartungskonto durch `--docker-user borgvr` neu zur Docker-Gruppe hinzugefügt
wurde, auch diese Berechtigung zurücknehmen:

```
sudo gpasswd -d borgvr docker
```

Den Namen bei einem anderen Konto ersetzen. Eine vorher bestehende Gruppenmitgliedschaft
nicht entfernen. Eine nur hierfür neu erzeugte, anschließend leere Docker-Gruppe kann der
Administrator nach Prüfung mit `getent group docker` auch mit `sudo groupdel docker` löschen.
Falls die Docker-Client-Konfiguration des aktuellen Kontos ausschließlich für diesen Test
neu angelegt wurde, kann sie ebenfalls entfernt werden:

```
rm -rf -- "$HOME/.docker"
```

Das nicht bei vorher bestehenden Docker-Kontexten oder anderen Registry-Anmeldungen tun.
Das Benutzerkonto selbst wird nicht gelöscht. NVIDIA-GPU-Treiber und
allgemeine Werkzeuge wie Python, OpenSSL und Git bleiben erhalten. Systemupdates sowie
globale Paketmanager-/Systemprotokolle werden nicht zurückgesetzt.
