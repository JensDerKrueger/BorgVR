import Foundation
import CryptoKit
import CoreFoundation

enum VoiceAgentSpeechRate {
  static let range = 0.5...2.0
  static let defaultMultiplier = 1.0

  static func normalized(_ value: Double) -> Double {
    value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultMultiplier
  }
}
enum VoiceAgentError: LocalizedError, Equatable {
  case configuration, protocolViolation, contextChanged, timedOut, imageTooLarge
  case permissions, speechUnavailable, connection, commandFailed
  case modelDeclined
  case contextLimit, changesAppliedContextLimit, changesAppliedVerificationFailed, completionUncertain

  var errorDescription: String? {
    let key: String
    switch self {
      case .configuration: key = "Check the HTTPS server address, access token and certificate."
      case .protocolViolation: key = "The assistant received an invalid decision or knowledge file."
      case .contextChanged: key = "The dataset or edit state changed. Start a new conversation."
      case .timedOut: key = "The agent did not respond in time. Start a new conversation."
      case .imageTooLarge: key = "The render image could not be prepared for the agent."
      case .permissions: key = "Microphone and speech recognition permission are required."
      case .speechUnavailable: key = "Speech recognition is unavailable. Try text input or change the on-device recognition setting."
      case .connection: key = "The agent connection failed. Check the server, token, certificate and network access."
      case .commandFailed: key = "The command could not be completed. Inspect the visualization before continuing."
      case .modelDeclined: key = "The model declined this request. No further action was taken."
      case .contextLimit: key = "The request exceeds the AI model's context. Start a new conversation or shorten the request."
      case .changesAppliedContextLimit: key = "Changes were applied, but the AI model's context was exhausted before the final check. Inspect the visualization and start a new conversation."
      case .changesAppliedVerificationFailed: key = "Changes were applied, but the final check could not be completed. Inspect the visualization before continuing."
      case .completionUncertain: key = "It is unclear whether the last change was fully applied. Inspect the visualization before starting a new conversation; the command will not be repeated automatically."
    }
    return NSLocalizedString(key, tableName: "VoiceAgent", comment: "")
  }
}

struct VoiceAgentEndpoint: Equatable {
  let origin: URL
  let host: String

  init(_ value: String) throws {
    guard value.utf8.count <= 2048,
          var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty, host != "0.0.0.0", host != "::",
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          ["", "/", "/v1", "/v1/"].contains(parts.path),
          parts.port == nil || (1...65535).contains(parts.port!),
          !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
    else { throw VoiceAgentError.configuration }
    self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
    parts.scheme = "https"
    parts.path = ""
    guard let origin = parts.url else { throw VoiceAgentError.configuration }
    self.origin = origin
  }

  static func validateToken(_ token: String) throws {
    guard (32...512).contains(token.utf8.count), token.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
    }) else { throw VoiceAgentError.configuration }
  }
}

enum VoiceAgentPolicy {
  static let commandHistoryTool = "get_command_history"
  static func failure(code: String?, changesApplied: Bool, completionUncertain: Bool) -> VoiceAgentError {
    if completionUncertain { return .completionUncertain }
    if code == "context_limit" { return changesApplied ? .changesAppliedContextLimit : .contextLimit }
    return changesApplied ? .changesAppliedVerificationFailed : .commandFailed
  }

  static let maximumFrameBytes = 4 * 1024 * 1024
  static let maximumResultBytes = 256 * 1024
  static let maximumTools = 48
  static let conversionTools: Set<String> = ["import_volume", "fuse_volumes"]
  static let fileTools: Set<String> = conversionTools.union(["save_visualization_state", "load_visualization_state", "export_edited_dataset"])
  private static let transitions = ["open_dataset": "open", "close_dataset": "close",
                                    "select_edit_state": "select_edit", "create_edit_state": "create_edit"]
  static let datasetTransitions = Set(transitions.keys)

