import Foundation

@MainActor
struct DatasetStorageAccess {
  let directoryURL: URL?
  private let beginAccessHandler: () -> URL?
  private let endAccessHandler: (URL?) -> Void
  private let accessErrorHandler: () -> String?

  init(
    directoryURL: URL?,
    beginAccess: @escaping () -> URL? = { nil },
    endAccess: @escaping (URL?) -> Void = { _ in },
    accessError: @escaping () -> String? = { nil }
  ) {
    self.directoryURL = directoryURL
    beginAccessHandler = beginAccess
    endAccessHandler = endAccess
    accessErrorHandler = accessError
  }

  func beginAccess() -> URL? {
    beginAccessHandler()
  }

  func endAccess(_ url: URL?) {
    endAccessHandler(url)
  }

  var accessError: String? {
    accessErrorHandler()
  }
}

enum RemoteDatasetOpenError: LocalizedError {
  case documentsDirectoryUnavailable
  case downloadStalled
  case downloadCancelled
  case noReachableOrigin

  var errorDescription: String? {
    switch self {
      case .documentsDirectoryUnavailable:
        return String(localized: "The documents directory is not available.")
      case .downloadStalled:
        return String(localized: "The remote download is no longer making progress.")
      case .downloadCancelled:
        return String(localized: "The remote download was paused.")
      case .noReachableOrigin:
        return String(localized: "The dataset is not available from any known source.")
    }
  }
}

private final class RemoteDatasetDownloadCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

@MainActor
final class DatasetCatalogService {
  private let appSettings: AppSettings
  private let storage: DatasetStorageAccess
  private let logger: LoggerBase?

  private(set) var localAccessError: String?

  init(
    appSettings: AppSettings,
    storage: DatasetStorageAccess,
    logger: LoggerBase?
  ) {
    self.appSettings = appSettings
    self.storage = storage
    self.logger = logger
  }

  func loadDatasets(
    includeRemote: Bool = true,
    includeBuiltIn: Bool = true,
    remoteLoadStarted: (() -> Void)? = nil
  ) async -> [AppModel.DatasetEntry] {
    var loaded = loadLocalDatasets(includeBuiltIn: includeBuiltIn)
    if includeRemote {
      remoteLoadStarted?()
      loaded.append(contentsOf: await loadRemoteDatasets())
    }
    return loaded.sorted { $0.description < $1.description }
  }

  func dataset(matchingID id: String, includeRemote: Bool = true) async -> AppModel.DatasetEntry? {
    let datasets = await loadDatasets(includeRemote: includeRemote)
    return datasets.first { dataset in
      dataset.uniqueId == id ||
        dataset.identifier == id ||
        URL(fileURLWithPath: dataset.identifier).lastPathComponent == id ||
        URL(fileURLWithPath: dataset.identifier).deletingPathExtension().lastPathComponent == id
    }
  }

  func openableDataset(from dataset: AppModel.DatasetEntry) -> AppModel.DatasetEntry {
    guard dataset.source == .local,
          !dataset.identifier.hasPrefix("/"),
          let directoryURL = storage.directoryURL else {
      return dataset
    }
    return AppModel.DatasetEntry(
      identifier: directoryURL.appendingPathComponent(dataset.identifier).path,
      description: dataset.description,
      source: dataset.source,
      uniqueId: dataset.uniqueId,
      metadataSummary: dataset.metadataSummary
    )
  }

