# BorgVR-Agent: Installation unter Linux und Windows/WSL 2

[English / vollständige Betriebsreferenz](README.md) | [Verbindungsprotokoll](PROTOCOL.md)

Für **Windows 11 mit NVIDIA-GPU** zuerst die [WSL-2-Anleitung](WINDOWS.de.md) verwenden.
Sie beschreibt Docker Desktop und Docker Engine in Ubuntu sowie die Windows-Netzfreigabe.
Die folgenden Host-Schritte beziehen sich auf **natives Linux**.

Dieses Verzeichnis enthält den selbst betriebenen Server für den KI-Assistenten von BorgVR
auf macOS, iOS und visionOS. Der Assistent versteht Sprach- und Textanfragen und kann die
Darstellung eines geöffneten Datensatzes steuern, Renderbilder auswerten und seine Schritte
mit Textantworten begleiten.

## Aufbau und Aufgaben

Der Server wird **nur für den KI-Assistenten** benötigt. Die normale Bedienung und das
Rendering von BorgVR funktionieren ohne ihn. Das KI-Modell läuft auf dem Linux-Rechner,
damit dessen GPU und Speicher für die rechenintensive Verarbeitung genutzt werden können,
ohne das Modell auf jedem iPhone, Mac oder Vision-Pro-Gerät installieren zu müssen.

Die Aufgaben sind auf die App und zwei Container verteilt:

| Komponente | Aufgabe |
| --- | --- |
| BorgVR-App | Erfasst Sprache oder Text, zeigt Antworten an und führt erlaubte Visualisierungsbefehle aus. Datensätze und Rendering bleiben in der App. |
| BorgVR-Agent | Verwaltet Gespräche, fragt das Modell ab und vermittelt geprüfte Werkzeugaufrufe zwischen Modell und App. Er stellt den mit TLS und Zugangsschlüssel abgesicherten Zugang bereit. |
| vLLM | Lädt das gewählte bildfähige Sprachmodell und berechnet dessen Antworten und Werkzeugvorschläge auf der GPU. |

**Warum zwei Container?** vLLM benötigt die GPU-Laufzeit und die Modellgewichte; der Agent
enthält die BorgVR-spezifische Gesprächs- und Werkzeugsteuerung auf Basis von Pydantic AI.
Die Trennung hält diese Abhängigkeiten auseinander und erlaubt getrennte Updates oder
einen Modellwechsel ohne Änderung des BorgVR-Verbindungsprotokolls. Nur der Agent ist vom
Client-Netz erreichbar; vLLM bleibt im privaten Container-Netz.

Bei einer Anfrage läuft die Kommunikation so ab:

1. BorgVR wandelt Sprache in Text um oder übernimmt eine getippte Anfrage und sendet sie
   über eine verschlüsselte WebSocket-Verbindung an den Agenten.
2. Der Agent fragt das Modell über vLLM ab. Das Modell kann eine Antwort formulieren oder
   ein Werkzeug anfordern, etwa den aktuellen Darstellungszustand oder eine Rotation.
3. Der Agent prüft den Aufruf und leitet ihn an BorgVR weiter. Die App prüft ihn ebenfalls,
   führt ihn über ihre gemeinsame Befehlsschicht aus und sendet das Ergebnis zurück.
4. Der Agent kann weitere Schritte ausführen oder die abschließende Antwort senden.
   Auf Wunsch liest BorgVR die Antwort lokal vor.

Mit gesonderter Erlaubnis kann die App dem Modell Renderbilder zur Verfügung stellen.
Der Agent erhält keine vollständigen Volumendateien und keinen Zugriff auf Kamera oder
Passthrough. Er ist nicht der BorgVR-Datensatzserver und stellt keine Datensatzkataloge bereit.
Anatomische Zuordnungen müssen vom Benutzer geprüft werden; die Sprachsteuerung ist
keine medizinische Diagnosefunktion.

Die folgenden Schritte richten zuerst den Server ein und prüfen ihn. Erst danach wird
die App mit dem erzeugten Zertifikat und Zugangsschlüssel verbunden.

## 1. Voraussetzungen

- Linux x86_64 oder Windows 11 x86_64 mit WSL 2 gemäß der separaten Anleitung.
  Unter nativem Linux unterstützt das Host-Skript **Ubuntu 22.04, 24.04 und 26.04 LTS**.
  Auf anderen Distributionen muss der Administrator Docker, Compose und die passende
  GPU-Laufzeit bereitstellen.
