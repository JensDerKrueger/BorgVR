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
  case remoteDatasets
  case backgroundServer
  case webServer
  case adHocServer
  case lod

  var id: String { rawValue }

  var title: String {
    switch self {
      case .rendering: return String(localized: "Rendering")
      case .importSettings: return String(localized: "Import")
      case .remoteDatasets: return String(localized: "Remote datasets")
      case .backgroundServer: return String(localized: "Background server")
      case .webServer: return String(localized: "WebGPU web server")
      case .adHocServer: return String(localized: "Ad-hoc server")
      case .lod: return String(localized: "LOD")
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings

  @State private var tempPort = ""
  @State private var tempServerAddress = ""
  @State private var tempServerPassword = ""
  @State private var tempTimeout = ""
  @State private var tempBrickSize = ""
  @State private var tempBrickOverlap = ""
  @State private var tempHashSize = ""
  @State private var tempPixelError = ""
  @State private var tempOversampling = ""
  @State private var validationMessage: String?
  @State private var pendingResetSection: SettingsResetSection?

  var body: some View {
    NavigationStack {
      settingsForm
        .navigationTitle("Settings")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("Back") {
              saveSettings()
              appModel.currentState = .start
            }
          }
        }
        .onAppear(perform: loadTemporaryValues)
        .onDisappear(perform: saveSettings)
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
  }

  private var settingsForm: some View {
    Form {
      renderingSection
      importSection
      remoteDatasetsSection
      backgroundServerSection
      if appSettings.enableDatasetServer {
        webServerSection
      }
      adHocServerSection
      lodSection
      validationSection
    }
  }

  private var renderingSection: some View {
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
      TextField("Oversampling", text: $tempOversampling)
        .keyboardType(.decimalPad)
      Stepper(value: $appSettings.atlasSizeMB, in: 128...AppSettings.maximumAtlasSizeMB, step: 128) {
        Text(String(format: String(localized: "Atlas size: %d MB"), appSettings.atlasSizeMB))
      }
      TextField("Min. hash table size (MB)", text: $tempHashSize)
        .keyboardType(.numberPad)
      Picker("Log-Level", selection: $appSettings.logLevel) {
        ForEach(AppLogLevel.allCases) { level in
          Text(level.label).tag(level.rawValue)
        }
      }
      resetButton(for: .rendering)
    }
  }

  private var importSection: some View {
    Section("Import") {
      TextField("Brick size", text: $tempBrickSize)
        .keyboardType(.numberPad)
      TextField("Overlap", text: $tempBrickOverlap)
        .keyboardType(.numberPad)
      Toggle("Compression", isOn: $appSettings.enableCompression)
      Picker("Borders", selection: $appSettings.borderMode) {
        Text("Zeroes").tag("zeroes")
        Text("Border").tag("border")
        Text("Repeat").tag("repeat")
      }
      resetButton(for: .importSettings)
    }
  }

  private var remoteDatasetsSection: some View {
    Section("Remote datasets") {
      ForEach(appSettings.servers) { server in
        serverRow(for: server)
      }

      TextField("Hostname", text: $tempServerAddress)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Port", text: $tempPort)
        .keyboardType(.numberPad)
      SecureField("Password (optional)", text: $tempServerPassword)
      Button {
        addServer()
      } label: {
        Label("Add server", systemImage: "plus")
      }
      TextField("Timeout", text: $tempTimeout)
        .keyboardType(.decimalPad)
      Toggle("Progressive loading", isOn: $appSettings.progressiveLoading)
      Toggle("Keep local copy", isOn: $appSettings.makeLocalCopy)
      resetButton(for: .remoteDatasets)
    }
  }

  private var backgroundServerSection: some View {
    Section("Background server") {
      Toggle("Enable dataset server", isOn: $appSettings.enableDatasetServer)
      if appSettings.enableDatasetServer {
        Toggle("Start server automatically", isOn: $appSettings.autoStartServer)
        portField("Port", value: $appSettings.serverPort)
        SecureField("Server password (optional)", text: $appSettings.serverPassword)
        Stepper(value: $appSettings.maxBricksPerGetRequest, in: 1...1000) {
          Text(String(format: String(localized: "Max. bricks per request: %d"), appSettings.maxBricksPerGetRequest))
        }
      }
      resetButton(for: .backgroundServer)
    }
  }

  private var webServerSection: some View {
    Section("WebGPU web server") {
      Toggle("Enable WebGPU web server", isOn: $appSettings.enableWebServer)
      Toggle("Use HTTPS", isOn: $appSettings.webServerUsesTLS)
      if !appSettings.webServerUsesTLS {
        Text("Without HTTPS, only localhost connections are possible.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if appSettings.webServerUsesTLS {
        WebServerCertificateControls(
          certificateData: $appSettings.webServerCertificateData
        )
      }
      portField("WebGPU web server port", value: $appSettings.webServerPort)
      resetButton(for: .webServer)
    }
  }

  private var adHocServerSection: some View {
    Section("Ad-hoc server") {
      portField("Ad-hoc dataset server port", value: $appSettings.sharePlayServerPort)
      portField("Ad-hoc WebGPU web server port", value: $appSettings.sharePlayWebServerPort)
      resetButton(for: .adHocServer)
    }
  }

  private var lodSection: some View {
    Section("LOD") {
      TextField("Screen-space pixel error", text: $tempPixelError)
        .keyboardType(.decimalPad)
      Stepper(value: $appSettings.initialBricks, in: 0...20000, step: 100) {
        Text(String(format: String(localized: "Initial bricks: %d"), appSettings.initialBricks))
      }
      Stepper(value: $appSettings.maxProbingAttempts, in: 1...512) {
        Text(String(format: String(localized: "Max. probing attempts: %d"), appSettings.maxProbingAttempts))
      }
      Toggle("Request low-res LOD", isOn: $appSettings.requestLowResLOD)
      Toggle("Stop on missing brick", isOn: $appSettings.stopOnMiss)
      if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
        Stepper(value: $appSettings.dropFPS, in: 1...120) {
          Text(String(format: String(localized: "Drop FPS: %d"), appSettings.dropFPS))
        }
        Stepper(value: $appSettings.recoveryFPS, in: 1...120) {
          Text(String(format: String(localized: "Recovery FPS: %d"), appSettings.recoveryFPS))
        }
      }
      resetButton(for: .lod)
    }
  }

  @ViewBuilder
  private var validationSection: some View {
    if let validationMessage {
      Section {
        Text(validationMessage)
          .foregroundStyle(.red)
      }
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

  private func serverRow(for server: StoredServer) -> some View {
    HStack {
      Text(serverLabel(for: server))
      Spacer()
      Button(role: .destructive) {
        removeServer(server)
      } label: {
        Image(systemName: "trash")
      }
    }
  }

  private func serverLabel(for server: StoredServer) -> String {
    if server.password.isEmpty {
      return "\(server.address):\(server.port)"
    }
    return "\(server.address):\(server.port) \(String(localized: "(Password)"))"
  }

  private func portField(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
    HStack {
      Text(title)
      Spacer()
      TextField(title, value: clampedPortBinding(value), formatter: portNumberFormatter)
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
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

  private func removeServer(_ server: StoredServer) {
    appSettings.servers.removeAll { $0.id == server.id }
  }

  private func loadTemporaryValues() {
    tempPort = "12345"
    tempServerAddress = ""
    tempServerPassword = ""
    tempTimeout = String(appSettings.timeout)
    tempBrickSize = String(appSettings.brickSize)
    tempBrickOverlap = String(appSettings.brickOverlap)
    tempHashSize = String(appSettings.minHashTableSize)
    tempPixelError = String(appSettings.screenSpaceError)
    tempOversampling = String(appSettings.oversampling)
  }

  private func saveSettings() {
    validationMessage = nil
    if let timeout = Double(tempTimeout.replacingOccurrences(of: ",", with: ".")), timeout > 0 {
      appSettings.timeout = timeout
    }
    if let brickSize = Int(tempBrickSize), brickSize >= 1 + appSettings.brickOverlap * 2 {
      appSettings.brickSize = brickSize
    }
    if let overlap = Int(tempBrickOverlap), overlap >= 1, appSettings.brickSize - overlap * 2 >= 1 {
      appSettings.brickOverlap = overlap
    }
    if let hashSize = Int(tempHashSize), hashSize >= 1 {
      appSettings.minHashTableSize = hashSize
    }
    if let pixelError = Double(tempPixelError.replacingOccurrences(of: ",", with: ".")), pixelError > 0 {
      appSettings.screenSpaceError = pixelError
    }
    if let oversampling = Double(tempOversampling.replacingOccurrences(of: ",", with: ".")), oversampling > 0 {
      appSettings.oversampling = oversampling
    }
  }

  private func addServer() {
    guard !tempServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let port = UInt16(tempPort) else {
      validationMessage = String(localized: "Server requires a hostname and a port between 0 and 65535.")
      return
    }
    appSettings.servers.append(
      StoredServer(
        address: tempServerAddress.trimmingCharacters(in: .whitespacesAndNewlines),
        port: Int(port),
        password: tempServerPassword
      )
    )
    tempServerAddress = ""
    tempServerPassword = ""
    validationMessage = nil
  }

  private func resetToDefaults(_ section: SettingsResetSection) {
    switch section {
      case .rendering:
        appSettings.resetRenderingDefaults()
      case .importSettings:
        appSettings.resetImportDefaults()
      case .remoteDatasets:
        appSettings.resetRemoteDefaults()
        tempPort = "12345"
        tempServerAddress = ""
        tempServerPassword = ""
      case .backgroundServer:
        appSettings.resetBackgroundServerDefaults()
      case .webServer:
        appSettings.resetWebServerDefaults()
      case .adHocServer:
        appSettings.resetAdHocServerDefaults()
      case .lod:
        appSettings.resetLODDefaults()
    }
    validationMessage = nil
    loadTemporaryValues()
  }
}
