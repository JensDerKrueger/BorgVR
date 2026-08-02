import Foundation

@MainActor
final class DatasetCatalogService {
  private let appSettings: AppSettings
  private let storedAppModel: StoredAppModel
  private let logger: LoggerBase?

  init(
    appSettings: AppSettings,
    storedAppModel: StoredAppModel,
    logger: LoggerBase?
  ) {
    self.appSettings = appSettings
    self.storedAppModel = storedAppModel
    self.logger = logger
  }

  func loadDatasets(includeRemote: Bool = true) async -> [AppModel.DatasetEntry] {
    var loaded = await loadLocalDatasets()
    if includeRemote {
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
    switch dataset.source {
      case .local:
        let identifierPath = dataset.identifier.hasPrefix("/")
          ? dataset.identifier
          : storedAppModel.resolvedDataDirectoryURL().appendingPathComponent(dataset.identifier).path
        return AppModel.DatasetEntry(
          identifier: identifierPath,
          description: dataset.description,
          source: dataset.source,
          uniqueId: dataset.uniqueId,
          metadataSummary: dataset.metadataSummary
        )
      case .remote, .builtIn:
        return dataset
    }
  }

  private func loadLocalDatasets() async -> [AppModel.DatasetEntry] {
    var loaded: [AppModel.DatasetEntry] = []
    let fileManager = FileManager.default
    let accessURL = storedAppModel.startAccessingDataDirectory()
    defer {
      storedAppModel.stopAccessingDataDirectory(accessURL)
    }

    do {
      let dataDirectoryURL = storedAppModel.resolvedDataDirectoryURL()
      let files = try fileManager.contentsOfDirectory(at: dataDirectoryURL, includingPropertiesForKeys: nil)
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
      logger?.error("Error loading local datasets: \(error.localizedDescription)")
    }

    if let datasetURLs = Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) {
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
            port: UInt16(server.port),
            logger: logger,
            notifier: nil
          )
          try manager.connect(timeout: timeout)
          for dataset in try manager.requestDatasetList() {
            loaded.append(
              AppModel.DatasetEntry(
                identifier: dataset.id,
                description: dataset.description,
                source: .remote(address: server.address, port: server.port),
                uniqueId: dataset.id,
                metadataSummary: nil
              )
            )
          }
        } catch {
          logger?.error("Error connecting to remote server \(server.address):\(server.port): \(error.localizedDescription)")
        }
      }
      return loaded
    }.value
  }

  static func metadataSummary(for metadata: BORGVRMetaData) -> String {
    let bitsPerComponent = metadata.bytesPerComponent * 8
    let channelText = metadata.componentCount == 1
      ? String(localized: "1 Kanal")
      : String(format: String(localized: "metadata_channel_count_format"), metadata.componentCount)
    let compressionText = metadata.compression
      ? String(localized: "komprimiert")
      : String(localized: "unkomprimiert")
    let lodText = metadata.levelMetadata.count == 1
      ? String(localized: "1 LOD")
      : String(format: String(localized: "metadata_lod_count_format"), metadata.levelMetadata.count)

    return "\(metadata.width) x \(metadata.height) x \(metadata.depth) - " +
      "\(bitsPerComponent)-bit, \(channelText) - " +
      "\(String(localized: "Brick")) \(metadata.brickSize) - \(lodText) - " +
      "\(compressionText) - \(String(localized: "Werte")) \(metadata.minValue)...\(metadata.maxValue)"
  }
}
