# Appweiter Assistent und vollständiger Funktionszugang

## Ziel und aktueller Lieferumfang

Der Assistent soll nach bewusster Aktivierung bereits im Startmenü nutzbar sein und
über dieselben fachlichen Operationen wie der Benutzer verfügen. Dazu gehören Suche,
Öffnen, Import, Registrierung/Fusion, Editing, Annotationen, Messungen und Export.
Funktionsumfang und Erlaubnis für einen konkreten Auftrag sind getrennt.

Dieser erste Schritt liefert den [Funktionskatalog](CAPABILITIES.md), seine
[maschinenlesbare Grundlage](capabilities.json), den statischen Registerabgleich und
die folgende Ausbaureihenfolge. Er aktiviert keine neuen Werkzeuge und verändert weder
das laufende Protokoll noch den Server auf ai1. Die folgenden Schnittstellen und
Werkzeugnamen sind Entwürfe, keine schon verfügbaren Funktionen.

## Experimentelle Agentenlogik bleibt austauschbar

```text
Sprache / Gespräch / experimenteller Agent
                    |
       VoiceAgentApplicationBridge
                    |
         BorgVRVoiceAgentBridge
                    |
    gemeinsame App-Automatisierungsdienste
       /            |              \
Katalogservice  Command-Service   Import-/Export-Jobservice
       |            |              |
       +----- dieselben Dienste wie UI / MCP / GSC -----+
```

Der bestehende Bridge-Vertrag wird um App-Kontext, Fähigkeiten und Jobreferenzen
erweitert, nicht durch direkte Zugriffe auf ConverterView, AppModel oder Renderer
umgangen. Nur der BorgVR-Adapter kennt die konkreten Dienste. Der Agentenkern sieht
versionierte Datenverträge und freigegebene Operationen.

Der Konvertierungsjobservice gehört zur normalen App, nicht zum Agenten. Er verwendet
BorgVRVolumeConversionService, die vorhandene Registrierung und die bestehenden
Import-/Renderer-Sperren. Auch der UI-Assistent wird sein Client. Ein Agent darf keinen
zweiten Konvertierungspfad, keine eigene RAW-/DICOM-Verarbeitung und keinen Zugriff auf
die internen Wizard-Schritte erhalten. GSC-/MCP-Adapter verwenden denselben Dienst.

Beim Ausbau oder Entfernen des Agenten bleiben Datensätze, Rendering, Konvertierung,
Jobs, Commands und GSC funktionsfähig. Es werden keine Agententypen in diese Dienste
eingeführt. [Bisherige Grenzen](../AppSupport/Voice/ARCHITECTURE.md) gelten weiter.

## Befund des Funktionsabgleichs

- 59 native MCP-Werkzeuge sind definiert; maximal 15 davon sind im nativen Agenten
  auf beiden Seiten erlaubt. Plattform, RGB/RGBA und Bildfreigabe reduzieren sie weiter.
  Die weiteren vier Modellwerkzeuge dienen nur dem Agentenablauf, nicht der App-Steuerung.
- Marker, Messungen und Editing sind überwiegend bereits über Commands und MCP erreichbar.
  Hier fehlen vor allem vollständige Agentenverträge, Freigaben und End-to-End-Tests.
- Katalogabfrage und Öffnen/Schließen existieren über MCP. Die KI-Verbindung verlangt
  trotzdem einen renderbereiten Datensatz; Schließen beziehungsweise Kontextwechsel
  beendet heute die Verbindung und teilweise das Assistentenfenster.
- Die Katalogeinträge enthalten bereits verfügbare Metadaten und Provenance. Eine
  begrenzte Themen-/Filterabfrage mit belegten Treffern ist noch kein eigenes Werkzeug.
- Import, Bildsequenzen und Fusion besitzen gemeinsame Konvertierungsalgorithmen, aber
  noch keinen fachlichen, appweiten Command-/MCP-/Agenten-Jobvertrag. macOS-GSC unterstützt
  Datei-/Verzeichnisimport, jedoch nicht den vollständigen mehrstufigen Fusionsablauf.
- Annotationsdateien, Auswahl-/Editorzustände, viele Settings, Panel-/SharePlay-/Diagnose-
  und Gerätefunktionen haben ebenfalls Lücken. Generische Command-Payloads oder
  writeFiles zählen nicht als fachlich vollständiger Workflow.

Der Katalog listet jede Gruppe mit Quellen, konkreten Registereinträgen, Abfragen,
Plattformen, Auswirkungen, Lücken und vorhandenen Testquellen. Die automatische Prüfung
belegt die Abdeckung der benannten Register, nicht beliebiger neuer UI-Buttons oder
die Laufzeitkorrektheit eines Workflows. Bei neuer UI-Funktionalität ist ein fachlicher
Katalogeintrag weiterhin Teil der Implementierung.

## App, Auftrag, Datensatz und Job getrennt modellieren

