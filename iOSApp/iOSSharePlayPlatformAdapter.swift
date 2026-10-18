import Foundation
import GroupActivities

@MainActor
final class iOSSharePlayPlatformAdapter: BorgVRSharePlayPlatformAdapter {
  let participantPlatform = BorgVRSharePlayPlatform.iOS
  let defaultDisplayName = String(localized: "iPhone or iPad")

  var configuredDisplayName: String {
    appSettings.sharePlayDisplayName
  }

  private let appSettings: AppSettings
  private let adHocServer = BorgVRSharePlayAdHocServer()

  init(appSettings: AppSettings) {
    self.appSettings = appSettings
  }

  func activate(
    _ activity: BorgVRSharePlayActivity
  ) async throws -> BorgVRSharePlayActivationResult {
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

  func findLocalDataset(
    id: String,
    description: String
  ) -> AppModel.DatasetEntry? {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first,
    let files = try? FileManager.default.contentsOfDirectory(
      at: documentsURL,
      includingPropertiesForKeys: nil
    ) else { return nil }
    return BorgVRSharePlayLocalDatasetLookup.dataset(
      in: files,
      id: id,
      description: description
    )
  }

  func ensureServing(dataset: AppModel.DatasetEntry) -> [DatasetOrigin] {
    adHocServer.ensureServing(
      dataset: dataset,
      fileURL: fileURL(for: dataset),
      settings: BorgVRSharePlayAdHocServerSettings(
        preferredServerPort: appSettings.sharePlayServerPort,
        maximumBricksPerRequest: appSettings.maxBricksPerGetRequest,
        enablesWebServer: appSettings.enableWebServer,
        preferredWebServerPort: appSettings.sharePlayWebServerPort,
        usesWebServerTLS: appSettings.webServerUsesTLS,
        webServerCertificateData: appSettings.webServerCertificateData,
        webServerCertificatePassword: appSettings.webServerCertificatePassword,
        excludedPorts: []
      )
    )
  }

  func serves(meshAssetIDs: Set<UUID>, for datasetID: String) -> Bool {
    adHocServer.serves(meshAssetIDs: meshAssetIDs, for: datasetID)
  }

  func stopSharePlayServer() {
    adHocServer.stop()
  }

  private func fileURL(for dataset: AppModel.DatasetEntry) -> URL? {
    switch dataset.source {
      case .local, .builtIn:
        return URL(fileURLWithPath: dataset.identifier)
      case .remote:
        return FileManager.default.urls(
          for: .documentDirectory,
          in: .userDomainMask
        ).first?.appendingPathComponent("\(dataset.uniqueId).data")
    }
  }
}