  private func loadLocalDatasets(includeBuiltIn: Bool) -> [AppModel.DatasetEntry] {
    var loaded: [AppModel.DatasetEntry] = []
    let accessURL = storage.beginAccess()
    defer { storage.endAccess(accessURL) }

    localAccessError = storage.accessError
    if let localAccessError {
      logger?.error(localAccessError)
    }

    if let directoryURL = storage.directoryURL {
      do {
        let files = try FileManager.default.contentsOfDirectory(
          at: directoryURL,
          includingPropertiesForKeys: nil
        )
        for url in files where url.pathExtension.lowercased() == "data" {
          if let data = try? BORGVRFileData(filename: url.path) {
            let metadata = data.getMetadata()
            loaded.append(
              AppModel.DatasetEntry(
                identifier: url.path,
                description: metadata.datasetDescription,
                source: .local,
                uniqueId: metadata.uniqueID,
                metadataSummary: Self.metadataSummary(for: metadata)
              )
            )
          }
        }
      } catch {
        let message = "Error loading dataset files in \(directoryURL.path): \(error.localizedDescription)"
        localAccessError = message
        logger?.error(message)
      }
    } else {
      localAccessError = String(localized: "The documents directory is not available.")
    }

    if includeBuiltIn,
       let datasetURLs = Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) {
      for url in datasetURLs {
        if let metadata = try? BORGVRMetaData(url: url) {
          loaded.append(
            AppModel.DatasetEntry(
              identifier: url.path,
              description: metadata.datasetDescription,
              source: .builtIn,
              uniqueId: metadata.uniqueID,
              metadataSummary: Self.metadataSummary(for: metadata)
            )
          )
        }
      }
    }
    return loaded
  }

  private func loadRemoteDatasets() async -> [AppModel.DatasetEntry] {
    let servers = appSettings.servers.filter { !$0.address.isEmpty }
    let timeout = appSettings.timeout
    let logger = logger

    return await Task.detached(priority: .userInitiated) {
      var loaded: [AppModel.DatasetEntry] = []
      for server in servers {
        do {
          let manager = BORGVRRemoteDataManager(
            host: server.address,
            port: UInt16(clamping: server.port),
            authSecret: server.password,
            logger: logger
          )
          try manager.connect(timeout: timeout)
          Self.synchronizeServerAssets(
            manager: manager,
            address: server.address,
            port: server.port,
            logger: logger
          )
          let remoteDatasets = try manager.requestDatasetList()
          DatasetOriginCatalog.shared.recordServerSnapshot(
            origin: DatasetOrigin(
              address: server.address,
              port: server.port,
              password: server.password
            ),
            datasetIDs: remoteDatasets.map(\.id),
            allowsSharing: server.shareViaSharePlay
          )
          loaded.append(contentsOf: remoteDatasets.map { dataset in
            AppModel.DatasetEntry(
              identifier: dataset.id,
              description: dataset.description,
              source: .remote(
                address: server.address,
                port: server.port,
                password: server.password
              ),
              uniqueId: dataset.id,
              metadataSummary: nil
            )
          })
        } catch {
          logger?.error(
            "Error connecting to remote server \(server.address):\(server.port): " +
              error.localizedDescription
          )
        }
      }
      return loaded
    }.value
  }

  nonisolated private static func synchronizeServerAssets(
    manager: BORGVRRemoteDataManager,
    address: String,
    port: Int,
    logger: LoggerBase?
  ) {
    do {
      let count = try TransferFunctionCatalog.storeRemoteTransferFunctions(from: manager, logger: logger)
      if count > 0 {
        logger?.info("Synced \(count) transfer functions from \(address):\(port).")
      }
    } catch {
      logger?.warning("Transfer function sync failed for \(address):\(port): \(error.localizedDescription)")
    }
    do {
      let count = try VolumeMarkerCatalog.storeRemoteMarkerFiles(from: manager, logger: logger)
      if count > 0 {
        logger?.info("Synced \(count) marker files from \(address):\(port).")
      }
    } catch {
      logger?.warning("Marker file sync failed for \(address):\(port): \(error.localizedDescription)")
    }
    do {
      let count = try SceneMeshAssetCatalog.storeRemoteMeshes(from: manager, logger: logger)
      if count > 0 {
        logger?.info("Synced \(count) meshes from \(address):\(port).")
      }
    } catch {
      logger?.warning("Mesh sync failed for \(address):\(port): \(error.localizedDescription)")
    }
  }

  static func metadataSummary(for metadata: BORGVRMetaData) -> String {
    let bitsPerComponent = metadata.bytesPerComponent * 8
    let channelText = metadata.componentCount == 1
      ? String(localized: "1 channel")
      : String(format: String(localized: "metadata_channel_count_format"), metadata.componentCount)
    let compressionText = metadata.compression
      ? String(localized: "compressed")
      : String(localized: "uncompressed")
    let lodText = metadata.levelMetadata.count == 1
      ? String(localized: "1 LOD")
      : String(format: String(localized: "metadata_lod_count_format"), metadata.levelMetadata.count)

    return "\(metadata.width) x \(metadata.height) x \(metadata.depth) - " +
      "\(bitsPerComponent)-bit, \(channelText) - " +
      "\(String(localized: "Brick")) \(metadata.brickSize) - \(lodText) - " +
      "\(compressionText) - \(String(localized: "Values")) \(metadata.minValue)...\(metadata.maxValue)"
  }
}

