# Optionaler KI-Assistent

Der Assistent ist ein optionales Subsystem. Renderer, Datensätze, Command-Ausführung und
GSC-Aufzeichnung dürfen weder den Agenten noch ein bestimmtes Modell voraussetzen.

Der [Funktionskatalog](../../BorgVRAgentServer/CAPABILITIES.md) und der
[Plan für den appweiten Assistenten](../../BorgVRAgentServer/CAPABILITY_PLAN.md) beschreiben
Iststand und nächste Ausbauschritte. Sie sind keine Laufzeitfreigabe. Insbesondere werden
Import/Fusion nicht direkt aus dem Agenten an UI-Views oder Konvertierungsobjekte gekoppelt.

## Schnittstellen

```text
UI / lokale Sprache
        |
VoiceAgentController -- WSS / Protokoll 1 -- BorgVR-Agent -- Modell-API -- vLLM
        |
VoiceAgentApplicationBridge
        |
BorgVRVoiceAgentBridge
        |
bestehender MCP-Werkzeugrouter / Command-Service / Command-Ereignisse
        |
BorgVR-Kern und Renderer
```

- **App-Vertrag:** `VoiceAgentApplicationBridge` bietet Kontextidentität, den freigegebenen
  Zustand, Werkzeugdefinitionen, Werkzeugausführung und semantische Änderungsereignisse.
  Er enthält keine MCP-, Renderer- oder Plattformmodelltypen.
- **Einziger Adapter:** `BorgVRVoiceAgentBridge` kennt den vorhandenen MCP-Router und die
  generischen Commands. Er kennzeichnet eigene Aufrufe mit einer privaten Herkunftskennung
  und übersetzt fremde Commands in sieben Änderungsdomänen. Rohbefehle, Dateipfade,
  Editierpuffer und Zugangsdaten werden nicht als Ereignisse übertragen.
- **Kern-Vertrag:** `BorgVRCommandExecuting.commandEvents` veröffentlicht unabhängig von
  einer GSC-Aufzeichnung Beginn, Abschluss und Fehlschlag von Aktionen. Der Kern kennt
  keine Agentenklasse. `originOverride` ist eine allgemeine Herkunftskennung für Adapter.
- **Netzvertrag:** `BorgVRAgentServer/PROTOCOL.md` beschreibt die begrenzten, validierten
  Nachrichten. Es gibt keinen direkten Serverzugriff auf App-Speicher oder Datensätze.

## Zuständigkeiten

`VoiceAgentController` verwaltet Verbindung, Auftragskontext, Abbruch, Freigaben und die
lokale Ausführungssicherung. `VoiceAgentPolicy` begrenzt Werkzeuge und Daten.
`VoiceAgentSpeech` und die SwiftUI-Views sind lokale Ein-/Ausgabe, nicht Teil der Planung.
`VoiceAgentSettings` hält Gerätekonfiguration und bestätigte Regeln. Der Python-Agent
besitzt Planung, Kontextpflege, Arbeitsbudget und Rückfragen; diese Logik liegt nicht im
Renderer. `create_app(settings, model)` erlaubt einen unabhängig injizierbaren Modelladapter.

## Appweite Sitzung

Die drei App-Wurzeln besitzen je einen Controller; Startmenü und Render-Bedienelemente
öffnen dieselbe Unterhaltung. Auf iOS liegt auch die Sheet-Präsentation an der App-Wurzel,
auf macOS und visionOS ist es ein eigenes Fenster. Öffnen verbindet nach bewusster
Aktivierung in den Einstellungen, startet aber weder Mikrofonaufnahme noch einen Auftrag.

Der Bridge-Kontext ist ohne Datensatz wirklich `nil`. Im ausgehandelten Protokollzusatz
`application_session` wird `dataset_id: null` übertragen. Ohne renderbereiten Datensatz
geben Client und Server `get_application_state`, `search_datasets` und `open_dataset` frei.
Schließen und Import-/Fusionsjobs sind noch nachfolgende Ausbauschritte, keine implizite Freigabe.

Bei einem Wechsel im Leerlauf werden Kontext-ID und Werkzeugkatalog neu abgeglichen.
Die Verbindung und der sichtbare Gesprächsverlauf bleiben erhalten. Der Server übernimmt
nur begrenzte Textauszüge als historische Daten; Bilder, Zustände und Werkzeugfolgen des
alten Datensatzes entfallen. Ein neuer Auftrag muss den aktuellen Zustand neu lesen.
Bei laufendem Auftrag, noch ausstehendem Werkzeug, manueller Bearbeitung oder erneutem
Wechsel während des Abgleichs wird stattdessen die Verbindung beendet. Fenster und
Gesprächsverlauf bleiben bestehen; nur eine neue Nutzereingabe startet neue Arbeit.
Alte Aufträge werden bei fremden Wechseln niemals automatisch fortgesetzt oder wiederholt. Ältere Server
werden mit einem verständlichen Aktualisierungshinweis abgewiesen.

## Katalog und geplantes Öffnen

