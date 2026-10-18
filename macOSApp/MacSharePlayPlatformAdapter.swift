import AppKit
import Combine
import Foundation
import GroupActivities

@MainActor
final class MacSharePlayPlatformAdapter: BorgVRSharePlayPlatformAdapter {
  let participantPlatform = BorgVRSharePlayPlatform.macOS
  let defaultDisplayName = String(localized: "Mac")

  var configuredDisplayName: String {
    storedAppModel.sharePlayDisplayName
  }

  var eligibilityPublisher: AnyPublisher<Bool, Never>? {
    groupStateObserver.$isEligibleForGroupSession
      .removeDuplicates()
      .eraseToAnyPublisher()
  }

  private let storedAppModel: StoredAppModel
  private let serverController: BackgroundServerController
  private let groupStateObserver = GroupStateObserver()

  init(
    storedAppModel: StoredAppModel,
    serverController: BackgroundServerController
  ) {
    self.storedAppModel = storedAppModel
    self.serverController = serverController
  }

  func activate(
    _ activity: BorgVRSharePlayActivity
  ) async throws -> BorgVRSharePlayActivationResult {
    if groupStateObserver.isEligibleForGroupSession {
      switch await activity.prepareForActivation() {
        case .activationPreferred:
          return .sessionExpected(try await activity.activate())
        case .activationDisabled:
          return .disabled
        case .cancelled:
          return .cancelled
        @unknown default:
          return .cancelled
      }
    }

    let controller = try GroupActivitySharingController(activity)
    guard let presentingController = NSApp.keyWindow?.contentViewController else {
      throw MacSharePlayPlatformError.missingPresentingWindow
    }
    presentingController.presentAsSheet(controller)
    switch await controller.result {
      case .success:
        return .waitingForSystemJoin
      case .cancelled:
        return .cancelled
      @unknown default:
        return .cancelled
    }
  }

  func findLocalDataset(
    id: String,
    description: String
  ) -> AppModel.DatasetEntry? {
    let accessURL = storedAppModel.startAccessingDataDirectory()
    defer { storedAppModel.stopAccessingDataDirectory(accessURL) }

    let directoryURL = storedAppModel.resolvedDataDirectoryURL()
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil
    ) else { return nil }
    return BorgVRSharePlayLocalDatasetLookup.dataset(
      in: files,
      id: id,
      description: description
    )
  }

  func ensureServing(dataset: AppModel.DatasetEntry) -> [DatasetOrigin] {
    serverController.ensureServing(dataset: dataset, using: storedAppModel)
  }

  func serves(meshAssetIDs: Set<UUID>, for datasetID: String) -> Bool {
    serverController.serves(meshAssetIDs: meshAssetIDs, for: datasetID)
  }

  func stopSharePlayServer() {
    serverController.stopSharePlayServer()
  }

}

private enum MacSharePlayPlatformError: LocalizedError {
  case missingPresentingWindow

  var errorDescription: String? {
    String(localized: "Failed to start SharePlay because no active window is available.")
  }
}