@MainActor
final class DatasetOpenWorkflow: ObservableObject {
  @Published private(set) var datasets: [AppModel.DatasetEntry] = []
  @Published var selectedDatasetKey: String?
  @Published private(set) var isLoading = false
  @Published private(set) var isOpening = false
  @Published private(set) var statusText = ""
  @Published private(set) var openProgress: Double?
  @Published var openErrorMessage: String?
  @Published private(set) var dataDirectoryAccessMessage: String?

  private var openingTask: Task<Void, Never>?
  private var downloadCancellation: RemoteDatasetDownloadCancellation?

  var selectedDataset: AppModel.DatasetEntry? {
    guard let selectedDatasetKey else { return nil }
    return datasets.first { $0.selectionKey == selectedDatasetKey }
  }

  func loadDatasetFiles(
    appSettings: AppSettings,
    storage: DatasetStorageAccess,
    logger: LoggerBase
  ) async {
    guard !isOpening else { return }
    isLoading = true
    statusText = String(localized: "Reading local datasets ...")
    await Task.yield()

    let catalog = DatasetCatalogService(
      appSettings: appSettings,
      storage: storage,
      logger: logger
    )
    let loaded = await catalog.loadDatasets(
      includeBuiltIn: !appSettings.hideBuiltInDatasets
    ) {
      self.statusText = String(localized: "Checking remote server ...")
    }
    dataDirectoryAccessMessage = catalog.localAccessError
    datasets = loaded
    if let selectedDatasetKey,
       !datasets.contains(where: { $0.selectionKey == selectedDatasetKey }) {
      self.selectedDatasetKey = nil
    }
    isLoading = false
    statusText = ""
  }

  func startOpening(
    _ dataset: AppModel.DatasetEntry,
    appModel: AppModel,
    appSettings: AppSettings,
    sharePlay: SharePlayCoordinator,
    storage: DatasetStorageAccess
  ) {
    guard !isLoading && !isOpening else { return }
    selectedDatasetKey = dataset.selectionKey
    openingTask?.cancel()
    openingTask = Task { [weak self] in
      await self?.openDatasetEntry(
        dataset,
        appModel: appModel,
        appSettings: appSettings,
        sharePlay: sharePlay,
        storage: storage
      )
    }
  }

  func cancelOpening() {
    downloadCancellation?.cancel()
    openingTask?.cancel()
  }

  func deleteDataset(withKey key: String, storage: DatasetStorageAccess, logger: LoggerBase) {
    guard let dataset = datasets.first(where: { $0.selectionKey == key }),
          dataset.source == .local else { return }
    let accessURL = storage.beginAccess()
    defer { storage.endAccess(accessURL) }
    let fileURL: URL
    if dataset.identifier.hasPrefix("/") {
      fileURL = URL(fileURLWithPath: dataset.identifier)
    } else if let directoryURL = storage.directoryURL {
      fileURL = directoryURL.appendingPathComponent(dataset.identifier)
    } else {
      logger.error(String(localized: "The documents directory is not available."))
      return
    }
    do {
      try FileManager.default.removeItem(at: fileURL)
      datasets.removeAll { $0.selectionKey == key }
      if selectedDatasetKey == key {
        selectedDatasetKey = nil
      }
    } catch {
      logger.error("Error deleting file: \(error.localizedDescription)")
    }
  }

