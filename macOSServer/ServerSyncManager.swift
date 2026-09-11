import Foundation

struct ServerSyncStatus: Equatable {
  let activeDatasetCount: Int
  let primaryDatasetDescription: String
  let primaryProgress: Double
  let averageProgress: Double

  static let idle = ServerSyncStatus(
    activeDatasetCount: 0,
    primaryDatasetDescription: "",
    primaryProgress: 0,
    averageProgress: 0
  )
}

final class ServerSyncManager {
  private static let transferFunctionSyncByteLimit = 32 * 1024 * 1024
  private static let datasetProgressTimeout: TimeInterval = 120

  private struct ActiveDatasetSync {
    let id: String
    let description: String
    let targetFilename: String
    let endpoint: ServerSyncEndpoint
    let remoteData: BORGVRRemoteData
    var lastProgress: Double
    var lastProgressDate: Date
  }

  private struct DatasetSyncSource {
    let endpoint: ServerSyncEndpoint
    let description: String
  }

  private let queue = DispatchQueue(label: "BorgVRServerSyncManager", qos: .background)
  private let logger: LoggerBase?
  private let dataDirectory: String
  private let endpoints: [ServerSyncEndpoint]
  private let onLocalCatalogChanged: () -> Void
  private let onStatusChanged: (ServerSyncStatus) -> Void

  private var timer: DispatchSourceTimer?
  private var lastCheckByEndpointID: [UUID: Date] = [:]
  private var activeDatasetSyncs: [String: ActiveDatasetSync] = [:]
  private var discoveredDatasetSources: [String: [DatasetSyncSource]] = [:]
  private var failedSourceIDsByDatasetID: [String: Set<UUID>] = [:]
  private var isRunning = false

  init(
    logger: LoggerBase?,
    dataDirectory: String,
    endpoints: [ServerSyncEndpoint],
    onLocalCatalogChanged: @escaping () -> Void,
    onStatusChanged: @escaping (ServerSyncStatus) -> Void
  ) {
    self.logger = logger
    self.dataDirectory = dataDirectory
    self.endpoints = endpoints
    self.onLocalCatalogChanged = onLocalCatalogChanged
    self.onStatusChanged = onStatusChanged
  }