Die App-Verbindung erhält eine eigene Sitzungsidentität unabhängig vom Renderer. Ein
Auftrag referenziert bei Bedarf einen Datensatzkontext und einen oder mehrere Jobs.
Ohne Datensatz ist dieser Kontext wirklich optional: keine erfundene Datensatz-ID,
kein versteckt geöffnetes Volumen und keine Renderer-Initialisierung nur für das Gespräch.

Ein Datensatzkontext enthält stabile Datensatz-ID, Öffnungs-ID, Editierstand und
Zustandsrevision. Bereits ausgeführte Call-IDs behalten ihre Belege auch bei einem
erlaubten Datensatzwechsel. Ein geplanter Übergang erhält eine korrelierte Übergangs-ID;
ein fremder Wechsel bleibt ein Grund zum Pausieren oder sicheren Abbruch. Ein alter
Werkzeugaufruf darf niemals auf den neuen Datensatz umgelenkt werden.

Der Nutzer kann die Verbindung nach aktivierter Einstellung schon beim Start herstellen.
Das startet weder Mikrofonaufnahme noch Hintergrundbeobachtung, Datensatzladen oder Import.
Schließen des Assistenten und Beenden eines Auftrags bleiben ausdrücklich möglich.
Datensatz schließen beendet nur den Dataset-Kontext; die App-Unterhaltung bleibt bestehen.
Auf visionOS ist zusätzlich der Immersive-Space-Lebenszyklus unabhängig davon zu behandeln.

Das Protokoll wird über ausgehandelte Fähigkeiten erweitert. Alte Clients behalten ihre
heutigen sicheren Grenzen; App-Funktionen werden nicht mit einem scheinbar kompatiblen
Hello ohne tatsächliche Unterstützung aktiviert. Bestehende Größen-/Zeit-/Eintragsgrenzen
bleiben wirksam. 59 MCP-Werkzeuge einfach in den heutigen 32-Tool-Hello zu kopieren ist
keine Lösung: begrenzte Fähigkeitsentdeckung und aufgabenbezogene Werkzeuggruppen planen.

## Drei exemplarische Abläufe

### Datensätze zu einem Thema finden

1. Im Startmenü eine Anfrage wie „Welche Datensätze zu Knochen haben wir?“ stellen.
2. Eine begrenzte Katalogsuche über freigegebene lokale und bekannte Remote-Quellen ausführen.
3. Treffer mit ID, Titel, ausgewählten Metadatenbelegen und Quellenstatus liefern.
   Nicht erreichbare Quellen und unvollständige Ergebnisse ausdrücklich kennzeichnen.
4. Erst auf Wunsch einen Treffer öffnen; Renderbilder nur nach Bildfreigabe untersuchen.

Erste neue Operationen: `search_datasets`, `get_dataset_info`, ergänzt um die vorhandenen
`list_datasets` und `open_dataset`. Keine willkürlichen URLs, Vollvolumendownloads oder
Patientendatenübertragung für eine reine Metadatensuche. „Keine Treffer in erreichbaren
Quellen“ ist nicht dieselbe Aussage wie „Es gibt keinen solchen Datensatz“.

### Daten importieren

1. Quelle aus dem Katalog wählen oder lokal eine Datei/ein Verzeichnis freigeben.
2. Die App liefert einen opaken Source-Handle mit begrenztem Geltungsbereich.
3. `prepare_import` prüft Quellformat, Zusatzdateien, Metadaten und Parameter. Der Benutzer
   ergänzt fehlende Größe oder Quelldateifreigaben; der Agent erfindet keine Werte.
4. Ein validierter Plan beschreibt Quelle, Ziel, Brickgröße, Kompression, Quantisierung,
   Provenance und gegebenenfalls Speicherbedarf. Nicht abschätzbare Werte bleiben unbekannt.
5. `start_import` startet nach Freigabe einen gemeinsamen App-Job. `get_job` und
   `cancel_job` liefern Phase, Fortschritt, Fehler, Cleanup- und Abschlussstatus.
6. Der fertige Job liefert eine Datensatz-ID; Öffnen ist ein eigener geplanter Übergang.

Handles werden auf dem App-Gerät aufgelöst. Ein Modellpfad gewährt keinen Sandbox-Zugriff.
Konvertierung und RAW-Zwischendaten bleiben auf dem App-Gerät, nicht auf dem KI-Server.

### Zwei Volumen fusionieren

`prepare_fusion` referenziert zwei separat freigegebene Quellen und ihre Rollen
Referenz/Moving. Unterstützte DICOM-/Datei-/Zarr-Inputs werden durch den bestehenden
BorgVRVolumeInput-Pfad aufbereitet. Bei .data-Quellen muss der Plan Original oder
gewählten Editierstand ausdrücklich festlegen; ein zufällig offener Zustand genügt nicht.
Der Agent klärt unbestimmte Auswahl oder Parameter mit einzelnen eindeutigen Fragen.

