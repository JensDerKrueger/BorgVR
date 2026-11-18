# Agenten-Entwicklung per SSH

Dieser optionale Modus ist für einen eigenen Entwicklungsserver gedacht. Python-Code des
Agenten lässt sich direkt übertragen und testen, ohne Git-Pull auf dem Server, Image-Build
oder Registry-Download für jede Änderung. vLLM und das geladene Modell laufen weiter.
Die normale HTTPS/WSS-Verbindung der BorgVR-App, Schlüssel und Zertifikate bleiben unverändert.

## Was der Zugang erlaubt

Das Setup erzeugt das eigene Systemkonto `borgvr-agent-dev`, ohne Passwort und ohne
zusätzliche Gruppen, sudo- oder Docker-Berechtigungen. Sein einziger eingerichteter
SSH-Schlüssel ist durch `restrict` und einen administratorgeschützten erzwungenen Befehl
begrenzt. Er akzeptiert nur `deploy`, `status`, `logs` und `restart`. Shell, SFTP/SCP,
Terminal, Port-, X11- und SSH-Agent-Weiterleitung sind über diesen Schlüssel nicht möglich.
Es werden keine Docker-Sockets oder zusätzlichen Netzwerkports im Container freigegeben.

**Der Zugang darf dennoch beliebigen Agenten-Code im Agenten-Container ausführen.**
Dieser Code kann auf dessen Zugangsschlüssel, TLS-Dateien und die von BorgVR übermittelten
Texte, Zustände und Bilder zugreifen. Den Schlüssel nur vertrauenswürdigen Entwicklern geben,
keine vertraulichen Datensätze während fremder Entwicklung öffnen und den Zugang anschließend
wieder entfernen. Es handelt sich nicht um eine Sandbox für fremden, nicht vertrauenswürdigen Code.

## Voraussetzungen auf ai1

Ein normal installierter, laufender BorgVR-Server und das vollständige BorgVR-Quellverzeichnis
werden vorausgesetzt. Ein reines Produktions-Deployment-Archiv enthält nicht den bearbeitbaren
Agenten-Code; dafür zusätzlich den passenden Quellcode aus GitHub auschecken oder entpacken.
Einmalig aktualisieren, um die Entwicklungswerkzeuge zu erhalten:

```sh
cd ~/BorgVR/BorgVRAgentServer
git pull
```

Falls du dich bereits per SSH auf ai1 anmeldest, ist kein weiterer SSH-Server nötig.
Andernfalls auf Ubuntu als Administrator installieren und starten:

```sh
sudo apt update
sudo apt install openssh-server
sudo systemctl enable --now ssh
```

Der vorhandene SSH-Port muss vom Entwicklungsrechner erreichbar sein. Das BorgVR-Setup
ändert dafür weder SSH-Konfiguration noch Firewall automatisch. Die reguläre Ubuntu-Konfiguration
mit PAM unterstützt Schlüsselanmeldung für das passwortgesperrte Konto. Bestehende Regeln wie
`AllowUsers`, `DenyUsers` oder abweichende Authentifizierungsrichtlinien muss der Administrator
gezielt prüfen; keine globalen Schutzmaßnahmen dafür abschalten.

## Einen eigenen Schlüssel auf dem Entwicklungsrechner anlegen