  static func outputName(_ value: Any?, extension suffix: String) -> String? {
    guard let raw = value as? String else { return nil }
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.lowercased().hasSuffix("." + suffix) { name = String(name.dropLast(suffix.count + 1)) }
    guard !name.isEmpty, name.utf8.count <= 160, !name.hasPrefix("."),
          !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet(charactersIn: "/\\:").contains($0)
          }) else { return nil }
    return name + "." + suffix
  }
  static let allowed: Set<String> = [
    "search_datasets", "open_dataset", "close_dataset", "get_command_history",
    "get_application_state", "get_transfer_function", "get_background", "set_render_mode",
    "set_transform", "rotate_view", "set_iso_value", "set_clipping", "set_lighting",
    "set_background", "set_transfer_function", "set_bounding_box", "set_screen_projection", "reset_state",
    "get_volume_edit_state", "select_edit_state", "create_edit_state", "rename_edit_state", "delete_edit_state",
    "configure_volume_brush", "edit_volume", "wait_volume_edits",
    "save_visualization_state", "load_visualization_state", "export_edited_dataset", "cancel_volume_export",
    "import_volume", "fuse_volumes", "get_import_status", "cancel_import",
    "list_objects", "upsert_sphere_marker", "upsert_stroke_marker",
    "list_measurements", "upsert_measurement", "set_annotation_visibility",
    "remove_object", "remove_measurement", "clear_annotations",
    "wait_until_rendered", "capture_screenshot", "pick_screenshot_positions"
  ]
  static let additionalTools: Set<String> = [
    "set_transfer_function_component", "capture_tf_preview",
  ]
  static let intensityPreviewTool: [String: Any] = [
    "name": "capture_tf_preview",
    "description": "Render a coarse, isolated Z projection of a scalar intensity band without changing the current view.",
    "inputSchema": ["type": "object", "additionalProperties": false, "required": ["channel", "high", "low", "palette"],
      "properties": ["channel": ["type": "integer", "minimum": 0, "maximum": 3],
                     "low": ["type": "number", "minimum": 0, "maximum": 1],
                     "high": ["type": "number", "minimum": 0, "maximum": 1],
                     "palette": ["type": "string", "enum": ["grayscale", "rainbow"]]]]
  ]
  static let reads: Set<String> = ["search_datasets", "get_application_state", "get_transfer_function", "get_background",
                                    "wait_until_rendered", "capture_screenshot", "capture_tf_preview", "pick_screenshot_positions", "list_objects", "list_measurements",
                                    "get_volume_edit_state", "wait_volume_edits", "get_command_history", "get_import_status"]

  static let maximumVolumeEditSamples = 256
  static let applicationTools: Set<String> = conversionTools.union([
    "get_application_state", "search_datasets", "open_dataset", "get_command_history", "get_import_status", "cancel_import",
  ])

  static var importCatalog: [[String: Any]] {
    func tool(_ name: String, _ text: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
      ["name": name, "description": text, "inputSchema": ["type": "object", "additionalProperties": false,
        "properties": properties, "required": required]]
    }
    let filename: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 120]
    let description: [String: Any] = ["type": "string", "maxLength": 300]
    let fusionKinds: [String: Any] = ["type": "string", "enum": ["file", "zarr", "dicom"]]
    return [
      tool("import_volume", "Import a user-selected local volume file, Zarr folder, DICOM series folder, or image sequence as new BorgVR .data, using current app import settings. Start with no dataset open. Ask for missing physical sizes for image sequences (meters, XYZ). No file paths. Returns a job; use get_import_status.", [
        "filename": filename, "description": description,
        "source_kind": ["type": "string", "enum": ["file", "zarr", "dicom", "images"]],
        "size_meters": ["type": "array", "minItems": 3, "maxItems": 3,
                         "items": ["type": "number", "exclusiveMinimum": 0]],
      ], ["filename", "source_kind"]),
      tool("fuse_volumes", "Register the second user-selected local volume to the first and save the fused .data in the dataset catalog. Use scalar inputs with matching sample precision. Start with no dataset open. No file paths. Returns a job; use get_import_status.", [
        "filename": filename, "description": description, "reference_kind": fusionKinds, "moving_kind": fusionKinds,
      ], ["filename", "reference_kind", "moving_kind"]),
      tool("get_import_status", "Read the latest local import/fusion job's progress and status (no source paths). Optionally wait up to 10 seconds. For a long-running job, report that it is running and let the local progress indicator show updates rather than repeatedly polling. After completion, search the dataset catalog to open the result.", [
        "wait_seconds": ["type": "number", "minimum": 0, "maximum": 10],
      ]),
      tool("cancel_import", "Cancel the active import or fusion using its exact job ID. Does not remove completed datasets.", [
        "id": ["type": "string", "maxLength": 36],
      ], ["id"]),
    ]
  }

  static func catalog(_ definitions: [[String: Any]], vision: Bool, transferFunctions: Bool,
                      images: Bool, datasetReady: Bool = true) -> [[String: Any]] {
    let history: [String: Any] = ["name": commandHistoryTool,
      "description": "Read confirmed historical BorgVR tool executions in this conversation and current app/dataset/edit context. Use source 'chat' for the user's earlier messages and final assistant text. Filter command receipts by tool or kind, then pass nextCursor as cursor for older matches. Larger fields can be read by id, field and nextOffset (byte offset). History is not current state, permission, or a replay command.",
      "inputSchema": ["type": "object", "additionalProperties": false, "properties": [
        "source": ["type": "string", "enum": ["commands", "chat"]],
        "tool": ["type": "string", "maxLength": 64],
        "kind": ["type": "string", "enum": ["all", "read", "mutation"]],
        "limit": ["type": "integer", "minimum": 1, "maximum": 8],
        "cursor": ["type": "string", "maxLength": 36],
        "id": ["type": "string", "maxLength": 36],
        "field": ["type": "string", "enum": ["arguments", "result", "text"]],
        "offset": ["type": "integer", "minimum": 0, "maximum": maximumResultBytes],
      ]] as [String: Any]]
    return (definitions.filter { $0["name"] as? String != commandHistoryTool } + [history]).compactMap { original in
      guard let name = original["name"] as? String, allowed.contains(name) || additionalTools.contains(name) else { return nil }
      if !datasetReady && !applicationTools.contains(name) { return nil }
      if datasetReady && conversionTools.contains(name) { return nil }
      if vision && ["set_background", "set_screen_projection", "get_background"].contains(name) { return nil }
      if !transferFunctions && ["get_transfer_function", "set_transfer_function", "set_transfer_function_component", "capture_tf_preview", "set_render_mode",
                                "set_iso_value", "set_lighting"].contains(name) { return nil }
      if !images && ["capture_screenshot", "capture_tf_preview", "pick_screenshot_positions"].contains(name) { return nil }
      var value = original
      if let schema = VoiceAgentAnnotationPolicy.schema(for: name) {
        value["inputSchema"] = schema
        if name == "remove_object" {
          value["description"] = "Remove one listed sphere, directional or stroke marker by UUID, never a mesh. Read application state and list_objects first. The app confirms deleting the last marker. Only delete on explicit user request."
        } else if name == "remove_measurement" || name == "clear_annotations" {
          value["description"] = (original["description"] as? String ?? "") + " Read state and the relevant annotation lists first. Bulk deletion and deletion of the last item require local human approval; a model-supplied confirm flag cannot grant permission. Never bypass a declined deletion with individual calls."
        } else {
          value["description"] = (original["description"] as? String ?? "") + VoiceAgentAnnotationPolicy.guidance
        }
      }
      if ["get_transfer_function", "set_transfer_function"].contains(name) {
        value["description"] = (original["description"] as? String ?? "") +
          " Returned samples are a uniformly spaced preview across [0,1], at most 256 entries. " +
          "originalSampleCount is the full table size; samplesArePreview marks approximate previews. " +
          "This does not reduce the actual TF resolution."
      }
      if name == "capture_screenshot" {
        var properties: [String: Any] = ["include_alpha": ["type": "boolean"]]
        if let schema = original["inputSchema"] as? [String: Any],
           let advertised = schema["properties"] as? [String: Any],
           let maxWidth = advertised["max_width"] {
          properties["max_width"] = maxWidth
        }
        value["inputSchema"] = ["type": "object", "properties": properties, "additionalProperties": false]
      }
      if name == "reset_state" {
        var scopes = ["transform", "clipping"]
        if transferFunctions { scopes += ["transfer_function", "lighting", "all"] }
        value["description"] = "Reset the specified visualization group to its defaults. 'all' resets the rendering parameters, not voxel edits or annotations. Use the smallest applicable scope."
        value["inputSchema"] = ["type": "object", "properties": ["scope": ["type": "string", "enum": scopes]],
                                "required": ["scope"], "additionalProperties": false] as [String: Any]
      }
      if name == "get_volume_edit_state" {
        value["description"] = "Read saved edit states (ID and display name), active state ID (absent for original), brush channels, brick readiness and export progress. No file paths. This never edits the volume."
      }
      if name == "configure_volume_brush" {
        value["description"] = "Choose the editable channels for subsequent erase/restore operations. Read componentCount in get_volume_edit_state first. Channel numbers start at 1. Pass every channel number to edit all channels."
        value["inputSchema"] = ["type": "object", "additionalProperties": false, "required": ["channels"],
          "properties": ["channels": ["type": "array", "minItems": 1, "maxItems": 4, "uniqueItems": true,
            "items": ["type": "integer", "minimum": 1, "maximum": 4]]]] as [String: Any]
      }
      if name == "load_visualization_state" {
        value["description"] = "Load a saved BorgVR visualization JSON for the open dataset. The user chooses the file locally. No arguments or file paths. Changes the presentation, not voxels or annotations."
        value["inputSchema"] = ["type": "object", "additionalProperties": false, "properties": [:]] as [String: Any]
      } else if fileTools.contains(name) && !conversionTools.contains(name) {
        value["description"] = name == "save_visualization_state"
          ? "Save the current view configuration (not voxel edits or annotations) as JSON. The user chooses the folder locally. Supply a filename only. Existing files are never overwritten."
          : "Export the current volume and active edits as a new .data dataset. The user chooses the folder locally. Supply a filename only. Poll get_volume_edit_state for completion before closing. This does not alter the source."
        value["inputSchema"] = ["type": "object", "additionalProperties": false, "required": ["filename"],
          "properties": ["filename": ["type": "string", "minLength": 1, "maxLength": 120]]] as [String: Any]
      }
      let editStateName: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 120]
      let editStateID: [String: Any] = ["type": "string", "minLength": 36, "maxLength": 36]
      switch name {
        case "create_edit_state":
          value["description"] = "Create and select an empty personal edit state. Set duplicate:true to copy the current state instead. Name is optional. Read get_volume_edit_state first and reread state after the switch."
          value["inputSchema"] = ["type": "object", "additionalProperties": false,
            "properties": ["name": editStateName, "duplicate": ["type": "boolean"]]] as [String: Any]
        case "rename_edit_state":
          value["description"] = "Rename a personal saved edit state. Read get_volume_edit_state first and use an exact UUID from savedStates. Does not select the state or alter its voxels."
          value["inputSchema"] = ["type": "object", "additionalProperties": false, "required": ["id", "name"],
            "properties": ["id": editStateID, "name": editStateName]] as [String: Any]
        case "delete_edit_state":
          value["description"] = "Delete one inactive personal edit state on explicit user request. Read get_volume_edit_state first and use an exact UUID from savedStates. The app requires local confirmation; no model argument can approve this. Do not retry a declined deletion."
          value["inputSchema"] = ["type": "object", "additionalProperties": false, "required": ["id"],
            "properties": ["id": editStateID]] as [String: Any]
        default: break
      }
      if name == "cancel_volume_export" {
        value["description"] = "Cancel only an export this assistant started. Use its exact job ID from the export receipt or status. Does not change voxel edits."
      }
      if name == "edit_volume", var schema = value["inputSchema"] as? [String: Any],
         var properties = schema["properties"] as? [String: Any],
         var samples = properties["samples"] as? [String: Any] {
        samples["maxItems"] = maximumVolumeEditSamples
        properties["samples"] = samples
        schema["properties"] = properties
        value["inputSchema"] = schema
        value["description"] = "Apply one locally approved batch of spherical erase or restore stamps to the current personal edit state and channels. The original dataset is not changed. Centers and radii are dataset-local meters from the minimum corner, independent of the view. Do not guess a 3D position from a 2D screenshot. Read get_application_state and get_volume_edit_state first. Submission does not imply bricks are ready: check bricksReady or use wait_volume_edits."
      }
      if name == "wait_volume_edits" {
        value["description"] = "Wait briefly for local edit-brick rebuild and persistence. A timeout returns pending status, not failure or cancellation of the edit. This does not verify that every updated brick has been uploaded to the GPU atlas."
        value["inputSchema"] = ["type": "object", "properties": ["timeout_seconds": ["type": "number", "minimum": 0.1, "maximum": 10]],
                                "additionalProperties": false] as [String: Any]
      }
      if name == "wait_until_rendered", var schema = value["inputSchema"] as? [String: Any],
         var properties = schema["properties"] as? [String: Any] {
        properties["timeout_seconds"] = ["type": "number", "minimum": 0.1, "maximum": 30]
        schema["properties"] = properties
        value["inputSchema"] = schema
      }
      return value
    }
  }

  static func validate(_ value: Any, schema: [String: Any], depth: Int = 0) throws {
    guard depth <= 16 else { throw VoiceAgentError.protocolViolation }
    switch schema["type"] as? String {
      case "object":
        guard let object = value as? [String: Any], let properties = schema["properties"] as? [String: Any],
              Set(object.keys).isSubset(of: Set(properties.keys)),
              Set(schema["required"] as? [String] ?? []).isSubset(of: Set(object.keys))
        else { throw VoiceAgentError.protocolViolation }
        for (key, item) in object {
          guard let child = properties[key] as? [String: Any] else { throw VoiceAgentError.protocolViolation }
          try validate(item, schema: child, depth: depth + 1)
        }
      case "array":
        guard let array = value as? [Any], array.count >= (schema["minItems"] as? Int ?? 0),
              array.count <= (schema["maxItems"] as? Int ?? 65536),
              let items = schema["items"] as? [String: Any] else { throw VoiceAgentError.protocolViolation }
        for item in array { try validate(item, schema: items, depth: depth + 1) }
      case "number", "integer":
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { throw VoiceAgentError.protocolViolation }
        let n = number.doubleValue
        if schema["type"] as? String == "integer", n.rounded() != n { throw VoiceAgentError.protocolViolation }
        if let min = schema["minimum"] as? NSNumber, n < min.doubleValue { throw VoiceAgentError.protocolViolation }
        if let max = schema["maximum"] as? NSNumber, n > max.doubleValue { throw VoiceAgentError.protocolViolation }
        if let min = schema["exclusiveMinimum"] as? NSNumber, n <= min.doubleValue { throw VoiceAgentError.protocolViolation }
      case "boolean":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { throw VoiceAgentError.protocolViolation }
      case "string":
        guard let string = value as? String, string.count <= (schema["maxLength"] as? Int ?? 8192)
        else { throw VoiceAgentError.protocolViolation }
      default: throw VoiceAgentError.protocolViolation
    }
    if let choices = schema["enum"] as? [String], let string = value as? String,
       !choices.contains(string) { throw VoiceAgentError.protocolViolation }
  }

  static func decode(_ string: String) throws -> [String: Any] {
    guard string.utf8.count <= maximumFrameBytes,
          let object = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
    else { throw VoiceAgentError.protocolViolation }
    return object
  }

  static func compactResult(_ original: [String: Any], tool: String) -> [String: Any] {
    var value = original
    value.removeValue(forKey: "volumeEditing")
    if ["get_transfer_function", "set_transfer_function"].contains(tool),
       let rows = value["samples"] as? [[Any]] {
      value["originalSampleCount"] = rows.count
      value["samplesArePreview"] = rows.count > 256
      if rows.count > 256 {
        value["samples"] = (0..<256).map { rows[Int((Double($0) * Double(rows.count - 1) / 255).rounded())] }
      }
    }
    return value
  }

  static func encoded(_ value: [String: Any], limit: Int = maximumFrameBytes) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard data.count <= limit, let string = String(data: data, encoding: .utf8)
    else { throw VoiceAgentError.protocolViolation }
    return string
  }
}

