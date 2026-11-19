import Foundation
import Combine

/// All knowledge of BorgVR commands, MCP routing and source attribution stays here.
@MainActor
final class BorgVRVoiceAgentBridge: VoiceAgentApplicationBridge {
  private let service: any BorgVRMCPCommandService
  private let router: BorgVRMCPToolRouter
  private let contextProvider: () -> VoiceAgentContext?
  private let readinessProvider: () -> Bool
  private let origin = BorgVRCommandSource.controller(UUID().uuidString)
  private var searchResults: [String: Date] = [:]

  init(service: any BorgVRMCPCommandService, isReady: @escaping () -> Bool = { true },
       context: @escaping () -> VoiceAgentContext?) {
    self.service = service
    self.router = BorgVRMCPToolRouter(commandService: service)
    self.contextProvider = context
    self.readinessProvider = isReady
  }

  var applicationDatasetContext: VoiceAgentContext? { contextProvider() }
  var context: VoiceAgentContext? { rendererReady ? contextProvider() : nil }
  var rendererReady: Bool { service.applicationState().rendererReady && readinessProvider() }
  var datasetID: String? { service.applicationState().dataset?.id }
  var hasTransferFunctions: Bool { service.transferFunctionCount > 0 }
  var toolDefinitions: [[String: Any]] { router.toolDefinitions }

  var changes: AnyPublisher<VoiceAgentApplicationChange, Never> {
    guard let executor = service.commandExecutor else { return Empty().eraseToAnyPublisher() }
    return executor.commandEvents.compactMap { [origin] event in
      guard event.source != origin, let domain = Self.domain(event.command) else { return nil }
      let phase: VoiceAgentApplicationChange.Phase
      switch event.phase {
        case .began: phase = .began
        case .committed: phase = .committed
        case .failed: phase = .failed
      }
      return VoiceAgentApplicationChange(id: event.id, domain: domain, phase: phase)
    }.eraseToAnyPublisher()
  }

  func stateSnapshot() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(service.applicationState())) as? [String: Any] ?? [:]
    return VoiceAgentPolicy.compactResult(object, tool: "get_application_state")
  }

  func executeTool(name: String, arguments: [String: Any], validateContext: @escaping () throws -> Void) async throws -> [String: Any] {
    let result = try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
      try await router.callTool(name: name, arguments: arguments, validateContext: validateContext)
    }
    if name == "search_datasets", let payload = result["structuredContent"] as? [String: Any],
       let matches = payload["matches"] as? [[String: Any]] {
      searchResults = searchResults.filter { $0.value > Date() }
      for match in matches {
        if let id = match["id"] as? String {
          if searchResults.count >= 2000, let oldest = searchResults.min(by: { $0.value < $1.value })?.key {
            searchResults.removeValue(forKey: oldest)
          }
          searchResults[id] = Date().addingTimeInterval(300)
        }
      }
    }
    return result
  }

  func openDataset(id: String, validateContext: @escaping () throws -> Void,
                   didBegin: @escaping (VoiceAgentContext) throws -> Void) async throws -> [String: Any] {
    guard let expiry = searchResults[id], expiry > Date() else {
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "search_required",
        "note": "Search the catalog again and use an ID returned to this client within five minutes."]]
    }
    var expected: VoiceAgentContext?
    _ = try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
      try await router.callTool(name: "open_dataset", arguments: ["id": id], validateContext: validateContext,
        datasetDidBegin: { [self] in
          guard let opened = applicationDatasetContext, opened.datasetID == id else { throw VoiceAgentError.contextChanged }
          try didBegin(opened)
          expected = opened
        })
    }
    guard let expected else { throw VoiceAgentError.contextChanged }
    let deadline = ContinuousClock.now + .seconds(300)
    while true {
      try Task.checkCancellation()
      try validateContext()
      guard let current = applicationDatasetContext, current.hasSameOpening(as: expected) else { throw VoiceAgentError.contextChanged }
      if let ready = context, ready.hasSameOpening(as: expected) {
        try didBegin(ready)
        return ["structuredContent": try stateSnapshot()]
      }
      guard ContinuousClock.now < deadline else { throw VoiceAgentError.timedOut }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func domain(_ command: BorgVRCommand) -> String? {
    switch command {
      case .setTransform, .rotate: return "transform"
      case .setClipping: return "clipping"
      case .setTransferFunction: return "transfer_function"
      case .setLighting: return "lighting"
      case .setRenderMode, .setNormalizedIsoValue, .setBackground, .setScreenProjection,
           .setBoundingBox, .setRenderOptimizations, .restoreDatasetViewState: return "rendering"
      case .setAnnotationVisibility, .upsertObject, .removeObject, .clearObjects,
           .upsertMeasurement, .removeMeasurement, .clearMeasurements: return "annotations"
      case .reset(let scope):
        switch scope {
          case .transform: return "transform"
          case .clipping: return "clipping"
          case .transferFunction: return "transfer_function"
          case .lighting: return "lighting"
          case .all: return "rendering"
        }
      case .mutation(let domain):
        switch domain {
          case .transferFunction: return "transfer_function"
          case .objects, .measurements: return "annotations"
          case .visualization: return "rendering"
          case .interaction: return nil
        }
      case .action(let action):
        switch action {
          case .editVolume, .discardVolumeEdits: return "volume"
          default: return nil
        }
      default: return nil
    }
  }
}

extension VoiceAgentController {
  func configure(service: any BorgVRMCPCommandService, isReady: @escaping () -> Bool = { true },
                 context: @escaping () -> VoiceAgentContext?) {
    configure(bridge: BorgVRVoiceAgentBridge(service: service, isReady: isReady, context: context))
  }
}