Auf dem Mac oder Linux-Rechner, auf dem der Code bearbeitet wird, **nicht auf ai1**:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/borgvr-ai1-dev -C BorgVR-agent-development
```

Bestehende Dateien nicht überschreiben. Eine Passphrase ist möglich; den Schlüssel dann für
automatische Übertragungen vorher mit `ssh-add ~/.ssh/borgvr-ai1-dev` entsperren. Ein Schlüssel
ohne Passphrase muss besonders sorgfältig geschützt werden und nur für diesen begrenzten
Entwicklungszugang verwendet werden. Die private Datei bleibt auf dem Entwicklungsrechner.

Vor der ersten SSH/SCP-Verbindung zu einer noch unbekannten Serveradresse auf ai1 den
Hostschlüssel-Fingerabdruck anzeigen und mit dem Verbindungsdialog auf dem Mac vergleichen:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Nur die öffentliche Datei übertragen. In diesem Beispiel heißen Administratorkonto und
Serveradresse `krueger` und `134.91.11.251`; beides bei anderen Installationen ersetzen:

```sh
scp ~/.ssh/borgvr-ai1-dev.pub krueger@134.91.11.251:borgvr-ai1-dev.pub
```

Diese einmalige SCP-Übertragung benutzt den vorhandenen Administratorzugang, nicht das neue
eingeschränkte Konto. Niemals die Datei ohne `.pub` auf den Server kopieren.

## Entwicklungsmodus auf ai1 einschalten

Auf ai1 im BorgVRAgentServer-Verzeichnis:

```sh
sudo ./setup.sh dev enable --ssh-key-file ~/borgvr-ai1-dev.pub
```

Das Setup prüft den öffentlichen Schlüssel und die Abhängigkeiten des installierten Images,
richtet das dedizierte Konto ein und startet **nur den Agenten-Container** neu. Ein fremdes,
bereits vorhandenes Konto oder eine gleichnamige Gruppe wird nicht übernommen. Erst nach
erfolgreichem Start wird der eingeschränkte SSH-Schlüssel freigeschaltet. vLLM wird weder
gestoppt noch neu erzeugt; ein neues Image wird nicht gebaut oder heruntergeladen.
Die zusätzlich ins Administrator-Home kopierte Datei `~/borgvr-ai1-dev.pub` kann danach
entfernt werden; die eingerichtete öffentliche Schlüsseldatei wird vom Setup verwaltet.

Dateien liegen unter `/var/lib/borgvr-agent-dev`; der root-geschützte Helfer liegt unter
`/usr/local/libexec/borgvr-agent-development.py`. Der Container liest vollständige Code-Snapshots
schreibgeschützt und schreibt nur in sein Entwicklungs-Steuerverzeichnis. Ein kleiner
Wächter beendet den alten Agenten-Prozess und startet danach den neuen Snapshot. Laufende
KI-Gespräche werden dabei abgebrochen; Befehle werden nicht automatisch wiederholt.

Die bestehenden Befehle `start`, `stop`, `restart`, `status`, `logs` und `test` berücksichtigen
den aktiven Modus. Das normale `restart` startet weiterhin beide Dienste neu; für schnelle
Agenten-Neustarts stattdessen den unten beschriebenen Entwicklungsbefehl verwenden.
Vor `install`, `configure`, `model` oder `update` zuerst den Entwicklungsmodus deaktivieren.

## Serveridentität prüfen und Verbindung testen

Bei einer erstmaligen SSH-Verbindung den Hostschlüssel nicht blind bestätigen. Auf ai1:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Auf dem Entwicklungsrechner die erste Verbindung bewusst herstellen und den angezeigten
Fingerabdruck mit dem auf ai1 vergleichen:

```sh
ssh -T -i ~/.ssh/borgvr-ai1-dev borgvr-agent-dev@134.91.11.251 status
```

Erwartet wird JSON mit `phase: "ready"`, einer Release-ID und einer Quellcode-Prüfsumme.
Die späteren automatischen Befehle verlangen einen bereits bekannten Hostschlüssel und
verwenden keine Passwort- oder Bestätigungsdialoge. Ein nacktes `ssh user@host` wird absichtlich
abgewiesen, weil es eine Shell anfordern würde. Bei einem anderen SSH-Port `-p PORT` ergänzen.

## Änderungen direkt übertragen und prüfen

Im lokalen `BorgVRAgentServer`-Verzeichnis, **ohne sudo**:

```sh
./setup.sh dev push --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
./setup.sh dev status --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
./setup.sh dev logs --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
./setup.sh dev restart --host 134.91.11.251 --key ~/.ssh/borgvr-ai1-dev
```

Für einen anderen SSH-Port jeweils `--port PORT` ergänzen. Der erste Befehl überträgt nur
`borgvr_agent/**/*.py`, `client.py`, `model_config.py` und `requirements.txt`; keine `.env`,
Zertifikate, Schlüssel, Datensätze oder Git-Metadaten. Er wartet auf den bestätigten Start
des neuen Agenten. Es gibt Upload-, Größen-, Eintrags- und Zeitlimits. Links, Pfad-Traversierung,
Spezialdateien und geänderte Bibliotheksabhängigkeiten werden abgelehnt. Alte Snapshots und
Entwicklungslogs sind begrenzt. Die zugehörigen Texte und Code-Dateien bleiben auf dem Mac
verfügbar und können nach Abschluss normal getestet, committed und veröffentlicht werden.

Bei einem Fehler zuerst Status und Logs prüfen. Ein fehlgeschlagener Snapshot bleibt zur
Analyse erhalten; es gibt kein automatisches Zurückrollen oder Wiederholen von App-Befehlen.
Eine korrigierte oder bekannte gute lokale Version erneut mit `dev push` übertragen.
Die Bibliotheken kommen weiterhin aus dem installierten Image: Bei geänderten
`requirements.txt` ist ein neues passendes Image erforderlich. Änderungen am Setup,
SSH-Helfer oder Wächter benötigen eine neue Einrichtung, nicht nur einen Code-Push.

## Abschalten und vollständig entfernen

Auf ai1:

```sh
sudo ./setup.sh dev disable --remove
```

Dadurch wird der Schlüssel gesperrt, nur der Agent auf das reguläre konfigurierte Image
zurückgestellt und das Entwicklungskonto mit seiner Gruppe sowie den Entwicklungsdateien
entfernt. Modell, vLLM, App-Einstellungen, normale Zugangsschlüssel und Zertifikate bleiben
erhalten. Ohne `--remove` bleiben Konto und Dateien für die Analyse erhalten, aber der
SSH-Schlüssel wird ebenfalls entfernt. Eine neue Einrichtung setzt dann zuerst
`dev disable --remove` voraus. Aktive SSH-Aufträge gegebenenfalls erst beenden, wenn die
Kontolöschung meldet, dass das Konto noch verwendet wird.

Auch das normale `sudo ./setup.sh uninstall --yes` berücksichtigt diese Entwicklungsressourcen
und zeigt sie vorher in der Vorschau. `uninstall --files-only` verlangt bei vorhandenen
Entwicklungsressourcen zuerst deren Entfernung, damit kein laufender Container auf gelöschte
Snapshots zeigt. Der OpenSSH-Server und andere Konten werden nicht entfernt oder verändert.
Den dedizierten privaten Schlüssel auf dem Mac anschließend entfernen, sobald er nicht mehr
benötigt wird; vorhandene SSH-Konfiguration und andere Schlüssel nicht mitlöschen.