`start_fusion` verwendet denselben Jobservice und die vorhandene Registrierung, keine
neue LLM-Registrierung. Ergebnis: Datensatz-ID, verwendete Transformation, Provenance,
verfügbare Qualitätsinformationen und Warnungen. Ein abgeschlossener Job beweist keine
anatomisch korrekte Registrierung. Menschliche Kontrolle bleibt Teil der Abnahme.

## Werkzeugfreigaben nicht aus Namen ableiten

Die heutigen Heuristiken `set_`/`rotate_view` und die kleine Liste lesender Werkzeuge
reichen nach dem Ausbau nicht mehr aus. `edit_volume`, `open_dataset`, Exporte oder
`clear_objects` hätten sonst falsche Wirkungs-/Berechtigungsklassen.

Jede Fähigkeit erhält Kontext, Eingabe-/Ausgabeschema, Lese-/Schreibwirkung,
Datei-/Netz-/Shared-State-Wirkung, lokale Bestätigung, Voraussetzungen und Jobverhalten.
Die App prüft diese Regeln vor Ausführung unabhängig vom Modell. Ein vom Modell gesetztes
`confirm:true` ersetzt keine korrelierte lokale Nutzerbestätigung. Erlaubnisse gelten
für konkrete Aufträge und Ziele; sie müssen nicht pro Pinselprobe erneut abgefragt werden.

Die komplette MCP-Schemenmenge benötigt Kompatibilitätstests: etwa oneOf bei Pinselkanälen
wird vom heutigen kleinen nativen Agentenvalidator nicht vollständig unterstützt.
Lange Imports oder Exporte dürfen nicht in die bisherige 40-Sekunden-Tooldeadline gezwängt
werden. Kurzlebige Jobaufrufe und gezielter Abbruch ersetzen blockierende Langläufer.
Der Ausschluss von Import und Renderer bleibt auch ohne sichtbaren Wizard durchgesetzt.

## Reihenfolge und Abnahme

1. **Katalog und Tests:** alle heutigen Command-/MCP-/GSC-/UI-Registereinträge klassifizieren;
   neue Einträge ohne Zuordnung schlagen im Test fehl. Dieser Schritt ist hier umgesetzt.
2. **Appweite Sitzung:** Assistent auf allen Startbildschirmen, Verbindung und Gespräch ohne
   Datensatz, geplanter Öffnen-/Schließen-Übergang, keine automatische Mikrofonaufnahme.
   Abnahme mit deterministischem Modell und leerem Renderer, auch bei Serverausfall.
3. **Katalog und Quellen:** begrenzte Themenabfrage, Trefferbelege, Metadatenabfrage und
   lokale Source-/Destination-Freigaben. Abnahme mit leeren/mehrseitigen Katalogen,
   unerreichbaren Quellen, abgelaufenen Handles und fehlender RAW-Dateifreigabe.
4. **Gemeinsamer Jobservice:** Datei-/DICOM-/Sequenzimport und Fusion aus UI-Views herauslösen;
   UI, MCP/GSC und Agent verwenden dieselben Commands. Tests für Parametervalidierung,
   Konfliktsperren, Abbruch, Teildateien, App-/Fensterwechsel und fertige Ergebnis-IDs.
5. **Editing, Marker, Messungen:** vorhandene MCP-Funktionen mit korrekten Schemen und
   lokalen Berechtigungen freigeben. Gegen bekannte Geometrien, Editiermasken, physische
   Einheiten und Originaldatenerhalt testen; SharePlay-Wirkung und Standwechsel absichern.
6. **Übrige Funktionsgruppen:** Settings, Dokumente, Diagnose, Panels, SharePlay, Geräte und
   generische App-Navigation abarbeiten. Plattformabweichungen bleiben sichtbare Capabilities.
7. **Erfahrungslernen:** erst auf verlässlicher Ausführung Episoden/Gedächtnis/Fähigkeiten
   aufbauen. Zunächst synthetische Testdaten und freigegebene Fälle; kein Training aus
   unbewerteten Nutzeraktionen und kein stiller Upload fachlicher Daten.

Jeder Schritt braucht Source-/Command-/Tool-/Abfrage-/Ergebnis-Tests. Bestehende native
TLS/WSS-, GSC-Roundtrip-, MCP-, Import- und Registrierungstests bleiben erhalten.
Insbesondere keine Regression bei Nutzervorrang, stale-call-Schutz, Schließen des
Immersive Space, Import-/Renderer-Sperre oder nicht bestätigter Regelspeicherung.

## Katalog pflegen

Im Agenten-Entwicklungsumfeld mit Python 3.10 oder neuer:

```sh
python3 audit_capabilities.py
python3 audit_capabilities.py --write
python3 -m pytest -q tests/test_capability_inventory.py
```

Die Prüfung braucht weder GPU noch Docker, Netzwerk, laufende BorgVR-App oder ai1.
Die JSON-Datei ist ein Entwicklungsinventar und wird nicht als Laufzeit-Toolfreigabe geladen.