`BorgVRDatasetSearch` ist ein normaler, agentenunabhängiger Automatisierungsdienst hinter
dem MCP-Router. Er verwendet die bestehenden begrenzten Katalogprovider und liefert bis zu
20 Treffer mit kurzen Metadatenbelegen. Maximal zwei Ergebnissnapshots, 512 Cursor und fünf
Minuten Lebensdauer begrenzen die Paginierung. URLs, Pfade und erkennbare Schlüsselwerte
werden aus Auszügen entfernt; Quellenadressen und Zugangsdaten werden nicht ausgegeben.
Nicht erreichbare Quellen sind kein Nachweis für fehlende Datensätze. Die Suche ist keine
Bildanalyse oder semantische Vektorsuche; Synonyme und Übersetzungen plant der Agent.

Nur der Bridge-Adapter kennt Katalog und Command-Service. Beide Agentenseiten merken sich
höchstens 2000 tatsächlich gelieferte Treffer-IDs für fünf Minuten. `open_dataset` erfordert
einen solchen Treffer, eine frische Zustandsabfrage und eine ausdrückliche Nutzerabsicht.
Pro Auftrag ist höchstens ein Öffnen möglich. Der gemeinsame Service prüft den Kontext nach
asynchronen Vorbereitungen und meldet den Öffnungsbeginn synchron mit seiner neuen Identität.
Die Bridge wartet bis zu fünf Minuten auf den Renderer und kontrolliert dabei die Öffnungs-ID.
Die stabile Öffnungsidentität bleibt dabei auch während der internen Bearbeitungsvorbereitung
vorhanden. Bereitschaft wird separat abgefragt; erst nach ihrem Abschluss wird der endgültige
Editierstand in den neuen Kontext übernommen. Gleiche Datensatz-ID mit anderer Öffnungs-ID
bleibt ein fremder Wechsel. Die laufende Prüfung erkennt auch verzögert eintretende Bereitschaft.
Fremde Auswahl oder Abbruch stoppen die Fortsetzung, ohne bereits begonnene Änderungen
automatisch zurückzunehmen. Der normale Command-/GSC-Pfad bleibt erhalten.

Die ausgehandelte Erweiterung `dataset_opening` koppelt den Werkzeugbeleg an den neuen
Kontext und Werkzeugkatalog. Erst die Serverbestätigung erlaubt neue Aufrufe. Der Server
verwirft den alten Werkzeugplan einschließlich weiterer Aufrufe aus demselben Modellpaket,
übernimmt nur historische Textauszüge und Ausführungsbelege und plant die unerledigten Teile
des ursprünglichen Auftrags mit frischer Zustandsabfrage neu. Keine Agententypen gelangen
in Katalog, Renderer, App-Modelle oder Command-Ausführung.

## Gemeinsame Bearbeitung

Manuelle Änderungen erhöhen die lokale Ansichtsrevision und unterbrechen nur die noch
nicht ausgeführte Modellplanung. Ereignisse werden bis zu 800 ms Bedienpause gebündelt;
asynchrone Nutzeraktionen müssen zuerst enden. Bereits gestartete Werkzeuge werden nicht
automatisch wiederholt oder zurückgesetzt. Vor dem nächsten Aufruf prüft die App erneut
die Revision. Veraltete Aufrufe erhalten eine ausdrücklich nicht ausgeführte Antwort.

Danach erhält der Agent den aktuellen Zustand und setzt denselben Auftrag fort. Alte
Zustandsdetails und Bilder werden als überholt markiert, Ausführungsbelege bleiben erhalten.
Ein Datensatzwechsel während laufender Arbeit beendet die Verbindung. Eine durch den
Benutzer angestoßene Bearbeitung darf den Editierstand innerhalb derselben Öffnung ändern.

Rückfragen laufen als gesonderte Nachrichten im selben Auftrag, nicht als neuer Prompt.
Regelvorschläge erfordern ausdrückliches Feedback und anschließend einen separaten
Bestätigungsklick. Erst dann werden höchstens 16 Regeln à 500 Zeichen auf diesem Gerät
gespeichert und künftigen Gesprächen mitgegeben. Sie sind fehlbare Präferenzen, keine
Sicherheitsregeln und kein Modelltraining. Löschen in den Einstellungen wirkt auf künftige
Gespräche; für das Vergessen im aktuellen Kontext ein neues Gespräch beginnen.

## Austauschen oder entfernen

- Ein anderer Agentenserver kann denselben Netzvertrag implementieren, ohne BorgVR zu ändern.
- Ein anderer App-Backendzugang implementiert ausschließlich `VoiceAgentApplicationBridge`.
- Zum vollständigen Ausbau `AppSupport/Voice` und `BorgVRAgentServer` entfernen sowie die
  Assistenten-Instanzen, Einstellungen, Fenster und Buttons in den drei App-Verzeichnissen.
  Mikrofon-/Spracherkennungsberechtigungen entfernen, soweit sie nicht anderweitig gebraucht werden.
  Renderer, Datensatzlogik, Command-Ausführung, MCP und GSC brauchen dafür keinen Ersatz.
  Der generische Ereigniskanal kann auch ohne Agent bestehen bleiben.

## Absicherung

`tests/test_collaboration.py` prüft Planungspause, sichere Fortsetzung, unveränderte
Auftragsziele, keine Befehlswiederholung, Rückfragen und explizite Regelentscheidungen.
Ein Strukturtest verhindert direkte Kernabhängigkeiten im Controller und Agentennamen im
Command-Kern. `Scripts/test-voice-agent.sh` prüft zusätzlich den echten nativen
TLS-/WebSocket-Weg, Herkunftsfilterung, Nutzerpriorität, lokale Regeln und GSC-Roundtrip.
