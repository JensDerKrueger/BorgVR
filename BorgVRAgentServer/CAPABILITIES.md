# Funktionskatalog des BorgVR Assistenten

Generiert aus `capabilities.json` und den Quellcode-Registern mit `python3 audit_capabilities.py --write`.
Dies ist ein statischer Abdeckungsnachweis, keine Laufzeitfreigabe und kein Nachweis ausgeführter Tests.
Plattformangaben beschreiben die Benutzerfunktion; konkrete MCP- und Agentenaufrufe haben zusätzliche Grenzen.
Der Swift-Assistent ist auch im Startmenü nutzbar. Lokale Freigaben, Datensatz- und Rendererzustand begrenzen die tatsächlich verfügbaren Werkzeuge.

Erfasst: **77 Funktionsgruppen**, **64 MCP-Werkzeuge**, **48 maximal erlaubte native Agentenwerkzeuge**, **100 Command-/UI-Registereinträge**, **105 unterschiedliche GSC-Namen**.

Der Agent filtert weiter nach Plattform, RGB/RGBA und Bildfreigabe. Beispiel: Hintergrund/Projektion entfallen auf visionOS.
GSC meint benannte macOS-DSL-Befehle. `sessioncommand` kann weitere native Commands verlustfrei auf allen nativen Plattformen wiedergeben;
daraus folgt weder eine Agentenfreigabe noch eine benannte DSL-Funktion. Tool-Definitionen sind nicht automatisch UI-/Zustands-/Test-Vollständigkeit.

Der Assistenzkern verwendet den lokalen Werkzeugrouter. Das Modell schlägt strukturierte Entscheidungen vor; es führt keine BorgVR-Commands aus.

## Übersicht

