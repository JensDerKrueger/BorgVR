import CoreGraphics
import Foundation
import ImageIO

private enum Failure: Error { case unexpected(String) }

private func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.unexpected(message) }
}

private final class ModelListFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, request.httpMethod == "GET", url.path == "/v1/models", request.httpBody == nil else {
      client?.urlProtocol(self, didFailWithError: Failure.unexpected("incorrect model list request"))
      return
    }
    let status: Int
    let body: String
    switch (url.host, request.value(forHTTPHeaderField: "Authorization")) {
      case ("api.openai.com", "Bearer draft-key"):
        status = 200
        body = #"{"data":[{"id":"gpt-test-2"},{"id":"ft:gpt-test:custom"},{"id":"gpt-test-2"},{"id":""},{"id":"invalid/id"},{"id":"invalid\n"}]}"#
      case ("api.openai.com", "Bearer empty-key"):
        status = 200
        body = #"{"data":[]}"#
      case ("api.openai.com", "Bearer forbidden-key"):
        status = 403
        body = #"{"error":{"message":"Missing models permission"}}"#
      case ("vllm.example", "Bearer local-key"):
        status = 200
        body = #"{"data":[{"id":"Qwen/local"},{"id":"adapter"}]}"#
      default:
        client?.urlProtocol(self, didFailWithError: Failure.unexpected("incorrect model list origin or token"))
        return
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@MainActor
private final class Workspace: AssistantWorkspace {
  var revision: UInt64 = 0
  let opening = UUID()
  var scans: [(Double, Double)] = []
  var changes: [[[Int]]] = []
  var evidenceVersion: AssistantEvidenceVersion { .init(opening: opening, revision: revision) }
  func waitForUser() async throws { try Task.checkCancellation() }
  func snapshot() throws -> [String: Any] { ["renderMode": "transfer-function"] }
  func operations() -> [[String: Any]] {
    [VoiceAgentPolicy.intensityPreviewTool, ["name": "get_transfer_function",
      "inputSchema": ["type": "object"]], ["name": "set_transfer_function", "inputSchema": ["type": "object"]],
     ["name": "capture_screenshot", "inputSchema": ["type": "object", "properties": [:]]]]
  }

  func execute(_ operation: String, arguments: [String: Any], at version: AssistantEvidenceVersion) async throws -> [String: Any] {
    try Task.checkCancellation()
    try check(version == evidenceVersion, "stale workspace access")
    switch operation {
      case "capture_tf_preview":
        let low = arguments["low"] as! Double, high = arguments["high"] as! Double
        scans.append((low, high))
        let png = try Self.image(visible: low <= 0.61 && high > 0.61)
        return ["content": [["type": "image", "data": png.base64EncodedString()]]]
      case "get_transfer_function": return ["structuredContent": ["originalSampleCount": 257]]
      case "capture_screenshot":
        return ["content": [["type": "image", "data": try Self.image(visible: !changes.isEmpty).base64EncodedString()]]]
      case "set_transfer_function":
        changes.append(arguments["samples"] as! [[Int]])
        return ["structuredContent": ["ok": true]]
      default: throw Failure.unexpected(operation)
    }
  }

  private static func image(visible: Bool) throws -> Data {
    let context = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 48,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if visible {
      context.setFillColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    try check(CGImageDestinationFinalize(destination), "PNG encoding")
    return data as Data
  }
}

@MainActor
private final class Model: AssistantDecisionModel {
  var step = 0
  let next: (Int, AssistantModelInput) throws -> AssistantDecision
  init(_ next: @escaping (Int, AssistantModelInput) throws -> AssistantDecision) { self.next = next }
  func decide(_ input: AssistantModelInput) async throws -> AssistantDecision {
    defer { step += 1 }
    return try next(step, input)
  }
  static func decision(_ kind: AssistantDecision.Kind, _ operation: String? = nil, _ args: [String: Any] = [:],
                       text: String? = nil) throws -> AssistantDecision {
    .init(kind: kind, operation: operation, arguments: try VoiceAgentPolicy.encoded(args), focus: "intensity evidence", text: text)
  }
}

@main
@MainActor
struct AssistantCoreTests {
  static func main() async throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let knowledge = try AssistantKnowledge.load(data)
    let available: Set<String> = ["inspect.intensity_bands", "set_transfer_function_component"]
    try check(knowledge.relevant(to: "Zeige die Knochen", available: available, lastOperation: nil) ==
              knowledge.relevant(to: "Show the bones", available: available, lastOperation: nil), "Multilingual rule selection differs")
    let replaced = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "intensityScan", with: "shell").utf8)
    do { _ = try AssistantKnowledge.load(replaced); throw Failure.unexpected("unknown operation accepted") }
    catch is DecodingError {}

    let app = Workspace()
    var chosen: String?
    let model = Model { step, input in
      switch step {
        case 0:
          try check(input.context.contains("inspect.intensity_bands") && input.context.contains("Coverage or an image difference"),
                    "available workflow or relevant expertise was not sent")
          return try Model.decision(.investigate, "inspect.intensity_bands")
        case 1:
          try check(app.changes.isEmpty && (7...17).contains(app.scans.count), "sweep mutated the TF or did not refine")
          try check(!input.images.isEmpty && input.images.count <= 2, "preview image not attached")
          chosen = input.images[0].id
          return try Model.decision(.apply, "apply_preview", ["id": chosen!])
        case 2:
          try check(app.changes.count == 1 && input.context.contains("Applied the intensity settings"), "selection not confirmed")
          return try Model.decision(.apply, "apply_preview", ["id": chosen!])
        case 3: return try Model.decision(.investigate, "capture_screenshot")
        default:
          try check(input.images.first?.id == "current_render", "final result verification saw the wrong image")
          return try Model.decision(.finish, text: "Selected the observed band.")
      }
    }
    let outcome = try await BorgVRAssistantCore(workspace: app, model: model, knowledge: knowledge, imagesAllowed: true).run("Show the bones")
    try check(outcome.applied == 1 && app.changes.count == 1, "replayed a confirmed change")
    try check(app.changes[0][156][3] == 255 && app.changes[0].first?[3] == 0 && app.changes[0].last?[3] == 0,
              "applied wrong band")

    let fresh = Workspace()
    let stale = Model { step, input in
      if step == 0 { return try Model.decision(.investigate, "inspect.intensity_bands") }
      if step == 1 {
        fresh.revision += 1
        return try Model.decision(.apply, "apply_preview", ["id": input.images[0].id])
      }
      try check(input.images.isEmpty && input.context.contains("user_state_changed"), "stale evidence retained after takeover")
      return try Model.decision(.ask, text: "What should stay visible?")
    }
    let asked = try await BorgVRAssistantCore(workspace: fresh, model: stale, knowledge: knowledge, imagesAllowed: true).run("Show the structure")
    try check(asked.awaitingAnswer && fresh.changes.isEmpty, "stale change applied")

    let stopped = Workspace()
    let cancelling = Model { _, _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return try Model.decision(.apply, "set_transfer_function")
    }
    let task = Task {
      try await BorgVRAssistantCore(workspace: stopped, model: cancelling, knowledge: knowledge, imagesAllowed: false).run("Stop")
    }
    do { _ = try await task.value; throw Failure.unexpected("cancellation returned success") }
    catch is CancellationError {}
    try check(stopped.changes.isEmpty, "a late response mutated the app after cancellation")

    let textOnly = Workspace()
    let noImages = Model { _, input in
      try check(input.images.isEmpty && !input.context.contains("inspect.intensity_bands"), "image workflow exposed without permission")
      return try Model.decision(.finish, text: "Text only")
    }
    _ = try await BorgVRAssistantCore(workspace: textOnly, model: noImages, knowledge: knowledge, imagesAllowed: false).run("Do not share images")
    let request = AssistantModelInput(system: "rules", context: "work", images: [("demo", Data([1, 2, 3]))])
    let vllm = String(decoding: try VoiceAgentModelClient.body(request, model: "local"), as: UTF8.self)
    try check(vllm.contains("response_format") && vllm.contains("image_url") && !vllm.contains("input_image"), "bad vLLM payload")
    let cloud = try JSONSerialization.jsonObject(with: VoiceAgentModelClient.body(request, model: "cloud", provider: .openAI)) as! [String: Any]
    let content = ((cloud["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
    try check(cloud["store"] as? Bool == false && content.last?["type"] as? String == "input_image", "bad OpenAI payload or persistence enabled")
    for (provider, output) in [(VoiceAgentModelProvider.vllm, #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"kind\":\"finish\",\"text\":\"ok\"}"}}]}"#),
                               (.openAI, #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"kind\":\"finish\",\"operation\":null,\"arguments\":null,\"focus\":null,\"text\":\"ok\"}"}]}]}"#)] {
      let decision = try VoiceAgentModelClient.decision(from: Data(output.utf8), provider: provider)
      try check(decision.kind == .finish && decision.text == "ok", "provider output did not decode to the shared decision")
    }
    try await testModelList()
    print("Swift assistant: sweep, exact application, stale evidence, cancellation, permissions, rules, and both provider contracts passed.")
  }

  private static func testModelList() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ModelListFixture.self]
    let cloud = try VoiceAgentEndpoint("https://api.openai.com")
    func client(_ token: String, selected: String = "") -> VoiceAgentModelClient {
      .init(endpoint: cloud, token: token, session: URLSession(configuration: config),
            provider: .openAI, configuredModel: selected)
    }

    let draft = client("draft-key", selected: "gpt-manual")
    let choices = try await draft.listOpenAIModels()
    try check(choices == ["ft:gpt-test:custom", "gpt-test-2"], "invalid/duplicate OpenAI IDs or wrong list order")
    try check(draft.model == "gpt-manual", "fetch replaced the model selection")
    let empty = try await client("empty-key").listOpenAIModels()
    try check(empty.isEmpty, "failed to handle an empty list without a selected model")
    do {
      _ = try await client("forbidden-key").listOpenAIModels()
      throw Failure.unexpected("a refused list request succeeded")
    } catch VoiceAgentError.connection {}

    let local = VoiceAgentModelClient(endpoint: try VoiceAgentEndpoint("https://vllm.example"), token: "local-key",
                                      session: URLSession(configuration: config))
    let model = try await local.discover()
    try check(model == "Qwen/local", "vLLM discovery did not keep the first served ID")
  }
}
