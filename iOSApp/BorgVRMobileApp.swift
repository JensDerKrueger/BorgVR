import SwiftUI

@main
struct BorgVRMobileApp: App {
  @State private var appModel = AppModel()
  @State private var renderingParameters = RenderingParameters()
  @StateObject private var appSettings = AppSettings()
  @StateObject private var sharePlay = SharePlayCoordinator()
  @StateObject private var serverController = BackgroundServerController()
  @StateObject private var updateChecker = AppStoreUpdateChecker()
  @StateObject private var mcpController = BorgVRMCPServerController()
  @AppStorage("sharePlayDisplayNameOnboardingCompleted")
  private var sharePlayDisplayNameOnboardingCompleted = false
  @State private var showsSharePlayDisplayNameOnboarding = false
  @State private var sharePlayDisplayNameDraft = ""

  var body: some Scene {
    WindowGroup {
      ContentView()
        .appStoreUpdateAlert(using: updateChecker)
        .sheet(isPresented: $showsSharePlayDisplayNameOnboarding) {
          SharePlayDisplayNameOnboardingView(name: $sharePlayDisplayNameDraft) {
            appSettings.sharePlayDisplayName = sharePlayDisplayNameDraft
              .trimmingCharacters(in: .whitespacesAndNewlines)
            sharePlayDisplayNameOnboardingCompleted = true
            showsSharePlayDisplayNameOnboarding = false
          }
          .interactiveDismissDisabled()
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
        .environmentObject(sharePlay)
        .environmentObject(serverController)
        .environmentObject(updateChecker)
        .environmentObject(mcpController)
        .task {
          await presentSharePlayDisplayNameOnboardingIfNeeded()
        }
        .onAppear {
          sharePlay.startObservingSessions(
            appModel: appModel,
            renderingParameters: renderingParameters,
            appSettings: appSettings
          )
          appModel.setLogLevel(appSettings.logLevel)
          configureMCP()
        }
        .onChange(of: sharePlay.hasObservedGroupSession) { _, hasObservedSession in
          if hasObservedSession {
            showsSharePlayDisplayNameOnboarding = false
          }
        }
        .onChange(of: appSettings.logLevel) { _, newValue in
          appModel.setLogLevel(newValue)
        }
        .onChange(of: appSettings.sharePlayDisplayName) { _, _ in
          sharePlay.participantInfoChanged()
        }
        .onChange(of: appSettings.autoStartServer) { _, enabled in
          if enabled, appSettings.enableDatasetServer, !serverController.isRunning {
            serverController.start(using: appSettings)
          }
        }
        .onChange(of: appSettings.enableDatasetServer) { _, enabled in
          if enabled {
            if appSettings.autoStartServer, !serverController.isRunning {
              serverController.start(using: appSettings)
            }
          } else {
            serverController.stop()
          }
        }
        .onChange(of: appSettings.serverPort) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.serverPassword) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.maxBricksPerGetRequest) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.enableWebServer) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.webServerPort) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.webServerUsesTLS) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.webServerCertificateData) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.enableMCPServer) { _, _ in applyMCPConfiguration() }
        .onChange(of: appSettings.mcpServerPort) { _, _ in applyMCPConfiguration() }
        .onChange(of: appSettings.mcpAllowRemoteConnections) { _, _ in applyMCPConfiguration() }
        .onChange(of: appSettings.mcpAccessToken) { _, _ in applyMCPConfiguration() }
        .onChange(of: appSettings.mcpServerCertificateData) { _, _ in applyMCPConfiguration() }
        .task {
          if appSettings.enableDatasetServer && appSettings.autoStartServer {
            serverController.start(using: appSettings)
          }
        }
        .onOpenURL { url in
          openExternalDataset(url)
        }
    }
    .handlesExternalEvents(matching: [BorgVRSharePlayActivity.activityIdentifier])
  }

  @MainActor
  private func configureMCP() {
    let service = BorgVRScreenCommandService(
      appModel: appModel,
      renderingParameters: renderingParameters,
      synchronizeTransform: { sharePlay.synchronize(kind: .transformOnly) },
      synchronizeState: { sharePlay.synchronize(kind: .stateOnly) },
      synchronizeFullState: { sharePlay.synchronize(kind: .full) },
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
    mcpController.configure(commandService: service, logger: appModel.logger)
    applyMCPConfiguration()
  }

  @MainActor
  private func loadMCPDatasetRecords() async -> [BorgVRMCPDatasetRecord] {
    let documentsDirectory = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first
    return await BorgVRMCPDatasetCatalog.load(
      localDirectory: documentsDirectory,
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
    appModel.openDataset(entry, asGroupSessionHost: sharePlay.isInSession ? nil : true)
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
    appModel.closeDataset(destination: .datasetSelection)
  }

  @MainActor
  private func applyMCPConfiguration() {
    mcpController.apply(BorgVRMCPConfiguration(
      enabled: appSettings.enableMCPServer,
      port: appSettings.mcpServerPort,
      allowRemoteConnections: appSettings.mcpAllowRemoteConnections,
      accessToken: appSettings.mcpAccessToken,
      tlsCertificateData: appSettings.mcpServerCertificateData,
      tlsCertificatePassword: appSettings.mcpServerCertificatePassword
    ))
  }

  @MainActor
  private func presentSharePlayDisplayNameOnboardingIfNeeded() async {
    guard !sharePlayDisplayNameOnboardingCompleted,
          !showsSharePlayDisplayNameOnboarding else { return }
    let configuredName = appSettings.sharePlayDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredName.isEmpty {
      sharePlayDisplayNameOnboardingCompleted = true
      return
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)
    guard !Task.isCancelled,
          !sharePlay.hasObservedGroupSession,
          !sharePlay.isInSession else { return }

    sharePlayDisplayNameDraft = UIDevice.current.name
    showsSharePlayDisplayNameOnboarding = true
  }

  private func openExternalDataset(_ url: URL) {
    Task { @MainActor in
      do {
        guard let documentsDirectory = FileManager.default.urls(
          for: .documentDirectory,
          in: .userDomainMask
        ).first else {
          throw ExternalDatasetImportError.destinationUnavailable
        }

        let dataset = try ExternalDatasetImporter.importDataset(
          from: url,
          into: documentsDirectory,
          logger: appModel.logger
        )
        appModel.openDataset(dataset, asGroupSessionHost: true)
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

private struct SharePlayDisplayNameOnboardingView: View {
  @Binding var name: String
  let onContinue: () -> Void

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Display name", text: $name)
            .textContentType(.name)
            .submitLabel(.continue)
            .onSubmit(continueIfPossible)
        } footer: {
          Text("What name should other people see for you in shared SharePlay sessions? You can change it later in Settings.")
        }
      }
      .navigationTitle("Choose your SharePlay name")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Continue", action: onContinue)
            .disabled(trimmedName.isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private func continueIfPossible() {
    guard !trimmedName.isEmpty else { return }
    onContinue()
  }
}