/// Confirmed tool receipts belong to the local conversation, never the model context window.
struct VoiceAgentCommandHistory<Scope: Equatable & Codable>: Codable {
  private struct Receipt: Codable {
    let id: UUID
    var scope: Scope
    let tool: String
    let read: Bool
    let arguments: Data
    let result: Data

    var bytes: Int { arguments.count + result.count }
  }
  private struct ChatMessage: Codable {
    let id: UUID
    var scope: Scope
    let role: String
    let text: Data
  }

  private var receipts: [Receipt] = []
  private var chat: [ChatMessage] = []
  private static var inlineBudget: Int { 12 * 1024 }
  private static var pageBytes: Int { 4096 }

  var transcript: [(user: Bool, text: String)] {
    chat.map { ($0.role == "user", String(decoding: $0.text, as: UTF8.self)) }
  }
  var scopes: [Scope] { receipts.map(\.scope) + chat.map(\.scope) }
  var isEmpty: Bool { receipts.isEmpty && chat.isEmpty }

  mutating func rebindScopes(_ replacement: (Scope) -> Scope) {
    for i in receipts.indices { receipts[i].scope = replacement(receipts[i].scope) }
    for i in chat.indices { chat[i].scope = replacement(chat[i].scope) }
  }

  mutating func clear() {
    receipts.removeAll()
    chat.removeAll()
  }

