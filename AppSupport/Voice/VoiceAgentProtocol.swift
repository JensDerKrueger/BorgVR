import Foundation
import CoreFoundation

enum VoiceAgentError: LocalizedError, Equatable {
  case configuration, protocolViolation, contextChanged, timedOut, imageTooLarge
  case permissions, speechUnavailable, connection, commandFailed
  case contextLimit, changesAppliedContextLimit, changesAppliedVerificationFailed, completionUncertain

  var errorDescription: String? {
    let key: String
    switch self {
      case .configuration: key = "Check the HTTPS server address, access token and certificate."
      case .protocolViolation: key = "The agent sent an invalid or unsupported message. The connection was closed."
      case .contextChanged: key = "The dataset or edit state changed. Start a new conversation."
      case .timedOut: key = "The agent did not respond in time. Start a new conversation."
      case .imageTooLarge: key = "The render image could not be prepared for the agent."
      case .permissions: key = "Microphone and speech recognition permission are required."
      case .speechUnavailable: key = "Speech recognition is unavailable. Try text input or change the on-device recognition setting."
      case .connection: key = "The agent connection failed. Check the server, token, certificate and network access."
      case .commandFailed: key = "The command could not be completed. Inspect the visualization before continuing."
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
  let socket: URL
  let host: String

  init(_ value: String) throws {
    guard value.utf8.count <= 2048,
          var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["https", "wss"].contains(parts.scheme?.lowercased() ?? ""),
          let host = parts.host, !host.isEmpty, host != "0.0.0.0", host != "::",
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/",
          parts.port == nil || (1...65535).contains(parts.port!),
          !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
    else { throw VoiceAgentError.configuration }
    self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
    parts.scheme = "https"
    parts.port = parts.port ?? 8766
    parts.path = ""
    guard let origin = parts.url else { throw VoiceAgentError.configuration }
    self.origin = origin
    parts.scheme = "wss"
    parts.path = "/v1/session"
    guard let socket = parts.url else { throw VoiceAgentError.configuration }
    self.socket = socket
  }

  static func validateToken(_ token: String) throws {
    guard (32...512).contains(token.utf8.count), token.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
    }) else { throw VoiceAgentError.configuration }
  }
}

enum VoiceAgentPolicy {
  static func failure(code: String?, changesApplied: Bool, completionUncertain: Bool) -> VoiceAgentError {
    if completionUncertain { return .completionUncertain }
    if code == "context_limit" { return changesApplied ? .changesAppliedContextLimit : .contextLimit }
    return changesApplied ? .changesAppliedVerificationFailed : .commandFailed
  }

  static let maximumFrameBytes = 4 * 1024 * 1024
  static let maximumResultBytes = 256 * 1024
  static let allowed: Set<String> = [
    "get_application_state", "get_transfer_function", "get_background", "set_render_mode",
    "set_transform", "rotate_view", "set_iso_value", "set_clipping", "set_lighting",
    "set_background", "set_transfer_function", "set_bounding_box", "set_screen_projection",
    "wait_until_rendered", "capture_screenshot"
  ]
  static let reads: Set<String> = ["get_application_state", "get_transfer_function", "get_background",
                                    "wait_until_rendered", "capture_screenshot"]

  static func catalog(_ definitions: [[String: Any]], vision: Bool, transferFunctions: Bool,
                      images: Bool) -> [[String: Any]] {
    definitions.compactMap { original in
      guard let name = original["name"] as? String, allowed.contains(name) else { return nil }
      if vision && ["set_background", "set_screen_projection", "get_background"].contains(name) { return nil }
      if !transferFunctions && ["get_transfer_function", "set_transfer_function", "set_render_mode",
                                "set_iso_value", "set_lighting"].contains(name) { return nil }
      if !images && name == "capture_screenshot" { return nil }
      var value = original
      if ["get_transfer_function", "set_transfer_function"].contains(name) {
        value["description"] = (original["description"] as? String ?? "") +
          " Returned samples are a uniformly spaced preview across [0,1], at most 256 entries. " +
          "originalSampleCount is the full table size; samplesArePreview marks approximate previews. " +
          "This does not reduce the actual TF resolution."
      }
      if name == "capture_screenshot" {
        value["inputSchema"] = ["type": "object", "properties": ["include_alpha": ["type": "boolean"]],
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
    if tool == "get_application_state" { value.removeValue(forKey: "volumeEditing") }
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

/// Call IDs are connection-scoped, not turn-scoped. Replays must never repeat a mutation.
struct VoiceAgentCallLedger {
  struct Entry {
    let signature: String
    var reply: String?
  }
  private(set) var entries: [String: Entry] = [:]
  private var bytes = 0

  mutating func begin(id: String, signature: String) throws -> Entry? {
    guard !id.isEmpty, id.utf8.count <= 128 else { throw VoiceAgentError.protocolViolation }
    if let previous = entries[id] {
      guard previous.signature == signature else { throw VoiceAgentError.protocolViolation }
      return previous
    }
    guard entries.count < 512, bytes + signature.utf8.count <= 8 * 1024 * 1024
    else { throw VoiceAgentError.protocolViolation }
    bytes += signature.utf8.count
    entries[id] = Entry(signature: signature)
    return nil
  }

  mutating func finish(id: String, reply: String) throws {
    guard var entry = entries[id], entry.reply == nil, bytes + reply.utf8.count <= 16 * 1024 * 1024
    else { throw VoiceAgentError.protocolViolation }
    bytes += reply.utf8.count
    entry.reply = reply
    entries[id] = entry
  }
}
