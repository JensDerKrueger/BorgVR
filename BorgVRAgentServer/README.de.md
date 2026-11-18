# BorgVR-Agent: Installation Unter Linux

[English / vollständige Betriebsreferenz](README.md) | [Verbindungsprotokoll](PROTOCOL.md)

Dieses Verzeichnis enthält den Server für die KI-Steuerung:
**vLLM mit einem wählbaren Vision-Language-Modell** und unseren **BorgVR-Agenten auf Basis von Pydantic AI**.
Die Dienste laufen in Containern. Nur der mit TLS und Zugangsschlüssel abgesicherte
Agent ist von außen erreichbar; vLLM bleibt im privaten Container-Netz.

**Stand:** Server, Textanfragen, externe Werkzeugaufrufe, Bilder, Zwischenmeldungen und
Abbruch sowie der gemeinsame Sprach-/Textclient für macOS, iOS und visionOS sind implementiert.
Die bisherigen fest vorgegebenen Vision-Sprachbefehle sind ersetzt. Anatomische Zuordnungen
müssen vom Benutzer geprüft werden; die Sprachsteuerung ist keine medizinische Diagnosefunktion.

### Native App Verbinden

Unter **Einstellungen > KI-Assistent** den Assistenten aktivieren, `https://ai1:8766`
eintragen (oder die zum Zertifikat passende IP), das öffentliche `runtime/tls/server.crt`
importieren und die Datei `runtime/secrets/agent_token` importieren oder deren Inhalt eingeben.
**Niemals `server.key` oder `vllm_token` auf die Geräte kopieren.** Der Zugangsschlüssel landet
im Geräte-Schlüsselbund. Übertragen Sie ihn nur auf vertrauenswürdige Geräte und entfernen Sie
Transferkopien nach dem Import. Der Servertest funktioniert ohne geöffneten Datensatz.

Dann einen Datensatz öffnen und **KI-Assistent** in den Render-Bedienelementen wählen.
Sprechen über das Mikrofon oder Text eingeben; Antworten und Zwischenmeldungen erscheinen
im Gespräch und werden auf Wunsch lokal vorgelesen. Renderbilder können separat erlaubt
werden. Kamera und Passthrough werden nicht übertragen. Spracherkennung erfolgt standardmäßig
auf dem Gerät; eine mögliche Verarbeitung durch Apple muss separat erlaubt werden.
Abbrechen beendet die Verbindung, macht bereits ausgeführte Änderungen aber nicht rückgängig.
Agenteneinstellungen und Schlüssel bleiben gerätelokal, außerhalb von SharePlay und GSC.

## 1. Was Auf Dem Rechner Installiert Sein Muss

- Linux x86_64, Zielsystem **Ubuntu 26.04.1 LTS (resolute)**.
- Eine von vLLM und dem gewählten Modell unterstützte **NVIDIA/CUDA- oder AMD/ROCm-GPU**
  mit passendem, bereits installiertem Treiber. Die H200 ist keine Voraussetzung.
- Genügend GPU- und Hauptspeicher für Gewichte, Bildencoder, Kontext/KV-Cache und Laufzeit.
  Kleinere Modelle oder passende quantisierte Checkpoints können deutlich weniger benötigen.
  Auch bei MoE-Modellen müssen normalerweise sämtliche Gewichte gespeichert werden.
- Freier Platz im Docker-Speicherverzeichnis: Profilreserve **200 GiB** für Qwen3.6-35B,
  **160 GiB** für Qwen3.8-27B und **80 GiB** für Qwen3.5-4B. Das sind konservative,
  konfigurierbare Startwerte (`--min-free-gib`), keine gemessenen Größen oder Garantien.
