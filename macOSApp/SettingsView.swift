import SwiftUI

private let portNumberFormatter: NumberFormatter = {
  let formatter = NumberFormatter()
  formatter.numberStyle = .none
  formatter.usesGroupingSeparator = false
  formatter.minimum = 1
  formatter.maximum = 65535
  return formatter
}()

private enum SettingsResetSection: String, Identifiable {
  case rendering
  case importSettings
  case lod
  case backgroundServer
  case adHocServer
  case externalDataSources

  var id: String { rawValue }

  var title: String {
    switch self {
      case .rendering: return "Rendering"
      case .importSettings: return "Import"
      case .lod: return "LOD"
      case .backgroundServer: return "Background server"
      case .adHocServer: return "Ad-hoc server"
      case .externalDataSources: return "External data sources"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel

  @State private var serverAddress = ""
  @State private var serverPort = "12345"
  @State private var serverPassword = ""
  @State private var showDataDirectoryPicker = false
  @State private var pendingResetSection: SettingsResetSection?

  var body: some View {
    Form {
      Section("Rendering") {
        Toggle("Automatically load/save transfer functions", isOn: $appSettings.autoloadTF)
        Picker("Oversampling", selection: $appSettings.oversamplingMode) {
          Text("Static").tag(OversamplingMode.staticMode.rawValue)
          Text("Dynamic").tag(OversamplingMode.dynamicMode.rawValue)
        }
        Picker("Background", selection: $appSettings.renderBackgroundMode) {
          ForEach(RenderBackgroundMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        if appSettings.renderBackgroundMode == RenderBackgroundMode.solid.rawValue {
          ColorPicker("Color", selection: Binding(
            get: { appSettings.renderBackgroundPrimaryColor },
            set: { appSettings.renderBackgroundPrimaryColor = $0 }
          ), supportsOpacity: true)
        }
        if appSettings.renderBackgroundMode == RenderBackgroundMode.gradient.rawValue {
          ColorPicker("Top color", selection: Binding(
            get: { appSettings.renderBackgroundPrimaryColor },
            set: { appSettings.renderBackgroundPrimaryColor = $0 }
          ), supportsOpacity: true)
          ColorPicker("Bottom color", selection: Binding(
            get: { appSettings.renderBackgroundSecondaryColor },
            set: { appSettings.renderBackgroundSecondaryColor = $0 }
          ), supportsOpacity: true)
        }
        Stepper(value: $appSettings.atlasSizeMB, in: 128...AppSettings.maximumAtlasSizeMB, step: 128) {
          Text("Atlas size: \(appSettings.atlasSizeMB) MB")
        }
        Stepper(value: $appSettings.minHashTableSize, in: 1...1024) {
          Text("Min. hash table size: \(appSettings.minHashTableSize) MB")
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
          Text("Brick size: \(storedAppModel.brickSize)")
        }
        Stepper(value: $storedAppModel.brickOverlap, in: 1...16) {
          Text("Overlap: \(storedAppModel.brickOverlap)")
        }
        Toggle("Compression", isOn: $storedAppModel.enableCompression)
        Picker("Borders", selection: $storedAppModel.borderModeString) {
          Text("Zeroes").tag("zeroes")
          Text("Border").tag("border")
          Text("Repeat").tag("repeat")
        }
        resetButton(for: .importSettings)
      }

      Section("LOD") {
        Stepper(value: $appSettings.screenSpaceError, in: 0.05...10, step: 0.05) {
          Text(String(format: "Screen-space pixel error: %.2f", appSettings.screenSpaceError))
        }
        Stepper(value: $appSettings.initialBricks, in: 0...20000, step: 100) {
          Text("Initial bricks: \(appSettings.initialBricks)")
        }
        Stepper(value: $appSettings.maxProbingAttempts, in: 1...512) {
          Text("Max. probing attempts: \(appSettings.maxProbingAttempts)")
        }
        Toggle("Request low-res LOD", isOn: $appSettings.requestLowResLOD)
        Toggle("Stop on missing brick", isOn: $appSettings.stopOnMiss)
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

      Section("Background server") {
        Toggle("Enable dataset server", isOn: $storedAppModel.enableDatasetServer)
        if storedAppModel.enableDatasetServer {
          Toggle("Start server automatically", isOn: $storedAppModel.autoStartServer)
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
            .help("Choose data directory")
          }
          portField("Port", value: $storedAppModel.port)
          SecureField("Server password (optional)", text: $storedAppModel.serverPassword)
          Toggle("Start WebGPU web server", isOn: $storedAppModel.enableWebServer)
          Toggle("Use HTTPS", isOn: $storedAppModel.webServerUsesTLS)
          if !storedAppModel.webServerUsesTLS {
            Text("Without HTTPS, only localhost connections are possible.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if storedAppModel.webServerUsesTLS {
            WebServerCertificateControls(
              certificateData: $storedAppModel.webServerCertificateData
            )
          }
          portField("WebGPU web server port", value: $storedAppModel.webServerPort)
          Stepper(value: $storedAppModel.maxBricksPerGetRequest, in: 1...1000) {
            Text("Max. bricks per request: \(storedAppModel.maxBricksPerGetRequest)")
          }
        }
        resetButton(for: .backgroundServer)
      }

      Section("Ad-hoc server") {
        portField("Ad-hoc dataset server port", value: $storedAppModel.sharePlayServerPort)
        portField("Ad-hoc WebGPU web server port", value: $storedAppModel.sharePlayWebServerPort)
        resetButton(for: .adHocServer)
      }

      Section("External data sources") {
        ForEach(appSettings.servers) { server in
          serverRow(for: server)
        }

        HStack {
          TextField("Server address", text: $serverAddress)
          TextField("Port", text: $serverPort)
            .frame(width: 90)
          SecureField("Password", text: $serverPassword)
            .frame(width: 160)
          Button {
            addRemoteServer()
          } label: {
            Image(systemName: "plus")
          }
          .help("Add server")
        }
        resetButton(for: .externalDataSources)
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Settings")
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
        Button("Back") {
          appModel.currentState = .start
        }
      }
    }
    .confirmationDialog(
      resetConfirmationTitle,
      isPresented: isResetConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) {
        if let pendingResetSection {
          resetToDefaults(pendingResetSection)
        }
        pendingResetSection = nil
      }
      Button("Cancel", role: .cancel) {}
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
      return "Reset settings?"
    }
    return "Reset \(pendingResetSection.title)?"
  }

  private var resetConfirmationMessage: String {
    guard let pendingResetSection else {
      return "The section will be reset to its default values."
    }
    return "The \(pendingResetSection.title) section will be reset to its default values."
  }

  private func resetButton(for section: SettingsResetSection) -> some View {
    Button(role: .destructive) {
      pendingResetSection = section
    } label: {
      Label("Reset \(section.title)", systemImage: "arrow.counterclockwise")
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
        port: port,
        password: serverPassword
      )
    )
    serverAddress = ""
    serverPassword = ""
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
      .help("Remove server")
    }
  }

  private func serverLabel(for server: StoredServer) -> String {
    if server.password.isEmpty {
      return "\(server.address):\(server.port)"
    }
    return "\(server.address):\(server.port) \(String(localized: "(Password)"))"
  }

  private func portField(_ title: String, value: Binding<Int>) -> some View {
    HStack {
      Text(title)
      Spacer()
      TextField(title, value: clampedPortBinding(value), formatter: portNumberFormatter)
        .multilineTextAlignment(.trailing)
        .textFieldStyle(.roundedBorder)
        .frame(width: 110)
    }
  }

  private func clampedPortBinding(_ value: Binding<Int>) -> Binding<Int> {
    Binding(
      get: { value.wrappedValue },
      set: { newValue in
        value.wrappedValue = min(65535, max(1, newValue))
      }
    )
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
        appSettings.maxBricksPerGetRequest = AppSettings.values["maxBricksPerGetRequest"] as? Int ?? 20
        storedAppModel.resetBackgroundServerDefaults()
      case .adHocServer:
        storedAppModel.resetAdHocServerDefaults()
      case .externalDataSources:
        appSettings.servers = []
        serverAddress = ""
        serverPort = "12345"
        serverPassword = ""
    }
  }
}
