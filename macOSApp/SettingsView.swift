import SwiftUI

private enum SettingsResetSection: String, Identifiable {
  case rendering
  case importSettings
  case lod
  case backgroundServer
  case externalDataSources

  var id: String { rawValue }

  var title: String {
    switch self {
      case .rendering: return "Rendering"
      case .importSettings: return "Import"
      case .lod: return "LOD"
      case .backgroundServer: return "Hintergrundserver"
      case .externalDataSources: return "Externe Datenquellen"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel

  @State private var serverAddress = ""
  @State private var serverPort = "12345"
  @State private var showDataDirectoryPicker = false
  @State private var pendingResetSection: SettingsResetSection?

  var body: some View {
    Form {
      Section("Rendering") {
        Toggle("Transfer Functions automatisch laden/speichern", isOn: $appSettings.autoloadTF)
        Picker("Oversampling", selection: $appSettings.oversamplingMode) {
          Text("Statisch").tag(OversamplingMode.staticMode.rawValue)
          Text("Dynamisch").tag(OversamplingMode.dynamicMode.rawValue)
        }
        Picker("Hintergrund", selection: $appSettings.renderBackgroundMode) {
          ForEach(RenderBackgroundMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        if appSettings.renderBackgroundMode == RenderBackgroundMode.solid.rawValue {
          ColorPicker("Farbe", selection: Binding(
            get: { appSettings.renderBackgroundPrimaryColor },
            set: { appSettings.renderBackgroundPrimaryColor = $0 }
          ), supportsOpacity: true)
        }
        if appSettings.renderBackgroundMode == RenderBackgroundMode.gradient.rawValue {
          ColorPicker("Farbe oben", selection: Binding(
            get: { appSettings.renderBackgroundPrimaryColor },
            set: { appSettings.renderBackgroundPrimaryColor = $0 }
          ), supportsOpacity: true)
          ColorPicker("Farbe unten", selection: Binding(
            get: { appSettings.renderBackgroundSecondaryColor },
            set: { appSettings.renderBackgroundSecondaryColor = $0 }
          ), supportsOpacity: true)
        }
        Stepper(value: $appSettings.atlasSizeMB, in: 128...AppSettings.maximumAtlasSizeMB, step: 128) {
          Text("Atlasgröße: \(appSettings.atlasSizeMB) MB")
        }
        Stepper(value: $appSettings.minHashTableSize, in: 1...1024) {
          Text("Min. Hash-Table-Größe: \(appSettings.minHashTableSize) MB")
        }
        Picker("Log-Level", selection: $appSettings.logLevel) {
          ForEach(AppLogLevel.allCases) { level in
            Text(level.label).tag(level.rawValue)
          }
        }
        resetButton(for: .rendering)
      }

      Section("Import") {
        Stepper(value: $storedAppModel.brickSize, in: 8...512, step: 8) {
          Text("Brick-Größe: \(storedAppModel.brickSize)")
        }
        Stepper(value: $storedAppModel.brickOverlap, in: 1...16) {
          Text("Überlappung: \(storedAppModel.brickOverlap)")
        }
        Toggle("Kompression", isOn: $storedAppModel.enableCompression)
        Picker("Ränder", selection: $storedAppModel.borderModeString) {
          Text("Nullen").tag("zeroes")
          Text("Rand").tag("border")
          Text("Wiederholen").tag("repeat")
        }
        resetButton(for: .importSettings)
      }

      Section("LOD") {
        Stepper(value: $appSettings.screenSpaceError, in: 0.05...10, step: 0.05) {
          Text(String(format: "Screen-Space-Pixelfehler: %.2f", appSettings.screenSpaceError))
        }
        Stepper(value: $appSettings.initialBricks, in: 0...20000, step: 100) {
          Text("Initiale Bricks: \(appSettings.initialBricks)")
        }
        Stepper(value: $appSettings.maxProbingAttempts, in: 1...512) {
          Text("Max. Suchversuche: \(appSettings.maxProbingAttempts)")
        }
        Toggle("Low-res LOD mit anfordern", isOn: $appSettings.requestLowResLOD)
        Toggle("Bei fehlendem Brick stoppen", isOn: $appSettings.stopOnMiss)
        if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
          Stepper(value: $appSettings.dropFPS, in: 1...120) {
            Text("Drop FPS: \(appSettings.dropFPS)")
          }
          Stepper(value: $appSettings.recoveryFPS, in: 1...120) {
            Text("Recovery FPS: \(appSettings.recoveryFPS)")
          }
        }
        resetButton(for: .lod)
      }

      Section("Hintergrundserver") {
        Toggle("Server automatisch starten", isOn: $storedAppModel.autoStartServer)
        HStack {
          Text(storedAppModel.dataDirectory)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button {
            showDataDirectoryPicker = true
          } label: {
            Image(systemName: "folder")
          }
          .help("Datenverzeichnis auswählen")
        }
        Stepper(value: $storedAppModel.port, in: 1...65535) {
          Text("Port: \(storedAppModel.port)")
        }
        Stepper(value: $storedAppModel.sharePlayServerPort, in: 1...65535) {
          Text("Ad-hoc Dataset-Server-Port: \(storedAppModel.sharePlayServerPort)")
        }
        Stepper(value: $storedAppModel.maxBricksPerGetRequest, in: 1...1000) {
          Text("Max. Bricks pro Anfrage: \(storedAppModel.maxBricksPerGetRequest)")
        }
        resetButton(for: .backgroundServer)
      }

      Section("Externe Datenquellen") {
        ForEach(appSettings.servers) { server in
          serverRow(for: server)
        }

        HStack {
          TextField("Serveradresse", text: $serverAddress)
          TextField("Port", text: $serverPort)
            .frame(width: 90)
          Button {
            addRemoteServer()
          } label: {
            Image(systemName: "plus")
          }
          .help("Server hinzufügen")
        }
        resetButton(for: .externalDataSources)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Einstellungen")
    .fileImporter(
      isPresented: $showDataDirectoryPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      if case let .success(urls) = result,
         let selectedURL = urls.first {
        storedAppModel.setDataDirectoryURL(selectedURL)
      }
    }
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Zurück") {
          appModel.currentState = .start
        }
      }
    }
    .confirmationDialog(
      resetConfirmationTitle,
      isPresented: isResetConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Zurücksetzen", role: .destructive) {
        if let pendingResetSection {
          resetToDefaults(pendingResetSection)
        }
        pendingResetSection = nil
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(resetConfirmationMessage)
    }
  }

  private var isResetConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingResetSection != nil },
      set: { isPresented in
        if !isPresented {
          pendingResetSection = nil
        }
      }
    )
  }

  private var resetConfirmationTitle: String {
    guard let pendingResetSection else {
      return "Einstellungen zurücksetzen?"
    }
    return "\(pendingResetSection.title) zurücksetzen?"
  }

  private var resetConfirmationMessage: String {
    guard let pendingResetSection else {
      return "Der Abschnitt wird auf seine Standardwerte zurückgesetzt."
    }
    return "Der Abschnitt \(pendingResetSection.title) wird auf seine Standardwerte zurückgesetzt."
  }

  private func resetButton(for section: SettingsResetSection) -> some View {
    Button(role: .destructive) {
      pendingResetSection = section
    } label: {
      Label("\(section.title) zurücksetzen", systemImage: "arrow.counterclockwise")
    }
  }

  private func addRemoteServer() {
    let trimmedAddress = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAddress.isEmpty,
          let port = Int(serverPort),
          (1...65535).contains(port),
          !appSettings.servers.contains(where: { $0.address == trimmedAddress && $0.port == port }) else {
      return
    }
    appSettings.servers.append(
      StoredServer(
        address: trimmedAddress,
        port: port
      )
    )
    serverAddress = ""
  }

  private func serverRow(for server: StoredServer) -> some View {
    HStack {
      Text(serverLabel(for: server))
      Spacer()
      Button(role: .destructive) {
        removeRemoteServer(server)
      } label: {
        Image(systemName: "trash")
      }
      .help("Server entfernen")
    }
  }

  private func serverLabel(for server: StoredServer) -> String {
    "\(server.address):\(server.port)"
  }

  private func removeRemoteServer(_ server: StoredServer) {
    appSettings.servers.removeAll { $0.id == server.id }
  }

  private func resetToDefaults(_ section: SettingsResetSection) {
    switch section {
      case .rendering:
        appSettings.resetRenderingDefaults()
      case .importSettings:
        appSettings.resetImportDefaults()
        storedAppModel.resetImportDefaults()
      case .lod:
        appSettings.resetLODDefaults()
      case .backgroundServer:
        appSettings.sharePlayServerPort = AppSettings.values["sharePlayServerPort"] as? Int ?? 12346
        appSettings.maxBricksPerGetRequest = AppSettings.values["maxBricksPerGetRequest"] as? Int ?? 20
        storedAppModel.resetBackgroundServerDefaults()
      case .externalDataSources:
        appSettings.servers = []
        serverAddress = ""
        serverPort = "12345"
    }
  }
}