- Docker Engine und Compose v2; bei NVIDIA zusätzlich NVIDIA Container Toolkit.
- Python 3 und OpenSSL für die Konfiguration, optional Git zum Klonen.
- Internetzugriff auf Paketquellen, Docker Hub, PyPI und Hugging Face samt Download-CDNs.
- Ein Benutzer mit sudo-Rechten für Einrichtung und Containerbetrieb. Normale BorgVR-Nutzer
  brauchen weder Docker-Zugriff noch Root-Rechte oder ein Shell-Konto auf dem Server.

**CUDA Toolkit, PyTorch, vLLM und die Python-Agentenpakete musst du nicht auf dem Host
installieren.** Diese Komponenten kommen in die Container. Ein passender GPU-Treiber
bleibt dagegen eine Voraussetzung des Hosts.

Bei NVIDIA zuerst prüfen:

```
nvidia-smi
```

Falls das nicht funktioniert, zuerst den von Distribution/Hersteller unterstützten Treiber
installieren und gegebenenfalls neu starten. Das Skript verändert absichtlich keine
Treiber, Secure-Boot-Einstellungen oder GPU-Partitionen und startet den Rechner nicht neu.
Bei AMD müssen `/dev/kfd` und `/dev/dri` durch einen passenden Treiber verfügbar sein.
Der Treiber muss zur CUDA-/ROCm-Laufzeit des gewählten Images passen; `doctor` prüft
das durch eine echte GPU-Speicherallokation im Container, einschließlich gewähltem Datentyp.

**Teststand:** Qwen3.6-35B-A3B wurde auf der H200 tatsächlich ausgeführt. Weitere Profile
und beide Backend-Konfigurationen sind automatisiert geprüft, aber nicht auf allen GPUs
praktisch vermessen. Insbesondere ROCm braucht noch einen Test auf echter AMD-Hardware.

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
`setup.sh` ergänzt automatisch `compose.cuda.yaml` oder `compose.rocm.yaml`.
Für Start/Update die Skriptbefehle verwenden, nicht `docker compose up` ohne Backend-Overlay.
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

Für AMD stattdessen `sudo ./setup-host.sh --backend rocm`. Dieser Weg installiert keine
NVIDIA-Pakete, verändert keine NVIDIA-Laufzeit und startet Docker nicht neu. GPU-Treiber
werden bei beiden Backends nicht installiert oder ersetzt.

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

