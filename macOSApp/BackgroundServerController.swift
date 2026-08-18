import Darwin
import Foundation

@MainActor
final class BackgroundServerController: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var statusText = "Server ist nicht gestartet."
  @Published private(set) var datasets: [DatasetInfo] = []

  private let serverHost: BorgVRServerHost
  private let sharePlayServerHost: BorgVRServerHost
  private let logger = GUILogger()
  private var sharePlayDatasetID: String?
  private var sharePlayAuthToken = ""
  private var sharePlayServerRunning = false
  private var sharePlayServerPort = StoredAppModel.defaultPort + 1
  private var runningPort = StoredAppModel.defaultPort

  init() {
    self.serverHost = BorgVRServerHost(logger: logger)
    self.sharePlayServerHost = BorgVRServerHost(logger: logger)
  }

  func start(using settings: StoredAppModel) {
    _ = settings.activateDataDirectoryAccess()
    startServer(using: settings, additionalDatasets: [])
  }

  func ensureServing(dataset: AppModel.DatasetEntry, using settings: StoredAppModel) -> (origins: [String], authToken: String) {
    guard let datasetInfo = serverDatasetInfo(for: dataset) else {
      return ([], "")
    }

    if sharePlayServerRunning,
       sharePlayDatasetID == datasetInfo.id {
      return (originAddresses(port: sharePlayServerPort), sharePlayAuthToken)
    }

    stopSharePlayServer()
    let authToken = BorgVRServerAuthentication.randomToken()
    for port in sharePlayCandidatePorts(preferredPort: settings.sharePlayServerPort) {
      let state = sharePlayServerHost.start(
        configuration: BorgVRServerConfiguration(
          dataDirectory: "",
          port: port,
          maxBricksPerGetRequest: settings.maxBricksPerGetRequest,
          authSecret: authToken
        ),
        additionalDatasets: [datasetInfo],
        includeScannedDatasets: false
      )

      guard state.isRunning, state.datasets.contains(where: { $0.id == datasetInfo.id }) else {
        continue
      }

      sharePlayDatasetID = datasetInfo.id
      sharePlayAuthToken = authToken
      sharePlayServerRunning = true
      sharePlayServerPort = state.port
      return (originAddresses(port: state.port), authToken)
    }

    logger.error("SharePlay dataset server did not start for dataset \(datasetInfo.id).")
    return ([], "")
  }

  private func startServer(using settings: StoredAppModel, additionalDatasets: [DatasetInfo]) {
    let state = serverHost.start(
      configuration: BorgVRServerConfiguration(
        dataDirectory: settings.dataDirectory,
        port: settings.port,
        maxBricksPerGetRequest: settings.maxBricksPerGetRequest,
        authSecret: settings.serverPassword
      ),
      additionalDatasets: additionalDatasets
    )

    datasets = state.datasets
    isRunning = state.isRunning
    runningPort = state.port
    statusText = isRunning
      ? "Port \(state.port), \(datasets.count) Datensätze"
      : "Server konnte nicht gestartet werden."
  }

  func stop() {
    serverHost.stop()
    isRunning = false
    statusText = "Server ist nicht gestartet."
  }

  func stopSharePlayServer() {
    sharePlayServerHost.stop()
    sharePlayDatasetID = nil
    sharePlayAuthToken = ""
    sharePlayServerRunning = false
  }

  private func serverDatasetInfo(for dataset: AppModel.DatasetEntry) -> DatasetInfo? {
    switch dataset.source {
      case .local, .builtIn:
        let url = URL(fileURLWithPath: dataset.identifier)
        guard let metadata = try? BORGVRMetaData(url: url) else {
          logger.error("SharePlay dataset server could not read metadata for \(dataset.identifier).")
          return nil
        }
        return DatasetInfo(
          id: metadata.uniqueID,
          filename: url.path,
          datasetDescription: metadata.datasetDescription.isEmpty ? dataset.description : metadata.datasetDescription
        )
      case .remote:
        return nil
    }
  }

  private func originAddresses(port: Int) -> [String] {
    var addresses = Self.localIPv4Addresses()
    if let hostname = Host.current().localizedName, !hostname.isEmpty {
      addresses.append(hostname)
    }

    var seen = Set<String>()
    let uniqueAddresses = addresses.filter { address in
      seen.insert(address).inserted
    }

    guard !uniqueAddresses.isEmpty else {
      logger.error("SharePlay dataset server could not determine a local network address.")
      return []
    }
    return uniqueAddresses.map { "\($0):\(port)" }
  }

  private func sharePlayCandidatePorts(preferredPort: Int) -> [Int] {
    let basePort = min(65534, max(1024, preferredPort))
    var ports: [Int] = [basePort]
    for offset in 1...64 {
      let port = basePort + offset
      if port <= 65535 {
        ports.append(port)
      }
    }
    for offset in 1...64 {
      let port = basePort - offset
      if port >= 1024 {
        ports.append(port)
      }
    }

    var seen = Set<Int>()
    return ports.filter { port in
      port != runningPort && seen.insert(port).inserted
    }
  }

  private static func localIPv4Addresses() -> [String] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return []
    }
    defer { freeifaddrs(interfaces) }

    var preferredAddresses: [String] = []
    var fallbackAddresses: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let interface = pointer?.pointee {
      defer { pointer = interface.ifa_next }

      let flags = Int32(interface.ifa_flags)
      guard (flags & IFF_UP) != 0,
            (flags & IFF_LOOPBACK) == 0,
            let addressPointer = interface.ifa_addr,
            addressPointer.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        addressPointer,
        socklen_t(addressPointer.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard result == 0 else { continue }

      let address = String(cString: hostname)
      let name = String(cString: interface.ifa_name)
      if name.hasPrefix("en") {
        preferredAddresses.append(address)
      } else {
        fallbackAddresses.append(address)
      }
    }

    return preferredAddresses + fallbackAddresses
  }
}