  private func openDatasetEntry(
    _ dataset: AppModel.DatasetEntry,
    appModel: AppModel,
    appSettings: AppSettings,
    sharePlay: SharePlayCoordinator,
    storage: DatasetStorageAccess
  ) async {
    isOpening = true
    statusText = String(localized: "Opening dataset ...")
    defer {
      isOpening = false
      statusText = ""
      openProgress = nil
      openingTask = nil
      downloadCancellation = nil
    }

    do {
      let resolved = try await resolveRemoteDataset(dataset, settings: appSettings)
      let datasetToOpen: AppModel.DatasetEntry
      if case .remote = resolved.source, !appSettings.progressiveLoading {
        let cancellation = RemoteDatasetDownloadCancellation()
        downloadCancellation = cancellation
        datasetToOpen = try await downloadRemoteDatasetBeforeOpening(
          resolved,
          settings: appSettings,
          storage: storage,
          cancellation: cancellation
        )
      } else {
        try await validateDatasetCanOpen(resolved, timeout: appSettings.timeout)
        datasetToOpen = resolved
      }

      let catalog = DatasetCatalogService(
        appSettings: appSettings,
        storage: storage,
        logger: appModel.logger
      )
      appModel.openDataset(
        catalog.openableDataset(from: datasetToOpen),
        asGroupSessionHost: sharePlay.isInSession ? nil : true
      )
      sharePlay.datasetOpened()
    } catch RemoteDatasetOpenError.downloadCancelled {
      appModel.logger.info(String(localized: "Remote dataset download paused."))
    } catch {
      appModel.logger.error("Error opening dataset: \(error.localizedDescription)")
      openErrorMessage = "\(dataset.description)\n\n\(error.localizedDescription)"
      removeUnavailableRemoteEntries(matching: dataset)
    }
  }

  private func resolveRemoteDataset(
    _ dataset: AppModel.DatasetEntry,
    settings: AppSettings
  ) async throws -> AppModel.DatasetEntry {
    guard case let .remote(address, port, password) = dataset.source else { return dataset }
    if let local = preferredLocalDataset(matching: dataset.uniqueId) {
      return local
    }

    let selectedOrigin = DatasetOrigin(address: address, port: port, password: password)
    let origins = DatasetOriginCatalog.deduplicated(
      [selectedOrigin] + DatasetOriginCatalog.shared.origins(for: dataset.uniqueId)
    )
    let timeout = settings.timeout
    for origin in origins {
      let available = try? await Task.detached(priority: .userInitiated) {
        let manager = BORGVRRemoteDataManager(
          host: origin.address,
          port: UInt16(clamping: origin.port),
          authSecret: origin.password,
          logger: nil
        )
        try manager.connect(timeout: timeout)
        return try manager.requestDatasetList()
      }.value
      guard let available else { continue }
      DatasetOriginCatalog.shared.recordServerSnapshot(
        origin: origin,
        datasetIDs: available.map(\.id),
        allowsSharing: DatasetOriginCatalog.shared.sharingAllowed(for: origin)
      )
      guard available.contains(where: { $0.id == dataset.uniqueId }) else { continue }
      return AppModel.DatasetEntry(
        identifier: dataset.uniqueId,
        description: dataset.description,
        source: .remote(address: origin.address, port: origin.port, password: origin.password),
        uniqueId: dataset.uniqueId,
        metadataSummary: dataset.metadataSummary
      )
    }
    throw RemoteDatasetOpenError.noReachableOrigin
  }

  private func preferredLocalDataset(matching uniqueID: String) -> AppModel.DatasetEntry? {
    let matches = datasets.filter {
      $0.uniqueId.caseInsensitiveCompare(uniqueID) == .orderedSame
    }
    return matches.first(where: { $0.source == .local })
      ?? matches.first(where: { $0.source == .builtIn })
  }

  private func validateDatasetCanOpen(
    _ dataset: AppModel.DatasetEntry,
    timeout: TimeInterval
  ) async throws {
    guard case let .remote(address, port, password) = dataset.source else { return }
    try await Task.detached(priority: .userInitiated) {
      let manager = BORGVRRemoteDataManager(
        host: address,
        port: UInt16(clamping: port),
        authSecret: password,
        logger: nil
      )
      try manager.connect(timeout: timeout)
      _ = try manager.openDataset(datasetID: dataset.identifier, timeout: timeout)
    }.value
  }

