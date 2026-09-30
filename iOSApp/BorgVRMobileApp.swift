import SwiftUI

@main
struct BorgVRMobileApp: App {
  @State private var appModel = AppModel()
  @State private var renderingParameters = RenderingParameters()
  @StateObject private var appSettings = AppSettings()
  @StateObject private var sharePlay = SharePlayCoordinator()
  @StateObject private var serverController = BackgroundServerController()
  @StateObject private var updateChecker = AppStoreUpdateChecker()
  @AppStorage("sharePlayDisplayNameOnboardingCompleted")
  private var sharePlayDisplayNameOnboardingCompleted = false
  @State private var showsSharePlayDisplayNameOnboarding = false
  @State private var sharePlayDisplayNameDraft = ""

  var body: some Scene {
    WindowGroup {
      ContentView()
        .appStoreUpdateAlert(using: updateChecker)
        .alert(
          "Choose your SharePlay name",
          isPresented: $showsSharePlayDisplayNameOnboarding
        ) {
          TextField("Display name", text: $sharePlayDisplayNameDraft)
          Button("Continue") {
            appSettings.sharePlayDisplayName = sharePlayDisplayNameDraft
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
        .environmentObject(sharePlay)
        .environmentObject(serverController)
        .environmentObject(updateChecker)
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
        appModel.activeDataset = dataset
        appModel.groupSessionHost = true
        appModel.currentState = .renderData
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
