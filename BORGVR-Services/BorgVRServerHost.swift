import Foundation

struct BorgVRServerConfiguration {
  var dataDirectory: String
  var port: Int
  var maxBricksPerGetRequest: Int
  var authSecret: String = ""
  var startDatasetServer: Bool = true
  var enableWebServer: Bool = false
  var webPort: Int = 8080
  var useWebServerTLS: Bool = true
  var webServerCertificateData: Data = Data()
  var webServerCertificatePassword: String = ""
}

struct BorgVRServerState {
  var isRunning: Bool
  var datasets: [DatasetInfo]
  var port: Int
  var serverError: String?
  var isWebServerRunning: Bool
  var webPort: Int
  var webServerUsesTLS: Bool
  var webServerError: String?
}

final class BorgVRServerHost {
  private var server: TCPServer?
  private var webServer: HTTPWebServer?
  private let logger: LoggerBase?

  private(set) var state = BorgVRServerState(
    isRunning: false,
    datasets: [],
    port: StoredServerDefaults.port,
    serverError: nil,
    isWebServerRunning: false,
    webPort: StoredServerDefaults.webPort,
    webServerUsesTLS: StoredServerDefaults.useWebServerTLS,
    webServerError: nil
  )

  init(logger: LoggerBase? = nil) {
    self.logger = logger
  }

  @discardableResult
  func start(
    configuration: BorgVRServerConfiguration,
    additionalDatasets: [DatasetInfo] = [],
    includeScannedDatasets: Bool = true
  ) -> BorgVRServerState {
    stop()

    let scannedDatasets: [DatasetInfo]
    let scannedTransferFunctions: [TransferFunctionInfo]
    if includeScannedDatasets {
      let scanner = DatasetScanner(directory: configuration.dataDirectory, logger: logger)
      scanner.loadDatasets()
      scannedDatasets = scanner.getDatasets()
      scannedTransferFunctions = scanner.getTransferFunctions()
    } else {
      scannedDatasets = []
      scannedTransferFunctions = []
    }
    let datasets = mergedDatasets(scannedDatasets, additionalDatasets: additionalDatasets)
    let transferFunctions = mergedTransferFunctions(
      scannedTransferFunctions,
      additionalTransferFunctions: DatasetScanner.bundledTransferFunctions(logger: logger)
    )

    let serverPort = UInt16(clamping: configuration.port)
    let newServer = TCPServer(
      port: serverPort,
      maxBricksPerGetRequest: configuration.maxBricksPerGetRequest,
      logger: logger,
      datasets: datasets,
      transferFunctions: transferFunctions,
      authSecret: configuration.authSecret
    )
    if configuration.startDatasetServer {
      newServer.start()
    }

    let webPort = effectiveWebPort(configuration: configuration, serverPort: serverPort)
    let newWebServer: HTTPWebServer?
    if configuration.enableWebServer {
      let server = HTTPWebServer(
        port: webPort,
        datasetServer: newServer,
        logger: logger,
        authSecret: configuration.authSecret,
        useTLS: configuration.useWebServerTLS,
        tlsCertificateData: configuration.webServerCertificateData,
        tlsCertificatePassword: configuration.webServerCertificatePassword
      )
      server.start()
      newWebServer = server
    } else {
      newWebServer = nil
    }

    server = newServer
    webServer = newWebServer
    state = BorgVRServerState(
      isRunning: newServer.isRunning || (newWebServer?.isRunning ?? false),
      datasets: datasets,
      port: Int(serverPort),
      serverError: newServer.lastError,
      isWebServerRunning: newWebServer?.isRunning ?? false,
      webPort: Int(webPort),
      webServerUsesTLS: configuration.useWebServerTLS,
      webServerError: newWebServer?.lastError
    )
    return state
  }

  func stop() {
    webServer?.stop()
    webServer = nil
    server?.stop()
    server = nil
    state = BorgVRServerState(
      isRunning: false,
      datasets: [],
      port: state.port,
      serverError: nil,
      isWebServerRunning: false,
      webPort: state.webPort,
      webServerUsesTLS: state.webServerUsesTLS,
      webServerError: nil
    )
  }

  private func mergedDatasets(_ scannedDatasets: [DatasetInfo], additionalDatasets: [DatasetInfo]) -> [DatasetInfo] {
    var datasets = scannedDatasets
    var knownIDs = Set(scannedDatasets.map(\.id))

    for dataset in additionalDatasets where !knownIDs.contains(dataset.id) {
      datasets.append(dataset)
      knownIDs.insert(dataset.id)
    }

    return datasets
  }

  private func mergedTransferFunctions(
    _ scannedTransferFunctions: [TransferFunctionInfo],
    additionalTransferFunctions: [TransferFunctionInfo]
  ) -> [TransferFunctionInfo] {
    var transferFunctions = scannedTransferFunctions
    var knownIDs = Set(scannedTransferFunctions.map(\.id))

    for transferFunction in additionalTransferFunctions where !knownIDs.contains(transferFunction.id) {
      transferFunctions.append(transferFunction)
      knownIDs.insert(transferFunction.id)
    }

    return transferFunctions
  }

  private func effectiveWebPort(configuration: BorgVRServerConfiguration, serverPort: UInt16) -> UInt16 {
    var webPort = UInt16(clamping: configuration.webPort)
    if configuration.startDatasetServer, webPort == serverPort {
      webPort = serverPort == UInt16.max ? 1 : serverPort + 1
      logger?.warning("WebGPU web server port matches the dataset server port. Using \(webPort) instead.")
    }
    return webPort
  }
}

private enum StoredServerDefaults {
  static let port = 12345
  static let webPort = 8080
  static let useWebServerTLS = true
}
