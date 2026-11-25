import Foundation
import Combine

struct VoiceAgentContext: Hashable, Codable {
  let datasetID: String
  let openingID: UUID
  let editStateID: UUID?

  func hasSameOpening(as other: VoiceAgentContext) -> Bool {
    datasetID == other.datasetID && openingID == other.openingID
  }
}

struct VoiceAgentFileSelection: Identifiable, Equatable {
  let id = UUID()
  let title: String
  let kind: Kind
  enum Kind { case file, folder, visualization }
}

struct VoiceAgentImportStatus: Equatable {
  enum Phase: String { case running, cancelling, completed, cancelled, failed }
  let id: UUID
  let filename: String
  var phase: Phase
  var progress: Double
  var detail: String? = nil
  var fileSelection: VoiceAgentFileSelection? = nil
  var active: Bool { phase == .running || phase == .cancelling }
}

struct VoiceAgentApplicationChange {
  enum Phase { case began, committed, failed }
  let id: UUID
  let domain: String
  let phase: Phase
}

struct VoiceAgentAnnotationDeletion: Identifiable {
  let id: UUID
  let scope: String
  let markerCount: Int
  let measurementCount: Int
}

struct VoiceAgentEditStateDeletion: Identifiable {
  let id: UUID
  let stateID: UUID
  let name: String
}

struct VoiceAgentVolumeEdit: Identifiable {
  let id: UUID
  let erase: Bool
  let sampleCount: Int
  let boundsMinimumMeters: SIMD3<Double>
  let boundsMaximumMeters: SIMD3<Double>
  let channels: [Int]
}

enum VoiceAgentVolumeBrickStatus: Equatable {
  case pending(Int), ready
}

/// The optional assistant depends only on this application-facing contract.
@MainActor
protocol VoiceAgentApplicationBridge: AnyObject {
  // No dataset is a valid application context, not an unavailable assistant.
  var context: VoiceAgentContext? { get }
  var applicationDatasetContext: VoiceAgentContext? { get }
  var rendererReady: Bool { get }
  var datasetID: String? { get }
  var hasTransferFunctions: Bool { get }
  var toolDefinitions: [[String: Any]] { get }
  var importUpdates: AnyPublisher<VoiceAgentImportStatus?, Never> { get }
  func cancelImport(id: UUID)
  func resolveImportFileSelection(id: UUID, url: URL?)
  var changes: AnyPublisher<VoiceAgentApplicationChange, Never> { get }
  func stateSnapshot() throws -> [String: Any]
  func sweepView() -> AssistantSweepView?
  func executeTool(name: String, arguments: [String: Any], validateContext: @escaping () throws -> Void) async throws -> [String: Any]
  func executeFileTool(name: String, arguments: [String: Any], select: (VoiceAgentFileSelection) async -> URL?,
                       validateContext: @escaping () throws -> Void, willCommit: () -> Void) async throws -> [String: Any]
  func prepareAnnotationDeletion(scope: String, targetID: String?) throws -> VoiceAgentAnnotationDeletion?
  func executeAnnotationDeletion(_ confirmation: VoiceAgentAnnotationDeletion,
                                validateContext: @escaping () throws -> Void) async throws -> [String: Any]
  func prepareEditStateDeletion(id: UUID) -> VoiceAgentEditStateDeletion?
  func executeEditStateDeletion(_ confirmation: VoiceAgentEditStateDeletion,
                                validateContext: @escaping () throws -> Void) async throws -> [String: Any]
  func prepareVolumeEdit(arguments: [String: Any]) throws -> VoiceAgentVolumeEdit
  func executeVolumeEdit(_ confirmation: VoiceAgentVolumeEdit,
                         validateContext: @escaping () throws -> Void) async throws -> [String: Any]
  func volumeBrickStatus() -> VoiceAgentVolumeBrickStatus?
  func openDataset(id: String, validateContext: @escaping () throws -> Void,
                   validateRequest: @escaping () throws -> Void) async throws -> [String: Any]
}

extension VoiceAgentApplicationBridge {
  var importUpdates: AnyPublisher<VoiceAgentImportStatus?, Never> { Just(nil).eraseToAnyPublisher() }
  func cancelImport(id: UUID) {}
  func resolveImportFileSelection(id: UUID, url: URL?) {}
  func executeFileTool(name: String, arguments: [String: Any], select: (VoiceAgentFileSelection) async -> URL?,
                       validateContext: @escaping () throws -> Void, willCommit: () -> Void) async throws -> [String: Any] { throw VoiceAgentError.commandFailed }
  func prepareAnnotationDeletion(scope: String, targetID: String?) throws -> VoiceAgentAnnotationDeletion? { throw VoiceAgentError.commandFailed }
  func executeAnnotationDeletion(_ confirmation: VoiceAgentAnnotationDeletion,
                                validateContext: @escaping () throws -> Void) async throws -> [String: Any] { throw VoiceAgentError.commandFailed }
  func prepareEditStateDeletion(id: UUID) -> VoiceAgentEditStateDeletion? { nil }
  func executeEditStateDeletion(_ confirmation: VoiceAgentEditStateDeletion,
                                validateContext: @escaping () throws -> Void) async throws -> [String: Any] { throw VoiceAgentError.commandFailed }
  func prepareVolumeEdit(arguments: [String: Any]) throws -> VoiceAgentVolumeEdit { throw VoiceAgentError.commandFailed }
  func executeVolumeEdit(_ confirmation: VoiceAgentVolumeEdit,
                         validateContext: @escaping () throws -> Void) async throws -> [String: Any] { throw VoiceAgentError.commandFailed }
  func volumeBrickStatus() -> VoiceAgentVolumeBrickStatus? { nil }
}