- Eine von vLLM und dem gewählten Modell unterstützte **NVIDIA/CUDA- oder AMD/ROCm-GPU**
  mit passendem, bereits installiertem Treiber.
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

**Kompatibilität prüfen:** Automatisierte Konfigurations- und Protokolltests garantieren
nicht, dass jedes Modell auf jeder GPU funktioniert. `doctor` und `test` auf dem jeweiligen
GPU-Rechner ausführen. AMD/ROCm ist noch nicht auf echter Hardware validiert.

## 2. Dateien auf den Server bringen

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

## 3. Host einrichten und Container starten

Der Server besteht aus **zwei laufenden Containern**: vLLM und unserem Agenten.
`compose.yaml` lädt nur fertige Images und enthält keinen Build-Schritt. Nur der
Image-Ersteller beziehungsweise Entwickler verwendet zusätzlich `compose.build.yaml`.
`setup.sh` ergänzt automatisch `compose.cuda.yaml` oder `compose.rocm.yaml`.
Für Start/Update die Skriptbefehle verwenden, nicht `docker compose up` ohne Backend-Overlay.
Ein privilegierter Installationscontainer mit Zugriff auf den Docker-Socket ist nicht nötig.

Alle folgenden Schritte führt dasselbe Konto mit sudo-Rechten aus. Wer bereits als root
angemeldet ist, lässt `sudo` weg. Eine Docker-Gruppenmitgliedschaft ist nicht nötig.

### A. Voraussetzungen prüfen

Bei bereits installiertem Docker zunächst prüfen:

```
sudo docker compose version
sudo docker ps
sudo docker info
```

Diese Prüfungen gelten für beide Backends: Compose v2 muss verfügbar sein und der lokale
Docker-Dienst muss laufen. Danach den GPU-Zugriff für das gewünschte Backend prüfen.

**NVIDIA / CUDA:** Treiber und registrierte GPU-Laufzeit von Docker prüfen:

```
nvidia-smi
sudo docker info --format '{{json .Runtimes}}'
```

`nvidia-smi` muss die GPU anzeigen; die Docker-Laufzeiten müssen `nvidia` enthalten.

**AMD / ROCm:** Prüfen, ob der Treiber die benötigten Gerätedateien bereitstellt:

```
ls -l /dev/kfd
ls -l /dev/dri
```

`/dev/kfd` muss ein Zeichengerät sein; `/dev/dri` muss die GPU-Gerätedateien enthalten.
Für dieses Backend sind weder NVIDIA-Laufzeit noch NVIDIA Container Toolkit erforderlich.
Die Gerätedateien allein belegen noch keine Modellkompatibilität; die Installation prüft
die GPU-Speicherallokation im gewählten Image.

Wenn Docker und die Voraussetzungen des gewählten Backends bereit sind, mit B fortfahren.
Andere Container bleiben bestehen. vLLM reserviert standardmäßig 85 % des Speichers der
ausgewählten GPU; konkurrierende GPU-Anwendungen können dadurch beeinträchtigt werden.

Nur bei fehlenden Voraussetzungen eine geprüfte Kopie des Host-Skripts für das jeweilige
Backend ausführen. Für NVIDIA:

```
sudo ./setup-host.sh --backend cuda
```

Für AMD:

```
sudo ./setup-host.sh --backend rocm
```

Beide Varianten richten Docker und Compose aus offiziellen signierten Paketquellen ein.
Nur die CUDA-Variante installiert zusätzlich NVIDIA Container Toolkit und konfiguriert
dessen Laufzeit. Die ROCm-Variante verwendet den vorhandenen AMD-Treiber und startet Docker
nicht neu. GPU-Treiber werden nicht installiert oder ersetzt. Konfligierende Docker-Pakete
werden nicht entfernt; bei vorhandenem Docker ein fehlendes Compose-Plugin aus dessen
bisheriger Paketquelle installieren.

