import Foundation
import SwiftUI

enum RenderMode: String, CaseIterable, Identifiable, CustomStringConvertible {
  case transferFunction1DLighting
  case transferFunction1D
  case isoValue

  var id: String { rawValue }

  var description: String {
    switch self {
      case .transferFunction1DLighting:
        return String(localized: "Transfer Function + Licht")
      case .transferFunction1D:
        return String(localized: "Transfer Function")
      case .isoValue:
        return String(localized: "Isowert")
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  typealias RenderScreenshotHandler = (
    _ url: URL?,
    _ accessURL: URL?,
    _ completion: @escaping (Result<URL, Error>) -> Void
  ) -> Void
  typealias RenderDisplaySyncHandler = (_ enabled: Bool) -> Void

  enum ContentViewState {
    case start
    case settings
    case importData
    case selectData
    case renderData
    case waitingForHost
  }

  enum InteractionMode: String, CaseIterable, Identifiable {
    case model
    case clipping
    case transferEditing

    var id: String { rawValue }
  }

  enum DatasetSource: Equatable {
    case local
    case remote(address: String, port: Int, password: String)
    case builtIn
  }

  struct DatasetEntry: Equatable, Identifiable {
    let identifier: String
    let description: String
    let source: DatasetSource
    let uniqueId: String
    let metadataSummary: String?

    var id: String { uniqueId }

    init(
      identifier: String,
      description: String,
      source: DatasetSource,
      uniqueId: String,
      metadataSummary: String? = nil
    ) {
      self.identifier = identifier
      self.description = description
      self.source = source
      self.uniqueId = uniqueId
      self.metadataSummary = metadataSummary
    }
  }

  @Published var currentState: ContentViewState = .start
  @Published var activeDataset: DatasetEntry?
  @Published var groupSessionHost = true
  @Published var interactionMode: InteractionMode = .model
  @Published var timer: CPUFrameTimer?
  @Published var performanceModel = PerformanceGraphModel()
  let logger = GUILogger()
  var renderScreenshotHandler: RenderScreenshotHandler?
  var renderDisplaySyncHandler: RenderDisplaySyncHandler?
  private(set) var renderDisplaySyncEnabled = true
  private(set) var brickReadbackCount: UInt64 = 0
  private(set) var lastMissingBrickCount: Int = 0
  private(set) var consecutiveEmptyBrickReadbacks: UInt64 = 0
  private(set) var renderedDatasetKey = ""
  private(set) var failedRenderedDatasetKey = ""
  private(set) var completedRenderFrameCount: UInt64 = 0
  private(set) var lastCompletedFrameDatasetKey = ""

  init() {
    logger.setMinimumLogLevel(.warning)
  }

  func setLogLevel(_ setting: String) {
    let logLevel = AppLogLevel(rawValue: setting) ?? .warning
    logger.setMinimumLogLevel(logLevel.level)
  }

  func requestRenderScreenshot(
    to url: URL?,
    accessURL: URL?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard let renderScreenshotHandler else {
      completion(.failure(AppModelError.rendererUnavailable))
      return
    }
    renderScreenshotHandler(url, accessURL, completion)
  }

  func setRenderDisplaySyncEnabled(_ enabled: Bool) {
    renderDisplaySyncEnabled = enabled
    renderDisplaySyncHandler?(enabled)
  }

  func transferFunctionFileURL(for dataset: DatasetEntry? = nil) -> URL? {
    guard let dataset = dataset ?? activeDataset else { return nil }

    switch dataset.source {
      case .local:
        let datasetURL: URL
        if dataset.identifier.hasPrefix("/") {
          datasetURL = URL(fileURLWithPath: dataset.identifier)
        } else if let documentsURL = documentsDirectoryURL() {
          datasetURL = documentsURL.appendingPathComponent(dataset.identifier)
        } else {
          return nil
        }
        let localURL = datasetURL.deletingPathExtension().appendingPathExtension("tf1d")
        movePersistentTransferFunctionIfNeeded(for: dataset, to: localURL)
        return localURL

      case .builtIn:
        return persistentTransferFunctionFileURL(for: dataset)

      case .remote:
        return persistentTransferFunctionFileURL(for: dataset)
    }
  }

  func datasetRenderKey(for dataset: DatasetEntry?) -> String {
    guard let dataset else { return "" }
    let sourceKey: String
    switch dataset.source {
      case .local:
        sourceKey = "local"
      case .builtIn:
        sourceKey = "builtIn"
      case let .remote(address, port, _):
        sourceKey = "remote:\(address):\(port)"
    }
    return "\(sourceKey)-\(dataset.identifier)"
  }

  var activeDatasetRenderKey: String {
    datasetRenderKey(for: activeDataset)
  }

  var rendererHasActiveDataset: Bool {
    !activeDatasetRenderKey.isEmpty && renderedDatasetKey == activeDatasetRenderKey
  }

  var rendererFailedActiveDataset: Bool {
    !activeDatasetRenderKey.isEmpty && failedRenderedDatasetKey == activeDatasetRenderKey
  }

  func markRenderedDataset(key: String) {
    renderedDatasetKey = key
    failedRenderedDatasetKey = ""
  }

  func markRenderedDatasetFailed(key: String) {
    renderedDatasetKey = ""
    failedRenderedDatasetKey = key
  }

  func resetBrickReadbackState() {
    brickReadbackCount = 0
    lastMissingBrickCount = 0
    consecutiveEmptyBrickReadbacks = 0
    completedRenderFrameCount = 0
    lastCompletedFrameDatasetKey = ""
  }

  func recordCompletedRenderFrame(datasetKey: String, missingBrickCount: Int) {
    completedRenderFrameCount += 1
    lastCompletedFrameDatasetKey = datasetKey
    brickReadbackCount += 1
    lastMissingBrickCount = missingBrickCount
    if missingBrickCount == 0 {
      consecutiveEmptyBrickReadbacks += 1
    } else {
      consecutiveEmptyBrickReadbacks = 0
    }
  }

  private func transferFunctionDirectoryURL() -> URL? {
    guard let documentsURL = documentsDirectoryURL() else { return nil }
    let directoryURL = documentsURL.appendingPathComponent("TransferFunctions", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      return directoryURL
    } catch {
      logger.warning("Transfer function directory unavailable: \(error.localizedDescription)")
      return nil
    }
  }

  private func persistentTransferFunctionFileURL(for dataset: DatasetEntry) -> URL? {
    guard let directoryURL = transferFunctionDirectoryURL() else { return nil }
    let fallbackName = URL(fileURLWithPath: dataset.identifier).deletingPathExtension().lastPathComponent
    let stem = sanitizedTransferFunctionFilename(dataset.uniqueId.isEmpty ? fallbackName : dataset.uniqueId)
    return directoryURL.appendingPathComponent(stem).appendingPathExtension("tf1d")
  }

  private func movePersistentTransferFunctionIfNeeded(for dataset: DatasetEntry, to localURL: URL) {
    guard let persistentURL = persistentTransferFunctionFileURL(for: dataset),
          persistentURL != localURL else {
      return
    }

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: persistentURL.path),
          !fileManager.fileExists(atPath: localURL.path) else {
      return
    }

    do {
      try fileManager.moveItem(at: persistentURL, to: localURL)
      logger.info("Transfer function migrated to \(localURL.lastPathComponent)")
    } catch {
      logger.warning("Transfer function migration failed: \(error.localizedDescription)")
    }
  }

  private func documentsDirectoryURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  }

  private func sanitizedTransferFunctionFilename(_ filename: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitizedScalars = filename.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(sanitizedScalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return sanitized.isEmpty ? "transfer-function" : sanitized
  }
}

enum AppModelError: LocalizedError {
  case rendererUnavailable

  var errorDescription: String? {
    switch self {
      case .rendererUnavailable:
        return String(localized: "Renderer ist nicht verfügbar.")
    }
  }
}