  private func downloadRemoteDatasetBeforeOpening(
    _ dataset: AppModel.DatasetEntry,
    settings: AppSettings,
    storage: DatasetStorageAccess,
    cancellation: RemoteDatasetDownloadCancellation
  ) async throws -> AppModel.DatasetEntry {
    guard case let .remote(address, port, password) = dataset.source else { return dataset }
    guard let directoryURL = storage.directoryURL else {
      throw RemoteDatasetOpenError.documentsDirectoryUnavailable
    }

    let accessURL = storage.beginAccess()
    defer { storage.endAccess(accessURL) }
    let datasetID = dataset.identifier
    let primaryOrigin = DatasetOrigin(address: address, port: port, password: password)
    let timeout = settings.timeout
    let cachePath = directoryURL.appendingPathComponent("\(datasetID).data").path
    let incompletePath = cachePath + ".incomplete"
    let stallTimeout = max(30.0, timeout * 10.0)

    statusText = String(localized: "Downloading remote dataset locally ...")
    openProgress = 0

    let localPath = try await Task.detached(priority: .userInitiated) {
      if cancellation.isCancelled {
        throw RemoteDatasetOpenError.downloadCancelled
      }
      let manager = BORGVRRemoteDataManager(
        host: address,
        port: UInt16(clamping: port),
        authSecret: password,
        logger: nil
      )
      try manager.connect(timeout: timeout)
      let remoteData = try manager.openDataset(
        datasetID: datasetID,
        timeout: timeout,
        localCacheFilename: cachePath,
        originProvider: {
          DatasetOriginCatalog.deduplicated(
            [primaryOrigin] + DatasetOriginCatalog.shared.origins(for: datasetID)
          )
        }
      )

      let brickBuffer = remoteData.allocateBrickBuffer()
      defer { brickBuffer.deallocate() }
      for index in remoteData.getMetadata().brickMetadata.indices {
        if cancellation.isCancelled {
          throw RemoteDatasetOpenError.downloadCancelled
        }
        try? remoteData.getBrick(index: index, outputBuffer: brickBuffer)
      }

      var lastProgress = -1.0
      var lastProgressDate = Date()
      while true {
        if cancellation.isCancelled {
          throw RemoteDatasetOpenError.downloadCancelled
        }
        let progress = remoteData.localRatio
        if progress > lastProgress + 0.001 {
          lastProgress = progress
          lastProgressDate = Date()
          await MainActor.run {
            self.openProgress = progress
            self.statusText = self.downloadProgressText(progress: progress)
          }
        }
        if progress >= 1.0,
           FileManager.default.fileExists(atPath: cachePath),
           !FileManager.default.fileExists(atPath: incompletePath) {
          break
        }
        if Date().timeIntervalSince(lastProgressDate) > stallTimeout {
          throw RemoteDatasetOpenError.downloadStalled
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      return remoteData.localFile ?? cachePath
    }.value

    let metadataSummary = (try? BORGVRMetaData(url: URL(fileURLWithPath: localPath)))
      .map { DatasetCatalogService.metadataSummary(for: $0) } ?? dataset.metadataSummary
    return AppModel.DatasetEntry(
      identifier: localPath,
      description: dataset.description,
      source: .local,
      uniqueId: dataset.uniqueId,
      metadataSummary: metadataSummary
    )
  }

  private func downloadProgressText(progress: Double) -> String {
    let percentage = progress.formatted(.percent.precision(.fractionLength(0)))
    return String(format: String(localized: "remote_dataset_download_progress_format"), percentage)
  }

  private func removeUnavailableRemoteEntries(matching dataset: AppModel.DatasetEntry) {
    guard case let .remote(address, port, _) = dataset.source else { return }
    datasets.removeAll {
      guard case let .remote(candidateAddress, candidatePort, _) = $0.source else { return false }
      return candidateAddress == address && candidatePort == port
    }
    selectedDatasetKey = nil
  }
}

extension AppModel.DatasetEntry {
  var selectionKey: String {
    "\(source.selectionKey)|\(identifier)|\(uniqueId)"
  }
}

private extension AppModel.DatasetSource {
  var selectionKey: String {
    switch self {
      case .local: return "local"
      case .builtIn: return "builtIn"
      case let .remote(address, port, _): return "remote:\(address):\(port)"
    }
  }
}
