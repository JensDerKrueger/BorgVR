import Foundation

/// Agent-facing bounds only; BorgVR's annotation types and execution stay in the bridge.
enum VoiceAgentAnnotationPolicy {
  static let maximumPoints = 256
  static let guidance = " Read application state and list existing annotations before changes. Coordinates are dataset-local [x,y,z] in [0,1], not pixels, world positions or patient axes. Omit id when creating; use a listed UUID when editing. Upsert replaces the complete item: preserve unmodified fields and measurement point IDs. Colors are normalized RGBA in [0,1], not bytes. Lists are paginated; check totalCount and truncated. Never invent anatomical orientation or precise 3D points from an ambiguous 2D view."

  static func schema(for name: String) -> [String: Any]? {
    let position: [String: Any] = ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1], "minItems": 3, "maxItems": 3]
    let color: [String: Any] = ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1], "minItems": 4, "maxItems": 4]
    let id: [String: Any] = ["type": "string", "maxLength": 36]
    var properties: [String: Any] = ["id": id, "name": ["type": "string", "maxLength": 128]]
    var required: [String] = []
    switch name {
      case "list_objects", "list_measurements":
        properties = ["offset": ["type": "integer", "minimum": 0, "maximum": 1_000_000],
                      "limit": ["type": "integer", "minimum": 1, "maximum": 64]]
      case "set_annotation_visibility":
        properties = ["objects": ["type": "boolean"], "measurements": ["type": "boolean"]]
      case "upsert_sphere_marker":
        properties.merge(["position": position, "color": color,
          "radius": ["type": "number", "minimum": 0.005, "maximum": 1],
          "direction_origin": position, "shows_direction": ["type": "boolean"]]) { _, new in new }
        required = ["position"]
      case "upsert_stroke_marker", "upsert_measurement":
        var pointProperties: [String: Any] = ["position": position]
        var pointRequired = ["position"]
        if name == "upsert_stroke_marker" {
          properties["color"] = color
          pointProperties["radius"] = ["type": "number", "minimum": 0.0002, "maximum": 0.25]
          pointRequired.append("radius")
        } else {
          pointProperties["id"] = id
          properties["kind"] = ["type": "string", "enum": ["length", "area", "volume"]]
          required.append("kind")
        }
        properties["points"] = ["type": "array", "minItems": name == "upsert_measurement" ? 2 : 1,
          "maxItems": maximumPoints, "items": ["type": "object", "additionalProperties": false,
            "properties": pointProperties, "required": pointRequired]]
        required.append("points")
      default: return nil
    }
    return ["type": "object", "properties": properties, "additionalProperties": false, "required": required]
  }

  static func validationError(name: String, arguments: [String: Any]) -> String? {
    guard let schema = schema(for: name) else { return nil }
    guard (try? VoiceAgentPolicy.validate(arguments, schema: schema)) != nil else {
      return "Use the advertised annotation schema and bounded dataset-local coordinates."
    }
    if name == "set_annotation_visibility", arguments.isEmpty { return "Specify objects and/or measurements visibility." }
    if let id = arguments["id"] as? String, UUID(uuidString: id) == nil { return "Use a listed UUID, or omit id to create an annotation." }
    if name == "upsert_sphere_marker", arguments["shows_direction"] as? Bool == true, arguments["direction_origin"] == nil {
      return "A directional marker requires direction_origin."
    }
    if name == "upsert_measurement", let points = arguments["points"] as? [[String: Any]] {
      let minimum = ["length": 2, "area": 3, "volume": 4][arguments["kind"] as? String ?? ""] ?? Int.max
      if points.count < minimum { return "Length needs 2 points, area 3, and volume 4."
      }
      let ids = points.compactMap { $0["id"] as? String }
      if ids.contains(where: { UUID(uuidString: $0) == nil }) || Set(ids.map { $0.lowercased() }).count != ids.count {
        return "Measurement point IDs must be unique UUIDs; preserve listed IDs when editing."
      }
    }
    return nil
  }
}
