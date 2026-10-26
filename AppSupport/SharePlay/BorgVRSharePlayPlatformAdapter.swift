import Combine
import Foundation
import GroupActivities

enum BorgVRSharePlayActivationResult {
  case sessionExpected(Bool)
  case waitingForSystemJoin
  case cancelled
  case disabled
}

@MainActor
protocol BorgVRSharePlayPlatformAdapter: AnyObject {
  var participantPlatform: BorgVRSharePlayPlatform { get }
  var defaultDisplayName: String { get }
  var configuredDisplayName: String { get }
  var eligibilityPublisher: AnyPublisher<Bool, Never>? { get }

  func activate(
    _ activity: BorgVRSharePlayActivity
  ) async throws -> BorgVRSharePlayActivationResult

  func findLocalDataset(
    id: String,
    description: String
  ) -> AppModel.DatasetEntry?

  func ensureServing(dataset: AppModel.DatasetEntry) async -> [DatasetOrigin]
  func serves(meshAssetIDs: Set<UUID>, for datasetID: String) -> Bool
  func stopSharePlayServer()
}

extension BorgVRSharePlayPlatformAdapter {
  var eligibilityPublisher: AnyPublisher<Bool, Never>? { nil }
}

enum BorgVRSharePlayLocalDatasetLookup {
  static func dataset(
    in files: [URL],
    id: String,
    description: String,
    source: AppModel.DatasetSource = .local
  ) -> AppModel.DatasetEntry? {
    for url in files where url.pathExtension.lowercased() == "data" {
      guard let metadata = try? BORGVRMetaData(url: url),
            metadata.uniqueID == id else { continue }
      return AppModel.DatasetEntry(
        identifier: url.path,
        description: metadata.datasetDescription.isEmpty
          ? description
          : metadata.datasetDescription,
        source: source,
        uniqueId: metadata.uniqueID,
        metadataSummary: metadata.summaryText
      )
    }
    return nil
  }
}
