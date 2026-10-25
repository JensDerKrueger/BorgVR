import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    disableWindowTabs()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeMain(_:)),
      name: NSWindow.didBecomeMainNotification,
      object: nil
    )
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  @objc private func windowDidBecomeMain(_ notification: Notification) {
    disableTabs(for: notification.object as? NSWindow)
  }

  private func disableWindowTabs() {
    NSApp.windows.forEach(disableTabs)
  }

  private func disableTabs(for window: NSWindow?) {
    guard let window else { return }
    window.tabbingMode = .disallowed
    window.tabGroup?.removeWindow(window)
  }
}

@main
struct macOSApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  @StateObject private var appModel: AppModel
  @StateObject private var renderingParameters: RenderingParameters
  @StateObject private var appSettings: AppSettings
  @StateObject private var storedAppModel: StoredAppModel
  @StateObject private var serverController: BackgroundServerController
  @StateObject private var sharePlay: SharePlayCoordinator
  @StateObject private var docking: DockingController
  @StateObject private var scriptRunner: BorgVRScriptRunner
  @StateObject private var updateChecker: AppStoreUpdateChecker
  @StateObject private var mcpController: BorgVRMCPServerController
  @StateObject private var session: ScreenBorgVRSession
  @AppStorage("sharePlayDisplayNameOnboardingCompleted")
  private var sharePlayDisplayNameOnboardingCompleted = false
  @State private var showsSharePlayDisplayNameOnboarding = false
  @State private var sharePlayDisplayNameDraft = ""

  init() {
    let appModel = AppModel()
    let renderingParameters = RenderingParameters()
    let appSettings = AppSettings()
    let storedAppModel = StoredAppModel()
    let serverController = BackgroundServerController()
    let sharePlay = SharePlayCoordinator(
      platformAdapter: MacSharePlayPlatformAdapter(
        storedAppModel: storedAppModel,
        serverController: serverController
      )
    )
    let docking = DockingController()
    let scriptRunner = BorgVRScriptRunner()
    let updateChecker = AppStoreUpdateChecker()
    let mcpController = BorgVRMCPServerController()
    let session = ScreenBorgVRSession.screen(
      appModel: appModel,
      renderingParameters: renderingParameters,
      appSettings: appSettings,
      synchronizeTransform: { [weak sharePlay] in
        sharePlay?.synchronize(kind: .transformOnly)
      },
      synchronizeState: { [weak sharePlay] in
        sharePlay?.synchronize(kind: .stateOnly)
      },
      synchronizeFullState: { [weak sharePlay] in
        sharePlay?.synchronize(kind: .full)
      },
      synchronizeObjects: { [weak sharePlay] in
        sharePlay?.synchronizeMarkers()
      },
      synchronizeMeasurements: { [weak sharePlay] in
        sharePlay?.synchronizeMeasurements()
      },
      renderModeDidChange: { [weak docking] mode in
        docking?.hideIncompatibleEditor(for: mode)
      }
    )

    _appModel = StateObject(wrappedValue: appModel)
    _renderingParameters = StateObject(wrappedValue: renderingParameters)
    _appSettings = StateObject(wrappedValue: appSettings)
    _storedAppModel = StateObject(wrappedValue: storedAppModel)
    _serverController = StateObject(wrappedValue: serverController)
    _sharePlay = StateObject(wrappedValue: sharePlay)
    _docking = StateObject(wrappedValue: docking)
    _scriptRunner = StateObject(wrappedValue: scriptRunner)
    _updateChecker = StateObject(wrappedValue: updateChecker)
    _mcpController = StateObject(wrappedValue: mcpController)
    _session = StateObject(wrappedValue: session)
  }

  var body: some Scene {
    WindowGroup("BorgVR") {
      ContentView()
        .volumeEditSelectionDialog(model: appModel.volumeBrush)
        .appStoreUpdateAlert(using: updateChecker)
        .alert(
          "Choose your SharePlay name",
          isPresented: $showsSharePlayDisplayNameOnboarding
        ) {
          TextField("Display name", text: $sharePlayDisplayNameDraft)
          Button("Continue") {
            storedAppModel.sharePlayDisplayName = sharePlayDisplayNameDraft
              .trimmingCharacters(in: .whitespacesAndNewlines)
            sharePlayDisplayNameOnboardingCompleted = true
          }
          .disabled(sharePlayDisplayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
          Text("What name should other people see for you in shared SharePlay sessions? You can change it later in Settings.")
        }
        .alert(
          "SharePlay Host Left",
          isPresented: $sharePlay.showsHostDeparturePrompt
        ) {
          Button("Take Over Host Role") {
            sharePlay.takeOverHostRole()
          }
          Button("Leave Session", role: .destructive) {
            sharePlay.leaveGroupActivity()
          }
          Button("Ignore", role: .cancel) {
            sharePlay.ignoreHostDeparture()
          }
        } message: {
          Text("The SharePlay host left the session. You can take over the host role, leave the session, or continue without a host.")
        }
        .alert(item: $sharePlay.protocolCompatibilityIssue) { issue in
          Alert(
            title: Text("Incompatible SharePlay Version"),
            message: Text(issue.localizedMessage),
            dismissButton: .default(Text("OK")) {
              sharePlay.protocolCompatibilityIssue = nil
            }
          )
        }
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
        .environmentObject(updateChecker)
        .environmentObject(mcpController)
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
          presentSharePlayDisplayNameOnboardingIfNeeded()
          sharePlay.startObservingSessions(
            appModel: appModel,
            renderingParameters: renderingParameters,
            appSettings: appSettings
          )
          appModel.setLogLevel(appSettings.logLevel)
          let commandService = makeCommandService()
          scriptRunner.configure(
            appModel: appModel,
            renderingParameters: renderingParameters,
            session: session,
            appSettings: appSettings,
            storedAppModel: storedAppModel,
            sharePlay: sharePlay,
            docking: docking,
            commandService: commandService
          )
          mcpController.configure(commandService: commandService, logger: appModel.logger)
          applyMCPConfiguration()
        }
        .onChange(of: appSettings.logLevel) { _, newValue in
          appModel.setLogLevel(newValue)
        }
        .onChange(of: storedAppModel.sharePlayDisplayName) { _, _ in
          sharePlay.participantInfoChanged()
        }
        .onChange(of: storedAppModel.enableDatasetServer) { _, enabled in
          if enabled {
            if storedAppModel.autoStartServer, !serverController.isRunning {
              serverController.start(using: storedAppModel)
            }
          } else {
            serverController.stop()
          }
        }
        .onChange(of: storedAppModel.autoStartServer) { _, enabled in
          if enabled, storedAppModel.enableDatasetServer, !serverController.isRunning {
            serverController.start(using: storedAppModel)
          }
        }
        .onChange(of: storedAppModel.enableMCPServer) { _, _ in applyMCPConfiguration() }
        .onChange(of: storedAppModel.mcpServerPort) { _, _ in applyMCPConfiguration() }
        .onChange(of: storedAppModel.mcpAllowRemoteConnections) { _, _ in applyMCPConfiguration() }
        .onChange(of: storedAppModel.mcpAccessToken) { _, _ in applyMCPConfiguration() }
        .onChange(of: storedAppModel.mcpServerCertificateData) { _, _ in applyMCPConfiguration() }
        .onOpenURL { url in
          openExternalDataset(url)
        }
        .task {
          _ = storedAppModel.activateDataDirectoryAccess()
          if storedAppModel.enableDatasetServer && storedAppModel.autoStartServer {
            serverController.start(using: storedAppModel)
          }
        }
    }
    .handlesExternalEvents(matching: [BorgVRSharePlayActivity.activityIdentifier])
    .defaultSize(width: 1200, height: 820)

    WindowGroup("Render UI", id: DockablePanelID.renderControls.windowID) {
      DetachedPanelContent(panel: .renderControls)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 720, height: 260)

    WindowGroup("Transfer Function", id: DockablePanelID.transferFunctionEditor.windowID) {
      DetachedPanelContent(panel: .transferFunctionEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 820, height: 320)

    WindowGroup("Isovalue", id: DockablePanelID.isoEditor.windowID) {
      DetachedPanelContent(panel: .isoEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 560, height: 180)

    WindowGroup("Performance", id: "PerformanceGraphView") {
      PerformanceGraphView()
        .environmentObject(appModel)
    }
    .defaultSize(width: 820, height: 360)

    Window("Script Log", id: "ScriptLogView") {
      ScriptLogView()
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 760, height: 480)
    .restorationBehavior(.disabled)

    WindowGroup("Objects", id: DockablePanelID.markerEditor.windowID) {
      DetachedPanelContent(panel: .markerEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 520, height: 560)

    WindowGroup("measurement_window_title", id: DockablePanelID.measurementEditor.windowID) {
      DetachedPanelContent(panel: .measurementEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 520, height: 600)

    WindowGroup("Brush", id: DockablePanelID.volumeBrushEditor.windowID) {
      DetachedPanelContent(panel: .volumeBrushEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 400, height: 430)

    WindowGroup("Lighting", id: DockablePanelID.lightingEditor.windowID) {
      DetachedPanelContent(panel: .lightingEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(session)
    }
    .defaultSize(width: 430, height: 500)
    .commands {
      BorgVRMenuCommands(
        appModel: appModel,
        renderingParameters: renderingParameters,
        appSettings: appSettings,
        serverController: serverController,
        sharePlay: sharePlay,
        docking: docking,
        scriptRunner: scriptRunner,
        session: session
      )
    }
  }

  @MainActor
  private func makeCommandService() -> BorgVRScreenCommandService {
    BorgVRScreenCommandService(
      session: session,
      datasetListProvider: {
        await loadMCPDatasetRecords().map(\.catalogEntry)
      },
      datasetOpener: { id in
        try await openMCPDataset(id: id)
      },
      datasetCloser: {
        closeMCPDataset()
      }
    )
  }

  @MainActor
  private func loadMCPDatasetRecords() async -> [BorgVRMCPDatasetRecord] {
    let accessURL = storedAppModel.startAccessingDataDirectory()
    defer { storedAppModel.stopAccessingDataDirectory(accessURL) }
    return await BorgVRMCPDatasetCatalog.load(
      localDirectory: storedAppModel.resolvedDataDirectoryURL(),
      servers: appSettings.servers,
      timeout: appSettings.timeout
    )
  }

  @MainActor
  private func openMCPDataset(id: String) async throws {
    let records = await loadMCPDatasetRecords()
    guard let record = records.first(where: { $0.catalogEntry.id == id }) else {
      throw BorgVRMCPCommandError.datasetNotFound(id)
    }
    let entry: AppModel.DatasetEntry
    switch record.preferredLocation {
      case .local(let url):
        entry = AppModel.DatasetEntry(
          identifier: url.path,
          description: record.catalogEntry.description,
          source: .local,
          uniqueId: record.catalogEntry.id
        )
      case .builtIn(let url):
        entry = AppModel.DatasetEntry(
          identifier: url.path,
          description: record.catalogEntry.description,
          source: .builtIn,
          uniqueId: record.catalogEntry.id
        )
      case .remote(let address, let port, let password):
        entry = AppModel.DatasetEntry(
          identifier: record.catalogEntry.id,
          description: record.catalogEntry.description,
          source: .remote(address: address, port: port, password: password),
          uniqueId: record.catalogEntry.id
        )
    }
    let accessURL = storedAppModel.startAccessingDataDirectory()
    defer { storedAppModel.stopAccessingDataDirectory(accessURL) }
    try await appModel.volumeBrush.prepareOpening(datasetID: entry.uniqueId,
      datasetURL: entry.editStorageURL(directoryURL: storedAppModel.resolvedDataDirectoryURL()), interactive: false)
    appModel.openDataset(entry, asGroupSessionHost: sharePlay.isInSession ? nil : true)
    docking.resetForDatasetClose()
    sharePlay.datasetOpened()
  }

  @MainActor
  private func closeMCPDataset() {
    guard appModel.activeDataset != nil else { return }
    if appSettings.autoloadTF,
       let fileURL = appModel.transferFunctionFileURL() {
      try? renderingParameters.transferFunction.save(to: fileURL)
    }
    appModel.saveAutomaticallyManagedDatasetState(
      appSettings: appSettings,
      renderingParameters: renderingParameters
    )
    if sharePlay.isInSession, !appModel.groupSessionHost {
      sharePlay.leaveGroupActivity()
    } else {
      sharePlay.closeSharedDataset()
    }
    appModel.removeAllVolumeMarkers()
    appModel.replaceSceneMeshInstances([])
    appModel.removeAllVolumeMeasurements()
    docking.resetForDatasetClose()
    appModel.closeDataset(destination: .datasetSelection)
  }

  @MainActor
  private func applyMCPConfiguration() {
    mcpController.apply(BorgVRMCPConfiguration(
      enabled: storedAppModel.enableMCPServer,
      port: storedAppModel.mcpServerPort,
      allowRemoteConnections: storedAppModel.mcpAllowRemoteConnections,
      accessToken: storedAppModel.mcpAccessToken,
      tlsCertificateData: storedAppModel.mcpServerCertificateData,
      tlsCertificatePassword: storedAppModel.mcpServerCertificatePassword
    ))
  }

  @MainActor
  private func presentSharePlayDisplayNameOnboardingIfNeeded() {
    guard !sharePlayDisplayNameOnboardingCompleted,
          !showsSharePlayDisplayNameOnboarding else { return }
    let configuredName = storedAppModel.sharePlayDisplayName
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredName.isEmpty {
      sharePlayDisplayNameOnboardingCompleted = true
      return
    }

    sharePlayDisplayNameDraft = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    showsSharePlayDisplayNameOnboarding = true
  }

  private func openExternalDataset(_ url: URL) {
    Task { @MainActor in
      do {
        let dataDirectoryAccessURL = storedAppModel.startAccessingDataDirectory()
        defer {
          storedAppModel.stopAccessingDataDirectory(dataDirectoryAccessURL)
        }

        let dataset = try ExternalDatasetImporter.importDataset(
          from: url,
          into: storedAppModel.resolvedDataDirectoryURL(),
          logger: appModel.logger
        )
        try await appModel.volumeBrush.prepareOpening(datasetID: dataset.uniqueId,
          datasetURL: dataset.editStorageURL(directoryURL: storedAppModel.resolvedDataDirectoryURL()))
        appModel.openDataset(dataset, asGroupSessionHost: true)
        docking.resetForDatasetClose()
        sharePlay.datasetOpened()
      } catch {
        appModel.logger.error(
          String(
            format: String(localized: "external_dataset_open_failed_format"),
            url.lastPathComponent,
            error.localizedDescription
          )
        )
      }
    }
  }
}

private struct BorgVRMenuCommands: Commands {
  @ObservedObject var appModel: AppModel
  @ObservedObject var renderingParameters: RenderingParameters
  @ObservedObject var appSettings: AppSettings
  @ObservedObject var serverController: BackgroundServerController
  @ObservedObject var sharePlay: SharePlayCoordinator
  @ObservedObject var docking: DockingController
  @ObservedObject var scriptRunner: BorgVRScriptRunner
  @ObservedObject var session: ScreenBorgVRSession

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button {
        appModel.navigationState = .selectData
      } label: {
        menuLabel("modeselection_open_dataset", systemImage: "folder")
      }
      .macKeyboardShortcut(.openDataset)
      .disabled(hasActiveDataset)

      Button {
        appModel.navigationState = .importData
      } label: {
        menuLabel("modeselection_import", systemImage: "arrow.up.arrow.down.square")
      }
      .macKeyboardShortcut(.importExport)
      .disabled(hasActiveDataset)
    }

    CommandGroup(replacing: .appSettings) {
      Button {
        appModel.navigationState = .settings
      } label: {
        menuLabel("Settings", systemImage: "gearshape")
      }
      .keyboardShortcut(",", modifiers: .command)
      .disabled(hasActiveDataset)
    }

    CommandMenu("Dataset") {
      Button {
        docking.request(.closeDataset)
      } label: {
        menuLabel("Close Dataset", systemImage: "xmark.circle")
      }
      .macKeyboardShortcut(.closeDataset)
      .disabled(!hasActiveDataset)

      Divider()

      Button {
        docking.request(.saveDatasetState)
      } label: {
        menuLabel("Save Dataset State", systemImage: "tray.and.arrow.down")
      }
      .macKeyboardShortcut(.saveDatasetState)
      .disabled(!hasActiveDataset)

      Button {
        docking.request(.restoreDatasetState)
      } label: {
        menuLabel("Restore Dataset State", systemImage: "tray.and.arrow.up")
      }
      .macKeyboardShortcut(.restoreDatasetState)
      .disabled(!hasActiveDataset)

      Divider()

      Button {
        docking.request(.render(.datasetInfo))
      } label: {
        menuLabel("dataset_info_button", systemImage: "info.circle")
      }
      .macKeyboardShortcut(.datasetInfo)
      .disabled(!hasActiveDataset)
    }

    CommandMenu("Interaction") {
      selectionCommand("Erase", systemImage: "eraser.fill", shortcut: .erase,
        isSelected: appModel.interactionMode == .volumeEditing && appModel.volumeBrush.mode == .erase)
      selectionCommand("Restore", systemImage: "arrow.uturn.backward", shortcut: .restore,
        isSelected: appModel.interactionMode == .volumeEditing && appModel.volumeBrush.mode == .restore)
      Button("Smaller Brush") { docking.request(.render(.smallerBrush)) }.macRenderShortcut(.smallerBrush)
      Button("Larger Brush") { docking.request(.render(.largerBrush)) }.macRenderShortcut(.largerBrush)
      Divider()
      selectionCommand(
        "Model",
        systemImage: "move.3d",
        shortcut: .model,
        isSelected: appModel.interactionMode == .model
      )
      selectionCommand(
        "Clipping",
        systemImage: "viewfinder",
        shortcut: .clipping,
        isSelected: appModel.interactionMode == .clipping
      )
      selectionCommand(
        "Transfer",
        systemImage: "slider.horizontal.3",
        shortcut: .transferInteraction,
        isSelected: appModel.interactionMode == .transferEditing
      )
      Divider()
      selectionCommand(
        "Draw",
        systemImage: "scribble",
        shortcut: .drawing,
        isSelected: appModel.interactionMode == .drawing
      )
      selectionCommand(
        "Place",
        systemImage: "cube",
        shortcut: .placement,
        isSelected: appModel.interactionMode == .objectPlacement
      )
      selectionCommand(
        "private_interaction_option_measurement",
        systemImage: "ruler",
        shortcut: .measurement,
        isSelected: appModel.interactionMode == .measurement
      )
      selectionCommand(
        "Edit Volume",
        systemImage: "eraser",
        shortcut: .volumeEditing,
        isSelected: appModel.interactionMode == .volumeEditing
      )
    }

    CommandMenu("Rendering") {
      selectionCommand(
        "Transfer Function",
        systemImage: "chart.xyaxis.line",
        shortcut: .transferFunctionRendering,
        isSelected: renderingParameters.renderMode == .transferFunction1D
      )
      selectionCommand(
        "Transfer function + lighting",
        systemImage: "lightbulb.max",
        shortcut: .lightingRendering,
        isSelected: renderingParameters.renderMode == .transferFunction1DLighting
      )
      selectionCommand(
        "Isovalue",
        systemImage: "square.3.layers.3d.top.filled",
        shortcut: .isoRendering,
        isSelected: renderingParameters.renderMode == .isoValue
      )

      Divider()

      Button {
        docking.request(.render(.extractIsosurface))
      } label: {
        menuLabel("Extract Isosurface", systemImage: "square.and.arrow.up")
      }
      .macRenderShortcut(.extractIsosurface)
      .disabled(!hasActiveDataset || renderingParameters.renderMode != .isoValue)

      renderCommand("Screenshot", systemImage: "camera", shortcut: .screenshot)
      renderCommand("Reset", systemImage: "arrow.counterclockwise", shortcut: .reset)

      Button {
        docking.request(.render(.bricks))
      } label: {
        menuLabel("Bricks", systemImage: "cube.transparent")
      }
      .macRenderShortcut(.bricks)
      .disabled(!hasActiveDataset || !appSettings.showBrickVisualization)
    }

    CommandMenu("Panels") {
      renderCommand("Editor", systemImage: "slider.horizontal.3", shortcut: .editor)
      renderCommand("Lighting", systemImage: "lightbulb.max", shortcut: .lighting)
      renderCommand("Objects", systemImage: "cube.transparent", shortcut: .objects)
      renderCommand(
        "measurement_window_title",
        systemImage: "ruler",
        shortcut: .measurements
      )

      Divider()

      renderCommand(
        "performance_title",
        systemImage: "chart.xyaxis.line",
        shortcut: .performance
      )

      if appSettings.showLogButton {
        renderCommand("Log", systemImage: "text.alignleft", shortcut: .log)
      }

      Divider()

      renderCommand(
        docking.isVisible(.renderControls) ? "Hide UI" : "Show UI",
        systemImage: docking.isVisible(.renderControls) ? "eye.slash" : "eye",
        shortcut: .toggleControls
      )
      renderCommand(
        docking.isDetached(.renderControls) ? "Dock panel" : "Detach panel",
        systemImage: docking.isDetached(.renderControls)
          ? DockablePanelID.renderControls.detachedIcon
          : DockablePanelID.renderControls.dockedIcon,
        shortcut: .docking
      )
    }

    CommandMenu("SharePlay") {
      Button {
        sharePlay.startSharePlay()
      } label: {
        menuLabel("Start SharePlay", systemImage: "shareplay")
      }
      .macKeyboardShortcut(.startSharePlay)
      .disabled(!hasActiveDataset)

      Button {
        docking.request(.render(.synchronizeView))
      } label: {
        menuLabel("Synchronize View", systemImage: "link")
      }
      .macKeyboardShortcut(.synchronizeView)
      .disabled(!hasActiveDataset || !sharePlay.isInSession)

      Divider()

      Button {
        copyWebGPUShareLink()
      } label: {
        menuLabel("Copy WebGPU link", systemImage: "link.badge.plus")
      }
      .macKeyboardShortcut(.copyWebGPULink)
      .disabled(!canCopyWebGPUShareLink)
    }

    CommandMenu("Script") {
      Button {
        scriptRunner.showOpenPanelAndRun()
      } label: {
        menuLabel("Run Script...", systemImage: "play.circle")
      }
      .macKeyboardShortcut(.runScript)

      Button {
        scriptRunner.stopScript()
      } label: {
        menuLabel("Stop Script", systemImage: "stop.circle")
      }
      .disabled(!scriptRunner.isRunning)
      .macKeyboardShortcut(.stopScript)

      Divider()

      Button {
        docking.request(.startRecording)
      } label: {
        menuLabel("Start Recording", systemImage: "record.circle")
      }
      .macKeyboardShortcut(.startRecording)
      .disabled(!hasActiveDataset || session.isCommandRecording)

      Button {
        docking.request(.stopRecording)
      } label: {
        menuLabel("Stop and Save", systemImage: "stop.circle.fill")
      }
      .macKeyboardShortcut(.stopRecording)
      .disabled(!session.isCommandRecording)
    }

    CommandGroup(replacing: .help) {
      Button {
        NSApplication.shared.showHelp(nil)
      } label: {
        menuLabel("BorgVR Help", systemImage: "questionmark.circle")
      }
      .keyboardShortcut("?", modifiers: .command)
    }
  }

  private var hasActiveDataset: Bool {
    appModel.activeDataset != nil
  }

  private func renderCommand(
    _ title: String,
    systemImage: String,
    shortcut: MacRenderShortcut
  ) -> some View {
    Button {
      docking.request(.render(shortcut))
    } label: {
      menuLabel(LocalizedStringKey(title), systemImage: systemImage)
    }
    .macRenderShortcut(shortcut)
    .disabled(!hasActiveDataset)
  }

  private func selectionCommand(
    _ title: String,
    systemImage: String,
    shortcut: MacRenderShortcut,
    isSelected: Bool
  ) -> some View {
    Toggle(
      isOn: Binding(
        get: { isSelected },
        set: { shouldSelect in
          guard shouldSelect else { return }
          docking.request(.render(shortcut))
        }
      )
    ) {
      menuLabel(LocalizedStringKey(title), systemImage: systemImage)
    }
    .macRenderShortcut(shortcut)
    .disabled(!hasActiveDataset)
  }

  private func menuLabel(
    _ title: LocalizedStringKey,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
      .labelStyle(.titleAndIcon)
  }

  private var canCopyWebGPUShareLink: Bool {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = appModel.activeDataset,
          serverController.datasets.contains(where: {
            $0.id.caseInsensitiveCompare(dataset.uniqueId) == .orderedSame
          }) else {
      return false
    }
    return baseURL.scheme == "https"
  }

  private func copyWebGPUShareLink() {
    guard let baseURL = serverController.shareableWebServerURL,
          let dataset = appModel.activeDataset else { return }
    guard let url = WebGPUShareLink.datasetURL(
      baseURL: baseURL,
      datasetID: dataset.uniqueId,
      transferFunctions: Array(renderingParameters.activeTransferFunctions),
      renderMode: renderingParameters.renderMode,
      normalizedIsoValue: renderingParameters.normIsoValue
    ) else { return }
    WebGPUShareLink.copyToPasteboard(url.absoluteString)
  }
}
