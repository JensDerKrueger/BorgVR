import Foundation
import Combine

/// All knowledge of BorgVR commands, MCP routing and source attribution stays here.
@MainActor
final class BorgVRVoiceAgentBridge: VoiceAgentApplicationBridge {
  private let service: any BorgVRMCPCommandService
  private let router: BorgVRMCPToolRouter
  private let contextProvider: () -> VoiceAgentContext?
  private let origin = BorgVRCommandSource.controller(UUID().uuidString)

  init(service: any BorgVRMCPCommandService, context: @escaping () -> VoiceAgentContext?) {
    self.service = service
    self.router = BorgVRMCPToolRouter(commandService: service)
    self.contextProvider = context
  }

  var context: VoiceAgentContext? { contextProvider() }
  var rendererReady: Bool { service.applicationState().rendererReady }
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
    try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
      try await router.callTool(name: name, arguments: arguments, validateContext: validateContext)
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
  func configure(service: any BorgVRMCPCommandService, context: @escaping () -> VoiceAgentContext?) {
    configure(bridge: BorgVRVoiceAgentBridge(service: service, context: context))
  }
}
