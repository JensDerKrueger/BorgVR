import Foundation
import Combine

struct VoiceAgentContext: Equatable {
  let datasetID: String
  let openingID: UUID
  let editStateID: UUID?
}

struct VoiceAgentApplicationChange {
  enum Phase { case began, committed, failed }
  let id: UUID
  let domain: String
  let phase: Phase
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
  var changes: AnyPublisher<VoiceAgentApplicationChange, Never> { get }
  func stateSnapshot() throws -> [String: Any]
  func executeTool(name: String, arguments: [String: Any], validateContext: @escaping () throws -> Void) async throws -> [String: Any]
  func openDataset(id: String, validateContext: @escaping () throws -> Void,
                   didBegin: @escaping (VoiceAgentContext) throws -> Void) async throws -> [String: Any]
}