  mutating func appendMessage(scope: Scope, user: Bool, text: String) {
    let data = Data(text.utf8)
    guard data.count <= 64 * 1024 else { return }
    let role = user ? "user" : "assistant"
    if let previous = chat.last, previous.scope == scope, previous.role == role, previous.text == data { return }
    chat.append(.init(id: UUID(), scope: scope, role: role, text: data))
    while chat.count > 100 || chat.reduce(0, { $0 + $1.text.count }) > 512 * 1024 {
      chat.removeFirst()
    }
  }

  mutating func append(scope: Scope, tool: String, arguments: [String: Any], result: [String: Any]) {
    guard tool != VoiceAgentPolicy.commandHistoryTool, result["not_applied"] as? Bool != true,
          result["ok"] as? Bool != false, result["error"] == nil,
          let inputs = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
          let output = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
          inputs.count <= VoiceAgentPolicy.maximumResultBytes, output.count <= VoiceAgentPolicy.maximumResultBytes
    else { return }
    let read = VoiceAgentPolicy.reads.contains(tool)
    receipts.append(Receipt(id: UUID(), scope: scope, tool: tool, read: read, arguments: inputs, result: output))
    // Polling and screenshot metadata must not displace mutation receipts.
    let countLimit = read ? 16 : 48
    let byteLimit = read ? 512 * 1024 : 1024 * 1024
    while true {
      let partition = receipts.indices.filter { receipts[$0].read == read }
      guard partition.count > countLimit || partition.reduce(0, { $0 + receipts[$1].bytes }) > byteLimit else { break }
      receipts.remove(at: partition[0])
    }
  }

