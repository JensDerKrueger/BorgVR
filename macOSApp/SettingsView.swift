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
  case dataSource
  case rendering
  case importSettings
  case lod
  case backgroundServer
  case adHocServer
  case externalDataSources
  case miscellaneous

  var id: String { rawValue }

  var title: String {
    switch self {
      case .dataSource: return "Data source"
      case .rendering: return "Rendering"
      case .importSettings: return "Import"
      case .lod: return "LOD"
      case .backgroundServer: return "Background server"
      case .adHocServer: return "Ad-hoc server"
      case .externalDataSources: return "External data sources"
      case .miscellaneous: return "Miscellaneous"
    }
  }

  var localizedTitle: String {
    String(localized: String.LocalizationValue(title))
  }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
  case dataSource
  case rendering
  case importSettings
  case lod
  case servers
  case externalDataSources
  case miscellaneous

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
      case .dataSource: return "Data source"
      case .rendering: return "Rendering"
      case .importSettings: return "Import"
      case .lod: return "LOD"
      case .servers: return "Servers"
      case .externalDataSources: return "External data sources"
      case .miscellaneous: return "Miscellaneous"
    }
  }

  var systemImage: String {
    switch self {
      case .dataSource: return "externaldrive"
      case .rendering: return "paintpalette"
      case .importSettings: return "square.and.arrow.down"
      case .lod: return "square.stack.3d.up"
      case .servers: return "server.rack"
      case .externalDataSources: return "network"
      case .miscellaneous: return "ellipsis.circle"
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
  @State private var selectedSettingsPage: SettingsPage = .dataSource

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
      case .dataSource:
        dataSourceSettings
      case .rendering:
        renderingSettings
      case .importSettings:
        importSettings
      case .lod:
        lodSettings
      case .servers:
        serverSettings
      case .externalDataSources:
        externalDataSourceSettings
      case .miscellaneous:
        miscellaneousSettings
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
      description: "Configure how datasets are rendered, including transfer-function handling, oversampling, background appearance, GPU memory limits, and hash table size. These settings can affect visual quality, memory use, and rendering speed."
    ) {
      toggleRow("Automatically load/save transfer functions", isOn: $appSettings.autoloadTF)
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
      resetButton(for: .rendering)
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

  private var lodSettings: some View {
    settingsGroup(
      "LOD",
      description: "Control level-of-detail selection and brick request behavior. These settings balance visual quality, paging speed, memory pressure, and responsiveness while navigating large datasets."
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
      resetButton(for: .lod)
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
      resetButton(for: .externalDataSources)
    }
  }

  private var miscellaneousSettings: some View {
    settingsGroup(
      "Miscellaneous",
      description: "Adjust general application behavior that is not tied to a specific renderer, importer, or server workflow."
    ) {
      pickerRow("Log level", selection: $appSettings.logLevel) {
        ForEach(AppLogLevel.allCases) { level in
          Text(level.label).tag(level.rawValue)
        }
      }
      resetButton(for: .miscellaneous)
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
    appSettings.servers.removeAll { $0.id == server.id }
  }

  private func resetToDefaults(_ section: SettingsResetSection) {
    switch section {
      case .dataSource:
        storedAppModel.resetDataSourceDefaults()
      case .rendering:
        appSettings.resetRenderingDefaults(resetLogLevel: false)
      case .importSettings:
        appSettings.resetImportDefaults()
        storedAppModel.resetImportDefaults()
      case .lod:
        appSettings.resetLODDefaults(resetOversamplingThresholds: false)
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
      case .miscellaneous:
        appSettings.resetMiscDefaults()
    }
  }
}
