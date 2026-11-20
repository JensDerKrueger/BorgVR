import Foundation
import Combine
import CryptoKit

/// All knowledge of BorgVR commands, MCP routing and source attribution stays here.
@MainActor
final class BorgVRVoiceAgentBridge: VoiceAgentApplicationBridge {
  private let service: any BorgVRMCPCommandService
  private let router: BorgVRMCPToolRouter
  private let contextProvider: () -> VoiceAgentContext?
  private let readinessProvider: () -> Bool
  private let origin = BorgVRCommandSource.controller(UUID().uuidString)
  private var searchResults: [String: Date] = [:]
  private var deletionPreview: (value: VoiceAgentAnnotationDeletion, context: VoiceAgentContext, digest: Data, expires: Date)?

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
    try validateContext()
    if name == "clear_annotations" {
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "confirmation_required",
        "note": "Bulk annotation deletion requires a fresh local human approval; confirm: true alone is insufficient."]]
    }
    if let error = VoiceAgentAnnotationPolicy.validationError(name: name, arguments: arguments) {
      return annotationRejection(error)
    }
    if name == "list_objects" {
      return try annotationList(service.listObjects(), key: "objects", arguments: arguments, encode: annotationJSON)
    }
    if name == "list_measurements" {
      return try annotationList(service.listMeasurements(), key: "measurements", arguments: arguments, encode: measurementResult)
    }
    if name == "remove_object" {
      guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID),
            let object = service.listObjects().first(where: { $0.id == id }), case .marker = object else {
        return annotationRejection("The marker ID is not present in this dataset. Mesh deletion is not available; list objects again.")
      }
      if annotationDeletionCounts(scope: "markers").0 == 1 {
        return ["structuredContent": ["ok": false, "not_applied": true, "code": "confirmation_required"]]
      }
    }
    if name == "remove_measurement" {
      guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID),
            service.listMeasurements().contains(where: { $0.id == id }) else {
        return annotationRejection("The measurement ID is not present in this dataset. List measurements again.")
      }
      if service.listMeasurements().count == 1 {
        return ["structuredContent": ["ok": false, "not_applied": true, "code": "confirmation_required"]]
      }
    }
    if ["upsert_sphere_marker", "upsert_stroke_marker"].contains(name), let rawID = arguments["id"] as? String {
      guard let id = UUID(uuidString: rawID), let object = service.listObjects().first(where: { $0.id == id }),
            case .marker(let marker) = object,
            (name == "upsert_sphere_marker" ? marker.kind == .sphere : marker.kind == .stroke) else {
        return annotationRejection("The marker ID/kind is not present in the current dataset. List objects again; omit id only for a new marker.")
      }
      guard marker.points.count <= VoiceAgentAnnotationPolicy.maximumPoints, marker.name.count <= 128,
            try JSONEncoder().encode(object).count <= 64 * 1024 else {
        return annotationRejection("This marker exceeds the agent's editable detail budget. Edit it manually; a summary must not replace it.")
      }
    }
    if name == "upsert_measurement" {
      if let rawID = arguments["id"] as? String {
        guard let existing = service.listMeasurements().first(where: { $0.id == UUID(uuidString: rawID) }) else {
          return annotationRejection("The measurement ID is not present in the current dataset. List measurements again; omit id only for a new measurement.")
        }
        guard existing.points.count <= VoiceAgentAnnotationPolicy.maximumPoints, existing.name.count <= 128,
              try JSONEncoder().encode(existing).count <= 64 * 1024 else {
          return annotationRejection("This measurement exceeds the agent's editable detail budget. Edit it manually; a summary must not replace it.")
        }
      }
      let rows = arguments["points"] as! [[String: Any]]
      let state = BorgVRMeasurementCommandState(id: UUID(), name: "Validation",
        kind: VolumeMeasurementKind(rawValue: arguments["kind"] as! String)!,
        points: rows.map { row in
          let position = row["position"] as! [NSNumber]
          return BorgVRMeasurementPointCommandState(id: UUID(), position: SIMD3(position[0].floatValue, position[1].floatValue, position[2].floatValue))
        })
      let geometry = try state.measurement(physicalExtent: measurementExtent ?? .one).geometry
      guard let value = geometry.value, value.isFinite, value > 0 else {
        return annotationRejection("The points do not form a nondegenerate measurement. Area points must be coplanar and volume points non-coplanar; no change was applied.")
      }
    }
    let result: [String: Any]
    do {
      result = try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
        try await router.callTool(name: name, arguments: arguments, validateContext: validateContext)
      }
    } catch BorgVRSessionCommandError.invalidClipping where name == "set_clipping" {
      // This validation rejects the command before changing any clipping state.
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "invalid_clipping",
        "error": "Clipping bounds were not changed. Each minimum must be less than or equal to its maximum, and all bounds must be between zero and one."]]
    } catch BorgVRSessionCommandError.invalidAnnotation where ["upsert_sphere_marker", "upsert_stroke_marker", "upsert_measurement"].contains(name) {
      return annotationRejection("The annotation failed validation before being applied. Check coordinates, radius, colors and geometry.")
    }
    if name == "upsert_measurement", let content = result["structuredContent"] as? [String: Any],
       let rawID = content["id"] as? String, let id = UUID(uuidString: rawID),
       let state = service.listMeasurements().first(where: { $0.id == id }) {
      return ["structuredContent": try measurementResult(state)]
    }
    if name == "remove_object" {
      return try annotationList(service.listObjects(), key: "objects", arguments: [:], encode: annotationJSON)
    }
    if name == "remove_measurement" {
      return try annotationList(service.listMeasurements(), key: "measurements", arguments: [:], encode: measurementResult)
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

  private func annotationRejection(_ message: String) -> [String: Any] {
    ["structuredContent": ["ok": false, "not_applied": true, "code": "invalid_annotation", "error": message]]
  }

  func prepareAnnotationDeletion(scope: String, targetID: String?) throws -> VoiceAgentAnnotationDeletion? {
    guard ["all", "markers", "measurements"].contains(scope), let context else { throw VoiceAgentError.contextChanged }
    let counts = annotationDeletionCounts(scope: scope)
    if let targetID {
      guard let id = UUID(uuidString: targetID) else { return nil }
      if scope == "markers" {
        guard counts.0 == 1, service.listObjects().contains(where: { object in
          if case .marker(let marker) = object { return marker.id == id }; return false
        }) else { return nil }
      } else {
        guard counts.1 == 1, service.listMeasurements().contains(where: { $0.id == id }) else { return nil }
      }
    }
    let preview = VoiceAgentAnnotationDeletion(id: UUID(), scope: scope, markerCount: counts.0, measurementCount: counts.1)
    deletionPreview = (preview, context, try annotationDeletionDigest(scope: scope), Date().addingTimeInterval(300))
    return preview
  }

  func executeAnnotationDeletion(_ confirmation: VoiceAgentAnnotationDeletion,
                                validateContext: @escaping () throws -> Void) async throws -> [String: Any] {
    guard let preview = deletionPreview, preview.value.id == confirmation.id else {
      return annotationRejection("Deletion approval is missing or has already been consumed.")
    }
    deletionPreview = nil
    guard preview.context == context, preview.expires > Date() else {
      return annotationRejection("The dataset changed or deletion approval expired; nothing was deleted.")
    }
    do {
      return try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
        try await router.callTool(name: "clear_annotations", arguments: ["scope": preview.value.scope, "confirm": true],
          validateContext: {
            do {
              try validateContext()
              guard preview.context == self.context,
                    try self.annotationDeletionDigest(scope: preview.value.scope) == preview.digest else { throw DeletionPreviewChanged() }
            } catch { throw DeletionPreviewChanged() }
          })
      }
    } catch is DeletionPreviewChanged {
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "user_changed_view",
        "note": "The context or annotation snapshot changed after the question; nothing was deleted."]]
    }
  }

  private struct DeletionPreviewChanged: Error {}

  private func annotationDeletionCounts(scope: String) -> (Int, Int) {
    let markers = scope == "measurements" ? 0 : service.listObjects().filter { if case .marker = $0 { return true }; return false }.count
    return (markers, scope == "markers" ? 0 : service.listMeasurements().count)
  }

  private func annotationDeletionDigest(scope: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = Data(scope.utf8)
    if scope != "measurements" {
      data.append(try encoder.encode(service.listObjects().filter { if case .marker = $0 { return true }; return false }))
    }
    if scope != "markers" { data.append(try encoder.encode(service.listMeasurements())) }
    return Data(SHA256.hash(data: data))
  }

  private var measurementExtent: SIMD3<Float>? {
    guard let extent = service.applicationState().dataset?.physicalExtentMeters, extent.count == 3,
          extent.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    return SIMD3(extent[0], extent[1], extent[2])
  }

  private func annotationJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
  }

  private func measurementResult(_ state: BorgVRMeasurementCommandState) throws -> [String: Any] {
    var result = try annotationJSON(state)
    let extent = measurementExtent
    let value = try state.measurement(physicalExtent: extent).geometry.value
    result["value"] = value.map { $0 as Any } ?? NSNull()
    result["unit"] = state.kind == .length ? "m" : state.kind == .area ? "m^2" : "m^3"
    result["physicalExtentAvailable"] = extent != nil
    result["geometry"] = state.kind == .length ? "polyline" : state.kind == .area ? "planar_polygon" : "convex_hull"
    return result
  }

  private func annotationList<T>(_ rows: [T], key: String, arguments: [String: Any],
                                 encode: (T) throws -> [String: Any]) throws -> [String: Any] {
    let offset = arguments["offset"] as? Int ?? 0
    let limit = arguments["limit"] as? Int ?? 32
    var page: [[String: Any]] = [], bytes = 0
    for value in rows.dropFirst(offset).prefix(limit) {
      let row = try encode(value)
      var item = row
      var data = try JSONSerialization.data(withJSONObject: item)
      if data.count > 64 * 1024 {
        let nested = row["marker"] as? [String: Any] ?? row["mesh"] as? [String: Any] ?? row
        item = ["id": nested["id"] ?? NSNull(), "detailsOmitted": true,
                "note": "Annotation exceeds the detail budget; do not replace it using this summary."]
        data = try JSONSerialization.data(withJSONObject: item)
      }
      if bytes + data.count > 200 * 1024 { break }
      page.append(item)
      bytes += data.count
    }
    let next = min(offset, rows.count) + page.count
    return ["structuredContent": [key: page, "totalCount": rows.count, "returnedCount": page.count,
      "truncated": next < rows.count, "nextOffset": next < rows.count ? next as Any : NSNull()]]
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