  func start() {
    queue.async { [self] in
      guard !self.isRunning else { return }
      self.isRunning = true

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .seconds(1))
      timer.setEventHandler { [weak self] in
        self?.tick()
      }
      self.timer = timer
      timer.resume()
      self.logger?.info("Server sync started.")
      self.publishStatus()
    }
  }

  func stop() {
    queue.async {
      self.isRunning = false
      self.timer?.cancel()
      self.timer = nil
      self.lastCheckByEndpointID.removeAll()
      self.activeDatasetSyncs.removeAll()
      self.discoveredDatasetSources.removeAll()
      self.failedSourceIDsByDatasetID.removeAll()
      self.logger?.info("Server sync stopped.")
      self.publishStatus()
    }
  }

  private func tick() {
    guard isRunning else { return }
    pollActiveDatasetSyncs()
    publishStatus()

    let now = Date()
    for endpoint in endpoints.filter(\.isUsable) {
      let lastCheck = lastCheckByEndpointID[endpoint.id] ?? .distantPast
      guard now.timeIntervalSince(lastCheck) >= TimeInterval(endpoint.intervalSeconds) else {
        continue
      }
      lastCheckByEndpointID[endpoint.id] = now
      sync(endpoint: endpoint)
    }
  }

  private func sync(endpoint: ServerSyncEndpoint) {
    let address = endpoint.address.trimmingCharacters(in: .whitespacesAndNewlines)
    logger?.info("Checking sync server \(address):\(endpoint.port).")

    do {
      let manager = BORGVRRemoteDataManager(
        host: address,
        port: UInt16(clamping: endpoint.port),
        authSecret: endpoint.password,
        logger: logger,
        notifier: nil
      )
      try manager.connect(timeout: 10)
      let didStoreTransferFunctions = try syncTransferFunctions(from: manager)
      let remoteDatasets = try manager.requestDatasetList()
      rememberDatasetSources(remoteDatasets, endpoint: endpoint)
      let localDatasetIDs = scanLocalDatasetIDs()

      for remoteDataset in remoteDatasets {
        guard shouldStartDatasetSync(
          id: remoteDataset.id,
          localDatasetIDs: localDatasetIDs
        ) else {
          continue
        }
        try startNextDatasetSync(
          id: remoteDataset.id,
          fallbackDescription: remoteDataset.description
        )
      }

      if didStoreTransferFunctions {
        notifyCatalogChanged()
      }
    } catch {
      logger?.warning(
        "Sync server \(address):\(endpoint.port) check failed: \(error.localizedDescription)"
      )
    }
  }

  private func shouldStartDatasetSync(
    id: String,
    localDatasetIDs: Set<String>
  ) -> Bool {
    !localDatasetIDs.contains(id) && activeDatasetSyncs[id] == nil
  }

  private func rememberDatasetSources(
    _ remoteDatasets: [(id: String, description: String)],
    endpoint: ServerSyncEndpoint
  ) {
    for remoteDataset in remoteDatasets {
      var sources = discoveredDatasetSources[remoteDataset.id] ?? []
      sources.removeAll { $0.endpoint.id == endpoint.id }
      sources.append(
        DatasetSyncSource(
          endpoint: endpoint,
          description: remoteDataset.description
        )
      )
      discoveredDatasetSources[remoteDataset.id] = sources
    }
  }

  private func startNextDatasetSync(
    id: String,
    fallbackDescription: String
  ) throws {
    guard var sources = discoveredDatasetSources[id], !sources.isEmpty else {
      return
    }

    var failedSourceIDs = failedSourceIDsByDatasetID[id] ?? []
    if sources.allSatisfy({ failedSourceIDs.contains($0.endpoint.id) }) {
      failedSourceIDs.removeAll()
      failedSourceIDsByDatasetID[id] = failedSourceIDs
    }

    sources.removeAll { failedSourceIDs.contains($0.endpoint.id) }
    guard let source = sources.first else { return }

    let manager = BORGVRRemoteDataManager(
      host: source.endpoint.address.trimmingCharacters(in: .whitespacesAndNewlines),
      port: UInt16(clamping: source.endpoint.port),
      authSecret: source.endpoint.password,
      logger: logger,
      notifier: nil
    )
    try manager.connect(timeout: 10)
    try startDatasetSync(
      (id: id, description: source.description.isEmpty ? fallbackDescription : source.description),
      from: manager,
      endpoint: source.endpoint
    )
  }

  private func startDatasetSync(
    _ remoteDataset: (id: String, description: String),
    from manager: BORGVRRemoteDataManager,
    endpoint: ServerSyncEndpoint
  ) throws {
    let dataDirectoryURL = try dataDirectoryURL()
    let targetURL = dataDirectoryURL
      .appendingPathComponent(remoteDataset.id)
      .appendingPathExtension("data")

    logger?.info(
      "Starting dataset sync for \(displayName(for: remoteDataset)) from \(endpoint.address):\(endpoint.port)."
    )

    let remoteData = try manager.openDataset(
      datasetID: remoteDataset.id,
      timeout: 10,
      localCacheFilename: targetURL.path
    )
    activeDatasetSyncs[remoteDataset.id] = ActiveDatasetSync(
      id: remoteDataset.id,
      description: remoteDataset.description,
      targetFilename: targetURL.path,
      endpoint: endpoint,
      remoteData: remoteData,
      lastProgress: remoteData.localRatio,
      lastProgressDate: Date()
    )
    publishStatus()
  }

  private func pollActiveDatasetSyncs() {
    let now = Date()
    var completedIDs: [String] = []
    var stalledSyncs: [ActiveDatasetSync] = []

    for (id, sync) in Array(activeDatasetSyncs) {
      let progress = sync.remoteData.localRatio
      if progress >= 1.0,
         FileManager.default.fileExists(atPath: sync.targetFilename) {
        logger?.info("Dataset sync completed for \(displayName(for: sync)).")
        completedIDs.append(id)
        continue
      }

      if progress > sync.lastProgress + 0.0001 {
        var updatedSync = sync
        updatedSync.lastProgress = progress
        updatedSync.lastProgressDate = now
        activeDatasetSyncs[id] = updatedSync
        continue
      }

      if now.timeIntervalSince(sync.lastProgressDate) > Self.datasetProgressTimeout {
        stalledSyncs.append(sync)
      }
    }

    for id in completedIDs {
      activeDatasetSyncs.removeValue(forKey: id)
      failedSourceIDsByDatasetID.removeValue(forKey: id)
    }
    if !completedIDs.isEmpty {
      notifyCatalogChanged()
    }

    for sync in stalledSyncs {
      activeDatasetSyncs.removeValue(forKey: sync.id)
      failedSourceIDsByDatasetID[sync.id, default: []].insert(sync.endpoint.id)
      logger?.warning(
        "Dataset sync for \(displayName(for: sync)) made no progress; trying another source if available."
      )
      do {
        try startNextDatasetSync(id: sync.id, fallbackDescription: sync.description)
      } catch {
        logger?.warning(
          "Unable to restart dataset sync for \(displayName(for: sync)): \(error.localizedDescription)"
        )
      }
    }
    if !completedIDs.isEmpty || !stalledSyncs.isEmpty {
      publishStatus()
    }
  }

  private func syncTransferFunctions(from manager: BORGVRRemoteDataManager) throws -> Bool {
    let dataDirectoryURL = try dataDirectoryURL()
    var localTransferFunctionIDs = scanLocalTransferFunctionIDs()
    let remoteTransferFunctions = try manager.requestTransferFunctionList()
    var transferredBytes = 0
    var didStoreTransferFunctions = false

    for remoteTransferFunction in remoteTransferFunctions {
      guard !localTransferFunctionIDs.contains(remoteTransferFunction.id) else {
        continue
      }

      guard transferredBytes + remoteTransferFunction.byteCount <=
              Self.transferFunctionSyncByteLimit else {
        logger?.warning(
          "Transfer function sync limit reached before \(remoteTransferFunction.id)."
        )
        break
      }

      let data = try manager.requestTransferFunction(id: remoteTransferFunction.id)
      let targetURL = uniqueTransferFunctionURL(
        in: dataDirectoryURL,
        remoteTransferFunction: remoteTransferFunction
      )
      try data.write(to: targetURL, options: .atomic)
      transferredBytes += data.count
      localTransferFunctionIDs.insert(remoteTransferFunction.id)
      didStoreTransferFunctions = true
      logger?.info(
        "Stored synced transfer function \(displayName(for: remoteTransferFunction))."
      )
    }

    return didStoreTransferFunctions
  }

  private func scanLocalDatasetIDs() -> Set<String> {
    let scanner = DatasetScanner(directory: dataDirectory, logger: nil)
    scanner.loadDatasets()
    return Set(scanner.getDatasets().map(\.id))
  }

  private func scanLocalTransferFunctionIDs() -> Set<String> {
    let scanner = DatasetScanner(directory: dataDirectory, logger: nil)
    scanner.loadDatasets()
    return Set(scanner.getTransferFunctions().map(\.id))
  }

  private func dataDirectoryURL() throws -> URL {
    let url = URL(fileURLWithPath: dataDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func uniqueTransferFunctionURL(
    in directoryURL: URL,
    remoteTransferFunction: BORGVRRemoteDataManager.RemoteTransferFunctionInfo
  ) -> URL {
    let baseName = sanitizedFilename(
      remoteTransferFunction.description.isEmpty ?
      remoteTransferFunction.id :
      remoteTransferFunction.description
    )

    var candidate = directoryURL
      .appendingPathComponent(baseName)
      .appendingPathExtension("tf1d")

    guard FileManager.default.fileExists(atPath: candidate.path) else {
      return candidate
    }

    candidate = directoryURL
      .appendingPathComponent("\(baseName)-\(remoteTransferFunction.id.prefix(8))")
      .appendingPathExtension("tf1d")

    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = directoryURL
        .appendingPathComponent("\(baseName)-\(remoteTransferFunction.id.prefix(8))-\(suffix)")
        .appendingPathExtension("tf1d")
      suffix += 1
    }
    return candidate
  }

  private func sanitizedFilename(_ filename: String) -> String {
    let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
      .union(.newlines)
      .union(.controlCharacters)
    let components = filename
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: invalidCharacters)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let sanitized = components.joined(separator: "-")
    return sanitized.isEmpty ? "Transfer Function" : sanitized
  }

  private func displayName(for dataset: (id: String, description: String)) -> String {
    let description = dataset.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.isEmpty ? dataset.id : description
  }

  private func displayName(for sync: ActiveDatasetSync) -> String {
    let description = sync.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.isEmpty ? sync.id : description
  }

  private func displayName(
    for transferFunction: BORGVRRemoteDataManager.RemoteTransferFunctionInfo
  ) -> String {
    let description = transferFunction.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return description.isEmpty ? transferFunction.id : description
  }

  private func notifyCatalogChanged() {
    DispatchQueue.main.async {
      self.onLocalCatalogChanged()
    }
  }

  private func publishStatus() {
    let activeSyncs = activeDatasetSyncs.values.sorted {
      displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
    }

    guard let primarySync = activeSyncs.first else {
      DispatchQueue.main.async {
        self.onStatusChanged(.idle)
      }
      return
    }

    let progressValues = activeSyncs.map { $0.remoteData.localRatio }
    let averageProgress = progressValues.reduce(0, +) / Double(progressValues.count)
    let status = ServerSyncStatus(
      activeDatasetCount: activeSyncs.count,
      primaryDatasetDescription: displayName(for: primarySync),
      primaryProgress: primarySync.remoteData.localRatio,
      averageProgress: averageProgress
    )

    DispatchQueue.main.async {
      self.onStatusChanged(status)
    }
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
