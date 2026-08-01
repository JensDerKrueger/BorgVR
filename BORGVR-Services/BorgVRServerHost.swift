import Foundation

struct BorgVRServerConfiguration {
  var dataDirectory: String
  var port: Int
  var maxBricksPerGetRequest: Int
}

struct BorgVRServerState {
  var isRunning: Bool
  var datasets: [DatasetInfo]
  var port: Int
}

final class BorgVRServerHost {
  private var server: TCPServer?
  private let logger: LoggerBase?

  private(set) var state = BorgVRServerState(
    isRunning: false,
    datasets: [],
    port: StoredServerDefaults.port
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
    if includeScannedDatasets {
      let scanner = DatasetScanner(directory: configuration.dataDirectory, logger: logger)
      scanner.loadDatasets()
      scannedDatasets = scanner.getDatasets()
    } else {
      scannedDatasets = []
    }
    let datasets = mergedDatasets(scannedDatasets, additionalDatasets: additionalDatasets)

    let serverPort = UInt16(clamping: configuration.port)
    let newServer = TCPServer(
      port: serverPort,
      maxBricksPerGetRequest: configuration.maxBricksPerGetRequest,
      logger: logger,
      datasets: datasets
    )
    newServer.start()

    server = newServer
    state = BorgVRServerState(
      isRunning: newServer.isRunning,
      datasets: datasets,
      port: Int(serverPort)
    )
    return state
  }

  func stop() {
    server?.stop()
    server = nil
    state = BorgVRServerState(
      isRunning: false,
      datasets: [],
      port: state.port
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
}

private enum StoredServerDefaults {
  static let port = 12345
}