  func lookup(scope: Scope, query: [String: Any]) -> [String: Any] {
    if query["source"] as? String == "chat" { return lookupChat(scope: scope, query: query) }
    let visible = receipts.reversed().filter { $0.scope == scope }
    if let field = query["field"] as? String {
      guard Set(query.keys).isSubset(of: ["source", "id", "field", "offset"]),
            let id = (query["id"] as? String).flatMap(UUID.init(uuidString:)),
            let receipt = visible.first(where: { $0.id == id }), ["arguments", "result"].contains(field)
      else { return ["ok": false, "code": "history_receipt_unavailable"] }
      let data = field == "arguments" ? receipt.arguments : receipt.result
      return page(data, offset: query["offset"] as? Int ?? 0,
                  metadata: ["id": id.uuidString, "tool": receipt.tool, "field": field, "format": "json"])
    }
    guard query["offset"] == nil else { return ["ok": false, "code": "history_offset_invalid"] }
    let tool = query["tool"] as? String
    let id = (query["id"] as? String).flatMap(UUID.init(uuidString:))
    if query["id"] != nil, id == nil { return ["ok": false, "code": "history_receipt_unavailable"] }
    let kind = query["kind"] as? String ?? "all"
    var matches = visible.filter {
      (tool == nil || $0.tool == tool) && (id == nil || $0.id == id) &&
      (kind == "all" || kind == ($0.read ? "read" : "mutation"))
    }
    if let cursor = query["cursor"] as? String {
      guard let cursorID = UUID(uuidString: cursor), let position = matches.firstIndex(where: { $0.id == cursorID })
      else { return ["ok": false, "code": "history_cursor_unavailable"] }
      matches = Array(matches.dropFirst(position + 1))
    }
    let limit = min(8, max(1, query["limit"] as? Int ?? 4))
    var budget = Self.inlineBudget
    let rows: [[String: Any]] = matches.prefix(limit).map { receipt in
      var row: [String: Any] = ["id": receipt.id.uuidString, "tool": receipt.tool,
        "kind": receipt.read ? "read" : "mutation", "argumentsBytes": receipt.arguments.count,
        "resultBytes": receipt.result.count]
      for (field, data) in [("arguments", receipt.arguments), ("result", receipt.result)] where data.count <= budget {
        row[field] = try? JSONSerialization.jsonObject(with: data)
        budget -= data.count
      }
      return row
    }
    var result: [String: Any] = ["history": rows, "historicalOnly": true]
    if matches.count > limit { result["nextCursor"] = matches[limit - 1].id.uuidString }
    return result
  }

