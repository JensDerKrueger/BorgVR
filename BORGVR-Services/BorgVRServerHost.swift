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
  private var catalogFingerprint = Set<String>()

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
    additionalMeshFiles: [MeshFileInfo] = [],
    includeScannedDatasets: Bool = true
  ) -> BorgVRServerState {
    stop()

    let catalog = loadCatalog(
      configuration: configuration,
      additionalDatasets: additionalDatasets,
      additionalMeshFiles: additionalMeshFiles,
      includeScannedDatasets: includeScannedDatasets,
      scanLogger: logger
    )
    logger?.info(
      "Server catalog contains \(catalog.datasets.count) datasets, " +
      "\(catalog.transferFunctions.count) transfer functions, and " +
      "\(catalog.markerFiles.count) marker files and \(catalog.meshFiles.count) meshes."
    )

    let serverPort = UInt16(clamping: configuration.port)
    let newServer = TCPServer(
      port: serverPort,
      maxBricksPerGetRequest: configuration.maxBricksPerGetRequest,
      logger: logger,
      datasets: catalog.datasets,
      transferFunctions: catalog.transferFunctions,
      markerFiles: catalog.markerFiles,
      meshFiles: catalog.meshFiles,
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
    catalogFingerprint = fingerprint(for: catalog)
    state = BorgVRServerState(
      isRunning: newServer.isRunning || (newWebServer?.isRunning ?? false),
      datasets: catalog.datasets,
      port: Int(serverPort),
      serverError: newServer.lastError,
      isWebServerRunning: newWebServer?.isRunning ?? false,
      webPort: Int(webPort),
      webServerUsesTLS: configuration.useWebServerTLS,
      webServerError: newWebServer?.lastError
    )
    return state
  }

  @discardableResult
  func refreshCatalog(
    configuration: BorgVRServerConfiguration,
    additionalDatasets: [DatasetInfo] = [],
    additionalMeshFiles: [MeshFileInfo] = [],
    includeScannedDatasets: Bool = true
  ) -> Bool {
    guard let server else { return false }

    let catalog = loadCatalog(
      configuration: configuration,
      additionalDatasets: additionalDatasets,
      additionalMeshFiles: additionalMeshFiles,
      includeScannedDatasets: includeScannedDatasets,
      scanLogger: nil
    )
    let refreshedFingerprint = fingerprint(for: catalog)
    guard refreshedFingerprint != catalogFingerprint else { return false }

    server.updateCatalog(
      datasets: catalog.datasets,
      transferFunctions: catalog.transferFunctions,
      markerFiles: catalog.markerFiles,
      meshFiles: catalog.meshFiles
    )
    catalogFingerprint = refreshedFingerprint
    state.datasets = catalog.datasets
    return true
  }

  func stop() {
    webServer?.stop()
    webServer = nil
    server?.stop()
    server = nil
    catalogFingerprint.removeAll()
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

  private func mergedMeshFiles(
    _ scannedMeshFiles: [MeshFileInfo],
    additionalMeshFiles: [MeshFileInfo]
  ) -> [MeshFileInfo] {
    var meshFiles = scannedMeshFiles
    var knownIDs = Set(scannedMeshFiles.map(\.id))

    for meshFile in additionalMeshFiles where !knownIDs.contains(meshFile.id) {
      meshFiles.append(meshFile)
      knownIDs.insert(meshFile.id)
    }

    return meshFiles
  }

  private func loadCatalog(
    configuration: BorgVRServerConfiguration,
    additionalDatasets: [DatasetInfo],
    additionalMeshFiles: [MeshFileInfo],
    includeScannedDatasets: Bool,
    scanLogger: LoggerBase?
  ) -> ServerCatalog {
    let scannedDatasets: [DatasetInfo]
    let scannedTransferFunctions: [TransferFunctionInfo]
    let scannedMarkerFiles: [MarkerFileInfo]
    let scannedMeshFiles: [MeshFileInfo]
    if includeScannedDatasets {
      let scanner = DatasetScanner(directory: configuration.dataDirectory, logger: scanLogger)
      scanner.loadDatasets()
      scannedDatasets = scanner.getDatasets()
      scannedTransferFunctions = scanner.getTransferFunctions()
      scannedMarkerFiles = scanner.getMarkerFiles()
      scannedMeshFiles = scanner.getMeshFiles()
    } else {
      scannedDatasets = []
      scannedTransferFunctions = []
      scannedMarkerFiles = []
      scannedMeshFiles = []
    }

    return ServerCatalog(
      datasets: mergedDatasets(scannedDatasets, additionalDatasets: additionalDatasets),
      transferFunctions: mergedTransferFunctions(
        scannedTransferFunctions,
        additionalTransferFunctions: DatasetScanner.bundledTransferFunctions(logger: scanLogger)
      ),
      markerFiles: scannedMarkerFiles,
      meshFiles: mergedMeshFiles(
        scannedMeshFiles,
        additionalMeshFiles: additionalMeshFiles
      )
    )
  }

  private func fingerprint(for catalog: ServerCatalog) -> Set<String> {
    Set(catalog.datasets.map {
      "dataset|\($0.id)|\($0.filename)|\($0.datasetDescription)|\(fileFingerprint(at: $0.filename))"
    })
      .union(catalog.transferFunctions.map {
        "transfer-function|\($0.id)|\($0.filename)|\($0.transferFunctionDescription)|\($0.byteCount)"
      })
      .union(catalog.markerFiles.map {
        "marker|\($0.id)|\($0.filename)|\($0.datasetID)|\($0.markerDescription)|\($0.byteCount)"
      })
      .union(catalog.meshFiles.map {
        "mesh|\($0.id.uuidString)|\($0.filename)|\($0.name)|\($0.byteCount)"
      })
  }

  private func fileFingerprint(at path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      return "missing"
    }
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    return "\(size)|\(modificationDate)"
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

private struct ServerCatalog {
  let datasets: [DatasetInfo]
  let transferFunctions: [TransferFunctionInfo]
  let markerFiles: [MarkerFileInfo]
  let meshFiles: [MeshFileInfo]
}

private enum StoredServerDefaults {
  static let port = BorgVRSharedDefaults.datasetServerPort
  static let webPort = 8080
  static let useWebServerTLS = true
}