Falls das Skript einen notwendigen Docker-Neustart meldet, erst ein Wartungsfenster
für die anderen Container vereinbaren. Dann `sudo ./setup-host.sh --allow-docker-restart`
ausführen. `--allow-docker-restart` erlaubt ausdrücklich einen bei der NVIDIA-Einrichtung notwendigen
Docker-Neustart. Andere Container können dabei unterbrochen werden. Ohne diese Erlaubnis
wird eine notwendige Laufzeitänderung abgelehnt; eine bereits registrierte Laufzeit bleibt
unverändert. Das Root-Skript erzeugt keine App-Konfiguration, Zugangsschlüssel,
Zertifikate oder Modelldownloads und liest keine `.env` aus dem Benutzerverzeichnis.
Es vergibt standardmäßig auch keine Docker-Rechte an Benutzer.

### B. Installieren und starten

Im Verzeichnis `BorgVRAgentServer` bei der ersten lokalen Installation das Backend wählen.
Für NVIDIA:

```
sudo ./setup.sh install --backend cuda
```

Für AMD:

```
sudo ./setup.sh install --backend rocm
```

`setup-host.sh` speichert die Backend-Auswahl nicht für `setup.sh`; sie muss bei der
Erstellung des Deployments ausdrücklich angegeben werden. Weitere Befehle übernehmen
das in `.env` gespeicherte Backend.

