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
    case remote(address: String, port: Int)
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

  init() {
    logger.setMinimumLogLevel(.warning)
  }

  func setLogLevel(_ setting: String) {
    let logLevel = AppLogLevel(rawValue: setting) ?? .warning
    logger.setMinimumLogLevel(logLevel.level)
  }
}
