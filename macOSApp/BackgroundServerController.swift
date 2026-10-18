import Foundation

@MainActor
final class BackgroundServerController: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var statusText = String(localized: "Server is not started.")
  @Published private(set) var datasets: [DatasetInfo] = []
  @Published private(set) var shareableWebServerURL: URL?

  private let serverHost: BorgVRServerHost
  private let sharePlayServer: BorgVRSharePlayAdHocServer
  private let logger = GUILogger()
  private var runningPort = StoredAppModel.defaultPort

  init() {
    self.serverHost = BorgVRServerHost(logger: logger)
    self.sharePlayServer = BorgVRSharePlayAdHocServer(logger: logger)
  }

  func start(using settings: StoredAppModel) {
    guard settings.enableDatasetServer else {
      stop()
      return
    }

    _ = settings.activateDataDirectoryAccess()
    startServer(using: settings, additionalDatasets: [])
  }

  func ensureServing(
    dataset: AppModel.DatasetEntry,
    using settings: StoredAppModel
  ) -> [DatasetOrigin] {
    let fileURL: URL
    switch dataset.source {
      case .local, .builtIn:
        fileURL = URL(fileURLWithPath: dataset.identifier)
      case .remote:
        fileURL = settings.resolvedDataDirectoryURL()
          .appendingPathComponent("\(dataset.uniqueId).data")
    }
    let hostname = Host.current().localizedName.map { [$0] } ?? []
    return sharePlayServer.ensureServing(
      dataset: dataset,
      fileURL: fileURL,
      settings: BorgVRSharePlayAdHocServerSettings(
        preferredServerPort: settings.sharePlayServerPort,
        maximumBricksPerRequest: settings.maxBricksPerGetRequest,
        enablesWebServer: settings.enableWebServer,
        preferredWebServerPort: settings.sharePlayWebServerPort,
        usesWebServerTLS: settings.webServerUsesTLS,
        webServerCertificateData: settings.webServerCertificateData,
        webServerCertificatePassword: settings.webServerCertificatePassword,
        excludedPorts: [runningPort]
      ),
      additionalHostnames: hostname
    )
  }

  private func startServer(using settings: StoredAppModel, additionalDatasets: [DatasetInfo]) {
    let state = serverHost.start(
      configuration: BorgVRServerConfiguration(
        dataDirectory: settings.dataDirectory,
        port: settings.port,
        maxBricksPerGetRequest: settings.maxBricksPerGetRequest,
        authSecret: settings.serverPassword,
        enableWebServer: settings.enableWebServer,
        webPort: settings.webServerPort,
        useWebServerTLS: settings.webServerUsesTLS,
        webServerCertificateData: settings.webServerCertificateData,
        webServerCertificatePassword: settings.webServerCertificatePassword
      ),
      additionalDatasets: additionalDatasets,
      additionalMeshFiles: SceneMeshAssetCatalog.serverFiles(logger: logger)
    )

    datasets = state.datasets
    isRunning = state.isRunning
    runningPort = state.port
    shareableWebServerURL = state.isWebServerRunning && state.webServerUsesTLS
      ? WebGPUShareLink.serverBaseURL(port: state.webPort)
      : nil
    let webStatus: String
    if state.isWebServerRunning {
      webStatus = ", WebGPU \(state.webServerUsesTLS ? "HTTPS" : "HTTP") \(state.webPort)"
    } else if settings.enableWebServer {
      let reason = state.webServerError.map { ": \($0)" } ?? ""
      let failedStatus = String(
        format: String(localized: "WebGPU %@ %@ failed%@"),
        state.webServerUsesTLS ? "HTTPS" : "HTTP",
        "\(state.webPort)",
        reason
      )
      webStatus = ", \(failedStatus)"
    } else {
      webStatus = ""
    }
    if isRunning {
      statusText = String(
        format: String(localized: "Port %@%@, %@ datasets"),
        "\(state.port)",
        webStatus,
        "\(datasets.count)"
      )
    } else {
      let reason = state.serverError.map { ": \($0)" } ?? ""
      statusText = "Server could not be started\(reason)"
    }
  }

  func stop() {
    serverHost.stop()
    shareableWebServerURL = nil
    isRunning = false
    statusText = String(localized: "Server is not started.")
  }

  func stopSharePlayServer() {
    sharePlayServer.stop()
  }

  func serves(meshAssetIDs: Set<UUID>, for datasetID: String) -> Bool {
    sharePlayServer.serves(meshAssetIDs: meshAssetIDs, for: datasetID)
  }
}
