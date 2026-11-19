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
    try check(endpoint.socket.absoluteString == "wss://ai1:8766/v1/session", "Wrong WSS path")
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
    let rows = (0..<65536).map { [$0 % 256, 0, 0, 255] }
    let preview = VoiceAgentPolicy.compactResult(["channel": 0, "samples": rows], tool: "get_transfer_function")
    try check(preview["originalSampleCount"] as? Int == 65536 && preview["samplesArePreview"] as? Bool == true,
              "TF preview was not explicitly marked")
    let samples = preview["samples"] as! [[Int]]
    try check(samples.count == 256 && samples.first == rows.first && samples.last == rows.last,
              "TF preview size or endpoints changed")
    _ = try VoiceAgentPolicy.encoded(preview, limit: VoiceAgentPolicy.maximumResultBytes)
    try check(rows.count == 65536, "TF preview changed the original table")
    var ledger = VoiceAgentCallLedger()
    try check(try ledger.begin(id: "one", signature: "actual") == nil, "Fresh call lost")
    try check(try ledger.begin(id: "one", signature: "actual")?.reply == nil, "Pending replay duplicated")
    try ledger.finish(id: "one", reply: "committed")
    try check(try ledger.begin(id: "one", signature: "actual")?.reply == "committed", "Cached reply lost")
    try rejects { _ = try ledger.begin(id: "one", signature: "changed") }
    try rejects { _ = try ledger.begin(id: "", signature: "invalid") }
    for index in 0..<3 {
      _ = try ledger.begin(id: "large-\(index)", signature: "screenshot-\(index)")
      try ledger.finish(id: "large-\(index)", reply: String(repeating: "x", count: 3 * 1024 * 1024))
    }
    try rejects { _ = try ledger.begin(id: "large-0", signature: "screenshot-0") }
    try check(try ledger.begin(id: "large-2", signature: "screenshot-2")?.reply != nil, "Recent reply evicted")
    try rejects { _ = try ledger.begin(id: "large-0", signature: "changed") }
    for index in 0..<1024 {
      _ = try ledger.begin(id: "long-\(index)", signature: "state")
      try ledger.finish(id: "long-\(index)", reply: "ok")
    }
    try check(!VoiceAgentPolicy.allowed.contains("open_dataset") && !VoiceAgentPolicy.allowed.contains("edit_volume") &&
              !VoiceAgentPolicy.allowed.contains("load_settings"), "Agent gained unsafe capabilities")
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
    print("Voice agent policy tests passed: endpoints, credentials, schemas, limits and call replay protection")
  }
}