| Bereich | Funktion | Kontext | Command-Pfad | MCP | Agent |
|---|---|---|---|---|---|
| App und Assistent | [Assistent aktivieren und ab App-Start benutzen](#app-assistant) | application | lokale Funktion | nein | nein |
| App und Assistent | [Ausgeführte Agentenbefehle und Gesprächskontext nachschlagen](#app-command_history) | assistant | lokale Funktion | nein | ja* |
| App und Assistent | [Textparameter für einen Skriptauftrag eingeben](#app-script_input) | application | lokale Funktion | nein | nein |
| App und Assistent | [Hauptmenü, Auswahl, Einstellungen und Assistent aufrufen](#app-navigation) | application | nur UI | nein | nein |
| App und Assistent | [Hilfe, Über und Datenschutz anzeigen](#app-help) | application | nur UI | nein | nein |
| App und Assistent | [Eigenen Mandelbulb erzeugen und öffnen](#app-fractal) | job | Service/Abfrage | nein | nein |
| Datensätze und Quellen | [Pufferung, Prefetch und Remote-Downloadstatus verfolgen](#datasets-streaming) | dataset | Service/Abfrage | nein | nein |
| Datensätze und Quellen | [Verfügbare Datensätze und vollständige Metadaten abfragen](#datasets-catalog) | application | Service/Abfrage | ja | nein |
| Datensätze und Quellen | [Datensätze nach Thema suchen, sortieren und gruppieren](#datasets-search) | application | Service/Abfrage | ja | ja* |
| Datensätze und Quellen | [Datensatz öffnen und Laden abbrechen](#datasets-open) | application | vorhanden | ja | ja* |
| Datensätze und Quellen | [Datensatz schließen und Zustand sichern](#datasets-close) | dataset | vorhanden | ja | ja* |
| Datensätze und Quellen | [Datensatzliste aktualisieren und Quellenstatus prüfen](#datasets-refresh) | application | Service/Abfrage | nein | nein |
| Datensätze und Quellen | [Lokale Datensätze und lokale Kopien löschen](#datasets-delete) | application | Service/Abfrage | nein | nein |
| Datensätze und Quellen | [Lokale Verzeichnisse, Remote-Server und Quellenauswahl verwalten](#datasets-sources) | application | teilweise | nein | nein |
| Import, Fusion und Export | [Volumendateien importieren oder native Daten übernehmen](#conversion-file) | job | Service/Abfrage | nein | ja* |
| Import, Fusion und Export | [DICOM-Verzeichnis prüfen, Serie auswählen und importieren](#conversion-dicom) | job | Service/Abfrage | nein | ja* |
| Import, Fusion und Export | [Bildsequenzen auswählen, ordnen und mit physischer Größe importieren](#conversion-images) | job | Service/Abfrage | nein | ja* |
| Import, Fusion und Export | [Zwei Volumen registrieren und fusioniert importieren](#conversion-fusion) | job | Service/Abfrage | nein | ja* |
| Import, Fusion und Export | [Brickgröße, Quantisierung, Kompression und Importmetadaten festlegen](#conversion-options) | job | teilweise | nein | nein |
| Import, Fusion und Export | [Quelldateien und referenzierte RAW-Dateien freigeben](#conversion-access) | application | lokale Funktion | nein | nein |
| Import, Fusion und Export | [Konvertierung starten, Fortschritt/Details lesen, abbrechen und Ergebnis öffnen](#conversion-jobs) | job | teilweise | nein | ja* |
| Import, Fusion und Export | [Meshes importieren oder exportieren](#conversion-mesh) | job | Service/Abfrage | nein | nein |
| Import, Fusion und Export | [BorgVR-LoD als flaches Volumen exportieren](#conversion-export_original) | job | Service/Abfrage | nein | nein |
| Import, Fusion und Export | [Isofläche extrahieren und als Mesh speichern](#windows-isosurface) | job | vorhanden | ja | nein |
| Darstellung | [Aktuellen App-, Datensatz- und Darstellungszustand lesen](#render-state) | application | Service/Abfrage | ja | ja* |
| Darstellung | [Rendermodus und Isowert ändern](#render-mode) | dataset | vorhanden | ja | ja* |
| Darstellung | [Rotieren, verschieben, skalieren und Transformation zurücksetzen](#render-transform) | dataset | vorhanden | ja | ja* |
| Darstellung | [Clip-Grenzen setzen und zurücksetzen](#render-clipping) | dataset | vorhanden | ja | ja* |
| Darstellung | [Lichtrichtung und Lichtfarben einstellen](#render-light) | dataset | vorhanden | ja | ja* |
| Darstellung | [Hintergrundfarbe und Verlauf einstellen](#render-background) | application | vorhanden | ja | ja* |
| Darstellung | [Field of View und Parallelprojektion einstellen](#render-projection) | application | vorhanden | ja | ja* |
| Darstellung | [Datensatz-Bounding-Box ein- und ausblenden](#render-bounding_box) | dataset | vorhanden | ja | ja* |
| Darstellung | [Sampling, LOD, Atlas und Optimierungen einstellen](#render-optimizations) | application | teilweise | ja | nein |
| Darstellung | [Darstellungsgruppen gezielt zurücksetzen](#render-reset) | dataset | vorhanden | ja | ja* |
| Darstellung | [Renderabschluss abwarten und Screenshot aufnehmen](#render-wait_capture) | dataset | vorhanden | ja | teilweise* |
| Darstellung | [Interaktionsmodus und TF-Malwerkzeug auswählen](#render-interaction) | dataset | vorhanden | nein | nein |
| Transferfunktionen | [Skalare Intensitätsbereiche isoliert abbilden](#tf-intensity_preview) | dataset | lokale Funktion | nein | ja* |
| Transferfunktionen | [Mehrkanal-TF lesen und durch RGBA-Einträge oder Stützstellen ändern](#tf-samples) | dataset | vorhanden | ja | ja* |
| Transferfunktionen | [Aktiven TF-Kanal und bearbeitete RGBA-Komponenten auswählen](#tf-channel) | dataset | vorhanden | nein | nein |
| Transferfunktionen | [TF-Katalog durchsuchen, TF laden und speichern](#tf-files) | dataset | teilweise | ja | nein |
| Volumenbearbeitung | [Pinselmodus, Radius, Projektion und Kanäle einstellen](#edit-brush) | dataset | vorhanden | ja | ja* |
| Volumenbearbeitung | [Volumenbereiche löschen oder wiederherstellen](#edit-apply) | dataset | vorhanden | ja | ja* |
| Volumenbearbeitung | [Edit-Bricks vorbereiten und deren Abschluss abwarten](#edit-finish) | job | Service/Abfrage | ja | teilweise* |
| Volumenbearbeitung | [Alle Edits im aktiven Zustand verwerfen](#edit-discard) | dataset | vorhanden | ja | nein |
| Volumenbearbeitung | [Editierstände auswählen, erzeugen, duplizieren, umbenennen und löschen](#edit-states) | dataset | vorhanden | ja | ja* |
| Volumenbearbeitung | [Bearbeiteten Datensatz exportieren und Export abbrechen](#edit-export) | job | vorhanden | ja | ja* |
| Marker, Objekte und Messungen | [Objekte, Messungen und Punkte auswählen sowie Projektionswerkzeuge konfigurieren](#annotations-selection) | dataset | nur UI | nein | nein |
| Marker, Objekte und Messungen | [Kugel-, Richtungs- und Strichmarker erstellen und bearbeiten](#annotations-markers) | dataset | vorhanden | ja | ja* |
| Marker, Objekte und Messungen | [Mesh-Assets auswählen und Instanzen platzieren oder transformieren](#annotations-mesh) | dataset | vorhanden | ja | nein |
| Marker, Objekte und Messungen | [Einzelne oder alle Marker und Objekte entfernen](#annotations-delete) | dataset | vorhanden | ja | teilweise* |
| Marker, Objekte und Messungen | [Längen-, Flächen- und Volumenmessungen anlegen und korrigieren](#annotations-measure) | dataset | vorhanden | ja | ja* |
| Marker, Objekte und Messungen | [Einzelne oder alle Messungen entfernen](#annotations-measure_delete) | dataset | vorhanden | ja | teilweise* |
| Marker, Objekte und Messungen | [Objekte und Messungen sichtbar oder unsichtbar schalten](#annotations-visibility) | dataset | vorhanden | ja | ja* |
| Marker, Objekte und Messungen | [Marker, Objekte und Messungen laden, zusammenführen und speichern](#annotations-files) | dataset | teilweise | nein | nein |
| Speichern und Automatisierung | [Darstellungszustand speichern und laden](#state-picture) | dataset | vorhanden | ja | ja* |
| Speichern und Automatisierung | [Command-Aufzeichnung starten, beenden und als GSC speichern](#state-record) | application | vorhanden | ja | nein |
| Speichern und Automatisierung | [Aufzeichnungen und allgemeine GSC-Skripte abspielen oder stoppen](#state-replay) | application | teilweise | ja | nein |
| Speichern und Automatisierung | [Interne Command-Payloads, Dateischreibbelege und Mutationsgrenzen](#state-internal) | application | intern | nein | nein |
| Einstellungen und Geräte | [Rendermodi, Interaktionen, Panel- und Diagnosebuttons vereinfachen](#settings-visibility) | application | teilweise | nein | nein |
| Einstellungen und Geräte | [Alle registrierten Einstellungen lesen und ändern](#settings-registered) | application | teilweise | nein | nein |
| Einstellungen und Geräte | [Settings sichern, laden und zurücksetzen](#settings-archive) | application | vorhanden | ja | nein |
| Einstellungen und Geräte | [KI-Verbindung, Sprache, Bildfreigabe, Arbeitsbudget und gemerkte Regeln verwalten](#settings-assistant) | assistant | lokale Funktion | nein | nein |
| Einstellungen und Geräte | [Hand-, Muse-, Controller- und Stiftbelegung konfigurieren](#settings-devices) | application | teilweise | nein | nein |
| Einstellungen und Geräte | [Erklärungsdialoge stummschalten und wieder anzeigen](#settings-explanations) | application | lokale Funktion | nein | nein |
| Einstellungen und Geräte | [Datensatz-, WebGPU- und MCP-Server starten, stoppen und konfigurieren](#settings-servers) | application | teilweise | nein | nein |
| SharePlay | [SharePlay starten, beitreten, verlassen und Hostrolle behandeln](#collaboration-shareplay) | application | Service/Abfrage | nein | nein |
| SharePlay | [Ansichten synchronisieren, Teilnehmeransichten und WebGPU-Link nutzen](#collaboration-views) | dataset | Service/Abfrage | nein | nein |
| Diagnose | [Resident-, Empty- und Missing-Bricks sichtbar machen](#diagnostics-bricks) | dataset | vorhanden | ja | nein |
| Diagnose | [Atlas leeren, Belegung/Paging und Working Set untersuchen](#diagnostics-atlas) | dataset | teilweise | nein | nein |
| Diagnose | [FPS, GPU-Zeiten, Speicher und Display-Sync prüfen](#diagnostics-performance) | dataset | teilweise | nein | nein |
| Diagnose | [Rotationsaufnahme erzeugen](#diagnostics-rotation) | dataset | vorhanden | nein | nein |
| Diagnose | [Anwendungs-, Import- und Skript-Details lesen, löschen und exportieren](#diagnostics-logs) | application | lokale Funktion | nein | nein |
| Diagnose | [Datensatzinformationen und Provenance anzeigen](#diagnostics-info) | dataset | Service/Abfrage | nein | nein |
| Fenster und Panels | [Immersive Space und AR-/VR-Stil steuern](#windows-immersive) | application | Service/Abfrage | nein | nein |
| Fenster und Panels | [Hauptfenstergröße und Fullscreen steuern](#windows-main) | application | vorhanden | ja | nein |
| Fenster und Panels | [Render-, TF-, Iso-, Licht-, Objekt-, Mess- und Pinselpanel öffnen](#windows-panels) | dataset | nur UI | nein | nein |
| Fenster und Panels | [Panels andocken, abdocken, formatieren und Layout speichern](#windows-layout) | dataset | nur UI | nein | nein |

* Kontextabhängig: App-Zustand, begrenzte Metadatensuche und autorisiertes Öffnen sind ohne Renderer nutzbar; ein erlaubter Teilaufruf bedeutet nicht, dass der gesamte Workflow abgedeckt ist.

## Details

<a id="app-assistant"></a>
### Assistent aktivieren und ab App-Start benutzen

- Kennung: `app.assistant`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Netzverbindung, separate Sprach-/Bildfreigabe.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Appweite Sitzung mit Text/Sprache, App-Zustand, begrenzter Katalogsuche und autorisiertem Öffnen ohne vorherigen Renderer. Geplante Übergänge verwerfen alte Werkzeugpläne und erfordern frische Zustandsabfrage.
- Lücke: Gelernte persönliche Routinen und gemeinsames Erkunden sind nicht implementiert. Fremde Datensatzwechsel stoppen laufende Arbeit.
- Nächster Schritt: Weitere App-Werkzeuge über die Bridge ergänzen; keine automatische Mikrofonaufnahme.
- Quellen: [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift), [AppSupport/Voice/VoiceAgentViews.swift](../AppSupport/Voice/VoiceAgentViews.swift), [macOSApp/ModeSelectionView.swift](../macOSApp/ModeSelectionView.swift), [iOSApp/ModeSelectionView.swift](../iOSApp/ModeSelectionView.swift), [VisionApp/ModeSelectionView.swift](../VisionApp/ModeSelectionView.swift), [AppSupport/Voice/ARCHITECTURE.md](../AppSupport/Voice/ARCHITECTURE.md)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/AssistantCoreTests.swift](../Tests/AssistantCoreTests.swift)

<a id="app-command_history"></a>
### Ausgeführte Agentenbefehle und Gesprächskontext nachschlagen

- Kennung: `app.command_history`; Plattformen: macOS, iOS, visionOS; Kontext: `assistant`; Wirkung: lokale Gesprächsdaten, nur im passenden Server- und Datensatzkontext abrufbar.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: `get_command_history`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Bestätigte Parameter und freigegebene Ergebnisse sowie frühere Nutzernachrichten und finale Antworten getrennt abfragen; optional ein laufendes Gespräch verschlüsselt auf dem Gerät speichern und laden.
- Lücke: Kein geräteübergreifendes Archiv. Keine Bilder, ungeklärten Ausführungen oder Freigaben zur Wiederholung.
- Nächster Schritt: Archiv und serverseitiges Erfahrungswissen getrennt behandeln.
- Quellen: [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift), [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift), [AppSupport/Voice/VoiceAgentConversationStore.swift](../AppSupport/Voice/VoiceAgentConversationStore.swift), [AppSupport/Voice/BorgVRAssistantCore.swift](../AppSupport/Voice/BorgVRAssistantCore.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentPolicyTests.swift](../Tests/VoiceAgentPolicyTests.swift), [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="app-script_input"></a>
### Textparameter für einen Skriptauftrag eingeben

- Kennung: `app.script_input`; Plattformen: macOS; Kontext: `application`; Wirkung: lokale Nutzereingabe.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `input`
- Zustandsabfrage: Skript-Input-Dialog auf macOS; Agentenrückfragen sind ein anderer Vertrag.
- Lücke: Kein plattformübergreifender Eingabe-/Bestätigungsvertrag für allgemeine App-Aufträge.
- Nächster Schritt: Typisierte Rückfragen für fachliche Entscheidungen; Geheimnisse nicht in freie Modelltexte übernehmen.
- Quellen: [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="app-navigation"></a>
### Hauptmenü, Auswahl, Einstellungen und Assistent aufrufen

- Kennung: `app.navigation`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: lokale Navigation.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: NavigationState und lokale Fensterzustände; nicht im Agentenvertrag.
- Lücke: Kein plattformneutraler Navigations-/Präsentations-Command. Dialoge sind keine semantischen Aufgaben.
- Nächster Schritt: App-Kontext und gezielte Präsentationsaktionen bereitstellen; fachliche Aktionen unabhängig vom sichtbaren Assistentenschritt ausführen.
- Quellen: [macOSApp/ContentView.swift](../macOSApp/ContentView.swift), [iOSApp/ContentView.swift](../iOSApp/ContentView.swift), [VisionApp/ContentView.swift](../VisionApp/ContentView.swift), [macOSApp/ModeSelectionView.swift](../macOSApp/ModeSelectionView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="app-help"></a>
### Hilfe, Über und Datenschutz anzeigen

- Kennung: `app.help`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: lokale Anzeige, ggf. externe Webseite.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Lokale UI und gebündelte HTML-Hilfe.
- Lücke: Kein Hilfeindex-/Themenwerkzeug oder Präsentations-Command für den Agenten.
- Nächster Schritt: Geprüfte Hilfethemen abfragen/öffnen; keine beliebige URL als Ersatz für Fachwissen.
- Quellen: [macOSApp/ModeSelectionView.swift](../macOSApp/ModeSelectionView.swift), [iOSApp/ModeSelectionView.swift](../iOSApp/ModeSelectionView.swift), [VisionApp/ModeSelectionView.swift](../VisionApp/ModeSelectionView.swift), [html/index.html](../html/index.html)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="app-fractal"></a>
### Eigenen Mandelbulb erzeugen und öffnen

- Kennung: `app.fractal`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: GPU/CPU-Arbeit und neue Datendatei.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Lokaler Generierungsdialog mit Größen-/Speicherplatzprüfung.
- Lücke: Generator nicht als abfragbarer, abbrechbarer App-Auftrag exponiert.
- Nächster Schritt: Generierungsauftrag mit Größe, temporärem/finalem Platzbedarf, Fortschritt und Ergebnis-ID anbieten.
- Quellen: [AppSupport/Datasets/MandelbulbEasterEggGenerator.swift](../AppSupport/Datasets/MandelbulbEasterEggGenerator.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="datasets-streaming"></a>
### Pufferung, Prefetch und Remote-Downloadstatus verfolgen

- Kennung: `datasets.streaming`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Netzwerk, Cache und Laden.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: App-/Datenquellenstatus und Lade-/Streaminganzeigen; Renderframe-Abschluss ist kein vollständiger Download.
- Lücke: Keine gezielte, appweite Agentenabfrage für gepufferte/geladene Daten, Prefetch-Ziel, fehlende Bricks oder Downloadabbruch unabhängig vom Renderer.
- Nächster Schritt: Lade-/Streaming-Snapshot mit Phase, Fortschritt, Vollständigkeit und korreliertem Öffnungsauftrag ergänzen.
- Quellen: [AppSupport/Datasets/DatasetOpenWorkflow.swift](../AppSupport/Datasets/DatasetOpenWorkflow.swift), [AppSupport/UI/DatasetBufferingView.swift](../AppSupport/UI/DatasetBufferingView.swift), [AppSupport/Application/AppModel.swift](../AppSupport/Application/AppModel.swift), [VisionApp/AppModels/RuntimeAppModel.swift](../VisionApp/AppModels/RuntimeAppModel.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="datasets-catalog"></a>
### Verfügbare Datensätze und vollständige Metadaten abfragen

- Kennung: `datasets.catalog`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Metadaten und Quellenadressen können vertraulich sein.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: `list_datasets`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: list_datasets liefert vollständige Metadaten, Provenance, Quellen und Metadatenfehler an MCP-Clients. Der native Agent verwendet stattdessen die begrenzte search_datasets-Abfrage.
- Lücke: Vollständige Rohmetadaten und Quellenadressen bleiben im Agenten gesperrt; Quellenabdeckung ist nicht garantiert.
- Nächster Schritt: Gezielte Metadatendetails und Quellenverfügbarkeit bei Bedarf ergänzen; keine globale Volumendatenübertragung.
- Quellen: [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [AppSupport/Automation/BorgVRScreenCommandService.swift](../AppSupport/Automation/BorgVRScreenCommandService.swift), [VisionApp/VisionBorgVRCommandService.swift](../VisionApp/VisionBorgVRCommandService.swift), [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift)
- Vorhandene Testquellen: [Tests/MCPCatalogLimitsTests.swift](../Tests/MCPCatalogLimitsTests.swift)

<a id="datasets-search"></a>
### Datensätze nach Thema suchen, sortieren und gruppieren

- Kennung: `datasets.search`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Metadatenzugriff.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: `search_datasets`
- Native Agentenwerkzeuge: `search_datasets`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Begrenzte Metadatensuche mit AND-verknüpften Begriffen, Belegen, stabiler Snapshot-Paginierung und Hinweis auf nicht verifizierte Quellenabdeckung. Keine Bildinhaltsanalyse; der Agent kann übersetzte Begriffe und Synonyme versuchen.
- Lücke: Keine semantische Vektorsuche und keine gesicherte Vollständigkeit nicht erreichbarer Quellen. Treffer sind Metadatenbelege, keine Diagnose oder Segmentierung.
- Nächster Schritt: Bei Bedarf gezielte Filter und Quellenstatus ergänzen; gemeinsame Suchimplementierung für UI/MCP/Agent beibehalten.
- Quellen: [BORGVR-Services/BorgVRDatasetSearch.swift](../BORGVR-Services/BorgVRDatasetSearch.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/AssistantCoreTests.swift](../Tests/AssistantCoreTests.swift)

<a id="datasets-open"></a>
### Datensatz öffnen und Laden abbrechen

- Kennung: `datasets.open`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Datensatz-/Rendererwechsel, Netzwerk und Speicher.
- Register: `BorgVRRecordedAction.openDataset`
- MCP: `open_dataset`
- Native Agentenwerkzeuge: `open_dataset`
- Benannte GSC-Befehle (macOS): `opendataset`
- Zustandsabfrage: Autorisiertes Öffnen eines kürzlich zurückgelieferten Suchtreffers über denselben Command-Service. Korrelierte Öffnungs-ID, Warten auf Rendererbereitschaft, neue Werkzeuge und erneute Zustandsabfrage vor Fortsetzung.
- Lücke: Noch kein allgemeiner Jobvertrag. Ein bereits begonnener Ladevorgang wird beim Abbruch nicht automatisch rückgängig gemacht.
- Nächster Schritt: Bei Bedarf Öffnungsfortschritt als allgemeinen Job exponieren; unbekannte IDs, fremde Übergänge und automatische Befehlswiederholung weiter abweisen.
- Quellen: [AppSupport/Datasets/DatasetOpenWorkflow.swift](../AppSupport/Datasets/DatasetOpenWorkflow.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift), [AppSupport/Voice/BorgVRAssistantCore.swift](../AppSupport/Voice/BorgVRAssistantCore.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/AssistantCoreTests.swift](../Tests/AssistantCoreTests.swift)

<a id="datasets-close"></a>
### Datensatz schließen und Zustand sichern

- Kennung: `datasets.close`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Renderer-/Immersive-Space-Ende, Speicherung.
- Register: `BorgVRRecordedAction.closeDataset`, `MacCommand.closeDataset`
- MCP: `close_dataset`
- Native Agentenwerkzeuge: `close_dataset`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Der Agent schließt über close_dataset, bestätigt das Ende des Renderers und setzt die Unterhaltung mit den Startmenü-Werkzeugen fort.
- Lücke: Ein aktiver Volumenexport muss zuerst beendet oder abgebrochen werden.
- Nächster Schritt: Bei Bedarf den Schließfortschritt für langsame Renderer gesondert anzeigen.
- Quellen: [AppSupport/Application/AppModel.swift](../AppSupport/Application/AppModel.swift), [VisionApp/RenderView.swift](../VisionApp/RenderView.swift), [AppSupport/Voice/VoiceAgentViews.swift](../AppSupport/Voice/VoiceAgentViews.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="datasets-refresh"></a>
### Datensatzliste aktualisieren und Quellenstatus prüfen

- Kennung: `datasets.refresh`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Remote-Katalogabfragen.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: list_datasets fragt verfügbare Quellen ab; UI besitzt Aktualisieren.
- Lücke: Keine explizite Refresh-/Cache-/Fortschrittssteuerung oder Quellenfehlerabfrage für Agenten.
- Nächster Schritt: Katalogservice wiederverwenden; Gesamtdauer, Byte-/Eintragsgrenzen und Abbruch weiterreichen.
- Quellen: [AppSupport/Datasets/OpenDatasetView.swift](../AppSupport/Datasets/OpenDatasetView.swift), [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="datasets-delete"></a>
### Lokale Datensätze und lokale Kopien löschen

- Kennung: `datasets.delete`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Dateilöschung.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: UI-Auswahl und lokale Quelleninformation.
- Lücke: Kein bestätigter, nach ID begrenzter Lösch-Command mit Ergebnisabfrage.
- Nächster Schritt: Fachlichen Delete-Command mit lokaler Freigabe, Schutz geöffneter Daten und nachvollziehbarem Ergebnis ergänzen.
- Quellen: [AppSupport/Datasets/OpenDatasetView.swift](../AppSupport/Datasets/OpenDatasetView.swift), [VisionApp/OpenDatasetView.swift](../VisionApp/OpenDatasetView.swift), [AppSupport/Application/AppModel.swift](../AppSupport/Application/AppModel.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="datasets-sources"></a>
### Lokale Verzeichnisse, Remote-Server und Quellenauswahl verwalten

- Kennung: `datasets.sources`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Dateizugriff, Netzwerk und Geheimnisse.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: UI-Serverlisten und Quelleneinstellungen; list_datasets zeigt bekannte Quellen ohne Passwörter.
- Lücke: Keine fachliche Quellenverwaltung; Settings-Archive sind kein sicherer Ersatz für Freigaben oder Credentials.
- Nächster Schritt: Quellen-IDs und lokale Datei-/Verzeichnisfreigaben anbieten; Schlüssel nur über lokale sichere Eingabe.
- Quellen: [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [VisionApp/AppModels/StoredAppModel.swift](../VisionApp/AppModels/StoredAppModel.swift), [AppSupport/UI/FilePickerView.swift](../AppSupport/UI/FilePickerView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-file"></a>
### Volumendateien importieren oder native Daten übernehmen

- Kennung: `conversion.file`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: Dateilesen, Konvertierung und neue Dateien.
- Register: `VolumeImportKind.volumeFile`
- MCP: fehlt
- Native Agentenwerkzeuge: `import_volume`
- Benannte GSC-Befehle (macOS): `importfile`
- Zustandsabfrage: Agent importiert lokal ausgewählte Volumendateien und Zarr-Ordner über BorgVRVolumeConversionService ins Datensatzverzeichnis.
- Lücke: Kein externer MCP-Import. Referenzierte Rohdateien werden nur bei Bedarf lokal nachgefordert.
- Nächster Schritt: Bei Bedarf Quellenfreigaben und validierte Pläne zwischen lokalen Aufrufern vereinheitlichen.
- Quellen: [BORGVR-IO/Importers/BorgVRVolumeConversionService.swift](../BORGVR-IO/Importers/BorgVRVolumeConversionService.swift), [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [iOSApp/ConverterView.swift](../iOSApp/ConverterView.swift), [VisionApp/ConverterView.swift](../VisionApp/ConverterView.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-dicom"></a>
### DICOM-Verzeichnis prüfen, Serie auswählen und importieren

- Kennung: `conversion.dicom`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: Patientendaten, Konvertierung und neue Dateien.
- Register: `VolumeImportKind.dicomDirectory`
- MCP: fehlt
- Native Agentenwerkzeuge: `import_volume`
- Benannte GSC-Befehle (macOS): `importdirectory`
- Zustandsabfrage: Agent importiert einen lokal ausgewählten DICOM-Ordner über den vorhandenen Konverter.
- Lücke: Kein Serien-/Vorschauwerkzeug im Agenten.
- Nächster Schritt: Serienvorschau und gezielte Auswahl bei mehreren Serien ergänzen.
- Quellen: [BORGVR-IO/Importers/BorgVRVolumeConversionService.swift](../BORGVR-IO/Importers/BorgVRVolumeConversionService.swift), [AppSupport/Datasets/DicomSlicePreview.swift](../AppSupport/Datasets/DicomSlicePreview.swift), [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-images"></a>
### Bildsequenzen auswählen, ordnen und mit physischer Größe importieren

- Kennung: `conversion.images`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: Dateilesen und neue Dateien.
- Register: `VolumeImportKind.imageSequence`
- MCP: fehlt
- Native Agentenwerkzeuge: `import_volume`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Agent importiert lokal ausgewählte Bildstapel mit expliziter physischer Breite, Höhe und Tiefe in Metern.
- Lücke: Die Reihenfolge ist wie im vorhandenen Importer; keine individuelle Bild- oder Kanalwahl im Agenten.
- Nächster Schritt: Zusätzliche Optionen erst bei Bedarf ergänzen.
- Quellen: [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [iOSApp/ConverterView.swift](../iOSApp/ConverterView.swift), [VisionApp/ConverterView.swift](../VisionApp/ConverterView.swift)
- Vorhandene Testquellen: [Tests/ImageSequenceConverterTests.cjs](../Tests/ImageSequenceConverterTests.cjs)

<a id="conversion-fusion"></a>
### Zwei Volumen registrieren und fusioniert importieren

- Kennung: `conversion.fusion`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: mehrere Datenquellen, Registrierung und neue Dateien.
- Register: `VolumeImportKind.volumeFusion`
- MCP: fehlt
- Native Agentenwerkzeuge: `fuse_volumes`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Agent wählt lokal Referenz und bewegtes Volumen getrennt; die bestehende starre Registrierung verarbeitet DICOM, Volumendateien und Zarr. Ergebnis ist ein neuer Datensatz.
- Lücke: Kein Transformations- oder Qualitätsbericht des Registrierers im Agenten.
- Nächster Schritt: Bei Bedarf verifizierbare Registrierungsmetriken und Vorschau melden.
- Quellen: [BORGVR-IO/Importers/BorgVRVolumeConversionService.swift](../BORGVR-IO/Importers/BorgVRVolumeConversionService.swift), [AppSupport/UI/ConverterChoiceView.swift](../AppSupport/UI/ConverterChoiceView.swift), [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [iOSApp/ConverterView.swift](../iOSApp/ConverterView.swift), [VisionApp/ConverterView.swift](../VisionApp/ConverterView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-options"></a>
### Brickgröße, Quantisierung, Kompression und Importmetadaten festlegen

- Kennung: `conversion.options`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: Datenqualität und Metadatenänderung.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `setimportbricksize`, `setimportoverlap`, `setbordermode`
- Zustandsabfrage: Wizard und registrierte Einstellungen; kein validierter Importplan als Dokument.
- Lücke: Einige Defaults sind aufgezeichnet, die konkreten Jobparameter und Provenance aber nicht als vollständiger Importauftrag.
- Nächster Schritt: Versionierten ImportPlan validieren, Quelle/Defaults/Overrides und neue UUID dokumentieren.
- Quellen: [BORGVR-IO/Importers/BorgVRVolumeConversionService.swift](../BORGVR-IO/Importers/BorgVRVolumeConversionService.swift), [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-access"></a>
### Quelldateien und referenzierte RAW-Dateien freigeben

- Kennung: `conversion.access`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Sandbox-/Dateizugriffsfreigabe.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `fileinput`, `dirinput`
- Zustandsabfrage: FilePickerView und SupportingFileAccessExplanation.
- Lücke: Kein sicherer Source-Handle-Vertrag; ein Modellpfad erteilt keine Berechtigung. Detached Header können weitere Freigaben brauchen.
- Nächster Schritt: Lokaler Vermittler für Datei-/Ordnerfreigaben mit Handles, Ablauf und Zusatzdateianforderung; keine beliebigen Serverpfade.
- Quellen: [AppSupport/UI/FilePickerView.swift](../AppSupport/UI/FilePickerView.swift), [AppSupport/UI/ConverterChoiceView.swift](../AppSupport/UI/ConverterChoiceView.swift), [BORGVR-IO/Importers/BorgVRImportFileAccess.swift](../BORGVR-IO/Importers/BorgVRImportFileAccess.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-jobs"></a>
### Konvertierung starten, Fortschritt/Details lesen, abbrechen und Ergebnis öffnen

- Kennung: `conversion.jobs`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: Langläufer, Teildateien und Renderer-Konflikt.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: `cancel_import`, `get_import_status`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Der gemeinsame Konvertierungsdienst liefert dem App-Assistenten lokalen Fortschritt; der Auftrag kann per UUID abgebrochen werden. Zum Öffnen den Datensatzkatalog nutzen.
- Lücke: Der Wizard besitzt weiterhin seinen eigenen Fortschrittszustand; Agentenauftrag ist nicht über die externe MCP-Schnittstelle verfügbar.
- Nächster Schritt: Bei Bedarf Jobstatus und Zusatzdateizugriff zwischen Wizard und anderen lokalen Aufrufern vereinheitlichen.
- Quellen: [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [iOSApp/ConverterView.swift](../iOSApp/ConverterView.swift), [VisionApp/ConverterView.swift](../VisionApp/ConverterView.swift), [BORGVR-IO/Importers/BorgVRVolumeConversionService.swift](../BORGVR-IO/Importers/BorgVRVolumeConversionService.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-mesh"></a>
### Meshes importieren oder exportieren

- Kennung: `conversion.mesh`; Plattformen: macOS; Kontext: `job`; Wirkung: Dateizugriff und Mesh-Konvertierung.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: macOS-Konverter mit importMesh/exportMesh; kein Jobwerkzeug.
- Lücke: Noch UI-eigener Ablauf; nicht mit upsert_mesh_instance oder export_isosurface gleichzusetzen.
- Nächster Schritt: Mesh-Konvertierung als Jobvariante mit validierten Quellen und Zielen exponieren; Plattformverfügbarkeit melden.
- Quellen: [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [AppSupport/Annotations/SceneMeshEditorView.swift](../AppSupport/Annotations/SceneMeshEditorView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="conversion-export_original"></a>
### BorgVR-LoD als flaches Volumen exportieren

- Kennung: `conversion.export_original`; Plattformen: macOS; Kontext: `job`; Wirkung: Quellzugriff und neue Datei.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `exportdataset`
- Zustandsabfrage: macOS-Konverter/GSC exportieren unkomprimiertes NRRD mit LoD-Auswahl.
- Lücke: Kein gemeinsamer abfragbarer Exportauftrag; export_edited_dataset ist ein anderer Workflow.
- Nächster Schritt: Exportquelle, LoD, Format und Ziel in den Job-Service übernehmen.
- Quellen: [AppSupport/Datasets/ConverterView.swift](../AppSupport/Datasets/ConverterView.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="windows-isosurface"></a>
### Isofläche extrahieren und als Mesh speichern

- Kennung: `windows.isosurface`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: Berechnung und Ausgabedatei.
- Register: `BorgVRRecordedAction.exportIsoSurface`, `MacRenderShortcut.extractIsosurface`
- MCP: `export_isosurface`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `exportisosurface`
- Zustandsabfrage: Export-API und lokaler Fortschritt; nicht als gemeinsamer Job exponiert.
- Lücke: MCP vorhanden, Agent gesperrt; begrenzte Tooldeadline und rohe Ausgabepfade reichen nicht für Langläufer.
- Nächster Schritt: Exportjob mit sicherem Ziel-Handle, Fortschritt, Abbruch und fertigem Ergebnis freigeben.
- Quellen: [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [macOSApp/RenderControlsPanel.swift](../macOSApp/RenderControlsPanel.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-state"></a>
### Aktuellen App-, Datensatz- und Darstellungszustand lesen

- Kennung: `render.state`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Zustands-/Metadatenfreigabe.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: `get_application_state`
- Native Agentenwerkzeuge: `get_application_state`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: get_application_state; der native Agent entfernt volumeEditing-Details.
- Lücke: Appzustand besitzt noch keinen eigenständigen Anwendungs-/Job-/Datensatzkontext. Agent kann diesen Getter derzeit trotzdem nur im Renderer benutzen.
- Nächster Schritt: AppSnapshot plus optionaler DatasetSnapshot mit klaren Revisionen und Job-Verweisen.
- Quellen: [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift), [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="render-mode"></a>
### Rendermodus und Isowert ändern

- Kennung: `render.mode`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Darstellung.
- Register: `BorgVRCommand.setRenderMode`, `BorgVRCommand.setNormalizedIsoValue`, `MacRenderShortcut.transferFunctionRendering`, `MacRenderShortcut.lightingRendering`, `MacRenderShortcut.isoRendering`
- MCP: `set_render_mode`, `set_iso_value`
- Native Agentenwerkzeuge: `set_iso_value`, `set_render_mode`
- Benannte GSC-Befehle (macOS): `rendermode`, `setmethod`, `isovalue`, `isovalueNormalized`
- Zustandsabfrage: get_application_state mit renderMode und normalizedIsoValue; RGB/RGBA hat diese Modi nicht.
- Lücke: Teilweise bereits verfügbar; Fähigkeiten müssen RGB/RGBA und lokale UI-Vereinfachung berücksichtigen.
- Nächster Schritt: Bestehende Werkzeuge und Tests behalten; gültige Modi explizit melden.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-transform"></a>
### Rotieren, verschieben, skalieren und Transformation zurücksetzen

- Kennung: `render.transform`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Darstellung, räumliche Ausrichtung.
- Register: `BorgVRCommand.setTransform`, `BorgVRCommand.rotate`, `MacRenderShortcut.translateLeft`, `MacRenderShortcut.translateRight`, `MacRenderShortcut.translateUp`, `MacRenderShortcut.translateDown`
- MCP: `set_transform`, `rotate_view`
- Native Agentenwerkzeuge: `rotate_view`, `set_transform`
- Benannte GSC-Befehle (macOS): `resetrotation`, `setrotationquaternion`, `addrotationx`, `addrotationy`, `addrotationz`, `settranslation`, `zoom`, `setscale`
- Zustandsabfrage: get_application_state.transform; plattformspezifische Semantik beachten.
- Lücke: Keine höherwertige Funktion für blickrelative Positionierung oder Ziel-Framing; keine automatische anatomische Orientierung.
- Nächster Schritt: Koordinatenvertrag und geometrische Hilfsoperationen ergänzen, vorhandene Commands behalten.
- Quellen: [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [VisionApp/VisionBorgVRCommandService.swift](../VisionApp/VisionBorgVRCommandService.swift), [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-clipping"></a>
### Clip-Grenzen setzen und zurücksetzen

- Kennung: `render.clipping`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Sichtbarkeit.
- Register: `BorgVRCommand.setClipping`
- MCP: `set_clipping`
- Native Agentenwerkzeuge: `set_clipping`
- Benannte GSC-Befehle (macOS): `clip`, `resetclip`
- Zustandsabfrage: get_application_state.clipMinimum/clipMaximum.
- Lücke: Nur achsenbezogene normierte Grenzen; keine blickrelative Hilfsoperation.
- Nächster Schritt: Bestehenden Setter behalten und getestete geometrische Fähigkeiten darauf aufbauen.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-light"></a>
### Lichtrichtung und Lichtfarben einstellen

- Kennung: `render.light`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Darstellung.
- Register: `BorgVRCommand.setLighting`
- MCP: `set_lighting`
- Native Agentenwerkzeuge: `set_lighting`
- Benannte GSC-Befehle (macOS): `setlightdirection`, `setambientlight`, `setdiffuselight`, `setspecularlight`, `resetlighting`
- Zustandsabfrage: get_application_state.lighting.
- Lücke: Bereits freigegeben, soweit ein passender skalarer Renderpfad vorhanden ist.
- Nächster Schritt: In Fähigkeits-/Berechtigungskatalog einordnen und bestehende Tests weiterverwenden.
- Quellen: [AppSupport/Rendering/LightingEditorView.swift](../AppSupport/Rendering/LightingEditorView.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-background"></a>
### Hintergrundfarbe und Verlauf einstellen

- Kennung: `render.background`; Plattformen: macOS, iOS; Kontext: `application`; Wirkung: lokale Darstellungseinstellung.
- Register: `BorgVRCommand.setBackground`
- MCP: `get_background`, `set_background`
- Native Agentenwerkzeuge: `get_background`, `set_background`
- Benannte GSC-Befehle (macOS): `background`, `getbackground`, `setbackgroundstate`
- Zustandsabfrage: get_background; visionOS hat Passthrough, keinen entsprechenden Farbhintergrund.
- Lücke: Fachlich vorhanden; nativer Agent verlangt derzeit dennoch einen offenen Datensatz.
- Nächster Schritt: Als App-/Render-Capability anbieten, Plattformgrenze beibehalten.
- Quellen: [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-projection"></a>
### Field of View und Parallelprojektion einstellen

- Kennung: `render.projection`; Plattformen: macOS, iOS; Kontext: `application`; Wirkung: lokale Darstellungseinstellung.
- Register: `BorgVRCommand.setScreenProjection`
- MCP: `set_screen_projection`
- Native Agentenwerkzeuge: `set_screen_projection`
- Benannte GSC-Befehle (macOS): `setfieldofview`, `setparallelprojection`
- Zustandsabfrage: get_application_state.renderingOptions.
- Lücke: Auf visionOS bewusst nicht dieselbe Kameraprojektion; derzeit nur im Renderer über Agent zugänglich.
- Nächster Schritt: Appweite Einstellung mit datasetabhängiger Wirkung und expliziter Plattformfähigkeit melden.
- Quellen: [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="render-bounding_box"></a>
### Datensatz-Bounding-Box ein- und ausblenden

- Kennung: `render.bounding_box`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Diagnoseanzeige.
- Register: `BorgVRCommand.setBoundingBox`
- MCP: `set_bounding_box`
- Native Agentenwerkzeuge: `set_bounding_box`
- Benannte GSC-Befehle (macOS): `showboundingbox`
- Zustandsabfrage: get_application_state.renderingOptions.datasetBoundingBoxVisible.
- Lücke: Bereits als Agentenwerkzeug vorhanden.
- Nächster Schritt: Bestehenden Pfad und Plattformtests behalten.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="render-optimizations"></a>
### Sampling, LOD, Atlas und Optimierungen einstellen

- Kennung: `render.optimizations`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Qualität, Ressourcen und persistente Einstellungen.
- Register: `BorgVRCommand.setRenderOptimizations`
- MCP: `set_render_optimizations`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `setsubbrickskipping`, `setopacityadaptivesampling`, `setalphaepsilon`
- Zustandsabfrage: get_application_state.renderingOptions enthält nur einen Teil; übrige Defaults im Settings-Register.
- Lücke: Agent sperrt das vorhandene Optimierungswerkzeug. Oversampling, LOD-/Atlas-/Prefetch-/Foveation-Parameter ohne typisierte Einzelwerkzeuge.
- Nächster Schritt: Settings-Schema mit Validierung, Restart-/Dataset-Wirkung und Plattformgrenzen bereitstellen; nicht nur drei Setter freigeben.
- Quellen: [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [VisionApp/AppModels/StoredAppModel.swift](../VisionApp/AppModels/StoredAppModel.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="render-reset"></a>
### Darstellungsgruppen gezielt zurücksetzen

- Kennung: `render.reset`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: vorhandene Darstellung überschreiben.
- Register: `BorgVRCommand.reset`, `MacRenderShortcut.reset`
- MCP: `reset_state`
- Native Agentenwerkzeuge: `reset_state`
- Benannte GSC-Befehle (macOS): `resettf`
- Zustandsabfrage: get_application_state und get_transfer_function nach Reset.
- Lücke: Agent verlangt einen expliziten Bereich und einen aktuellen Zustand; RGB/RGBA bietet nur Transformation und Clipping an.
- Nächster Schritt: Sichere exakte Snapshots für spätere Wiederherstellung bereitstellen.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift), [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="render-wait_capture"></a>
### Renderabschluss abwarten und Screenshot aufnehmen

- Kennung: `render.wait_capture`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Bildübertragung oder lokale Datei.
- Register: `BorgVRRecordedAction.captureScreenshot`, `MacRenderShortcut.screenshot`, `BorgVRRecordedAction.captureExtendedScreenshot`
- MCP: `wait_until_rendered`, `capture_screenshot`, `capture_extended_screenshot`, `pick_screenshot_positions`
- Native Agentenwerkzeuge: `capture_screenshot`, `pick_screenshot_positions`, `wait_until_rendered`
- Benannte GSC-Befehle (macOS): `waitframes`, `waitloaded`, `waitidle`, `screenshot`, `extendedscreenshot`
- Zustandsabfrage: PNG, optional letzte Positionskarte und erweiterte Aufnahmedatei; Agent bekommt nach Bildfreigabe Screenshot und einzelne Positionsabfragen.
- Lücke: GSC gibt die erweiterte Aufnahme als Datei aus. Der Agent erhält weder die vollständige Positionskarte noch einen Screenshot-Ausgabepfad.
- Nächster Schritt: Job-/Frame-/Vollständigkeitszustände sauber trennen; Bildfreigabe und stale-frame-Schutz beibehalten.
- Quellen: [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift), [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="render-interaction"></a>
### Interaktionsmodus und TF-Malwerkzeug auswählen

- Kennung: `render.interaction`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: lokales Eingabeverhalten.
- Register: `BorgVRCommand.setInteractionMode`, `BorgVRCommand.setTransferEditing`, `MacRenderShortcut.model`, `MacRenderShortcut.clipping`, `MacRenderShortcut.transferInteraction`, `MacRenderShortcut.drawing`, `MacRenderShortcut.placement`, `MacRenderShortcut.measurement`, `MacRenderShortcut.volumeEditing`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Lokaler Interaktionszustand; configure_volume_brush kann nur den Edit-Modus aktivieren.
- Lücke: Kein allgemeiner Modus-/Eingabewerkzeug-Getter/-Setter. Ein Agentenauftrag darf nicht ungefragt die manuelle Bedienung umstellen.
- Nächster Schritt: Semantische Eingabekonfiguration mit lokaler Zustandsabfrage ergänzen; Aktionen selbst nicht von UI-Moduswahl abhängig machen.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [iOSApp/RenderView.swift](../iOSApp/RenderView.swift), [VisionApp/PrivateApplicationView.swift](../VisionApp/PrivateApplicationView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="tf-intensity_preview"></a>
### Skalare Intensitätsbereiche isoliert abbilden

- Kennung: `tf.intensity_preview`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Bildübertragung nur bei erlaubter Bildfreigabe.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: `capture_tf_preview`
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Grobe Z-Projektion eines einzelnen normierten Intensitätsbandes; keine Änderung der Ansichts-TF.
- Lücke: Feste Ansicht aus der niedrigsten Volumenauflösung, keine exakte Live-Ansicht.
- Nächster Schritt: Laufzeit und Treffer auf repräsentativen Datensätzen messen.
- Quellen: [AppSupport/Voice/VoiceAgentVolumePreview.swift](../AppSupport/Voice/VoiceAgentVolumePreview.swift), [AppSupport/Voice/assistant-knowledge.json](../AppSupport/Voice/assistant-knowledge.json), [AppSupport/Voice/BorgVRAssistantCore.swift](../AppSupport/Voice/BorgVRAssistantCore.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="tf-samples"></a>
### Mehrkanal-TF lesen und durch RGBA-Einträge oder Stützstellen ändern

- Kennung: `tf.samples`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Darstellung.
- Register: `BorgVRCommand.setTransferFunction`
- MCP: `get_transfer_function`, `set_transfer_function`, `set_transfer_function_component`
- Native Agentenwerkzeuge: `get_transfer_function`, `set_transfer_function`, `set_transfer_function_component`
- Benannte GSC-Befehle (macOS): `settransferfunction`, `gettransferfunction`, `settransferfunctionjson`, `settransferfunctioncomponent`
- Zustandsabfrage: get_transfer_function; Agent erhält ggf. eine markierte Vorschau statt der vollständigen Tabelle.
- Lücke: Kein exakter zustandsbewahrender Snapshot-Handle für TF-Restaurierung über den Agenten.
- Nächster Schritt: Exakte lokale Snapshots mit begrenzten Handles ergänzen; RGB/RGBA weiterhin ohne TF-Werkzeuge.
- Quellen: [AppSupport/Voice/VoiceAgentProtocol.swift](../AppSupport/Voice/VoiceAgentProtocol.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="tf-channel"></a>
### Aktiven TF-Kanal und bearbeitete RGBA-Komponenten auswählen

- Kennung: `tf.channel`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: lokales Editorverhalten.
- Register: `BorgVRCommand.selectTransferFunctionChannel`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: TF-Werkzeuge unterstützen explizite Kanalnummern; aktive UI-Auswahl ist eine andere Information.
- Lücke: Kein Getter/Setter für sichtbaren Kanal, RGBA-Komponenten oder TF-Editoransicht.
- Nächster Schritt: Editorzustand explizit anbieten, ohne Kanalwahl als Voraussetzung für programmgesteuerte TF-Änderungen zu verlangen.
- Quellen: [AppSupport/Rendering/TransferFunctionEditorView.swift](../AppSupport/Rendering/TransferFunctionEditorView.swift), [VisionApp/TransferFunctionEditorView.swift](../VisionApp/TransferFunctionEditorView.swift), [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="tf-files"></a>
### TF-Katalog durchsuchen, TF laden und speichern

- Kennung: `tf.files`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Dateizugriff und Überschreiben.
- Register: `BorgVRRecordedAction.saveTransferFunction`
- MCP: `load_transfer_function`, `save_transfer_function`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `settffile`, `loadtf`, `savetffile`, `savetf`
- Zustandsabfrage: TF-Dateioperationen vorhanden; lokaler TransferFunctionCatalog nicht als MCP-Liste exponiert.
- Lücke: Agent sperrt Dateiwerkzeuge; TF-Katalogabfrage und sichere Datei-Handles fehlen.
- Nächster Schritt: Katalog-IDs für TFs, Zielauswahl und Überschreibfreigabe einführen; vollständige Tabellen intern erhalten.
- Quellen: [AppSupport/Rendering/TransferFunctionEditorView.swift](../AppSupport/Rendering/TransferFunctionEditorView.swift), [VisionApp/TransferFunctionEditorView.swift](../VisionApp/TransferFunctionEditorView.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="edit-brush"></a>
### Pinselmodus, Radius, Projektion und Kanäle einstellen

- Kennung: `edit.brush`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Vorbereitung einer Volumenbearbeitung.
- Register: `BorgVRRecordedAction.configureBrush`, `MacRenderShortcut.erase`, `MacRenderShortcut.restore`, `MacRenderShortcut.smallerBrush`, `MacRenderShortcut.largerBrush`
- MCP: `get_volume_edit_state`, `configure_volume_brush`
- Native Agentenwerkzeuge: `configure_volume_brush`, `get_volume_edit_state`
- Benannte GSC-Befehle (macOS): `setvolumebrush`, `setvolumeeditchannels`
- Zustandsabfrage: Der Agent liest get_volume_edit_state und setzt die Bearbeitungskanäle mit configure_volume_brush.
- Lücke: Agentenwerkzeug ändert ausschließlich Kanäle, nicht den lokalen Pinselmodus, Radius oder Projektionsmodus.
- Nächster Schritt: Nur bei Bedarf weitere unabhängige Pinselparameter freigeben.
- Quellen: [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="edit-apply"></a>
### Volumenbereiche löschen oder wiederherstellen

- Kennung: `edit.apply`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: persönlichen Editierstand ändern; gemeinsamer Editierstand nur über bestehende UI/MCP/GSC-Workflows.
- Register: `BorgVRRecordedAction.editVolume`
- MCP: `edit_volume`
- Native Agentenwerkzeuge: `edit_volume`
- Benannte GSC-Befehle (macOS): `erasevolume`, `restorevolume`, `editvolume`
- Zustandsabfrage: get_volume_edit_state und wait_volume_edits; Bricks angezeigt unabhängig von der Modellantwort.
- Lücke: Agent kann bis zu 256 Kugelproben pro Aufruf anwenden. Bestätigung ist standardmäßig an, lokal abschaltbar. Bekanntes XYZ in Metern und aktive Kanäle nötig; kein räumliches Raten aus Screenshots, keine Agenten-Edits in SharePlay.
- Nächster Schritt: Geprüfte Projektions- und Auswahlwerkzeuge für interaktive Regionseingabe sowie bedarfsgerechte Freigaben für geteilte Edits ergänzen.
- Quellen: [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="edit-finish"></a>
### Edit-Bricks vorbereiten und deren Abschluss abwarten

- Kennung: `edit.finish`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: CPU/GPU, Netzwerk und Persistenz.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: `wait_volume_edits`, `prepare_volume_edits`
- Native Agentenwerkzeuge: `wait_volume_edits`
- Benannte GSC-Befehle (macOS): `waitvolumeedits`, `preparevolumeedits`, `hasvolumeedits`, `volumeeditsbusy`
- Zustandsabfrage: get_volume_edit_state.bricksReady/pendingBrickCount und wait_volume_edits.timedOut.
- Lücke: Agent kann begrenzt warten, die lokale UI beobachtet den Abschluss unabhängig davon; keine Aussage über GPU-Atlas oder Bildqualität. Vorbereiten mit erhöhter Priorität bleibt separat.
- Nächster Schritt: Längere Vorbereitung als abbrechbaren Auftrag mit Fortschritt anbieten.
- Quellen: [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="edit-discard"></a>
### Alle Edits im aktiven Zustand verwerfen

- Kennung: `edit.discard`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: aktive Änderungen verwerfen, SharePlay betrifft alle.
- Register: `BorgVRRecordedAction.discardVolumeEdits`
- MCP: `discard_volume_edits`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `clearvolumeedits`
- Zustandsabfrage: get_volume_edit_state; separate confirm-Anforderung.
- Lücke: MCP vorhanden, Agent gesperrt. Die Bestätigung muss vom Nutzer stammen, nicht vom Modell selbst.
- Nächster Schritt: Lokale, auf Auftrag und Editierstand gebundene Bestätigung plus Ergebnisprüfung.
- Quellen: [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="edit-states"></a>
### Editierstände auswählen, erzeugen, duplizieren, umbenennen und löschen

- Kennung: `edit.states`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Zustandswechsel und Löschung; eingeschränkt bei SharePlay.
- Register: `BorgVRRecordedAction.selectEditState`, `BorgVRRecordedAction.duplicateEditState`, `BorgVRRecordedAction.renameEditState`, `BorgVRRecordedAction.deleteEditState`, `BorgVRRecordedAction.restoreEditState`, `BorgVRRecordedAction.installSavedEditState`
- MCP: `select_edit_state`, `create_edit_state`, `rename_edit_state`, `delete_edit_state`
- Native Agentenwerkzeuge: `create_edit_state`, `delete_edit_state`, `rename_edit_state`, `select_edit_state`
- Benannte GSC-Befehle (macOS): `logeditstates`, `selecteditstate`, `neweditstate`, `duplicateeditstate`, `renameeditstate`, `deleteeditstate`
- Zustandsabfrage: Der Agent listet und wählt persönliche Stände, legt einen leeren Stand an, dupliziert den aktiven Stand oder benennt einen gespeicherten Stand um. Löschen verlangt lokale Freigabe und betrifft nur einen inaktiven Stand.
- Lücke: Keine Standverwaltung während SharePlay. Der Assistent verwirft keine vollständigen Bearbeitungen.
- Nächster Schritt: Bei Bedarf explizite, separat bestätigte Aufräumvorgänge anbieten.
- Quellen: [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift)
- Vorhandene Testquellen: [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="edit-export"></a>
### Bearbeiteten Datensatz exportieren und Export abbrechen

- Kennung: `edit.export`; Plattformen: macOS, iOS, visionOS; Kontext: `job`; Wirkung: neue Datei, kein Export während SharePlay.
- Register: `BorgVRRecordedAction.exportVolume`
- MCP: `export_edited_dataset`, `cancel_volume_export`
- Native Agentenwerkzeuge: `cancel_volume_export`, `export_edited_dataset`
- Benannte GSC-Befehle (macOS): `exportediteddataset`
- Zustandsabfrage: export_edited_dataset nutzt lokale Ordnerauswahl und Dateinamen; get_volume_edit_state liefert Status; cancel_volume_export begrenzt den Agenten auf seinen eigenen Auftrag.
- Lücke: Kein Agentenexport während SharePlay und kein Überschreiben.
- Nächster Schritt: Bei Bedarf zusätzliche Exportformate und Optionen getrennt freigeben.
- Quellen: [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="annotations-selection"></a>
### Objekte, Messungen und Punkte auswählen sowie Projektionswerkzeuge konfigurieren

- Kennung: `annotations.selection`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: lokales Eingabeverhalten und Auswahl.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Auswahl-IDs im internen Annotationssnapshot; UI kennt Messungsart, Projektionsschalter und Werkzeugdefaults.
- Lücke: Keine typisierten Commands/Getter für Auswahl und Annotations-Eingabewerkzeuge. Upsert verändert das Ergebnis, aber nicht die sichtbare Auswahl oder Punktwerkzeugkonfiguration.
- Nächster Schritt: Auswahl-/Werkzeugkonfiguration getrennt von persistenter Annotation exponieren; nutzerseitige Auswahl bei Agentenaktionen bewahren.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [macOSApp/MacMarkerView.swift](../macOSApp/MacMarkerView.swift), [macOSApp/MacMeasurementView.swift](../macOSApp/MacMeasurementView.swift), [iOSApp/MobileMarkerView.swift](../iOSApp/MobileMarkerView.swift), [iOSApp/MobileMeasurementView.swift](../iOSApp/MobileMeasurementView.swift), [VisionApp/MarkerView.swift](../VisionApp/MarkerView.swift), [VisionApp/MeasurementView.swift](../VisionApp/MeasurementView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="annotations-markers"></a>
### Kugel-, Richtungs- und Strichmarker erstellen und bearbeiten

- Kennung: `annotations.markers`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Annotationen und ggf. SharePlay-Zustand ändern.
- Register: `BorgVRCommand.upsertObject`
- MCP: `list_objects`, `upsert_sphere_marker`, `upsert_stroke_marker`
- Native Agentenwerkzeuge: `list_objects`, `upsert_sphere_marker`, `upsert_stroke_marker`
- Benannte GSC-Befehle (macOS): `addspheremarker`, `adddirectionalmarker`, `addstrokemarker`, `setspheremarker`, `setstrokemarker`
- Zustandsabfrage: Agent: paginiertes list_objects mit stabilen IDs, Namen, Farben und Geometrie; höchstens 64 Einträge pro Seite.
- Lücke: Agent-Upserts sind auf 256 Punkte, gültige vorhandene Edit-IDs und normierte Koordinaten begrenzt. Keine präzise anatomische Zuordnung aus einem einzelnen Screenshot.
- Nächster Schritt: Optional einen expliziten Bildpunkt-zu-Volumen-Projektionsvertrag ergänzen; Lösch- und Mesh-Capabilities bleiben getrennt.
- Quellen: [AppSupport/Voice/VoiceAgentAnnotationPolicy.swift](../AppSupport/Voice/VoiceAgentAnnotationPolicy.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift), [AppSupport/Annotations/BorgVRAnnotationCommands.swift](../AppSupport/Annotations/BorgVRAnnotationCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [VisionApp/MarkerView.swift](../VisionApp/MarkerView.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/VoiceAgentPolicyTests.swift](../Tests/VoiceAgentPolicyTests.swift), [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift), [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="annotations-mesh"></a>
### Mesh-Assets auswählen und Instanzen platzieren oder transformieren

- Kennung: `annotations.mesh`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Objektzustand und ggf. geteilte Szene ändern.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: `list_mesh_assets`, `upsert_mesh_instance`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `setmeshinstance`
- Zustandsabfrage: list_mesh_assets und list_objects; Instanztranslation in Metern.
- Lücke: Agent gesperrt. Vorhandene Assets instanziieren ist kein Import einer neuen Mesh-Datei.
- Nächster Schritt: Objekt-Capability mit Asset-ID, vollständiger Transformation und konkreter Größenprüfung ergänzen.
- Quellen: [AppSupport/Annotations/SceneMeshEditorView.swift](../AppSupport/Annotations/SceneMeshEditorView.swift), [AppSupport/Annotations/BorgVRAnnotationCommands.swift](../AppSupport/Annotations/BorgVRAnnotationCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="annotations-delete"></a>
### Einzelne oder alle Marker und Objekte entfernen

- Kennung: `annotations.delete`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Annotationen löschen.
- Register: `BorgVRCommand.removeObject`, `BorgVRCommand.clearObjects`
- MCP: `remove_object`, `clear_objects`, `clear_annotations`
- Native Agentenwerkzeuge: `clear_annotations`, `remove_object`
- Benannte GSC-Befehle (macOS): `removemarker`, `clearmarkers`, `removeobject`, `clearobjects`
- Zustandsabfrage: list_objects vor/nach der Änderung; lokale Löschvorschau mit exakten Anzahlen und Snapshot-Freigabe.
- Lücke: Agent darf Marker, aber keine Meshes löschen. clear_annotations und das Löschen des letzten Markers erfordern lokale Zustimmung; clear_objects bleibt im Agenten gesperrt.
- Nächster Schritt: Freigaben für weitere destruktive Fähigkeiten getrennt ergänzen; kein Wiederverwenden oder Umgehen einer abgelehnten Freigabe.
- Quellen: [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift), [AppSupport/Voice/VoiceAgentViews.swift](../AppSupport/Voice/VoiceAgentViews.swift), [VisionApp/MarkerView.swift](../VisionApp/MarkerView.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="annotations-measure"></a>
### Längen-, Flächen- und Volumenmessungen anlegen und korrigieren

- Kennung: `annotations.measure`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: wissenschaftliche Messdaten ändern.
- Register: `BorgVRCommand.upsertMeasurement`
- MCP: `list_measurements`, `upsert_measurement`
- Native Agentenwerkzeuge: `list_measurements`, `upsert_measurement`
- Benannte GSC-Befehle (macOS): `setmeasurement`
- Zustandsabfrage: Agent: list_measurements liefert Punkt-IDs, normierte Koordinaten, BorgVR-Messwerte in m/m^2/m^3 und physicalExtentAvailable.
- Lücke: Höchstens 256 Punkte. Degenerierte Geometrie wird ohne Änderung abgelehnt; Volumen bezeichnet die konvexe Hülle, nicht segmentiertes Organvolumen. Physische Genauigkeit hängt von der Datensatzkalibrierung ab.
- Nächster Schritt: Bildpunktprojektion und explizite Genauigkeits-/Kalibrierungsangaben weiter ausbauen; keine erfundenen anatomischen Messpunkte.
- Quellen: [AppSupport/Voice/VoiceAgentAnnotationPolicy.swift](../AppSupport/Voice/VoiceAgentAnnotationPolicy.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift), [VisionApp/MeasurementView.swift](../VisionApp/MeasurementView.swift), [AppSupport/Annotations/BorgVRAnnotationCommands.swift](../AppSupport/Annotations/BorgVRAnnotationCommands.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift), [Tests/VoiceAgentPolicyTests.swift](../Tests/VoiceAgentPolicyTests.swift), [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift), [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="annotations-measure_delete"></a>
### Einzelne oder alle Messungen entfernen

- Kennung: `annotations.measure_delete`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Messdaten löschen.
- Register: `BorgVRCommand.removeMeasurement`, `BorgVRCommand.clearMeasurements`
- MCP: `remove_measurement`, `clear_measurements`, `clear_annotations`
- Native Agentenwerkzeuge: `clear_annotations`, `remove_measurement`
- Benannte GSC-Befehle (macOS): `removemeasurement`, `clearmeasurements`
- Zustandsabfrage: list_measurements vor/nach der Änderung; Snapshot-gebundene lokale Bestätigung für Sammellöschen.
- Lücke: Agent darf gezielt löschen; Sammellöschen oder die letzte Messung benötigen lokale Zustimmung. clear_measurements bleibt im Agenten gesperrt.
- Nächster Schritt: Weitere destruktive Fähigkeiten nur mit eigenen Freigaben; Kontextwechsel, Abbruch und Snapshot-Änderungen entwerten die Zustimmung.
- Quellen: [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift), [AppSupport/Voice/BorgVRVoiceAgentBridge.swift](../AppSupport/Voice/BorgVRVoiceAgentBridge.swift), [AppSupport/Voice/VoiceAgentViews.swift](../AppSupport/Voice/VoiceAgentViews.swift), [VisionApp/MeasurementView.swift](../VisionApp/MeasurementView.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="annotations-visibility"></a>
### Objekte und Messungen sichtbar oder unsichtbar schalten

- Kennung: `annotations.visibility`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible lokale Anzeige.
- Register: `BorgVRCommand.setAnnotationVisibility`
- MCP: `set_annotation_visibility`
- Native Agentenwerkzeuge: `set_annotation_visibility`
- Benannte GSC-Befehle (macOS): `hideobjects`, `hidemeasurements`
- Zustandsabfrage: get_application_state.annotationVisibility.
- Lücke: Agent darf die vollständige Objekt- oder Messungsanzeige umschalten; keine separate Sichtbarkeit pro Marker.
- Nächster Schritt: Sichtbarkeit pro Element bei Bedarf separat ergänzen; Sichtbarkeit ist keine Löschung.
- Quellen: [AppSupport/Voice/VoiceAgentAnnotationPolicy.swift](../AppSupport/Voice/VoiceAgentAnnotationPolicy.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift)
- Vorhandene Testquellen: [Tests/VoiceAgentTests.swift](../Tests/VoiceAgentTests.swift)

<a id="annotations-files"></a>
### Marker, Objekte und Messungen laden, zusammenführen und speichern

- Kennung: `annotations.files`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Dateizugriff, Import und ggf. Ersetzen vorhandener Einträge.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `loadmarkers`, `savemarkers`
- Zustandsabfrage: UI-Dateidialoge; geladene Inhalte werden in Commands überführt. Messungsdateien haben keinen gleichwertigen benannten GSC-Lade-/Speicherbefehl.
- Lücke: Generische writeFiles/Upserts zeichnen Ergebnisse auf, ersetzen aber keinen fachlichen Dokument-Import/Export mit Merge-/Replace-Policy.
- Nächster Schritt: Typisierte Annotationsdokument-Aufträge mit Dataset-Mismatch-, ID-Konflikt- und Merge-/Replace-Behandlung.
- Quellen: [VisionApp/MarkerView.swift](../VisionApp/MarkerView.swift), [VisionApp/MeasurementView.swift](../VisionApp/MeasurementView.swift), [macOSApp/MacMarkerView.swift](../macOSApp/MacMarkerView.swift), [macOSApp/MacMeasurementView.swift](../macOSApp/MacMeasurementView.swift), [iOSApp/MobileMarkerView.swift](../iOSApp/MobileMarkerView.swift), [iOSApp/MobileMeasurementView.swift](../iOSApp/MobileMeasurementView.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="state-picture"></a>
### Darstellungszustand speichern und laden

- Kennung: `state.picture`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Dateizugriff und bestehende Darstellung ersetzen.
- Register: `BorgVRCommand.restoreDatasetViewState`, `BorgVRRecordedAction.saveVisualizationState`, `MacCommand.saveDatasetState`, `MacCommand.restoreDatasetState`
- MCP: `save_visualization_state`, `load_visualization_state`
- Native Agentenwerkzeuge: `load_visualization_state`, `save_visualization_state`
- Benannte GSC-Befehle (macOS): `savestate`, `loadstate`, `savevisualizationstate`, `loadvisualizationstate`, `setviewstate`
- Zustandsabfrage: Agent speichert einen benannten JSON-Darstellungszustand per lokaler Ordnerauswahl und lädt eine lokal gewählte JSON für den offenen Datensatz. Keine Voxeländerungen, Marker oder Messungen.
- Lücke: Lokale Dateiauswahl erforderlich; der Assistent kann weder Pfad noch automatischen Speicherstand wählen.
- Nächster Schritt: Bei Bedarf Vorschau vor dem Laden oder Verwaltung mehrerer gespeicherter Darstellungen anbieten.
- Quellen: [AppSupport/Datasets/DatasetViewState.swift](../AppSupport/Datasets/DatasetViewState.swift), [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [macOSApp/RenderView.swift](../macOSApp/RenderView.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift), [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="state-record"></a>
### Command-Aufzeichnung starten, beenden und als GSC speichern

- Kennung: `state.record`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Aufzeichnung kann vertrauliche fachliche Daten enthalten.
- Register: `MacCommand.startRecording`, `MacCommand.stopRecording`
- MCP: `start_command_recording`, `stop_command_recording`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `sessioncommand`
- Zustandsabfrage: commandExecutor.isCommandRecording und vollständige Aufzeichnung nach Abschluss.
- Lücke: Agent sperrt Aufnahme; Start-Baseline kann Datensatz-/Editierzustand benötigen. Aufnahme ist kein dauerhaftes Agentengedächtnis.
- Nächster Schritt: Aufzeichnung bewusst freigeben, Commit-/Fehlerbelege behalten; App-Start und Aufnahme ohne Datensatz gesondert testen.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift), [Tests/CommandRecordingCoverageTests.js](../Tests/CommandRecordingCoverageTests.js)

<a id="state-replay"></a>
### Aufzeichnungen und allgemeine GSC-Skripte abspielen oder stoppen

- Kennung: `state.replay`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: zusammengesetzte Änderungen, Datensatzwechsel und Dateien.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: `replay_command_recording`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: MCP/alle nativen Plattformen können nur das validierte Recorder-Subset abspielen; allgemeine DSL nur macOS.
- Lücke: Agent gesperrt. Ein Replay kann andere Tools/Freigaben indirekt umgehen, wenn es pauschal freigegeben würde.
- Nächster Schritt: Jeden enthaltenen Command gegen Auftragsrechte prüfen; kein Umweg um fehlende Agentenwerkzeuge.
- Quellen: [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="state-internal"></a>
### Interne Command-Payloads, Dateischreibbelege und Mutationsgrenzen

- Kennung: `state.internal`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: abhängig vom enthaltenen Vorgang.
- Register: `MacCommand.render`, `BorgVRCommand.action`, `BorgVRCommand.mutation`, `BorgVRRecordedAction.writeFiles`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Recorder-/Command-Ereignisse; keine frei aufzurufende Benutzerfunktion.
- Lücke: Kein generisches Agentenwerkzeug für beliebige Payloads vorsehen. Nicht repräsentierte Mutationen dürfen nicht als vollständige Automatisierung gelten.
- Nächster Schritt: Fachliche Einzeloperationen katalogisieren; generische Wrapper nicht als Paritätsnachweis zählen.
- Quellen: [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift), [AppSupport/Automation/VolumeEditingCommands.swift](../AppSupport/Automation/VolumeEditingCommands.swift)
- Vorhandene Testquellen: [Tests/CommandRecordingTests.swift](../Tests/CommandRecordingTests.swift)

<a id="settings-visibility"></a>
### Rendermodi, Interaktionen, Panel- und Diagnosebuttons vereinfachen

- Kennung: `settings.visibility`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: lokale UI-Sichtbarkeit.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: InterfaceVisibility und registrierte uiRenderModes/uiInteractionModes/uiPanelButtons/Show-Optionen.
- Lücke: Nur allgemeiner Settings-Pfad, keine gezielte Visibility-Abfrage/-Änderung. Ausgeblendete UI ist keine Sicherheitsfreigabe für den Agenten.
- Nächster Schritt: Validierte UI-Policy exponieren: mindestens ein Render-/Interaktionsmodus; RGB/RGBA, SharePlay-Ausnahmen und Plattformunterschiede beibehalten.
- Quellen: [AppSupport/UI/InterfaceVisibilitySettingsView.swift](../AppSupport/UI/InterfaceVisibilitySettingsView.swift), [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [VisionApp/AppModels/StoredAppModel.swift](../VisionApp/AppModels/StoredAppModel.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="settings-registered"></a>
### Alle registrierten Einstellungen lesen und ändern

- Kennung: `settings.registered`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Qualität, Bedienung, Persistenz und Dienste.
- Register: `BorgVRCommand.setSettings`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Defaults-Register, settingsBinding und validierter SettingsStore; Einzelregister siehe Anhang.
- Lücke: Kein allgemeiner Settings-Schema-/Getter-/Setter-Vertrag. Einige Werte sind speziell exponiert, andere nur über Archive.
- Nächster Schritt: Typisierte Settings-Capability mit Wirkungsbereich, Bereichsprüfung, Plattform und Schutz laufender Verbindungen; Geheimnisse getrennt.
- Quellen: [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [VisionApp/AppModels/StoredAppModel.swift](../VisionApp/AppModels/StoredAppModel.swift), [BORGVR-IO/BorgVRSettingsArchive.swift](../BORGVR-IO/BorgVRSettingsArchive.swift), [macOSApp/SettingsView.swift](../macOSApp/SettingsView.swift), [iOSApp/SettingsView.swift](../iOSApp/SettingsView.swift), [VisionApp/SettingsView.swift](../VisionApp/SettingsView.swift)
- Vorhandene Testquellen: [Tests/CommandRecordingCoverageTests.js](../Tests/CommandRecordingCoverageTests.js), [Tests/SettingsArchiveTests.swift](../Tests/SettingsArchiveTests.swift)

<a id="settings-archive"></a>
### Settings sichern, laden und zurücksetzen

- Kennung: `settings.archive`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: persistente Einstellungen und optional sensible Sicherung.
- Register: `BorgVRRecordedAction.saveSettings`
- MCP: `save_settings`, `load_settings`, `reset_settings`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `savesettings`, `loadsettings`, `resetsettings`
- Zustandsabfrage: Settings-Archiv; laufende MCP-Verbindung wird beim Restore/Reset geschützt.
- Lücke: Agent sperrt alle Settings-Werkzeuge. include_credentials darf nicht zur Geheimnisabfrage durch das Modell werden; Agentenverbindung braucht eigenen Bestandsschutz.
- Nächster Schritt: Sichere Settings-Backups mit lokalen Ziel-Handles; sensible Eingaben/Exporte lokal bestätigen und Verbindungen schützen.
- Quellen: [BORGVR-IO/BorgVRSettingsArchive.swift](../BORGVR-IO/BorgVRSettingsArchive.swift), [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [AppSupport/UI/SettingsFileControls.swift](../AppSupport/UI/SettingsFileControls.swift)
- Vorhandene Testquellen: [Tests/SettingsArchiveTests.swift](../Tests/SettingsArchiveTests.swift), [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="settings-assistant"></a>
### KI-Verbindung, Sprache, Bildfreigabe, Arbeitsbudget und gemerkte Regeln verwalten

- Kennung: `settings.assistant`; Plattformen: macOS, iOS, visionOS; Kontext: `assistant`; Wirkung: Credentials, Freigaben und persönliches Wissen.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: VoiceAgentSettings separat von den allgemeinen Defaults; Regeln bleiben pro Gerät.
- Lücke: Bewusst keine Modellabfrage von Tokens/Zertifikatsschlüsseln. Noch kein strukturierter Wissens-/Freigabevertrag außerhalb der UI.
- Nächster Schritt: Nicht sensible Optionen gezielt exponieren; Freigaben und Schlüssel bleiben lokal kontrolliert. Bestehende Regeln verlustfrei migrieren.
- Quellen: [AppSupport/Voice/VoiceAgentConnection.swift](../AppSupport/Voice/VoiceAgentConnection.swift), [AppSupport/Voice/VoiceAgentViews.swift](../AppSupport/Voice/VoiceAgentViews.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="settings-devices"></a>
### Hand-, Muse-, Controller- und Stiftbelegung konfigurieren

- Kennung: `settings.devices`; Plattformen: visionOS; Kontext: `application`; Wirkung: Hardwareverbindung und lokales Eingabeverhalten.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: StoredAppModel und Vision-Settings; manche Werte im Settings-Archiv.
- Lücke: Keine typisierten Geräte-/Verbindungs-/Belegungsabfragen oder Start-/Stop-Aktionen.
- Nächster Schritt: Verfügbarkeit und Belegung als separate lokale Fähigkeiten; Betriebssystem-Pairing/Berechtigungen lokal vermitteln.
- Quellen: [VisionApp/SettingsView.swift](../VisionApp/SettingsView.swift), [VisionApp/AppModels/StoredAppModel.swift](../VisionApp/AppModels/StoredAppModel.swift), [VisionApp/SpatialControllerShortcuts.swift](../VisionApp/SpatialControllerShortcuts.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="settings-explanations"></a>
### Erklärungsdialoge stummschalten und wieder anzeigen

- Kennung: `settings.explanations`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: lokale Hilfedarstellung.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: ExplanationDialogPreference, kein allgemeiner Agenten-Getter.
- Lücke: Nicht alle lokalen Präferenzen gehören zum Defaults-Register oder sind über Settings-Archive erreichbar.
- Nächster Schritt: Lokale UI-Präferenzen gezielt erfassen; fachliche Berechtigungen nicht mit ausgeblendeten Erklärungen verwechseln.
- Quellen: [AppSupport/UI/SettingsFileControls.swift](../AppSupport/UI/SettingsFileControls.swift), [AppSupport/UI/ConverterChoiceView.swift](../AppSupport/UI/ConverterChoiceView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="settings-servers"></a>
### Datensatz-, WebGPU- und MCP-Server starten, stoppen und konfigurieren

- Kennung: `settings.servers`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Netzwerkfreigabe, Ports und Geheimnisse.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Lokale Servercontroller/Settings; keine Agenten-Dienststatus- oder Steuerwerkzeuge.
- Lücke: Settings-Persistenz ist nicht dasselbe wie abfragbare Dienststeuerung. Serverfreigabe muss ausdrücklich autorisiert werden.
- Nächster Schritt: Dienststatus und bestätigte Start-/Stop-Commands ergänzen, ohne Tokens oder private Schlüssel zum Modell zu senden.
- Quellen: [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [AppSupport/Application/AppSettings.swift](../AppSupport/Application/AppSettings.swift), [VisionApp/SettingsView.swift](../VisionApp/SettingsView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="collaboration-shareplay"></a>
### SharePlay starten, beitreten, verlassen und Hostrolle behandeln

- Kennung: `collaboration.shareplay`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: gemeinsame Sitzung und Datenteilung.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: SharePlayCoordinator/SessionEngine; keine Agenten-Teilnehmer-/Rollenabfrage.
- Lücke: Keine appweite SharePlay-Capability. Lokale Bestätigung darf nicht vom Modell ersetzt werden.
- Nächster Schritt: Sitzungs-/Rollenstatus und bestätigte Beitritts-/Austritts-/Hostübergaben bereitstellen; bestehende Plattformgrenzen beibehalten.
- Quellen: [AppSupport/SharePlay/SharePlayCoordinator.swift](../AppSupport/SharePlay/SharePlayCoordinator.swift), [AppSupport/SharePlay/BorgVRSharePlaySessionEngine.swift](../AppSupport/SharePlay/BorgVRSharePlaySessionEngine.swift), [VisionApp/GroupActivities.swift](../VisionApp/GroupActivities.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="collaboration-views"></a>
### Ansichten synchronisieren, Teilnehmeransichten und WebGPU-Link nutzen

- Kennung: `collaboration.views`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Ansichtsänderung und Verbindungsdaten teilen.
- Register: `MacRenderShortcut.synchronizeView`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: SharePlay-Ansichtszustände im internen FrameSnapshot; keine Agenten-Abfrage.
- Lücke: Keine Werkzeuge für Ansichtsübernahme, Synchronisation oder begrenzte Linkfreigabe; fremde Events dürfen nicht als lokale Demonstration gelten.
- Nächster Schritt: Akteur und Empfänger ausdrücklich modellieren; Freigaben für gemeinsam wirkende Änderungen berücksichtigen.
- Quellen: [AppSupport/SharePlay/BorgVRSharePlaySessionEngine.swift](../AppSupport/SharePlay/BorgVRSharePlaySessionEngine.swift), [VisionApp/PrivateApplicationView.swift](../VisionApp/PrivateApplicationView.swift), [macOSApp/macOSApp.swift](../macOSApp/macOSApp.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="diagnostics-bricks"></a>
### Resident-, Empty- und Missing-Bricks sichtbar machen

- Kennung: `diagnostics.bricks`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: reversible Diagnoseanzeige.
- Register: `BorgVRCommand.setBrickVisualization`, `MacRenderShortcut.bricks`
- MCP: `set_brick_visualization`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `showbricks`, `showresidentbricks`, `showemptybricks`, `showmissingbricks`
- Zustandsabfrage: get_application_state.renderingOptions enthält Filter und Enabled-Zustand.
- Lücke: MCP vorhanden, Agent gesperrt.
- Nächster Schritt: Als Diagnosefähigkeit einordnen und mit Darstellungserlaubnis anbieten.
- Quellen: [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift), [VisionApp/ProfileView.swift](../VisionApp/ProfileView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="diagnostics-atlas"></a>
### Atlas leeren, Belegung/Paging und Working Set untersuchen

- Kennung: `diagnostics.atlas`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Performance, Nachladen und temporärer Speicher.
- Register: `BorgVRRecordedAction.purgeAtlas`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Performance-/Profiling-UI besitzt Kurven und Atlasdaten; Working-Set-Messung speziell visionOS.
- Lücke: Purge ist als Command vorhanden, aber kein MCP/Agentenwerkzeug. Atlas-/Paging-/Working-Set-Status nicht als Diagnosevertrag verfügbar.
- Nächster Schritt: Begrenzte Diagnose-Snapshots und bestätigte Purge-/Mess-Jobs, ohne niedrigste dauerhaft residente Brick zu verlieren.
- Quellen: [macOSApp/PerformanceGraphView.swift](../macOSApp/PerformanceGraphView.swift), [VisionApp/ProfileView.swift](../VisionApp/ProfileView.swift), [VisionApp/MemoryUsageView.swift](../VisionApp/MemoryUsageView.swift), [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="diagnostics-performance"></a>
### FPS, GPU-Zeiten, Speicher und Display-Sync prüfen

- Kennung: `diagnostics.performance`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Diagnosedaten, ggf. lokale Renderkonfiguration.
- Register: `MacRenderShortcut.performance`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `resetfps`, `setDisplaySync`
- Zustandsabfrage: Lokale Performance-UI; GSC-Basisfunktionen logfps/loggpu ergänzen diese auf macOS.
- Lücke: Keine gemeinsamen Agenten-Performance-/Speicherabfragen; einige GSC-Basisfunktionen stehen nicht im BorgVR-Erweiterungsmanifest.
- Nächster Schritt: Read-only Diagnosesnapshot; Reset/Display-Sync getrennt und plattformspezifisch anbieten.
- Quellen: [macOSApp/PerformanceGraphView.swift](../macOSApp/PerformanceGraphView.swift), [VisionApp/PerformanceGraphView.swift](../VisionApp/PerformanceGraphView.swift), [VisionApp/MemoryUsageView.swift](../VisionApp/MemoryUsageView.swift), [macOSApp/BorgVRScriptRunner.swift](../macOSApp/BorgVRScriptRunner.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="diagnostics-rotation"></a>
### Rotationsaufnahme erzeugen

- Kennung: `diagnostics.rotation`; Plattformen: visionOS; Kontext: `dataset`; Wirkung: Aufnahme und Datei-/Ressourcenverbrauch.
- Register: `BorgVRRecordedAction.captureRotation`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Aufnahme-Request im visionOS-RenderSnapshot; auf macOS/iOS nicht als entsprechende Aufnahme implementiert.
- Lücke: Recorder-Action vorhanden; Abschluss und Ergebnis sind nicht als Tool-/Jobvertrag beschrieben.
- Nächster Schritt: Capture-Capability pro Plattform melden und Aufnahme als Job mit Ergebnis abfragen.
- Quellen: [VisionApp/ProfileView.swift](../VisionApp/ProfileView.swift), [VisionApp/Rendering/VisionVolumeRenderer.swift](../VisionApp/Rendering/VisionVolumeRenderer.swift), [AppSupport/Application/BorgVRSession.swift](../AppSupport/Application/BorgVRSession.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="diagnostics-logs"></a>
### Anwendungs-, Import- und Skript-Details lesen, löschen und exportieren

- Kennung: `diagnostics.logs`; Plattformen: macOS, iOS, visionOS; Kontext: `application`; Wirkung: Logs können private Pfade und Metadaten enthalten.
- Register: `MacRenderShortcut.log`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: Lokale Logger-Views/ImportDetailsView/ScriptLogView; kein strukturierter Agentenstatus-Verlauf.
- Lücke: Kein datensparsamer Ereignis-/Job-/Fehlervertrag. Rohlogs sind kein sicherer Agenten-Kontext.
- Nächster Schritt: Strukturierte Statusereignisse ohne Prompts/Bilder/Schlüssel, begrenzte Diagnoseabfrage und expliziter Export.
- Quellen: [AppSupport/UI/LoggerView.swift](../AppSupport/UI/LoggerView.swift), [VisionApp/ImportDetailsView.swift](../VisionApp/ImportDetailsView.swift), [macOSApp/ScriptLogView.swift](../macOSApp/ScriptLogView.swift), [AppSupport/Voice/VoiceAgentController.swift](../AppSupport/Voice/VoiceAgentController.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="diagnostics-info"></a>
### Datensatzinformationen und Provenance anzeigen

- Kennung: `diagnostics.info`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: Metadatenfreigabe.
- Register: `MacRenderShortcut.datasetInfo`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: DatasetInfo/Provenance-UI; list_datasets enthält vollständige verfügbare Metadaten, get_application_state nur ausgewählte Felder.
- Lücke: Kein kleiner gezielter metadata-/provenance-Getter für einen Katalogeintrag; UI-Präsentation nicht automatisiert.
- Nächster Schritt: get_dataset_info nach ID ohne Rendererpflicht; Ausgabe und eventuell medizinische Inhalte begrenzen.
- Quellen: [AppSupport/Datasets/DatasetInfoView.swift](../AppSupport/Datasets/DatasetInfoView.swift), [AppSupport/Datasets/DatasetProvenanceView.swift](../AppSupport/Datasets/DatasetProvenanceView.swift), [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="windows-immersive"></a>
### Immersive Space und AR-/VR-Stil steuern

- Kennung: `windows.immersive`; Plattformen: visionOS; Kontext: `application`; Wirkung: räumliche Darstellung und Betriebssystem-Lebenszyklus.
- Register: kein spezifischer Command/UI-Registereintrag
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: visionOS-App-/Renderer-Lebenszyklus und Immersionsauswahl; kein Agentenstatus.
- Lücke: Keine Capability für Space-Status, Stil und bestätigtes Öffnen/Schließen. OS-Entscheidungen und Nutzerabbruch sind keine Renderbefehle.
- Nächster Schritt: Immersionsstatus und lokale Lebenszyklusaktionen anbieten; Assistentensitzung vom Space und Datensatz trennen.
- Quellen: [VisionApp/VisionApp.swift](../VisionApp/VisionApp.swift), [VisionApp/OpenDatasetView.swift](../VisionApp/OpenDatasetView.swift), [VisionApp/RenderView.swift](../VisionApp/RenderView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="windows-main"></a>
### Hauptfenstergröße und Fullscreen steuern

- Kennung: `windows.main`; Plattformen: macOS; Kontext: `application`; Wirkung: lokale Fenstergeometrie.
- Register: `BorgVRRecordedAction.resizeWindow`, `BorgVRRecordedAction.setFullscreen`
- MCP: `get_window_state`, `resize_window`, `set_fullscreen`
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): `resize`, `fullscreen`, `getwindowstate`
- Zustandsabfrage: get_window_state mit Punkten, Pixeln, Rahmen, Skalierung und Übergang.
- Lücke: Agent sperrt alle drei Werkzeuge; nicht für iOS-/visionOS-Fenster geeignet.
- Nächster Schritt: macOS-App-Capability anbieten und Fullscreen-/Sheet-/Minimumgrenzen erhalten.
- Quellen: [BORGVR-Services/BorgVRMCP.swift](../BORGVR-Services/BorgVRMCP.swift), [BORGVR-Services/BorgVRMCPServer.swift](../BORGVR-Services/BorgVRMCPServer.swift)
- Vorhandene Testquellen: [Tests/MCPVisualizationTests.swift](../Tests/MCPVisualizationTests.swift)

<a id="windows-panels"></a>
### Render-, TF-, Iso-, Licht-, Objekt-, Mess- und Pinselpanel öffnen

- Kennung: `windows.panels`; Plattformen: macOS, iOS, visionOS; Kontext: `dataset`; Wirkung: lokale Präsentation.
- Register: `DockablePanelID.renderControls`, `DockablePanelID.transferFunctionEditor`, `DockablePanelID.isoEditor`, `DockablePanelID.markerEditor`, `DockablePanelID.measurementEditor`, `DockablePanelID.lightingEditor`, `DockablePanelID.volumeBrushEditor`, `MacRenderShortcut.editor`, `MacRenderShortcut.lighting`, `MacRenderShortcut.objects`, `MacRenderShortcut.measurements`, `MacRenderShortcut.brush`, `MacRenderShortcut.toggleControls`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: DockingController, iOS-Sheets und visionOS-Fensterzustände sind lokale UI-Zustände.
- Lücke: Kein gemeinsamer Panel-Status-/Präsentations-Command; fachliche Änderungen benötigen kein geöffnetes Panel.
- Nächster Schritt: UI-Präsentation separat von fachlichen Commands katalogisieren und anbieten, ohne OS-Fensterplatzierung zu versprechen.
- Quellen: [macOSApp/DockingController.swift](../macOSApp/DockingController.swift), [iOSApp/RenderView.swift](../iOSApp/RenderView.swift), [VisionApp/PrivateApplicationView.swift](../VisionApp/PrivateApplicationView.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

<a id="windows-layout"></a>
### Panels andocken, abdocken, formatieren und Layout speichern

- Kennung: `windows.layout`; Plattformen: macOS; Kontext: `dataset`; Wirkung: lokales Layout und Darstellung.
- Register: `MacRenderShortcut.docking`
- MCP: fehlt
- Native Agentenwerkzeuge: fehlen
- Benannte GSC-Befehle (macOS): keine; Command-Payloads ggf. separat verfügbar
- Zustandsabfrage: DockingController/PanelParameterStorage, kein Agentenvertrag.
- Lücke: Keine Layout-/Panelparameter-/Titelformat-Getter/-Setter.
- Nächster Schritt: Benannte Panel-IDs und validierte Layout-/Formatoperationen ergänzen; native Fensterrestriktionen beachten.
- Quellen: [macOSApp/DockingController.swift](../macOSApp/DockingController.swift), [macOSApp/PanelParameterControls.swift](../macOSApp/PanelParameterControls.swift), [AppSupport/Datasets/PanelParameterStorage.swift](../AppSupport/Datasets/PanelParameterStorage.swift)
- Vorhandene Testquellen: kein spezifischer Test zugeordnet

## Registrierte Einstellungen

Alle folgenden Schlüssel stammen aus den beiden Defaults-Registern. `setSettings`/Archivimport ist keine einzelne typisierte Einstellungsschnittstelle.
MCP bietet derzeit Archiv speichern/laden/zurücksetzen, aber keinen allgemeinen Einstellungs-Getter/-Setter. Der Agent bietet keines davon an.
Weitere lokale Einstellungen (etwa Serverlisten, Panel-Layout, Assistent und Erklärungsdialoge) sind in den Funktionsgruppen gesondert erfasst.

| Schlüssel | Defaults-Register | GSC-Aufzeichnung |
|---|---|---|
| `alphaEpsilon` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `atlasCompression` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `atlasSizeMB` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `autoStartServer` | screen, vision | bewusst lokal/ausgeschlossen |
| `autoloadMeasurements` | screen, vision | bewusst lokal/ausgeschlossen |
| `autoloadObjects` | screen, vision | bewusst lokal/ausgeschlossen |
| `autoloadRenderState` | screen, vision | bewusst lokal/ausgeschlossen |
| `autoloadTF` | screen, vision | bewusst lokal/ausgeschlossen |
| `autostartVoiceInput` | vision | bewusst lokal/ausgeschlossen |
| `borderMode` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `brickOverlap` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `brickSize` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `controllerButtonAAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `controllerButtonBAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `controllerButtonXAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `controllerButtonYAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `dicomResamplingFilter` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `disableFoveation` | vision | aufgezeichnet, ohne Geheimnisse |
| `dropFPS` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `enableCompression` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `enableDatasetServer` | screen, vision | bewusst lokal/ausgeschlossen |
| `enableMCPServer` | screen, vision | bewusst lokal/ausgeschlossen |
| `enableVoiceInput` | vision | bewusst lokal/ausgeschlossen |
| `enableVoiceOutput` | vision | bewusst lokal/ausgeschlossen |
| `enableWebServer` | screen, vision | bewusst lokal/ausgeschlossen |
| `foveationSamplingStrength` | vision | aufgezeichnet, ohne Geheimnisse |
| `hideBuiltInDatasets` | screen, vision | bewusst lokal/ausgeschlossen |
| `importColorCompression` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `initialBricks` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `leftControllerThumbstickXAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `leftControllerThumbstickYAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `leftControllerToolMode` | vision | aufgezeichnet, ohne Geheimnisse |
| `logLevel` | screen | bewusst lokal/ausgeschlossen |
| `makeLocalCopy` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `markerDefaultBlue` | vision | aufgezeichnet, ohne Geheimnisse |
| `markerDefaultColorInitialized` | vision | aufgezeichnet, ohne Geheimnisse |
| `markerDefaultGreen` | vision | aufgezeichnet, ohne Geheimnisse |
| `markerDefaultRed` | vision | aufgezeichnet, ohne Geheimnisse |
| `markerSpawnAtGaze` | vision | aufgezeichnet, ohne Geheimnisse |
| `maxBricksPerGetRequest` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `maxProbingAttempts` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `mcpAccessToken` | screen, vision | bewusst lokal/ausgeschlossen |
| `mcpAllowRemoteConnections` | screen, vision | bewusst lokal/ausgeschlossen |
| `mcpServerCertificateData` | screen, vision | bewusst lokal/ausgeschlossen |
| `mcpServerPort` | screen, vision | bewusst lokal/ausgeschlossen |
| `minHashTableSize` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `normalizeIsoSurfaceExport` | screen | aufgezeichnet, ohne Geheimnisse |
| `opacityAdaptiveSampling` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `oversampling` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `oversamplingMode` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `parallelProjection` | screen | aufgezeichnet, ohne Geheimnisse |
| `progressiveLoading` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `projectMeasurementsOntoVolume` | vision | aufgezeichnet, ohne Geheimnisse |
| `projectObjectsOntoVolume` | vision | aufgezeichnet, ohne Geheimnisse |
| `quantizeImportsTo8Bit` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `quickMarker` | vision | aufgezeichnet, ohne Geheimnisse |
| `quickMarkerDoublePinchInterval` | vision | aufgezeichnet, ohne Geheimnisse |
| `recoveryFPS` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundMode` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundPrimaryAlpha` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundPrimaryBlue` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundPrimaryGreen` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundPrimaryRed` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundSecondaryAlpha` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundSecondaryBlue` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundSecondaryGreen` | screen | aufgezeichnet, ohne Geheimnisse |
| `renderBackgroundSecondaryRed` | screen | aufgezeichnet, ohne Geheimnisse |
| `requestLowResLOD` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `rightControllerThumbstickXAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `rightControllerThumbstickYAction` | vision | aufgezeichnet, ohne Geheimnisse |
| `rightControllerToolMode` | vision | aufgezeichnet, ohne Geheimnisse |
| `sampleJitter` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `screenFieldOfView` | screen | aufgezeichnet, ohne Geheimnisse |
| `screenSpaceError` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `serverPassword` | screen, vision | bewusst lokal/ausgeschlossen |
| `serverPort` | screen, vision | bewusst lokal/ausgeschlossen |
| `sharePlayDisplayName` | screen, vision | bewusst lokal/ausgeschlossen |
| `sharePlayServerPort` | screen, vision | bewusst lokal/ausgeschlossen |
| `sharePlayWebServerPort` | screen, vision | bewusst lokal/ausgeschlossen |
| `shareSpatialStylusPosition` | vision | bewusst lokal/ausgeschlossen |
| `showBrickVisualization` | screen | aufgezeichnet, ohne Geheimnisse |
| `showDatasetBoundingBox` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `showHandsAndAccessories` | vision | aufgezeichnet, ohne Geheimnisse |
| `showLogButton` | screen | aufgezeichnet, ohne Geheimnisse |
| `showModeResetButtons` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `showNotifications` | vision | bewusst lokal/ausgeschlossen |
| `showPanelButtons` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `showPerformanceButton` | screen | aufgezeichnet, ohne Geheimnisse |
| `showProfiling` | vision | aufgezeichnet, ohne Geheimnisse |
| `stopOnMiss` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `stylusStartFunction` | vision | aufgezeichnet, ohne Geheimnisse |
| `stylusToolMode` | vision | aufgezeichnet, ohne Geheimnisse |
| `subbrickSkipping` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `tfMode` | vision | aufgezeichnet, ohne Geheimnisse |
| `timeout` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `uiInteractionModes` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `uiPanelButtons` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `uiRenderModes` | screen, vision | aufgezeichnet, ohne Geheimnisse |
| `webServerCertificateData` | screen, vision | bewusst lokal/ausgeschlossen |
| `webServerPort` | screen, vision | bewusst lokal/ausgeschlossen |
| `webServerUsesTLS` | screen, vision | bewusst lokal/ausgeschlossen |

## Grenzen des Abgleichs

Neue Registereinträge müssen einer Funktionsgruppe zugeordnet werden. Neue freie UI-Aktionen ohne Register werden dadurch nicht automatisch erkannt.
Die Quellenliste muss deshalb bei UI-Änderungen mitgepflegt werden. Ein UI-Button oder ein generischer `writeFiles`-Command ersetzt keinen fachlichen Import-/Exportauftrag.
Betriebssystemdialoge und Hardwareberechtigungen bleiben lokale Vermittlung; die fachliche Aktion soll trotzdem über denselben Command-Service erreichbar werden.
Startarchitektur, fehlende Aufträge und Abnahmekriterien: [Architektur](../AppSupport/Voice/ARCHITECTURE.md).