Dieser eine Befehl erzeugt `.env`, Zugangsschlüssel und Testzertifikat, prüft die profilabhängige
Platzreserve und die GPU, lädt fehlende Images und startet beide Dienste. Das fertige
[Agenten-Image 3.9.4](https://github.com/JensDerKrueger/BorgVR/pkgs/container/borgvr-agent)
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
Abhöradresse. Bei einer ersten Installation auf AMD zusätzlich `--backend rocm` angeben.
Ohne Angabe von Host und Abhöradresse bleibt es bei localhost/`127.0.0.1`. `0.0.0.0` gibt alle
IPv4-Schnittstellen frei und braucht bewusste Netzabsicherung. Port ist **8766** (`--port`),
GPU **0** (`--gpu INDEX` oder NVIDIA-GPU-UUID). CUDA erlaubt zusätzlich `--gpu all`;
damit werden ausdrücklich alle NVIDIA-GPUs zugänglich, wie für WSL erforderlich.

### Modelle und Grafikkarten wählen

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
sudo ./setup.sh update --agent-image ghcr.io/jensderkrueger/borgvr-agent:3.9.4
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
sudo ./setup.sh install --host ai.example.org --bind 0.0.0.0 --port 8766
```

Statt `ai.example.org` ist auch eine feste IP möglich. Passt das vorhandene Zertifikat nicht zum
angegebenen Host, wird es erneuert und privat unter `runtime/tls-before-install-*` gesichert.
Clients müssen danach dem neuen Zertifikat vertrauen; ihre Zugangsschlüssel bleiben gleich.
Ein passendes Zertifikat wird nicht ersetzt. Änderungen an `.env` erhalten eine private
Sicherung unter `runtime/env-before-update-*`. Ungültige Optionen werden vor `down` abgelehnt.
`init` überschreibt keine vorhandene Konfiguration.
Ein nach einem Fehler vorhandenes `runtime` ohne `.env` muss
manuell geprüft werden, damit keine Schlüssel versehentlich verloren gehen.

### Modell mit einem Befehl wechseln

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
nicht automatisch einen Hardwaredefekt. Ein geöffneter Datensatz oder eine verbundene
native App ist für diesen Test nicht erforderlich.

Ein Test von einem anderen Rechner ist ebenfalls möglich; siehe den englischen Leitfaden.
Der Testclient prüft Zertifikat und Hostname, es gibt keinen unsicheren TLS-Schalter.

Eine eigene Frage stellen:

```
sudo docker compose exec -T agent python client.py --url https://127.0.0.1:8766 \
  --ca /run/tls/server.crt --token-file /run/secrets/agent_token \
  --text "Was ist ein Mandelbulb? Antworte kurz auf Deutsch."
```

## 5. Native App verbinden

Voraussetzung ist ein erfolgreich geprüfter Server, der vom Gerät aus erreichbar ist.
Die Installation hat das öffentliche Zertifikat `runtime/tls/server.crt` und den
Zugangsschlüssel `runtime/secrets/agent_token` erzeugt. Bei Verwendung einer eigenen CA
stattdessen deren Vertrauenskette wie im folgenden Abschnitt beschrieben einrichten.

1. In BorgVR unter **Einstellungen > KI-Assistent** den Assistenten aktivieren.
2. Die HTTPS-Adresse des Servers eintragen, zum Beispiel `https://ai.example.org:8766`,
   oder die zum Zertifikat passende IP-Adresse. `localhost` verweist auf das jeweilige
   App-Gerät und ist für den Zugriff auf einen anderen Rechner nicht geeignet.
3. Das öffentliche Zertifikat importieren und die Datei `runtime/secrets/agent_token`
   importieren oder deren Inhalt als Zugangsschlüssel eingeben.
4. Den Servertest in den Einstellungen ausführen. Dafür muss kein Datensatz geöffnet sein.
5. Einen Datensatz öffnen und **KI-Assistent** in den Render-Bedienelementen wählen.
   Eine Textanfrage eingeben oder über das Mikrofon sprechen.

**Niemals `server.key` oder `vllm_token` auf die Geräte kopieren.** Der Zugangsschlüssel
landet im Geräte-Schlüsselbund. Nur auf vertrauenswürdige Geräte übertragen und
Transferkopien nach dem Import entfernen.

Antworten und Zwischenmeldungen erscheinen im Gespräch und werden auf Wunsch lokal
vorgelesen. Renderbilder können separat erlaubt werden. Kamera und Passthrough werden
nicht übertragen. Spracherkennung erfolgt standardmäßig auf dem Gerät; eine mögliche
Verarbeitung durch Apple muss separat erlaubt werden. Abbrechen beendet die Verbindung,
macht bereits ausgeführte Änderungen aber nicht rückgängig. Agenteneinstellungen und
Schlüssel bleiben gerätelokal, außerhalb von SharePlay und GSC.

## 6. Sicherheit und Zertifikate

- `.env` enthält Image-/Modellrevision, GPU, Speicherbudget, Adresse, Port und Benutzer-IDs.
- `runtime/secrets/agent_token` ist der Zugangsschlüssel für Clients, wie ein Passwort
  behandeln. Er gilt für **die gesamte Installation**, nicht separat pro Gerät.
- `runtime/secrets/vllm_token` ist nur für die interne Modellkommunikation, Modus 0640.
- `runtime/tls/server.crt` ist das öffentliche Zertifikat.
- `runtime/tls/server.key` ist der private Schlüssel und gehört niemals auf einen Client.
- Diese Rechte nicht durch weltweite Lesbarkeit umgehen.

Bei Einrichtung mit `sudo` gehört `runtime` dem aufrufenden Benutzer, mit Modus 0700.
Er kann die Dateien darin ohne sudo lesen und verwalten.
Die Unterverzeichnisse `secrets` und `tls` haben Modus 0750, ihre Container-Dateien
0640 und die Gruppe `BORGVR_GID`. Damit bleibt der Agent über seine Gruppe leseberechtigt
und läuft mit der konfigurierten unprivilegierten UID/GID (Standard bei Einrichtung mit
sudo: 10001). vLLM erhält diese zusätzliche Gruppe ausschließlich für den internen Token.
Andere Benutzer bekommen keinen Zugriff; Sicherungsverzeichnisse bleiben 0700,
Sicherungsdateien 0600. Die neu erzeugte `.env` bleibt root-eigen und 0600.

`install`, `init`, `start`, `restart` und `update` richten diese Runtime-Rechte automatisch
ein, ohne Schlüssel, Container-IDs oder Modelle auszutauschen. Ein bereits eingerichteter
Runtime-Besitzer bleibt auch bei späteren Aufrufen durch root oder andere Administratoren
erhalten. Bei einer direkten root-Ersteinrichtung ohne sudo-Benutzer bleiben die Dateien
nur für root beziehungsweise den Container-Benutzer zugänglich.

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
sind nicht automatisiert. TLS-Prüfungen niemals abschalten.

Der Dienst sollte im privaten Netz oder VPN bleiben. Ohne ausdrücklichen Schalter ändert
das Skript keine Firewall-Regeln.

### Optionale Firewall-Freigabe

`install`, `start`, `restart`, `update`, `status` und `doctor` prüfen, ob UFW oder
firewalld aktiv ist. Die Prüfung beweist nicht, dass der Server von einem anderen
Gerät erreichbar ist. Für eine bereits eingerichtete Installation kann die Freigabe
ausdrücklich angefordert werden, ohne das laufende Modell neu zu laden:

```
sudo ./setup.sh start --open-firewall
```

Oder direkt bei der Installation, zum Beispiel für einen Rechner mit dieser eigenen IP:

```
sudo ./setup.sh install --host 192.168.1.20 --bind 192.168.1.20 --open-firewall
```

Der Schalter erlaubt IPv4-TCP zum **konfigurierten Port** (standardmäßig 8766) an
der eingestellten Abhöradresse, aus beliebigen IPv4-Quellen. Er installiert oder aktiviert
keine Firewall, ändert keine Standardrichtlinien, SSH-Regeln oder Docker-Ketten und führt
keinen globalen Reload aus. Bei firewalld werden gezielt Laufzeit- und permanente Regeln
in dessen Standardzone angelegt. Bei Bedarf die passende Zone ausdrücklich wählen:

```
sudo ./setup.sh start --open-firewall --firewall-zone internal
```

Die Zone muss zum Interface beziehungsweise Quellnetz der Clients passen. Bei mehreren
aktiven oder nicht zuverlässig lesbaren Firewall-Managern wird keine automatische Änderung
versucht. Eigene nftables-/iptables-Konfigurationen werden nicht verändert. Ist keine
unterstützte Firewall aktiv, wird nur ein Hinweis ausgegeben. Ein nur an localhost
gebundener Server wird dadurch nicht netzwerkfähig; zuerst dessen `--bind` ändern.

**Docker-Besonderheit:** Veröffentlichte Container-Ports können UFW und firewalld-Regeln
für Host-Eingangsverkehr umgehen. Die Freigabe ist daher **keine Einschränkung auf
vertrauenswürdige Clients**. Eine solche Absicherung gehört in eine Docker-taugliche
Forwarding-Policy oder vorgeschaltete Firewall/VPN. Bei firewalld mit `StrictForwardPorts`
oder eigenen Forwarding-Regeln kann eine zusätzliche administrative Freigabe nötig sein.
Router-, Provider- und Organisations-Firewalls können weiterhin blockieren; das Setup kann
diese weder prüfen noch freischalten. Siehe die
[Docker-Hinweise zu Firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

Nur neu angelegte BorgVR-Regeln werden in `runtime/firewall-rules.json` vermerkt und bei
der bestätigten Deinstallation entfernt. Vorhandene Regeln werden weder übernommen noch
gelöscht. Die Freigabe bleibt nach einem Neustart bestehen; der Schalter muss nicht bei
jedem Start erneut angegeben werden. Bei einem Portwechsel bleiben vorherige Freigaben
bis zur Deinstallation erhalten. Ein späteres Weglassen von `--open-firewall` schließt
keine bereits freigegebenen Ports.
**Docker-Portfreigaben können UFW-Regeln umgehen**; Netzfreigaben daher zusätzlich am
Netzrand beziehungsweise mit Docker-tauglichen Regeln absichern. vLLM-Port 8000 bleibt
ungeöffnet. Zugangsschlüssel werden im Authorization-Header übertragen, nicht in URLs.

Der Agent speichert keine Gespräche, Bilder oder Werkzeugdaten auf Platte und protokolliert
deren Inhalte nicht. vLLM-Request-Logging und Nutzungs-Telemetrie sind abgeschaltet.
Gespräche liegen während der Verbindung im RAM; nach Trennung werden sie verworfen.
Es gibt keinen Cloud-Fallback. Externe Verbindungen entstehen für Paket-/Modelldownloads,
nicht für die eigentliche Inferenz.

## 7. Betrieb und Updates

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

### Nach einem Rechner-Neustart

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

## 8. Entwicklung und Tests

### Schnelle Entwicklung per SSH

Der optionale Entwicklungsmodus aktualisiert nur den Agenten-Prozess, ohne Image-Build,
Veröffentlichung oder Neustart von vLLM. Ein eigenes eingeschränktes SSH-Konto ohne
Docker-/sudo-Rechte erlaubt begrenzte Code-Uploads, Logs und kontrollierte Neustarts.
Die [Einrichtung, Hostschlüsselprüfung und vollständige Entfernung](DEVELOPMENT.de.md)
sind separat beschrieben. Der normale Betrieb verwendet weiterhin ein festes Image;
geänderte Bibliotheksabhängigkeiten benötigen ein neues passendes Image.

### Automatische Kontextpflege

Vor jeder Modellanfrage zählt der Agent die tatsächlichen Eingabetokens über vLLMs
authentifizierten Endpunkt `/tokenize`, einschließlich Werkzeugbeschreibungen und Bildern.
Es gilt das kleinere Limit aus dem vom Modell gemeldeten Kontext und `--context-length`.
Antwortlänge und Sicherheitsreserve werden vorher abgezogen. Ab 85 % dieses Eingabebudgets
werden ältere abgeschlossene Gesprächsteile zu begrenzten Auszügen verdichtet, veraltete
Bilder entfernt und große oder überholte Werkzeugergebnisse bei Bedarf durch gekennzeichnete
Vorschauen oder Ausführungsbelege ersetzt. Dafür läuft kein zweites Modell. Der aktuelle
Auftrag, Werkzeugargumente und zusammengehörige Aufrufe und Antworten bleiben erhalten;
Anwendungszustand und tatsächliche TF-Auflösung ändern sich nicht. Ältere Details können
verloren gehen; der Agent muss den aktuellen Zustand erneut abfragen.

Passt selbst der aktive Auftrag nicht mehr, wird sicher angehalten. Eine wegen Kontextüberlauf
abgelehnte Modellanfrage darf nach weiterer Verdichtung einmal wiederholt werden, bereits
ausgeführte Werkzeuge dagegen nicht. Die aktualisierte native App unterscheidet zwischen
Kontextüberlauf ohne Änderung, bestätigten Änderungen mit fehlgeschlagener Abschlussprüfung
und unklarem Befehlsabschluss. Das Container-Update aktiviert die Kontextpflege; für die neuen
Fehlermeldungen muss auch die native App aktualisiert bzw. neu gebaut werden. Ein größerer
Kontext hilft weiterhin bei umfangreichen Einzelaufträgen, ersetzt diese Pflege aber nicht.
Die bestehende Grenze von 64 Anfragen pro Sitzung bleibt bestehen; ein neues Gespräch beginnt
mit einer frischen Zustandsabfrage.

Die Entwicklertests laufen ohne GPU mit einem deterministischen Testmodell durch die echte
Pydantic-AI-Schleife. Getestet werden unter anderem Anmeldung, Eingabevalidierung,
Werkzeugbeschränkungen, Bilder, Abbruch, Zeitlimits, veraltete Antworten, Kontextpflege ohne
doppelte Werkzeugausführung und Fehler nach bestätigten Änderungen. Den Test auf
dem jeweiligen GPU-Rechner und den Test mit dem Mikrofon auf dem jeweiligen Gerät ersetzen sie nicht.

`Scripts/test-voice-agent.sh` prüft zusätzlich den nativen macOS-Client über echtes lokales
TLS/WSS mit deterministischem Modell: Zustandsabfrage, Rotation, Transferfunktion, Renderbild,
Fortschrittsantwort, GSC-Roundtrip, Abbruch bei Kontextwechsel und Fehler nach bereits
ausgeführten Änderungen. Das Protokoll ist in
[PROTOCOL.md](PROTOCOL.md) beschrieben.

### Fehlersuche bei Werkzeugaufrufen

Bei fehlgeschlagenen Werkzeugaufrufen lässt sich der Modellpfad im laufenden Container
ohne echte Datensätze prüfen. Im Deployment-Verzeichnis ausführen:

```
sudo docker compose exec -T agent python - --catalog-json "$(cat diagnostic_catalog.json)" < diagnose_tools.py
```

Der Test vergleicht einen minimalen Zustandsaufruf mit dem Werkzeugkatalog der nativen App.
Nur `get_application_state` liefert einen synthetischen Zustand; andere Werkzeuge werden
abgewiesen. Die Ausgabe enthält Testargumente (höchstens 4096 Zeichen pro Aufruf) und
Fehlerkategorien, keine Zugangsschlüssel oder echten Datensatzinhalte. Ein Exitcode ungleich
null bedeutet, dass mindestens ein Test fehlgeschlagen ist.

Eigene vLLM-Images und Tool-Parser müssen strikte Aufrufe für parameterlose Werkzeuge
und `set_transfer_function` unterstützen. Beim TF-Setter muss das Modell den Kanal
ausdrücklich angeben und pro Eintrag genau vier ganzzahlige Bytes `[R,G,B,A]` liefern,
keine vorangestellte Position. Die Positionen sind gleichmäßig verteilt; kurze Rampen
werden auf die native Tabellenauflösung interpoliert. Ungültige TF-Argumente erhalten
eine konkrete Korrekturanweisung, werden aber nicht automatisch umgedeutet. Die native
und die MCP-Schnittstelle behalten ihren optionalen Kanal-Standardwert.
Server und native App prüfen Argumente zusätzlich gegen das jeweilige Schema;
ungültige Aufrufe werden nicht ausgeführt.

Für Probleme speziell beim Erzeugen einer Transferfunktion gibt es einen weiteren,
ebenfalls vollständig synthetischen Test:

```
sudo docker compose exec -T agent python - --scenario transfer-function --catalog-json "$(cat diagnostic_catalog.json)" < diagnose_tools.py
```

Er vergleicht die normale TF-Schnittstelle mit einer auf höchstens 16 gleichmäßig verteilte
RGBA-Einträge begrenzten Rampe. Ausgegeben werden außerdem Laufzeiten, Anzahl übernommener
TF-Einträge und die Fehlerkette. Nur der Test speichert diese TF im Arbeitsspeicher; kein
App-Client wird verbunden und kein echter Datensatz verändert. Jeder Durchlauf hat eine
Frist von 90 Sekunden. Das Skript wird vom Checkout eingelesen; dafür ist kein neues
Agenten-Image nötig.

## 9. Agenten-Image für die Entwicklung bauen

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

## 10. Builds und Veröffentlichung über GitHub

**Veröffentlicht: 3.9.4 für linux/amd64**, aus Commit
`7c41e45f020e1662c540b53337b5df5e522ec1bc`.
[Build, Tests und Veröffentlichung](https://github.com/JensDerKrueger/BorgVR/actions/runs/44325296665)
sind erfolgreich; der anonyme Registry-Zugriff wurde geprüft. Unveränderliche Image-Adresse:

```text
ghcr.io/jensderkrueger/borgvr-agent@sha256:9f94e52954aae5f0d3d4bd9645790f2c40b9be0d2e75643e8a0736559e82682f
```

Bestehende Installationen mit `git pull` und anschließend
`sudo ./setup.sh update --agent-image ghcr.io/jensderkrueger/borgvr-agent:3.9.4` aktualisieren.
`git pull` allein ersetzt den laufenden Container nicht; `update` ohne `--agent-image`
behält das bisher konfigurierte Image bei. Modell, Zugangsschlüssel und Zertifikate bleiben
erhalten.

Der Workflow [BorgVR Agent Container](https://github.com/JensDerKrueger/BorgVR/actions/workflows/borgvr-agent.yml)
baut und testet nach relevanten Änderungen auf `main` sowie bei Pull Requests automatisch
ein Image für **linux/amd64**. Zusätzlich zu den Tests startet er den echten Container mit
TLS, Authentifizierung und schreibgeschütztem Dateisystem. Der CPU-Runner testet dabei
bewusst keine GPU-Inferenz; diese Prüfung bleibt auf dem jeweiligen GPU-Rechner erforderlich.

Pushes und Pull Requests erzeugen nur Build-Artefakte, kein Registry-Image. Die
Veröffentlichung erfolgt ausschließlich nach manuellem Start und erfolgreichen Tests.
Ein veröffentlichtes Image wird nicht automatisch auf Servern installiert.

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
den Branch **main** wählen, **publish** aktivieren und eine bisher unbenutzte Versionsnummer
eintragen. Nach erneut erfolgreichen Tests wird exakt das geprüfte Image ohne weiteren
Build veröffentlicht:

```text
ghcr.io/jensderkrueger/borgvr-agent:VERSION
ghcr.io/jensderkrueger/borgvr-agent:sha-VOLLSTÄNDIGER_QUELLCODE_COMMIT
```

`VERSION` durch die im Workflow angegebene Versionsnummer ersetzen.

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

## 11. Deinstallation und erneuter Test

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
Außerdem entfernt das Skript die von ihm protokollierten Firewall-Freigaben, auch bei
`--files-only`. Scheitert deren Entfernung, bleibt die lokale Konfiguration für einen
erneuten Versuch erhalten; vorbestehende Freigaben bleiben unberührt.

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
