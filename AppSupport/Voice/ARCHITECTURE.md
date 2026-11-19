# Optionaler KI-Assistent

Der Assistent ist ein optionales Subsystem. Renderer, Datensätze, Command-Ausführung und
GSC-Aufzeichnung dürfen weder den Agenten noch ein bestimmtes Modell voraussetzen.

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

## Gemeinsame Bearbeitung

Manuelle Änderungen erhöhen die lokale Ansichtsrevision und unterbrechen nur die noch
nicht ausgeführte Modellplanung. Ereignisse werden bis zu 800 ms Bedienpause gebündelt;
asynchrone Nutzeraktionen müssen zuerst enden. Bereits gestartete Werkzeuge werden nicht
automatisch wiederholt oder zurückgesetzt. Vor dem nächsten Aufruf prüft die App erneut
die Revision. Veraltete Aufrufe erhalten eine ausdrücklich nicht ausgeführte Antwort.

Danach erhält der Agent den aktuellen Zustand und setzt denselben Auftrag fort. Alte
Zustandsdetails und Bilder werden als überholt markiert, Ausführungsbelege bleiben erhalten.
Ein Datensatzwechsel oder Schließen beendet weiterhin die Verbindung. Eine durch den
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