Dieser eine Befehl erzeugt `.env`, Zugangsschlüssel und Testzertifikat, prüft die profilabhängige
Platzreserve und die GPU, lädt fehlende Images und startet beide Dienste. Das fertige
[Agenten-Image ab 3.9.1](https://github.com/JensDerKrueger/BorgVR/pkgs/container/borgvr-agent)
unterstützt Modellprofile und ist ohne Anmeldung herunterladbar.
Es wird nichts lokal gebaut. vLLM lädt das Modell in seinen persistenten Cache;
der Agent startet erst, wenn vLLM bereit ist. Der erste Download und die
Kernel-Kompilierung können dauern; maximal eine Stunde wird abgewartet.
Danach werden Textantwort, Werkzeugaufrufe und Bildverarbeitung tatsächlich getestet.

Für Zugriff von anderen Geräten Hostname oder IP und lokale Abhöradresse angeben:

```
sudo ./setup.sh install --host 192.168.1.20 --bind 192.168.1.20
```

Hostname und IP ersetzen. `--host` bestimmt den Zertifikatsnamen, `--bind` die
Abhöradresse. Ohne Angabe bleibt es bei localhost/`127.0.0.1`. `0.0.0.0` gibt alle
IPv4-Schnittstellen frei und braucht bewusste Netzabsicherung. Port ist **8766** (`--port`),
GPU **0** (`--gpu INDEX` oder NVIDIA-GPU-UUID).

### Modelle Und Grafikkarten Wählen

Das **vLLM-Image** enthält die Inferenzsoftware und CUDA/ROCm, nicht automatisch das Modell.
**Modell und Revision** wählen separat den Checkpoint. Ein Modellwechsel braucht nur dann
ein anderes vLLM-Image, wenn Modellarchitektur, Parser oder Hardware ein anderes benötigen.
Unser Agenten-Image und das Client-Protokoll bleiben ansonsten gleich.

```
./setup.sh profiles
sudo ./setup.sh install --backend cuda --profile qwen35-4b
```

Die drei Modellprofile `qwen36-35b`, `qwen35-4b` und `qwen38-27b` enthalten feste,
jeweils eigene Modellrevisionen sowie passende Ausgangswerte für Parser und Ressourcen.
Für eine neue AMD-Installation etwa `sudo ./setup.sh install --backend rocm --profile qwen35-4b`.
CUDA- und ROCm-Images sind unabhängig per Digest festgelegt. Keiner dieser Befehle garantiert,
dass jedes Modell auf jeder Karte passt; Kernel-, Quantisierungs- und Speicheranforderungen gelten weiter.

Bestehende Installation umstellen, ohne Schlüssel oder Modell-Cache zu löschen:

```
sudo ./setup.sh update --agent-image ghcr.io/jensderkrueger/borgvr-agent:3.9.1
sudo ./setup.sh configure --profile qwen38-27b
sudo ./setup.sh doctor
sudo ./setup.sh update
```

`configure` sichert die alte `.env`, prüft und schreibt die neuen Einstellungen, startet aber
keine Container. `--backend rocm` wählt auch das ROCm-Image und die ermittelten Geräte-Gruppen.
`--vllm-image REF` erlaubt ausdrücklich ein anderes kompatibles vLLM-Image.
Die bisherige laufende Instanz ändert sich erst mit `update` oder `start`.

Ein eigenes **bildfähiges Modell mit Tool Calling** konfigurieren:

```
sudo ./setup.sh configure --profile custom \
  --model ORGANISATION/MODELL --model-revision COMMIT \
  --tool-parser PARSER --reasoning-parser none --thinking default
```

Platzhalter aus Modellkarte und vLLM-Dokumentation ersetzen. Bei einem anderen Checkpoint
wird niemals stillschweigend die Commit-ID des vorherigen Modells übernommen.
`--thinking default` lässt modellspezifische Request-Parameter ganz weg; die Qwen-Profile
schalten Thinking gezielt ab. Reine Textmodelle werden nicht unterstützt.

Weitere Stellschrauben: `--dtype auto|float16|bfloat16|float32`, `--quantization NAME`,
`--context-length N`, `--max-seqs N`, `--max-output-tokens N`, `--gpu-memory-fraction F`,
`--enforce-eager true|false` und `--cpu-offload-gb N`. Bei älteren Karten kann `float16`
statt `bfloat16` nötig sein. Eine Quantisierungsoption macht nicht jeden beliebigen
Checkpoint automatisch kleiner; Format, Kernel und Backend müssen zusammenpassen.
Kürzerer Kontext und weniger parallele Sequenzen sparen Speicher, können aber Aufgaben begrenzen.

Quellen: [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B),
[Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B),
[vLLM-Modell-/Tool-Parser](https://docs.vllm.ai/en/latest/features/tool_calling/),
[vLLM-GPU-Anforderungen](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/).

Dabei entstehen zwei private zufällige Zugangsschlüssel und ein selbstsigniertes Zertifikat.
Für die native App dessen öffentliches Zertifikat ausdrücklich importieren oder ein
vertrauenswürdiges CA-Zertifikat verwenden, siehe unten.

**Die eigentlichen Nutzer verbinden sich danach nur aus BorgVR mit dem Server.** Sie
müssen nichts auf dem Linux-Server installieren und brauchen dort keine Docker-Rechte.

Die Skripte verwenden den lokalen rootful
Docker-Socket `/var/run/docker.sock`, keinen entfernten Docker-Kontext.
`setup.sh` installiert keine Systempakete, startet Docker nicht neu und ruft nicht selbst
sudo auf. Für einen Entwickler-Build ausdrücklich `--build-agent` mit einem lokalen
Image-Tag verwenden. Besondere Volume-Quotas separat prüfen.

Bei erneutem `install` werden vorhandene BorgVR-Container und das Projekt-Netzwerk zunächst
mit `down` entfernt, aber **keine Volumes oder Images gelöscht**. Das gibt auch den vom
alten Modell belegten GPU-Speicher frei. Zugangsschlüssel und Modell-Cache bleiben erhalten.
Ausdrücklich angegebene Optionen ändern die bestehende Konfiguration; nicht angegebene
Werte bleiben erhalten. Das gilt auch für Hostname/IP, Abhöradresse und Port:

```
sudo ./setup.sh install --host ai1 --bind 0.0.0.0 --port 8766
```

Statt `ai1` ist auch eine feste IP möglich. Passt das vorhandene Zertifikat nicht zum
angegebenen Host, wird es erneuert und privat unter `runtime/tls-before-install-*` gesichert.
Clients müssen danach dem neuen Zertifikat vertrauen; ihre Zugangsschlüssel bleiben gleich.
Ein passendes Zertifikat wird nicht ersetzt. Änderungen an `.env` erhalten eine private
Sicherung unter `runtime/env-before-update-*`. Ungültige Optionen werden vor `down` abgelehnt.
`init` allein bleibt unverändert: Es überschreibt keine vorhandene Konfiguration.
Ein nach einem Fehler vorhandenes `runtime` ohne `.env` muss
manuell geprüft werden, damit keine Schlüssel versehentlich verloren gehen.
Wenn eine alte `.env` noch `BORGVR_AGENT_IMAGE=borgvr-agent:3.9` enthält und dieses lokale
Image nicht existiert, mit `sudoedit .env` nur die Image-Adresse auf
`ghcr.io/jensderkrueger/borgvr-agent:3.9.1` beziehungsweise den veröffentlichten Digest ändern.
Schlüssel und Zertifikate müssen dafür nicht neu erzeugt werden.

### Modell Mit Einem Befehl Wechseln

```
sudo ./setup.sh model
sudo ./setup.sh model qwen35-4b
sudo ./setup.sh model qwen36-35b
sudo ./setup.sh model qwen38-27b
```

Ohne Profil zeigt `model` das konfigurierte Modell und alle verfügbaren Profile an, ohne
Dienste zu ändern. Mit Profil sichert und ändert es die Modellkonfiguration, lädt fehlende
Images, startet die Dienste mit dem gewählten Modell und prüft Bildverarbeitung und
Werkzeugaufrufe. Bereits heruntergeladene Modelle bleiben im Cache; beim Zurückwechseln
ist kein erneuter Download derselben Revision nötig. Das Laden in den GPU-Speicher braucht
weiterhin Zeit, und nicht jedes Modell passt auf jede Karte. Netzwerkadresse, Zugangsschlüssel
und Zertifikat bleiben unverändert. Weitere Modelloptionen können angehängt werden,
etwa `sudo ./setup.sh model qwen35-4b --context-length 4096`.
Bei einem fehlgeschlagenen Start bleiben Konfiguration und Sicherung zur Fehleranalyse erhalten.

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

Der Test prüft Modellbereitschaft, Authentifizierung und TLS und fordert eine kurze Antwort
vom **echten Modell** an. Danach muss es zwei harmlose Test-Werkzeuge aufrufen und die Farbe
eines synthetischen roten Bildes erkennen. Es wird kein echter Datensatz geöffnet oder verändert.
Ein Fehlschlag bedeutet fehlende Kompatibilität oder eine nicht zuverlässig erfüllte Testaufgabe,
nicht automatisch einen Hardwaredefekt. Die native App wird separat wie oben beschrieben eingerichtet.

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
- Diese Rechte nicht durch weltweite Lesbarkeit umgehen.

Bei Einrichtung mit `sudo` gehört `runtime` dem aufrufenden Benutzer (zum Beispiel
`krueger`), mit Modus 0700. Er kann die Dateien darin ohne sudo lesen und verwalten.
Die Unterverzeichnisse `secrets` und `tls` haben Modus 0750, ihre Container-Dateien
0640 und die Gruppe `BORGVR_GID`. Damit bleibt der Agent über seine Gruppe leseberechtigt
und läuft weiterhin mit seiner bisherigen unprivilegierten UID/GID (bei neuer Einrichtung
10001). vLLM erhält diese zusätzliche Gruppe ausschließlich für den internen Token.
Andere Benutzer bekommen keinen Zugriff; Sicherungsverzeichnisse bleiben 0700,
Sicherungsdateien 0600. Die neu erzeugte `.env` bleibt root-eigen und 0600.

`install`, `init`, `start`, `restart` und `update` richten diese Runtime-Rechte automatisch
ein, ohne Schlüssel, Container-IDs oder Modelle auszutauschen. Für eine bereits laufende
Installation genügt, als gewünschter Benutzer aus dem Agenten-Verzeichnis:

```
sudo ./setup.sh permissions
```

Dies benötigt weder Docker noch einen Neustart der Container. Ein bereits eingerichteter
Runtime-Besitzer bleibt auch bei späteren Aufrufen durch root oder andere Administratoren
erhalten. Bei einer direkten root-Ersteinrichtung ohne sudo-Benutzer bleiben die Dateien
wie bisher nur für root beziehungsweise den Container-Benutzer zugänglich.

Standardmäßig wird ein eigener interner Schlüssel zufällig erzeugt. Ein auf dem Host
gesetztes `VLLM_API_KEY` wird niemals übernommen. Optional kann bei der **ersten**
Einrichtung `VLLM_BORGVR_API_KEY` vorgegeben werden (32 bis 512 ASCII-Buchstaben, Ziffern,
Punkte, Unter- oder Bindestriche); bei sudo muss diese Variable gezielt mit
`--preserve-env=VLLM_BORGVR_API_KEY` weitergereicht werden. Nicht in die Befehlszeile
schreiben oder in `.env` ablegen. Bei vorhandener Konfiguration bleibt der alte Schlüssel.
Nur innerhalb des BorgVR-vLLM-Containers setzt der Starter aus der privaten Schlüsseldatei
den von vLLM vorgeschriebenen Namen `VLLM_API_KEY`. Andere Container bleiben unabhängig.

Das automatisch erzeugte, selbstsignierte Zertifikat gilt 365 Tage. Die native App kann
ihm durch den ausdrücklichen Import des öffentlichen Zertifikats vertrauen; Hostname
beziehungsweise IP und Gültigkeit werden weiterhin geprüft. Alternativ ein Zertifikat
einer auf den Geräten vertrauten internen oder öffentlichen CA verwenden.
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

Mit `sudo ./setup.sh doctor` lässt sich der CUDA-/ROCm-Zugriff erneut prüfen.

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
`sudo ./setup.sh install --build-agent` mit vorher bewusst gewähltem lokalen Agenten-Image-Tag.
Eine bestehende `.env` behält bewusst ihre alte
vLLM-/Modellrevision; diese bei einem Inferenz-Update ausdrücklich anpassen. Keine
stillschweigende Umstellung auf `latest`. Details zur Rückkehr auf alte Versionen,
Zertifikatswechsel, Fehlerbehebung und Deinstallation stehen im englischen Leitfaden.

## 7. Tests

Die Entwicklertests laufen ohne GPU mit einem deterministischen Testmodell durch die echte
Pydantic-AI-Schleife. Getestet werden unter anderem Anmeldung, Eingabevalidierung,
Werkzeugbeschränkungen, Bilder, Abbruch, Zeitlimits und veraltete Antworten. Den Test auf
der echten H200 und den Test mit dem Mikrofon auf dem jeweiligen Gerät ersetzen sie nicht.

`Scripts/test-voice-agent.sh` prüft zusätzlich den nativen macOS-Client über echtes lokales
TLS/WSS mit deterministischem Modell: Zustandsabfrage, Rotation, Transferfunktion, Renderbild,
Fortschrittsantwort, GSC-Roundtrip und Abbruch bei Kontextwechsel. Das Protokoll ist in
[PROTOCOL.md](PROTOCOL.md) beschrieben.

## 8. Agenten-Image Einmal Bauen Und Verteilen

Der normale Veröffentlichungsweg ist der folgende GitHub-Workflow; er erzeugt bereits
geprüfte Image- und Deployment-Archive. Nutzer brauchen keinen lokalen Build und keine
manuellen Registry-Tags. Für lokale Entwicklung auf einer eingerichteten Maschine:

```
sudo ./setup.sh configure --agent-image borgvr-agent:dev
sudo ./setup.sh install --build-agent
```

`compose.build.yaml` ist nur das Entwickler-Build-Overlay. Im normalen Betrieb wird das
getestete GHCR-Image verwendet. Gewichte, Schlüssel, Zertifikate und Python-Caches gehören
nicht ins Image. Das Setup veröffentlicht niemals selbst Images oder ändert Paketsichtbarkeit.

## 9. Wiederholbare Builds Und Veröffentlichung Über GitHub

**Veröffentlicht: 3.9.1 für linux/amd64**, aus Commit
`e764cebc3d565247c232c2bda9bc11f3a7097af8`.
[Build, Tests und Veröffentlichung](https://github.com/JensDerKrueger/BorgVR/actions/runs/44180364432)
sind erfolgreich; der anonyme Registry-Zugriff wurde geprüft. Unveränderliche Image-Adresse:

```text
ghcr.io/jensderkrueger/borgvr-agent@sha256:d033276eacdce742d8a86fd1af26dbf697369c0c53098ce7190b2218cde2c02d
```

Der Workflow [BorgVR Agent Container](https://github.com/JensDerKrueger/BorgVR/actions/workflows/borgvr-agent.yml)
baut und testet nach relevanten Änderungen auf `main` sowie bei Pull Requests automatisch
ein Image für **linux/amd64**. Zusätzlich zu den Tests startet er den echten Container mit
TLS, Authentifizierung und schreibgeschütztem Dateisystem. Der CPU-Runner testet dabei
bewusst keine GPU-Inferenz; diese Prüfung bleibt auf dem jeweiligen GPU-Rechner erforderlich.

### Was Der Workflow Genau Macht

1. **Auslösen:** Änderungen unter `BorgVRAgentServer` oder am Workflow starten den Lauf
   bei einem Push auf `main` oder einem Pull Request. Ein manueller Start ist ebenfalls möglich.
2. **Isolierter Build-Rechner:** GitHub stellt einen temporären Ubuntu-24.04-Rechner mit
   Python 3.12 bereit und lädt genau den auslösenden Quellcode-Commit. Dein Linux-Server
   wird dabei nicht kontaktiert. Mehrere Läufe desselben Branches werden nacheinander ausgeführt.
3. **Metadaten und Tests:** Repository, Commit, Plattform und optionale Versionsnummer
   werden validiert. Die festgelegten Test-Abhängigkeiten werden installiert und die
   Unit-, Protokoll-, Installer-, Rechte-, TLS- und Deinstallationstests ausgeführt.
4. **Compose prüfen:** Eine temporäre Testkonfiguration wird erzeugt. Die CUDA- und
   ROCm-Konfiguration sowie das Entwickler-Build-Overlay werden auf Gültigkeit geprüft.
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
den Branch **main** wählen, **publish** aktivieren und eine neue Version wie **3.9.2**
eintragen. Nach erneut erfolgreichen Tests wird exakt das geprüfte Image ohne weiteren
Build veröffentlicht:

```text
ghcr.io/jensderkrueger/borgvr-agent:3.9.2
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
