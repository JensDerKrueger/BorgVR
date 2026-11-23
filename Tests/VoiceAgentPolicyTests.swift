import Foundation

private enum Failure: Error { case failed(String) }
private func check(_ condition: Bool, _ label: String) throws {
  if !condition { throw Failure.failed(label) }
}
private func rejects(_ operation: () throws -> Void) throws {
  do { try operation() } catch { return }
  throw Failure.failed("Unsafe input accepted")
}

@main
struct VoiceAgentPolicyTests {
  static func main() throws {
    let endpoint = try VoiceAgentEndpoint("https://ai1:8766/")
    try check(endpoint.origin.absoluteString == "https://ai1:8766", "Wrong HTTPS origin")
    try check(try VoiceAgentEndpoint("https://[::1]:8766").host == "::1", "IPv6 host normalization")
    for value in ["http://ai1", "https://user:secret@ai1", "https://ai1?token=x", "https://ai1/path",
                  "https://ai1#fragment", "https://ai1:0", "https://ai1:65536", "https://0.0.0.0"] {
      try rejects { _ = try VoiceAgentEndpoint(value) }
    }
    try VoiceAgentEndpoint.validateToken(String(repeating: "a", count: 64))
    try rejects { try VoiceAgentEndpoint.validateToken("short") }
    try rejects { try VoiceAgentEndpoint.validateToken(String(repeating: "a", count: 64) + "\n") }
    let schema: [String: Any] = ["type": "object", "additionalProperties": false,
      "properties": ["visible": ["type": "boolean"], "value": ["type": "number", "minimum": 0, "maximum": 1]],
      "required": ["visible"]]
    try VoiceAgentPolicy.validate(["visible": true, "value": 0.5], schema: schema)
    try rejects { try VoiceAgentPolicy.validate(["visible": 1], schema: schema) }
    try rejects { try VoiceAgentPolicy.validate(["visible": true, "value": Double.nan], schema: schema) }
    try rejects { try VoiceAgentPolicy.validate(["visible": true, "value": 2], schema: schema) }
    try rejects { try VoiceAgentPolicy.validate(["visible": true, "output_path": "/secret"], schema: schema) }
    try rejects { _ = try VoiceAgentPolicy.decode("[]") }
    try rejects { _ = try VoiceAgentPolicy.encoded(["text": String(repeating: "x", count: 1024)], limit: 64) }
    try check(VoiceAgentPolicy.outputName(" Result.DATA ", extension: "data") == "Result.data", "Filename extension not normalized")
    for name in ["", ".", "..", "../test", "/tmp/test", "folder\\test", ".hidden", "a:b", "a\u{0}b"] {
      try check(VoiceAgentPolicy.outputName(name, extension: "data") == nil, "Unsafe output filename accepted")
    }
    let rows = (0..<65536).map { [$0 % 256, 0, 0, 255] }
    let preview = VoiceAgentPolicy.compactResult(["channel": 0, "samples": rows], tool: "get_transfer_function")
    try check(preview["originalSampleCount"] as? Int == 65536 && preview["samplesArePreview"] as? Bool == true,
              "TF preview was not explicitly marked")
    let samples = preview["samples"] as! [[Int]]
    try check(samples.count == 256 && samples.first == rows.first && samples.last == rows.last,
              "TF preview size or endpoints changed")
    _ = try VoiceAgentPolicy.encoded(preview, limit: VoiceAgentPolicy.maximumResultBytes)
    try check(rows.count == 65536, "TF preview changed the original table")
    try check(VoiceAgentPolicy.allowed.contains("open_dataset") && VoiceAgentPolicy.reads.contains("search_datasets") &&
              VoiceAgentPolicy.allowed.contains("edit_volume") && !VoiceAgentPolicy.reads.contains("edit_volume") &&
              VoiceAgentPolicy.reads.contains("wait_volume_edits") &&
              !VoiceAgentPolicy.allowed.contains("discard_volume_edits") &&
              !VoiceAgentPolicy.allowed.contains("load_settings"), "Wrong permissions for volume edits or unsafe capabilities")
    var history = VoiceAgentCommandHistory<String>()
    let exact = ["degrees": 13.125]
    history.append(scope: "opening-a", tool: "rotate_view", arguments: exact, result: ["frame": 17])
    history.append(scope: "opening-a", tool: "rotate_view", arguments: ["degrees": 99],
                   result: ["not_applied": true])
    history.append(scope: "opening-a", tool: "get_command_history", arguments: [:], result: ["history": []])
    history.appendMessage(scope: "opening-a", user: true, text: "Turn the volume slightly.")
    history.appendMessage(scope: "opening-a", user: false, text: "Turned.")
    for index in 0..<30 {
      history.append(scope: "opening-a", tool: "get_application_state", arguments: [:], result: ["frame": index])
    }
    let rotation = history.lookup(scope: "opening-a", query: ["kind": "mutation"])["history"] as? [[String: Any]]
    try check(rotation?.count == 1 && rotation?.first?["arguments"] as? [String: Double] == exact &&
              (rotation?.first?["result"] as? [String: Int])?["frame"] == 17,
              "Polling, rejected actions, or readback corrupted a confirmed command")
    let browse = history.lookup(scope: "opening-a", query: ["kind": "read", "limit": 2])
    let cursor = browse["nextCursor"] as? String ?? ""
    let older = history.lookup(scope: "opening-a", query: ["kind": "read", "limit": 2, "cursor": cursor])
    try check((older["history"] as? [[String: Any]])?.first?["id"] as? String != cursor &&
              older["nextCursor"] != nil, "History did not page older records")
    let chat = history.lookup(scope: "opening-a", query: ["source": "chat"])["chat"] as? [[String: Any]]
    try check(chat?.count == 2 && chat?.last?["text"] as? String == "Turn the volume slightly." &&
              (history.lookup(scope: "opening-b", query: ["source": "chat"])["chat"] as? [[String: Any]])?.isEmpty == true,
              "History lost chat context or crossed an opening boundary")
    let large = String(repeating: "\u{00E9}\u{6F22}\"", count: 5000)
    history.append(scope: "opening-a", tool: "list_objects", arguments: [:], result: ["text": large])
    let item = (history.lookup(scope: "opening-a", query: ["tool": "list_objects"])["history"] as? [[String: Any]])!.first!
    let receiptID = item["id"] as! String
    try check(item["result"] == nil && item["resultBytes"] != nil, "Large fields were sent inline or lost")
    var assembled = ""
    var offset: Int? = 0
    while let current = offset {
      let page = history.lookup(scope: "opening-a", query: ["id": receiptID, "field": "result", "offset": current])
      assembled += page["fragment"] as? String ?? ""
      offset = page["nextOffset"] as? Int
    }
    let reconstructed = try JSONSerialization.jsonObject(with: Data(assembled.utf8)) as? [String: String]
    try check(reconstructed?["text"] == large &&
              history.lookup(scope: "opening-b", query: ["id": receiptID, "field": "result"])["ok"] as? Bool == false,
              "Large field was not recovered exactly or leaked into another context")
    history.clear()
    try check((history.lookup(scope: "opening-a", query: [:])["history"] as? [[String: Any]])?.isEmpty == true,
              "A new conversation retained old command history")
    let sphereSchema = VoiceAgentAnnotationPolicy.schema(for: "upsert_sphere_marker")!
    try VoiceAgentPolicy.validate(["position": [0.2, 0.3, 0.4], "radius": 0.01], schema: sphereSchema)
    for arguments: [String: Any] in [["position": [-0.1, 0.3, 0.4]], ["position": [0.2, 1.1, 0.4]],
      ["position": [0.2, 0.3, 0.4], "radius": -1], ["position": [0.2, 0.3, 0.4], "color": [255, 0, 0, 255]]] {
      try rejects { try VoiceAgentPolicy.validate(arguments, schema: sphereSchema) }
    }
    try check(VoiceAgentAnnotationPolicy.validationError(name: "upsert_sphere_marker",
      arguments: ["position": [0.2, 0.3, 0.4], "shows_direction": true]) != nil, "Direction origin not required")
    try check(VoiceAgentAnnotationPolicy.validationError(name: "upsert_sphere_marker",
      arguments: ["id": "invented", "position": [0.2, 0.3, 0.4]]) != nil, "Invalid annotation UUID accepted")
    try check(VoiceAgentAnnotationPolicy.validationError(name: "upsert_measurement",
      arguments: ["kind": "area", "points": [["position": [0, 0, 0]], ["position": [1, 0, 0]]]]) != nil,
      "Incomplete area accepted")
    let pointID = UUID().uuidString
    try check(VoiceAgentAnnotationPolicy.validationError(name: "upsert_measurement",
      arguments: ["kind": "length", "points": [["id": pointID, "position": [0, 0, 0]],
        ["id": pointID, "position": [1, 0, 0]]]]) != nil, "Duplicate point IDs accepted")
    for name in ["list_objects", "list_measurements", "upsert_sphere_marker", "upsert_stroke_marker", "upsert_measurement",
                 "remove_object", "remove_measurement", "clear_annotations"] {
      try check(VoiceAgentPolicy.allowed.contains(name), "Annotation capability missing")
    }
    for name in ["clear_objects", "clear_measurements", "upsert_mesh_instance"] {
      try check(!VoiceAgentPolicy.allowed.contains(name), "Annotation capability gained destructive/mesh operations")
    }
    try check(VoiceAgentAnnotationPolicy.validationError(name: "clear_annotations", arguments: ["confirm": false]) != nil,
              "Bulk deletion accepted a false confirmation flag")
    try check(VoiceAgentAnnotationPolicy.validationError(name: "remove_object", arguments: ["id": "guessed"]) != nil,
              "Deletion accepted an invalid UUID")
    try check(VoiceAgentPolicy.failure(code: "context_limit", changesApplied: false, completionUncertain: false) == .contextLimit,
              "Context overflow without a mutation was misreported")
    try check(VoiceAgentPolicy.failure(code: "context_limit", changesApplied: true, completionUncertain: false) == .changesAppliedContextLimit,
              "Confirmed changes were not acknowledged after context overflow")
    try check(VoiceAgentPolicy.failure(code: "run_failed", changesApplied: true, completionUncertain: false) == .changesAppliedVerificationFailed,
              "Confirmed changes were confused with uncertain completion")
    try check(VoiceAgentPolicy.failure(code: "context_limit", changesApplied: true, completionUncertain: true) == .completionUncertain,
              "An uncertain final mutation must take precedence over earlier confirmed changes")
    for value in [Double.nan, Double.infinity, -Double.infinity] {
      try check(VoiceAgentSpeechRate.normalized(value) == 1, "Invalid speech rate changed the default")
    }
    try check(VoiceAgentSpeechRate.normalized(3) == 2 && VoiceAgentSpeechRate.normalized(0) == 0.5,
              "Speech rate bounds not enforced")
    let markdown = VoiceAgentMarkdown("# Bones\n\nShow **only** the `head`.\n\n- first\n- second\n  - nested\n\n1. one\n2. two\n\n> quote\n\n```gsc\nrotate 20\nclip true\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
    try check(markdown.blocks.first?.style == .heading(1), "Markdown heading lost")
    try check(markdown.blocks.filter { $0.marker != nil }.map(\.marker) == ["\u{2022}", "\u{2022}", "\u{2022}", "1.", "2."],
              "Markdown list markers lost")
    try check(markdown.blocks.contains { $0.indentation == 2 }, "Nested list indentation lost")
    try check(markdown.blocks.contains { $0.style == .quote }, "Markdown quote lost")
    try check(markdown.blocks.contains { $0.style == .code && String($0.cells[0].characters).contains("\nclip true") },
              "Code block line breaks lost")
    try check(markdown.blocks.contains { $0.style == .tableHeader && $0.cells.count == 2 } &&
              markdown.blocks.contains { $0.style == .tableRow && $0.cells.count == 2 }, "Table cells not grouped")
    try check(markdown.blocks[1].cells[0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true },
              "Inline bold formatting lost")
    try check(markdown.plainText.contains("Show only the head.") && !markdown.plainText.contains("**"),
              "Speech still contains Markdown formatting")
    let links = VoiceAgentMarkdown("[web](https://example.com) [local](file:///tmp/private) [app](borgvr://command) [credentials](https://user:secret@example.com)")
    let urls = links.blocks.flatMap(\.cells).flatMap { $0.runs.compactMap(\.link) }
    try check(urls.count == 1 && urls.first?.absoluteString == "https://example.com", "Unsafe Markdown link enabled")
    try check(VoiceAgentMarkdown("").blocks.isEmpty, "Empty message acquired visible content")
    print("Voice agent policy tests passed: endpoints, credentials, schemas, limits and history")
  }
}
