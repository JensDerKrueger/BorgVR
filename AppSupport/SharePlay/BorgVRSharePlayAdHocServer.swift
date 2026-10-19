import Darwin
import Foundation

struct BorgVRSharePlayAdHocServerSettings {
  let preferredServerPort: Int
  let maximumBricksPerRequest: Int
  let enablesWebServer: Bool
  let preferredWebServerPort: Int
  let usesWebServerTLS: Bool
  let webServerCertificateData: Data
  let webServerCertificatePassword: String
  let excludedPorts: Set<Int>
}

@MainActor
final class BorgVRSharePlayAdHocServer {
  private let serverHost: BorgVRServerHost
  private let logger: GUILogger
  private var datasetID: String?
  private var authToken = ""
  private var isRunning = false
  private var port = 0
  private var meshAssetIDs = Set<UUID>()

  init(logger: GUILogger = GUILogger()) {
    self.logger = logger
    self.serverHost = BorgVRServerHost(logger: logger)
  }

  func ensureServing(
    dataset: AppModel.DatasetEntry,
    fileURL: URL?,
    settings: BorgVRSharePlayAdHocServerSettings,
    additionalHostnames: [String] = []
  ) -> [DatasetOrigin] {
    guard let fileURL,
          let datasetInfo = datasetInfo(for: dataset, fileURL: fileURL) else {
      stop()
      return []
    }

    let meshFiles = SceneMeshAssetCatalog.serverFiles(logger: logger)
    let requestedMeshAssetIDs = Set(meshFiles.map(\.id))
    if isRunning,
       datasetID == dataset.uniqueId,
       meshAssetIDs == requestedMeshAssetIDs {
      return origins(
        port: port,
        authToken: authToken,
        additionalHostnames: additionalHostnames
      )
    }

    stop()
    let newAuthToken = BorgVRServerAuthentication.randomToken()
    for candidatePort in candidatePorts(
      preferredPort: settings.preferredServerPort,
      excludedPorts: settings.excludedPorts
    ) {
      let state = serverHost.start(
        configuration: BorgVRServerConfiguration(
          dataDirectory: "",
          port: candidatePort,
          maxBricksPerGetRequest: settings.maximumBricksPerRequest,
          authSecret: newAuthToken,
          enableWebServer: settings.enablesWebServer,
          webPort: webServerPort(
            serverPort: candidatePort,
            preferredServerPort: settings.preferredServerPort,
            preferredWebServerPort: settings.preferredWebServerPort
          ),
          useWebServerTLS: settings.usesWebServerTLS,
          webServerCertificateData: settings.webServerCertificateData,
          webServerCertificatePassword: settings.webServerCertificatePassword
        ),
        additionalDatasets: [datasetInfo],
        additionalMeshFiles: meshFiles,
        includeScannedDatasets: false
      )

      guard state.isRunning,
            state.datasets.contains(where: { $0.id == dataset.uniqueId }) else {
        continue
      }

      datasetID = dataset.uniqueId
      authToken = newAuthToken
      isRunning = true
      port = state.port
      meshAssetIDs = requestedMeshAssetIDs
      return origins(
        port: state.port,
        authToken: newAuthToken,
        additionalHostnames: additionalHostnames
      )
    }

    logger.error("SharePlay asset server did not start for dataset \(dataset.uniqueId).")
    return []
  }

  func serves(meshAssetIDs requestedMeshAssetIDs: Set<UUID>, for datasetID: String) -> Bool {
    isRunning
      && self.datasetID == datasetID
      && requestedMeshAssetIDs.isSubset(of: meshAssetIDs)
  }

  func stop() {
    serverHost.stop()
    datasetID = nil
    authToken = ""
    isRunning = false
    port = 0
    meshAssetIDs.removeAll()
  }

  private func datasetInfo(
    for dataset: AppModel.DatasetEntry,
    fileURL: URL
  ) -> DatasetInfo? {
    guard let metadata = try? BORGVRMetaData(url: fileURL),
          metadata.uniqueID.caseInsensitiveCompare(dataset.uniqueId) == .orderedSame else {
      if dataset.source.isLocalFile {
        logger.error("SharePlay dataset server could not read metadata for \(dataset.identifier).")
      }
      return nil
    }
    return DatasetInfo(
      id: metadata.uniqueID,
      filename: fileURL.path,
      datasetDescription: metadata.datasetDescription.isEmpty
        ? dataset.description
        : metadata.datasetDescription,
      size: [metadata.width, metadata.height, metadata.depth],
      voxelSpacing: [
        metadata.voxelSpacingX,
        metadata.voxelSpacingY,
        metadata.voxelSpacingZ
      ]
    )
  }

  private func origins(
    port: Int,
    authToken: String,
    additionalHostnames: [String]
  ) -> [DatasetOrigin] {
    var addresses = Self.localIPv4Addresses()
    addresses.append(contentsOf: additionalHostnames.filter { !$0.isEmpty })
    var seen = Set<String>()
    let uniqueAddresses = addresses.filter { seen.insert($0).inserted }
    guard !uniqueAddresses.isEmpty else {
      logger.error("SharePlay dataset server could not determine a local network address.")
      return []
    }
    return uniqueAddresses.map {
      DatasetOrigin(address: $0, port: port, password: authToken)
    }
  }

  private func webServerPort(
    serverPort: Int,
    preferredServerPort: Int,
    preferredWebServerPort: Int
  ) -> Int {
    if preferredWebServerPort == preferredServerPort {
      return min(65535, max(1, serverPort + 1))
    }
    return preferredWebServerPort
  }

  private func candidatePorts(
    preferredPort: Int,
    excludedPorts: Set<Int>
  ) -> [Int] {
    let basePort = min(65534, max(1024, preferredPort))
    var ports = [basePort]
    for offset in 1...64 where basePort + offset <= 65535 {
      ports.append(basePort + offset)
    }
    for offset in 1...64 where basePort - offset >= 1024 {
      ports.append(basePort - offset)
    }
    var seen = Set<Int>()
    return ports.filter { !excludedPorts.contains($0) && seen.insert($0).inserted }
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
            addressPointer.pointee.sa_family == UInt8(AF_INET) else {
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

private extension AppModel.DatasetSource {
  var isLocalFile: Bool {
    switch self {
      case .local, .builtIn:
        return true
      case .remote:
        return false
    }
  }
}
