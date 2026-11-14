import Foundation
import Observation

/// Serializes import work and dataset preparation across windows and automation.
@MainActor @Observable
final class VisionDatasetActivityGate {
  enum BusyError: LocalizedError {
    case renderer, importing, preparing

    var errorDescription: String? {
      switch self {
        case .renderer:
          String(localized: "Close the current dataset before importing another dataset.", table: "ImportMessages")
        case .importing:
          String(localized: "An import is still running. Wait until it finishes or cancellation completes.", table: "ImportMessages")
        case .preparing:
          String(localized: "A dataset is already being opened. Wait until it finishes.", table: "ImportMessages")
      }
    }
  }

  private var importID: UUID?
  private var preparationID: UUID?
  var isImporting: Bool { importID != nil }
  var isPreparingDataset: Bool { preparationID != nil }
  var canPrepareDataset: Bool { !isImporting && !isPreparingDataset }

  func beginImport(rendererIsIdle: Bool) throws -> UUID {
    guard !isImporting else { throw BusyError.importing }
    guard !isPreparingDataset else { throw BusyError.preparing }
    guard rendererIsIdle else { throw BusyError.renderer }
    let id = UUID()
    importID = id
    return id
  }

  func finishImport(_ id: UUID) {
    if importID == id { importID = nil }
  }

  func beginDatasetPreparation() throws -> UUID {
    guard !isImporting else { throw BusyError.importing }
    guard !isPreparingDataset else { throw BusyError.preparing }
    let id = UUID()
    preparationID = id
    return id
  }

  func finishDatasetPreparation(_ id: UUID) {
    if preparationID == id { preparationID = nil }
  }

  func checkRendererStart() throws {
    guard !isImporting else { throw BusyError.importing }
  }
}
