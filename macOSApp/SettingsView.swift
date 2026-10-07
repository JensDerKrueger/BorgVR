import SwiftUI

private let portNumberFormatter: NumberFormatter = {
  let formatter = NumberFormatter()
  formatter.numberStyle = .none
  formatter.usesGroupingSeparator = false
  formatter.minimum = 1
  formatter.maximum = 65535
  return formatter
}()

private let macAppSettingsGroupWidth: CGFloat = 680
private let macAppSettingsGroupContentWidth: CGFloat = 640
private let macAppSettingsSidebarWidth: CGFloat = 220

private enum SettingsResetSection: String, Identifiable {
  case general
  case dataSource
  case rendering
  case performance
  case importSettings
  case backgroundServer
  case adHocServer
  case externalDataSources

  var id: String { rawValue }

  var title: String {
    switch self {
      case .general: return "General"
      case .dataSource: return "Data source"
      case .rendering: return "Rendering"
      case .performance: return "Performance"
      case .importSettings: return "Import"
      case .backgroundServer: return "Background server"
      case .adHocServer: return "Ad-hoc server"
      case .externalDataSources: return "External data sources"
    }
  }

  var localizedTitle: String {
    String(localized: String.LocalizationValue(title))
  }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
  case general
  case rendering
  case performance
  case dataSource
  case importSettings
  case externalDataSources
  case servers
  case sharePlay

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
      case .general: return "General"
      case .dataSource: return "Data source"
      case .rendering: return "Rendering"
      case .performance: return "Performance"
      case .importSettings: return "Import"
      case .servers: return "Servers"
      case .externalDataSources: return "External data sources"
      case .sharePlay: return "SharePlay"
    }
  }

  var systemImage: String {
    switch self {
      case .general: return "gearshape"
      case .dataSource: return "externaldrive"
      case .rendering: return "paintpalette"
      case .performance: return "gauge.with.dots.needle.50percent"
      case .importSettings: return "square.and.arrow.down"
      case .servers: return "server.rack"
      case .externalDataSources: return "network"
      case .sharePlay: return "shareplay"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var updateChecker: AppStoreUpdateChecker

  @State private var serverAddress = ""
  @State private var serverPort = String(BorgVRSharedDefaults.datasetServerPort)
  @State private var serverPassword = ""
  @State private var shareNewServerViaSharePlay = false
  @State private var showDataDirectoryPicker = false
  @State private var showClearOriginCacheConfirmation = false
  @State private var pendingResetSection: SettingsResetSection?
  @State private var selectedSettingsPage: SettingsPage = .general

  var body: some View {
    HStack(spacing: 0) {
      settingsSidebar
      Divider()
      ScrollView {
        settingsTabContent {
          settingsPageContent(selectedSettingsPage)
        }
      }
    }
    .frame(minWidth: 840, minHeight: 480)
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
          appModel.navigationState = .start
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
    .confirmationDialog(
      "Clear Dataset Origin Cache?",
      isPresented: $showClearOriginCacheConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear", role: .destructive) {
        DatasetOriginCatalog.shared.clear()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("BorgVR will forget all previously discovered dataset sources.")
    }
  }

  private var settingsSidebar: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(SettingsPage.allCases) { page in
        Button {
          selectedSettingsPage = page
        } label: {
          Label(page.title, systemImage: page.systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
              if selectedSettingsPage == page {
                RoundedRectangle(cornerRadius: 6)
                  .fill(Color.accentColor.opacity(0.18))
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedSettingsPage == page ? .primary : .secondary)
      }
      Spacer()
    }
    .padding(10)
    .frame(width: macAppSettingsSidebarWidth)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func settingsPageContent(_ page: SettingsPage) -> some View {
    switch page {
      case .general:
        generalSettings
      case .dataSource:
        dataSourceSettings
      case .rendering:
        renderingSettings
      case .performance:
        performanceSettings
      case .importSettings:
        importSettings
      case .servers:
        serverSettings
      case .externalDataSources:
        externalDataSourceSettings
      case .sharePlay:
        sharePlaySettings
    }
  }

  private var dataSourceSettings: some View {
    settingsGroup(
      "Data source",
      description: "Choose the local folder BorgVR uses for datasets and transfer functions. The app reads local datasets from this directory, imports new datasets into it, and the background server publishes the same content when enabled."
    ) {
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
      resetButton(for: .dataSource)
    }
  }

  private var renderingSettings: some View {
    settingsGroup(
      "Rendering",
      description: "Configure visual appearance and sampling quality. These controls affect how the rendered image looks and how sampling adapts to the current frame rate."
    ) {
      pickerRow("Oversampling mode", selection: $appSettings.oversamplingMode) {
        Text("Static").tag(OversamplingMode.staticMode.rawValue)
        Text("Dynamic").tag(OversamplingMode.dynamicMode.rawValue)
      }
      doubleStepperRow("Oversampling factor",
                       value: $appSettings.oversampling,
                       range: 0.1...8.0,
                       step: 0.1,
                       format: "%.1f")
      toggleRow("Randomized sample phase", isOn: $appSettings.sampleJitter)
      if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
        intStepperRow("Drop FPS",
                      value: $appSettings.dropFPS,
                      range: 1...240,
                      step: 1,
                      suffix: "fps")
        intStepperRow("Recovery FPS",
                      value: $appSettings.recoveryFPS,
                      range: 1...240,
                      step: 1,
                      suffix: "fps")
      }
      pickerRow("Background", selection: $appSettings.renderBackgroundMode) {
        ForEach(RenderBackgroundMode.allCases) { mode in
          Text(mode.label).tag(mode.rawValue)
        }
      }
      if appSettings.renderBackgroundMode == RenderBackgroundMode.solid.rawValue {
        colorRow("Color", selection: Binding(
          get: { appSettings.renderBackgroundPrimaryColor },
          set: { appSettings.renderBackgroundPrimaryColor = $0 }
        ))
      }
      if appSettings.renderBackgroundMode == RenderBackgroundMode.gradient.rawValue {
        colorRow("Top color", selection: Binding(
          get: { appSettings.renderBackgroundPrimaryColor },
          set: { appSettings.renderBackgroundPrimaryColor = $0 }
        ))
        colorRow("Bottom color", selection: Binding(
          get: { appSettings.renderBackgroundSecondaryColor },
          set: { appSettings.renderBackgroundSecondaryColor = $0 }
        ))
      }
      resetButton(for: .rendering)
    }
  }

  private var generalSettings: some View {
    settingsGroup(
      "General",
      description: "Configure automatic loading, optional interface diagnostics, logging, and update checks."
    ) {
      toggleRow("Automatically load/save transfer functions", isOn: $appSettings.autoloadTF)
      toggleRow("Automatically load/save objects", isOn: $appSettings.autoloadObjects)
      toggleRow("Automatically load/save measurements", isOn: $appSettings.autoloadMeasurements)
      toggleRow(
        "Automatically load/save view and rendering state",
        isOn: $appSettings.autoloadRenderState
      )
      toggleRow("Show Brick Visualization", isOn: $appSettings.showBrickVisualization)
      toggleRow("Show Log Button", isOn: $appSettings.showLogButton)
      pickerRow("Log level", selection: $appSettings.logLevel) {
        ForEach(AppLogLevel.allCases) { level in
          Text(level.label).tag(level.rawValue)
        }
      }
      toggleRow(
        "Automatically check for updates",
        isOn: $updateChecker.checksEnabled
      )
      Text("BorgVR periodically checks the App Store for new versions and displays a notification when an update is available.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      resetButton(for: .general)
    }
  }

  private var importSettings: some View {
    settingsGroup(
      "Import",
      description: "Choose how newly imported volumes are converted into BorgVR datasets. Brick size, overlap, compression, and border handling influence dataset size, loading performance, and sampling quality."
    ) {
      intStepperRow("Brick size",
                    value: $storedAppModel.brickSize,
                    range: 8...512,
                    step: 8)
      intStepperRow("Overlap",
                    value: $storedAppModel.brickOverlap,
                    range: 1...16,
                    step: 1)
      toggleRow("Compression", isOn: $storedAppModel.enableCompression)
      pickerRow("Borders", selection: $storedAppModel.borderModeString) {
        Text("Zeroes").tag("zeroes")
        Text("Border").tag("border")
        Text("Repeat").tag("repeat")
      }
      resetButton(for: .importSettings)
    }
  }

  private var performanceSettings: some View {
    settingsGroup(
      "Performance",
      description: "Control level-of-detail selection, brick requests, GPU memory, and hash table sizing. Most users can leave these advanced settings unchanged."
    ) {
      doubleStepperRow("Screen-space pixel error",
                       value: $appSettings.screenSpaceError,
                       range: 0.05...10,
                       step: 0.05,
                       format: "%.2f")
      intStepperRow("Initial bricks",
                    value: $appSettings.initialBricks,
                    range: 0...20000,
                    step: 100)
      intStepperRow("Max. probing attempts",
                    value: $appSettings.maxProbingAttempts,
                    range: 1...512,
                    step: 1)
      toggleRow("Request low-res LOD", isOn: $appSettings.requestLowResLOD)
      toggleRow("Stop on missing brick", isOn: $appSettings.stopOnMiss)
      intStepperRow("Atlas size",
                    value: $appSettings.atlasSizeMB,
                    range: 128...AppSettings.maximumAtlasSizeMB,
                    step: 128,
                    suffix: "MB")
      intStepperRow("Min. hash table size",
                    value: $appSettings.minHashTableSize,
                    range: 1...1024,
                    step: 1,
                    suffix: "MB")
      resetButton(for: .performance)
    }
  }

  private var serverSettings: some View {
    Group {
      settingsGroup(
        "Background server",
        description: "Enable the local dataset server used by other BorgVR clients and the WebGPU preview. Here you configure ports, password, HTTPS certificate, and transfer batch size for the shared local data source."
      ) {
        toggleRow("Enable dataset server", isOn: $storedAppModel.enableDatasetServer)
        if storedAppModel.enableDatasetServer {
          toggleRow("Start server automatically", isOn: $storedAppModel.autoStartServer)
          portField("Port", value: $storedAppModel.port)
          secureFieldRow("Server password (optional)", text: $storedAppModel.serverPassword)
          toggleRow("Start WebGPU web server", isOn: $storedAppModel.enableWebServer)
          toggleRow("Use HTTPS", isOn: $storedAppModel.webServerUsesTLS)
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
          intStepperRow("Max. bricks per request",
                        value: $storedAppModel.maxBricksPerGetRequest,
                        range: 1...1000,
                        step: 1)
        }
        resetButton(for: .backgroundServer)
      }

      settingsGroup(
        "Ad-hoc server",
        description: "Configure the temporary server ports used for ad-hoc sharing sessions such as SharePlay. These settings are separate from the persistent background dataset server."
      ) {
        portField("Ad-hoc dataset server port", value: $storedAppModel.sharePlayServerPort)
        portField("Ad-hoc WebGPU web server port", value: $storedAppModel.sharePlayWebServerPort)
        resetButton(for: .adHocServer)
      }
    }
  }

  private var externalDataSourceSettings: some View {
    settingsGroup(
      "External data sources",
      description: "Manage remote BorgVR dataset servers that this app can query. Added servers appear in the dataset browser; enter the address, port, and password provided by the server operator."
    ) {
      ForEach(appSettings.servers) { server in
        serverRow(for: server)
      }

      HStack {
        TextField("Server address", text: $serverAddress)
          .textFieldStyle(.roundedBorder)
        TextField("Port", text: $serverPort)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
        SecureField("Password", text: $serverPassword)
          .textFieldStyle(.roundedBorder)
          .frame(width: 160)
        Button {
          addRemoteServer()
        } label: {
          Image(systemName: "plus")
        }
        .help("Add server")
      }
      Toggle("Share source via SharePlay", isOn: $shareNewServerViaSharePlay)
      Text("When enabled, the server address, port, and password may be sent to SharePlay participants so they can load shared datasets directly.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
        .padding(.vertical, 4)
      Text("Loading")
        .font(.headline)
      doubleStepperRow(
        "Timeout (seconds)",
        value: $appSettings.timeout,
        range: 0.1...120,
        step: 0.5,
        format: "%.1f"
      )
      toggleRow("Progressive loading", isOn: $appSettings.progressiveLoading)
      Text("Datasets provided through SharePlay ad-hoc connections are always loaded progressively, regardless of this setting.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      toggleRow("Keep local copy", isOn: $appSettings.makeLocalCopy)
      Button(role: .destructive) {
        showClearOriginCacheConfirmation = true
      } label: {
        Label("Clear Dataset Origin Cache", systemImage: "trash")
      }
      resetButton(for: .externalDataSources)
    }
  }

  private var sharePlaySettings: some View {
    settingsGroup(
      "SharePlay",
      description: "Choose how you appear to other people during SharePlay collaboration. Your display name is shared only with participants in the current session."
    ) {
      HStack {
        Text("SharePlay display name")
        Spacer()
        TextField("SharePlay display name", text: $storedAppModel.sharePlayDisplayName)
          .textFieldStyle(.roundedBorder)
          .frame(width: 260)
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
      return String(localized: "Reset settings?")
    }
    return String(
      format: String(localized: "Reset %@?"),
      pendingResetSection.localizedTitle
    )
  }

  private var resetConfirmationMessage: String {
    guard let pendingResetSection else {
      return String(localized: "The section will be reset to its default values.")
    }
    return String(
      format: String(localized: "The %@ section will be reset to its default values."),
      pendingResetSection.localizedTitle
    )
  }

  private func resetButton(for section: SettingsResetSection) -> some View {
    Button(role: .destructive) {
      pendingResetSection = section
    } label: {
      Label(
        String(format: String(localized: "Reset %@"), section.localizedTitle),
        systemImage: "arrow.counterclockwise"
      )
    }
  }

  private func settingsTabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .center, spacing: 12) {
      content()
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 12)
  }

  private func settingsGroup<Content: View>(
    _ title: LocalizedStringKey,
    description: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    GroupBox(
      label: Text(title)
        .font(.title3)
        .fontWeight(.semibold)
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        content()
      }
      .frame(width: macAppSettingsGroupContentWidth, alignment: .leading)
      .padding(.vertical, 4)
    }
    .frame(width: macAppSettingsGroupWidth, alignment: .leading)
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
        password: serverPassword,
        shareViaSharePlay: shareNewServerViaSharePlay
      )
    )
    serverAddress = ""
    serverPassword = ""
    shareNewServerViaSharePlay = false
  }

  private func serverRow(for server: StoredServer) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(serverLabel(for: server))
        Spacer()
        Toggle("Share source via SharePlay", isOn: serverSharingBinding(server))
          .toggleStyle(.switch)
        Button(role: .destructive) {
          removeRemoteServer(server)
        } label: {
          Image(systemName: "trash")
        }
        .help("Remove server")
      }
    }
  }

  private func serverSharingBinding(_ server: StoredServer) -> Binding<Bool> {
    Binding(
      get: { appSettings.servers.first(where: { $0.id == server.id })?.shareViaSharePlay ?? false },
      set: { allowed in
        guard let index = appSettings.servers.firstIndex(where: { $0.id == server.id }) else { return }
        appSettings.servers[index].shareViaSharePlay = allowed
        DatasetOriginCatalog.shared.setSharingAllowed(
          allowed,
          for: DatasetOrigin(address: server.address, port: server.port, password: server.password)
        )
      }
    )
  }

  private func serverLabel(for server: StoredServer) -> String {
    if server.password.isEmpty {
      return "\(server.address):\(server.port)"
    }
    return "\(server.address):\(server.port) \(String(localized: "(Password)"))"
  }

  private func portField(_ title: String, value: Binding<Int>) -> some View {
    controlRow(LocalizedStringKey(title)) {
      TextField("", value: clampedPortBinding(value), formatter: portNumberFormatter)
        .multilineTextAlignment(.trailing)
        .textFieldStyle(.roundedBorder)
        .frame(width: 110)
    }
  }

  private func secureFieldRow(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
    controlRow(title) {
      SecureField("", text: text)
        .textFieldStyle(.roundedBorder)
        .frame(width: 240)
    }
  }

  private func toggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
    controlRow(title) {
      Toggle("", isOn: isOn)
        .labelsHidden()
        .fixedSize()
    }
  }

  private func pickerRow<SelectionValue: Hashable, Content: View>(
    _ title: LocalizedStringKey,
    selection: Binding<SelectionValue>,
    @ViewBuilder content: () -> Content
  ) -> some View {
    controlRow(title) {
      Picker("", selection: selection) {
        content()
      }
      .labelsHidden()
      .frame(width: 240)
    }
  }

  private func colorRow(_ title: LocalizedStringKey, selection: Binding<Color>) -> some View {
    controlRow(title) {
      ColorPicker("", selection: selection, supportsOpacity: true)
        .labelsHidden()
        .fixedSize()
    }
  }

  private func intStepperRow(
    _ title: LocalizedStringKey,
    value: Binding<Int>,
    range: ClosedRange<Int>,
    step: Int,
    suffix: String? = nil
  ) -> some View {
    controlRow(title) {
      Stepper(value: value, in: range, step: step) {
        Text(valueLabel(value.wrappedValue, suffix: suffix))
          .monospacedDigit()
          .frame(minWidth: 84, alignment: .trailing)
      }
      .fixedSize()
    }
  }

  private func doubleStepperRow(
    _ title: LocalizedStringKey,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    format: String,
    suffix: String? = nil
  ) -> some View {
    controlRow(title) {
      Stepper(value: value, in: range, step: step) {
        Text(valueLabel(String(format: format, value.wrappedValue), suffix: suffix))
          .monospacedDigit()
          .frame(minWidth: 84, alignment: .trailing)
      }
      .fixedSize()
    }
  }

  private func controlRow<Control: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(title)
      Spacer(minLength: 24)
      control()
        .frame(minWidth: 220, alignment: .trailing)
    }
  }

  private func valueLabel(_ value: Int, suffix: String?) -> String {
    valueLabel("\(value)", suffix: suffix)
  }

  private func valueLabel(_ value: String, suffix: String?) -> String {
    guard let suffix else { return value }
    return "\(value) \(suffix)"
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
    DatasetOriginCatalog.shared.setSharingAllowed(
      false,
      for: DatasetOrigin(address: server.address, port: server.port, password: server.password)
    )
    appSettings.servers.removeAll { $0.id == server.id }
  }

  private func resetToDefaults(_ section: SettingsResetSection) {
    switch section {
      case .general:
        appSettings.resetGeneralDefaults()
        updateChecker.checksEnabled = true
      case .dataSource:
        storedAppModel.resetDataSourceDefaults()
      case .rendering:
        appSettings.resetRenderingDefaults()
      case .performance:
        appSettings.resetPerformanceDefaults()
      case .importSettings:
        appSettings.resetImportDefaults()
        storedAppModel.resetImportDefaults()
      case .backgroundServer:
        appSettings.maxBricksPerGetRequest = AppSettings.values["maxBricksPerGetRequest"] as? Int
          ?? BorgVRSharedDefaults.maximumBricksPerRequest
        storedAppModel.resetBackgroundServerDefaults()
      case .adHocServer:
        storedAppModel.resetAdHocServerDefaults()
      case .externalDataSources:
        appSettings.resetRemoteDefaults()
        serverAddress = ""
        serverPort = String(BorgVRSharedDefaults.datasetServerPort)
        serverPassword = ""
    }
  }
}