  private func lookupChat(scope: Scope, query: [String: Any]) -> [String: Any] {
    var matches = chat.reversed().filter { $0.scope == scope }
    if query["field"] != nil {
      guard Set(query.keys).isSubset(of: ["source", "id", "field", "offset"]),
            query["field"] as? String == "text",
            let id = (query["id"] as? String).flatMap(UUID.init(uuidString:)),
            let message = matches.first(where: { $0.id == id })
      else { return ["ok": false, "code": "history_message_unavailable"] }
      return page(message.text, offset: query["offset"] as? Int ?? 0,
                  metadata: ["id": id.uuidString, "role": message.role, "field": "text", "format": "text"])
    }
    guard Set(query.keys).isSubset(of: ["source", "cursor", "limit"]) else {
      return ["ok": false, "code": "history_query_invalid"]
    }
    if let cursor = query["cursor"] as? String {
      guard let id = UUID(uuidString: cursor), let position = matches.firstIndex(where: { $0.id == id })
      else { return ["ok": false, "code": "history_cursor_unavailable"] }
      matches = Array(matches.dropFirst(position + 1))
    }
    let limit = min(8, max(1, query["limit"] as? Int ?? 4))
    var budget = Self.inlineBudget
    let rows: [[String: Any]] = matches.prefix(limit).map { message in
      var row: [String: Any] = ["id": message.id.uuidString, "role": message.role, "textBytes": message.text.count]
      if message.text.count <= budget {
        row["text"] = String(decoding: message.text, as: UTF8.self)
        budget -= message.text.count
      }
      return row
    }
    var result: [String: Any] = ["chat": rows, "historicalOnly": true]
    if matches.count > limit { result["nextCursor"] = matches[limit - 1].id.uuidString }
    return result
  }

  private func page(_ data: Data, offset: Int, metadata: [String: Any]) -> [String: Any] {
    // Use byte offsets but never split a UTF-8 scalar.
    guard (0..<data.count).contains(offset), data[offset] & 0xc0 != 0x80 else {
      return ["ok": false, "code": "history_offset_invalid"]
    }
    var end = min(data.count, offset + Self.pageBytes)
    while end < data.count, data[end] & 0xc0 == 0x80 { end -= 1 }
    var page = metadata
    page["offset"] = offset
    page["totalBytes"] = data.count
    page["fragment"] = String(decoding: data[offset..<end], as: UTF8.self)
    if end < data.count { page["nextOffset"] = end }
    return page
  }
}
