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

private enum ServerConnectionTestResult {
  case success(datasetCount: Int, transferFunctionCount: Int)
  case failure(String)
}

private enum SettingsPage: String, CaseIterable, Identifiable {
  case general
  case rendering
  case importSettings
  case remoteDatasets
  case localServer
  case sharePlay
  case lod

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
      case .general: "General"
      case .rendering: "Rendering"
      case .importSettings: "Import"
      case .remoteDatasets: "Remote datasets"
      case .localServer: "Local server"
      case .sharePlay: "SharePlay"
      case .lod: "LOD"
    }
  }

  var systemImage: String {
    switch self {
      case .general: "gearshape"
      case .rendering: "paintpalette"
      case .importSettings: "square.and.arrow.down"
      case .remoteDatasets: "network"
      case .localServer: "server.rack"
      case .sharePlay: "shareplay"
      case .lod: "square.stack.3d.up"
    }
  }
}

struct SettingsView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var updateChecker: AppStoreUpdateChecker

  @State private var tempPort = ""
  @State private var tempServerAddress = ""
  @State private var tempServerPassword = ""
  @State private var tempTimeout = ""
  @State private var tempBrickSize = ""
  @State private var tempBrickOverlap = ""
  @State private var tempHashSize = ""
  @State private var tempPixelError = ""
  @State private var validationMessage: String?
  @State private var showingAddServerSheet = false
  @State private var addServerValidationMessage: String?
  @State private var isTestingServerConnection = false
  @State private var serverConnectionTestResult: ServerConnectionTestResult?
  @State private var pendingServerDeletion: StoredServer?
  @State private var pendingResetSection: SettingsResetSection?
  @State private var selectedSettingsPage: SettingsPage?

  var body: some View {
    GeometryReader { proxy in
      let layout = AdaptiveLayout(
        size: proxy.size,
        safeAreaInsets: proxy.safeAreaInsets,
        horizontalSizeClass: horizontalSizeClass,
        verticalSizeClass: verticalSizeClass
      )

      settingsNavigation(isWideLayout: layout.isRegularWidth)
    }
    .onAppear(perform: loadTemporaryValues)
    .onDisappear(perform: saveSettings)
    .sheet(isPresented: $showingAddServerSheet) {
      addServerSheet
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
    .alert(
      "Delete server?",
      isPresented: isServerDeleteConfirmationPresented,
    ) {
      Button("Delete", role: .destructive) {
        if let pendingServerDeletion {
          removeServer(pendingServerDeletion)
        }
        pendingServerDeletion = nil
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This remote server will be removed from the list.")
    }
  }

  private func settingsNavigation(isWideLayout: Bool) -> some View {
    NavigationSplitView {
      settingsSidebar
    } detail: {
      settingsDetail(for: selectedSettingsPage ?? .rendering)
    }
    .navigationSplitViewStyle(.balanced)
    .onAppear {
      if isWideLayout, selectedSettingsPage == nil {
        selectedSettingsPage = .rendering
      }
    }
    .onChange(of: isWideLayout) { _, isWide in
      if isWide, selectedSettingsPage == nil {
        selectedSettingsPage = .rendering
      }
    }
  }

  private var settingsSidebar: some View {
    List(selection: $selectedSettingsPage) {
      Section {
        ForEach(SettingsPage.allCases) { page in
          NavigationLink(value: page) {
            settingsCategoryLabel(page.title, systemImage: page.systemImage)
          }
        }
      }
      validationSection
    }
    .navigationTitle("Settings")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          saveSettings()
          appModel.currentState = .start
        } label: {
          Label("Back", systemImage: "chevron.backward")
        }
      }
    }
  }

  @ViewBuilder
  private func settingsDetail(for page: SettingsPage) -> some View {
    switch page {
      case .general:
        settingsPage(
          title: page.title,
          description: "Configure general application behavior, including automatic checks for new BorgVR versions in the App Store."
        ) {
          Section("Updates") {
            Toggle(
              "Automatically check for updates",
              isOn: $updateChecker.checksEnabled
            )
            Text("BorgVR periodically checks the App Store for new versions and displays a notification when an update is available.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      case .rendering:
        settingsPage(
          title: page.title,
          description: "This page contains settings for the BorgVR rendering system. Some options, such as the background color, are mostly cosmetic, while others, such as the atlas size, can have a major impact on performance. If renderer problems occur, you can return this section to the default settings, which are suitable for most cases."
        ) {
          renderingSection
        }
      case .importSettings:
        settingsPage(
          title: page.title,
          description: "This page controls the parameters used when importing and converting datasets. Datasets that have already been converted are not affected by these settings."
        ) {
          importSection
        }
      case .remoteDatasets:
        settingsPage(
          title: page.title,
          description: "If you have access to one or more central dataset servers, you can configure them here. The server details are provided by the server operator. More information about dataset servers in general, and about running a dedicated server yourself, is available on the support website."
        ) {
          remoteDatasetsSection
        }
      case .localServer:
        settingsPage(
          title: page.title,
          description: "You can share your local datasets with other users directly from this device, without running a dedicated server. You can start a general dataset server from this app and share the device address with other users. During SharePlay collaboration, BorgVR can also create a session-specific server that shares data only with the SharePlay participants."
        ) {
          backgroundServerSection
          if appSettings.enableDatasetServer {
            webServerSection
          }
          adHocServerSection
        }
      case .sharePlay:
        settingsPage(
          title: page.title,
          description: "Choose how you appear to other people during SharePlay collaboration. Your display name is shared only with participants in the current session."
        ) {
          Section("Identity") {
            TextField("SharePlay display name", text: $appSettings.sharePlayDisplayName)
              .textInputAutocapitalization(.words)
          }
        }
      case .lod:
        settingsPage(
          title: page.title,
          description: "This page controls BorgVR's level-of-detail system. These settings allow fine tuning between visual quality and rendering performance."
        ) {
          lodSection
        }
    }
  }

  private func settingsPage<Content: View>(
    title: LocalizedStringKey,
    description: LocalizedStringKey,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    Form {
      settingsDescriptionSection(description)
      content()
      validationSection
    }
    .navigationTitle(title)
    .onDisappear(perform: saveSettings)
  }

  private func settingsCategoryLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
  }

  private func settingsDescriptionSection(_ description: LocalizedStringKey) -> some View {
    Section {
      Text(description)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var renderingSection: some View {
    Section("General") {
      Toggle("Automatically load/save transfer functions", isOn: $appSettings.autoloadTF)
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
    }

    Section("Advanced") {
      Picker("Oversampling mode", selection: $appSettings.oversamplingMode) {
        Text("Static").tag(OversamplingMode.staticMode.rawValue)
        Text("Dynamic").tag(OversamplingMode.dynamicMode.rawValue)
      }
      Stepper(value: $appSettings.oversampling, in: 0.1...8.0, step: 0.1) {
        Text(String(format: String(localized: "Oversampling factor: %.1f"), appSettings.oversampling))
      }
      if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
        Stepper(value: $appSettings.dropFPS, in: 1...240) {
          Text(String(format: String(localized: "Drop FPS: %d fps"), appSettings.dropFPS))
        }
        Stepper(value: $appSettings.recoveryFPS, in: 1...240) {
          Text(String(format: String(localized: "Recovery FPS: %d fps"), appSettings.recoveryFPS))
        }
      }
      Toggle("Randomized sample phase", isOn: $appSettings.sampleJitter)
      Stepper(value: $appSettings.atlasSizeMB, in: 128...AppSettings.maximumAtlasSizeMB, step: 128) {
        Text(String(format: String(localized: "Atlas size: %d MB"), appSettings.atlasSizeMB))
      }
      textFieldRow("Min. hash table size (MB)", text: $tempHashSize, keyboardType: .numberPad)
      Picker("Log-Level", selection: $appSettings.logLevel) {
        ForEach(AppLogLevel.allCases) { level in
          Text(level.label).tag(level.rawValue)
        }
      }
      resetButton(for: .rendering)
    }
  }

  private var importSection: some View {
    Section {
      textFieldRow("Brick size (voxels)", text: $tempBrickSize, keyboardType: .numberPad)
      textFieldRow("Overlap (voxels)", text: $tempBrickOverlap, keyboardType: .numberPad)
      Toggle("Compression", isOn: $appSettings.enableCompression)
      Picker("Borders", selection: $appSettings.borderMode) {
        Text("Zeroes").tag("zeroes")
        Text("Border").tag("border")
        Text("Repeat").tag("repeat")
      }
      resetButton(for: .importSettings)
    }
  }

  @ViewBuilder
  private var remoteDatasetsSection: some View {
    Section("Configured servers") {
      if appSettings.servers.isEmpty {
        Text("No remote servers configured.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(appSettings.servers) { server in
          serverRow(for: server)
        }
      }

      Button {
        beginAddingServer()
      } label: {
        Label("Add server", systemImage: "plus")
      }
    }

    Section("Loading") {
      textFieldRow("Timeout (seconds)", text: $tempTimeout, keyboardType: .decimalPad)
      Toggle("Progressive loading", isOn: $appSettings.progressiveLoading)
      Toggle("Keep local copy", isOn: $appSettings.makeLocalCopy)
    }

    Section {
      resetButton(for: .remoteDatasets)
    }
  }

  private var addServerSheet: some View {
    NavigationStack {
      Form {
        Section("Server") {
          textFieldRow(
            "Hostname",
            text: $tempServerAddress,
            keyboardType: .URL,
            textInputAutocapitalization: .never,
            autocorrectionDisabled: true
          )
          textFieldRow("Port", text: $tempPort, keyboardType: .numberPad)
          secureFieldRow("Password (optional)", text: $tempServerPassword)
        }

        if let addServerValidationMessage {
          Section {
            Text(addServerValidationMessage)
              .foregroundStyle(.red)
          }
        }

        Section {
          Button {
            testServerConnection()
          } label: {
            if isTestingServerConnection {
              HStack {
                ProgressView()
                Text("Testing connection ...")
              }
            } else {
              Label("Test connection", systemImage: "network")
            }
          }
          .disabled(isTestingServerConnection)

          if let serverConnectionTestResult {
            serverConnectionTestResultView(serverConnectionTestResult)
          }
        }
      }
      .navigationTitle("Add server")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            showingAddServerSheet = false
          } label: {
            Label("Cancel", systemImage: "xmark")
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button {
            if addServer() {
              showingAddServerSheet = false
            }
          } label: {
            Label("Add", systemImage: "plus")
          }
        }
      }
    }
  }

  private var backgroundServerSection: some View {
    Section("Background server") {
      Toggle("Enable dataset server", isOn: $appSettings.enableDatasetServer)
      if appSettings.enableDatasetServer {
        Toggle("Start server automatically", isOn: $appSettings.autoStartServer)
        portField("Port", value: $appSettings.serverPort)
        secureFieldRow("Server password (optional)", text: $appSettings.serverPassword)
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
    Section {
      textFieldRow("Screen-space pixel error (pixels)", text: $tempPixelError, keyboardType: .decimalPad)
      Stepper(value: $appSettings.initialBricks, in: 0...20000, step: 100) {
        Text(String(format: String(localized: "Initial bricks: %d"), appSettings.initialBricks))
      }
      Stepper(value: $appSettings.maxProbingAttempts, in: 1...512) {
        Text(String(format: String(localized: "Max. probing attempts: %d"), appSettings.maxProbingAttempts))
      }
      Toggle("Request low-res LOD", isOn: $appSettings.requestLowResLOD)
      Toggle("Stop on missing brick", isOn: $appSettings.stopOnMiss)
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

  private var isServerDeleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingServerDeletion != nil },
      set: { isPresented in
        if !isPresented {
          pendingServerDeletion = nil
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
        pendingServerDeletion = server
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
    }
  }

  @ViewBuilder
  private func serverConnectionTestResultView(_ result: ServerConnectionTestResult) -> some View {
    switch result {
      case let .success(datasetCount, transferFunctionCount):
        Label {
          Text(
            String(
              format: String(localized: "Connection successful: %d datasets, %d transfer functions available."),
              datasetCount,
              transferFunctionCount
            )
          )
        } icon: {
          Image(systemName: "checkmark.circle.fill")
        }
        .foregroundStyle(.green)
      case let .failure(message):
        Label(message, systemImage: "xmark.octagon.fill")
          .foregroundStyle(.red)
    }
  }

  private func serverLabel(for server: StoredServer) -> String {
    if server.password.isEmpty {
      return "\(server.address):\(server.port)"
    }
    return "\(server.address):\(server.port) \(String(localized: "(Password)"))"
  }

  private func textFieldRow(
    _ title: LocalizedStringKey,
    text: Binding<String>,
    keyboardType: UIKeyboardType,
    textInputAutocapitalization: TextInputAutocapitalization? = nil,
    autocorrectionDisabled: Bool = false
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      TextField("", text: text)
        .keyboardType(keyboardType)
        .textInputAutocapitalization(textInputAutocapitalization)
        .autocorrectionDisabled(autocorrectionDisabled)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 180)
    }
  }

  private func secureFieldRow(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
    HStack {
      Text(title)
      Spacer()
      SecureField("", text: text)
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: 180)
    }
  }

  private func portField(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
    HStack {
      Text(title)
      Spacer()
      TextField("", value: clampedPortBinding(value), formatter: portNumberFormatter)
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

  private func beginAddingServer() {
    tempServerAddress = ""
    tempPort = String(BorgVRSharedDefaults.datasetServerPort)
    tempServerPassword = ""
    addServerValidationMessage = nil
    serverConnectionTestResult = nil
    isTestingServerConnection = false
    showingAddServerSheet = true
  }

  private func loadTemporaryValues() {
    tempPort = String(BorgVRSharedDefaults.datasetServerPort)
    tempServerAddress = ""
    tempServerPassword = ""
    tempTimeout = String(appSettings.timeout)
    tempBrickSize = String(appSettings.brickSize)
    tempBrickOverlap = String(appSettings.brickOverlap)
    tempHashSize = String(appSettings.minHashTableSize)
    tempPixelError = String(appSettings.screenSpaceError)
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
  }

  private func addServer() -> Bool {
    let trimmedAddress = tempServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAddress.isEmpty,
          let port = UInt16(tempPort),
          port > 0 else {
      addServerValidationMessage = String(localized: "Server requires a hostname and a port between 1 and 65535.")
      return false
    }
    appSettings.servers.append(
      StoredServer(
        address: trimmedAddress,
        port: Int(port),
        password: tempServerPassword
      )
    )
    tempServerAddress = ""
    tempServerPassword = ""
    addServerValidationMessage = nil
    validationMessage = nil
    return true
  }

  private func testServerConnection() {
    let trimmedAddress = tempServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAddress.isEmpty,
          let port = UInt16(tempPort),
          port > 0 else {
      addServerValidationMessage = String(localized: "Server requires a hostname and a port between 1 and 65535.")
      serverConnectionTestResult = nil
      return
    }

    addServerValidationMessage = nil
    serverConnectionTestResult = nil
    isTestingServerConnection = true
    let password = tempServerPassword
    let timeout = appSettings.timeout

    Task {
      let result: ServerConnectionTestResult = await Task.detached(priority: .userInitiated) {
        do {
          let manager = BORGVRRemoteDataManager(
            host: trimmedAddress,
            port: port,
            authSecret: password,
            logger: nil,
            notifier: nil
          )
          try manager.connect(timeout: timeout)
          let datasets = try manager.requestDatasetList()
          let transferFunctions = try manager.requestTransferFunctionList()
          return .success(
            datasetCount: datasets.count,
            transferFunctionCount: transferFunctions.count
          )
        } catch {
          return .failure(error.localizedDescription)
        }
      }.value

      serverConnectionTestResult = result
      isTestingServerConnection = false
    }
  }

  private func resetToDefaults(_ section: SettingsResetSection) {
    switch section {
      case .rendering:
        appSettings.resetRenderingDefaults()
      case .importSettings:
        appSettings.resetImportDefaults()
      case .remoteDatasets:
        appSettings.resetRemoteDefaults()
        tempPort = String(BorgVRSharedDefaults.datasetServerPort)
        tempServerAddress = ""
        tempServerPassword = ""
      case .backgroundServer:
        appSettings.resetBackgroundServerDefaults()
      case .webServer:
        appSettings.resetWebServerDefaults()
      case .adHocServer:
        appSettings.resetAdHocServerDefaults()
      case .lod:
        appSettings.resetLODDefaults(resetOversamplingThresholds: false)
    }
    validationMessage = nil
    loadTemporaryValues()
  }
}
