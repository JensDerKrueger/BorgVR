import CoreGraphics
import Foundation
import ImageIO

private enum Failure: Error { case unexpected(String) }

private func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.unexpected(message) }
}

private final class ModelAPIFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let status: Int
    let body: String
    let token = request.value(forHTTPHeaderField: "Authorization")
    switch (url.host, request.httpMethod, url.path, token) {
      case ("api.openai.com", "GET", "/v1/models", "Bearer draft-key"):
        status = 200
        body = """
        {"data":[{"id":"gpt-6.2-sol"},{"id":"gpt-5.4-mini-2026-03-17"},{"id":"gpt-6.2-sol"},
                 {"id":"gpt-image-2.6-flare"},{"id":"text-embedding-3-small"},{"id":"gpt-realtime-2"},
                 {"id":"gpt-4-turbo"},{"id":"gpt-5.4-pro"},{"id":"gpt-6.2-sol-preview"},
                 {"id":"gpt-5.4-mini-2099-01-01"},{"id":"ft:gpt-5.4-mini:custom"}]}
        """
      case ("api.openai.com", "GET", "/v1/models", "Bearer incompatible-key"):
        status = 200
        body = #"{"data":[{"id":"gpt-4-turbo"},{"id":"whisper-1"}]}"#
      case ("api.openai.com", "GET", "/v1/models", "Bearer forbidden-key"):
        status = 403
        body = #"{"error":{"message":"Missing models permission"}}"#
      case ("vllm.example", "GET", "/v1/models", "Bearer local-key"):
        status = 200
        body = #"{"data":[{"id":"Qwen/local"},{"id":"adapter"}]}"#
      case ("vllm.example", "POST", "/v1/chat/completions", "Bearer local-key"),
           ("api.openai.com", "POST", "/v1/responses", "Bearer phase-key"):
        let payload = requestBody().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let cloud = url.host == "api.openai.com"
        let format = (payload?["text"] as? [String: Any])?["format"] as? [String: Any]
        let grammar = (payload?["structured_outputs"] as? [String: String])?["grammar"]
        let intake = format?["name"] as? String == "borgvr_intake" || grammar?.contains("item ::=") == true
        let stateUpdate = format?["name"] as? String == "borgvr_state_update" || grammar?.contains(#"\"notes\""#) == true
        guard intake || stateUpdate else {
          client?.urlProtocol(self, didFailWithError: Failure.unexpected("Missing auxiliary schema"))
          return
        }
        let result = intake ? #"{"items":[{"kind":"information","text":"Das ist unten."}]}"# : #"{"notes":["A model note."]}"#
        let response: [String: Any] = cloud
          ? ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": result]]]]]
          : ["choices": [["finish_reason": "stop", "message": ["content": result]]]]
        status = 200
        body = (try? VoiceAgentPolicy.encoded(response)) ?? ""
      case ("api.openai.com", "GET", "/v1/models/gpt-manual", "Bearer vision-key"),
           ("api.openai.com", "GET", "/v1/models/gpt-manual", "Bearer wrong-color"):
        status = 200
        body = #"{"id":"gpt-manual"}"#
      case ("api.openai.com", "POST", "/v1/responses", "Bearer vision-key"),
           ("api.openai.com", "POST", "/v1/responses", "Bearer wrong-color"):
        guard testImageAndSchemaPresent else {
          client?.urlProtocol(self, didFailWithError: Failure.unexpected("OpenAI compatibility test must use a valid PNG and a strict schema"))
          return
        }
        status = 200
        let color = token == "Bearer vision-key" ? "Red" : "Blue"
        body = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"kind\":\"finish\",\"text\":\"\#(color)\"}"}]}]}"#
      default:
        client?.urlProtocol(self, didFailWithError: Failure.unexpected("incorrect model API request"))
        return
    }
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private var testImageAndSchemaPresent: Bool {
    guard let data = requestBody(),
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          payload["model"] as? String == "gpt-manual",
          payload["store"] as? Bool == false,
          let text = payload["text"] as? [String: Any],
          let format = text["format"] as? [String: Any],
          format["type"] as? String == "json_schema", format["strict"] as? Bool == true,
          let input = payload["input"] as? [[String: Any]], input.count == 1,
          let content = input.first?["content"] as? [[String: Any]],
          let imageURL = content.last?["image_url"] as? String,
          content.last?["type"] as? String == "input_image", imageURL.hasPrefix("data:image/png;base64,"),
          let png = Data(base64Encoded: String(imageURL.dropFirst("data:image/png;base64,".count))),
          let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
    return image.width == 32 && image.height == 32
  }

  private func requestBody() -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { return nil }
      if count == 0 { return result }
      result.append(contentsOf: buffer.prefix(count))
    }
  }
}

@MainActor
private final class Workspace: AssistantWorkspace {
  var revision: UInt64 = 0
  let opening = UUID()
  var rendererReady = true
  var manualRotation = 0.0
  var manualDomains: [String: UInt64] = [:]
  static let sweepTransitionWidth = 0.06
  static let originalTF = (0...256).map { index in [index % 256, 120, 230, (index * 7) % 256] }
  var transferFunction = originalTF
  var scans: [[[Int]]] = []
  var cancelSweep = false
  var failSweep = false
  private var renderedTF: [[Int]]?
  var sparsePreviewSize: Int?
  var sweepImage: ((Int) throws -> Data)?
  var changes: [[[Int]]] = []
  var componentChanges: [[String: Any]] = []
  var rotations: [[String: Any]] = []
  var screenshots: [[String: Any]] = []
  var screenshotTFs: [[[Int]]] = []
  var datasetDescription: String?
  var boundingBoxes: [Bool] = []
  var supportsLitRenderMode = false
  var initialRenderMode = "transfer_function"
  var renderModes: [String] = []
  var screenshotModes: [String] = []
  var onScreenshot: ((Int) throws -> Void)?
  var measurementReads = 0
  var failNextMeasurementRead = false
  var reverseCatalog = false
  var clips = 0
  var acceptsRotation = true
  var sweepRotation = SIMD4<Float>(0, 0, 0, 1)
  var sweepTranslation = SIMD3<Float>.zero
  var sweepRenderSignature: Data?
  var evidenceVersion: AssistantEvidenceVersion { .init(opening: opening, revision: revision) }
  func manualChangeDomains(since revision: UInt64) -> [String] {
    manualDomains.compactMap { $0.value > revision ? $0.key : nil }.sorted()
  }
  func waitForUser() async throws { try Task.checkCancellation() }
  func snapshot() throws -> [String: Any] {
    var state: [String: Any] = ["renderMode": renderModes.last ?? initialRenderMode, "rendererReady": rendererReady]
    state["renderingOptions"] = ["datasetBoundingBoxVisible": boundingBoxes.last ?? false]
    let halfAngle = rotations.compactMap { ($0["degrees"] as? NSNumber)?.doubleValue }.reduce(manualRotation, +) * .pi / 360
    state["transform"] = ["rotation": [0, sin(halfAngle), 0, cos(halfAngle)], "translation": [0, 0, 0], "scale": [1, 1, 1]]
    if let datasetDescription { state["dataset"] = ["description": datasetDescription, "dimensions": [512, 512, 512]] }
    return state
  }
  func sweepView() -> AssistantSweepView? {
    sweepRenderSignature.map { .init(opening: opening, rotation: sweepRotation, translation: sweepTranslation, renderSignature: $0) }
  }
  func operations() -> [[String: Any]] {
    var catalog: [[String: Any]] = [["name": "get_transfer_function",
      "inputSchema": ["type": "object", "properties": ["channel": ["type": "integer"]]]],
     ["name": "set_transfer_function", "inputSchema": ["type": "object", "required": ["samples"], "properties": [
       "channel": ["type": "integer", "minimum": 0, "maximum": 3],
       "samples": ["type": "array", "minItems": 1, "maxItems": 65536, "items": ["type": "array", "minItems": 4,
         "maxItems": 4, "items": ["type": "integer", "minimum": 0, "maximum": 255]]]]]],
     ["name": "wait_until_rendered", "inputSchema": ["type": "object"]],
     ["name": "capture_screenshot", "inputSchema": ["type": "object", "properties": [
       "max_width": ["type": "integer"], "include_alpha": ["type": "boolean", "default": true]]]],
     ["name": "set_transfer_function_component", "inputSchema": ["type": "object", "required": ["channel", "component", "points"],
       "properties": ["channel": ["type": "integer"], "component": ["type": "integer"],
                      "points": ["type": "array", "items": ["type": "array", "items": ["type": "number"]]]]]],
     ["name": "set_clipping", "inputSchema": ["type": "object", "properties": [:]]],
     ["name": "list_measurements", "description": "List the measurements in the current dataset.",
      "inputSchema": ["type": "object", "additionalProperties": false, "properties": [:]]],
     ["name": "set_bounding_box", "description": "Show or hide the bounding box around the current volume.",
      "inputSchema": ["type": "object", "additionalProperties": false, "required": ["visible"],
                      "properties": ["visible": ["type": "boolean"]]]],
     ["name": "rotate_view", "inputSchema": ["type": "object", "additionalProperties": false, "required": ["axis", "degrees"],
       "properties": ["axis": ["type": "array", "minItems": 3, "maxItems": 3, "items": ["type": "number"]],
                      "degrees": ["type": "number"]]]]]
    if supportsLitRenderMode {
      catalog.append(["name": "set_render_mode", "inputSchema": ["type": "object", "required": ["mode"],
        "properties": ["mode": ["type": "string", "enum": ["transfer_function", "transfer_function_lighting"]]]]])
    }
    return reverseCatalog ? Array(catalog.reversed()) : catalog
  }

  func execute(_ operation: String, arguments: [String: Any], at version: AssistantEvidenceVersion) async throws -> [String: Any] {
    try Task.checkCancellation()
    try check(version == evidenceVersion, "stale workspace access")
    switch operation {
      case "get_transfer_function": return ["structuredContent": ["channel": arguments["channel"] as? Int ?? 0, "samples": transferFunction]]
      case "wait_until_rendered":
        renderedTF = transferFunction
        return ["structuredContent": ["ok": true]]
      case "capture_screenshot":
        let png: Data
        if let renderedTF {
          try check(renderedTF == transferFunction && transferFunction != Self.originalTF,
                    "The sweep captured a frame without its live transfer function")
          self.renderedTF = nil
          scans.append(renderedTF)
          if cancelSweep { withUnsafeCurrentTask { $0?.cancel() } }
          if failSweep { throw VoiceAgentError.commandFailed }
          let midpoint = renderedTF.firstIndex { $0[3] >= 128 } ?? renderedTF.count
          let low = Double(midpoint) / Double(renderedTF.count - 1) - Self.sweepTransitionWidth / 2
          if let sweepImage {
            png = try sweepImage(scans.count - 1)
          } else if let size = sparsePreviewSize {
            png = try Self.image(visible: low < 0.73, canvas: 64, extent: size)
          } else {
            png = try Self.image(visible: low < 0.73, gray: low < 0.23 ? 0.35 : 0.75)
          }
        } else {
          screenshots.append(arguments)
          screenshotTFs.append(transferFunction)
          let mode = renderModes.last ?? initialRenderMode
          screenshotModes.append(mode)
          try onScreenshot?(screenshots.count)
          png = try Self.image(visible: transferFunction != Self.originalTF || !componentChanges.isEmpty || supportsLitRenderMode,
                               gray: mode == "transfer_function_lighting" ? 0.55 : 1)
        }
        return ["content": [["type": "image", "data": png.base64EncodedString()]]]
      case "set_transfer_function":
        transferFunction = arguments["samples"] as! [[Int]]
        changes.append(transferFunction)
        return ["structuredContent": ["ok": true]]
      case "set_transfer_function_component":
        componentChanges.append(arguments)
        return ["structuredContent": ["ok": true]]
      case "set_clipping":
        clips += 1
        return ["structuredContent": ["ok": true]]
      case "set_bounding_box":
        boundingBoxes.append(arguments["visible"] as! Bool)
        return ["structuredContent": ["ok": true]]
      case "set_render_mode":
        renderModes.append(arguments["mode"] as! String)
        return ["structuredContent": ["ok": true]]
      case "list_measurements":
        measurementReads += 1
        if failNextMeasurementRead {
          failNextMeasurementRead = false
          throw VoiceAgentError.timedOut
        }
        return ["structuredContent": ["measurements": []]]
      case "rotate_view":
        guard acceptsRotation else { return ["structuredContent": ["ok": true, "not_applied": true]] }
        rotations.append(arguments)
        return ["structuredContent": ["rendererReady": true]]
      default: throw Failure.unexpected(operation)
    }
  }

  static func image(visible: Bool, gray: CGFloat = 0.75, canvas: Int = 12, extent: Int = 12,
                    stripes: [CGFloat]? = nil) throws -> Data {
    let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 4 * canvas,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let stripes {
      let width = CGFloat(canvas) / CGFloat(stripes.count)
      for (index, value) in stripes.enumerated() {
        context.setFillColor(red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: CGFloat(index) * width, y: 0, width: width, height: CGFloat(canvas)))
      }
    } else if visible {
      context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: extent, height: extent))
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
  var parsedMessages: [String] = []
  var stateInputs: [AssistantStateInput] = []
  var reviewed = 0
  var reviewedObservations: [[AssistantReplyObservation]] = []
  var reviewedVisualEvidence: [Bool] = []
  let next: (Int, AssistantModelInput) throws -> AssistantDecision
  let review: (String, AssistantDecision.Kind, String) throws -> AssistantReplyVerdict
  let intake: (String) throws -> [AssistantIntake.Item]
  let update: (Int, AssistantStateInput) throws -> [String]
  let fillsGoalCheck: Bool
  init(intake: @escaping (String) throws -> [AssistantIntake.Item] = { [.init(kind: .task, text: $0)] },
       update: @escaping (Int, AssistantStateInput) throws -> [String] = { _, input in input.notes },
       review: @escaping (String, AssistantDecision.Kind, String) throws -> AssistantReplyVerdict = { _, _, _ in .accept },
       fillsGoalCheck: Bool = true,
       _ next: @escaping (Int, AssistantModelInput) throws -> AssistantDecision) {
    self.intake = intake
    self.update = update
    self.review = review
    self.fillsGoalCheck = fillsGoalCheck
    self.next = next
  }
  func parseInput(_ message: String) async throws -> AssistantIntake {
    parsedMessages.append(message)
    return try .init(items: intake(message))
  }
  func updateState(_ input: AssistantStateInput) async throws -> [String] {
    stateInputs.append(input)
    return try update(stateInputs.count - 1, input)
  }
  func decide(_ input: AssistantModelInput) async throws -> AssistantDecision {
    defer { step += 1 }
    var decision = try next(step, input)
    if fillsGoalCheck, input.requiresGoalCheck, decision.goalCheck == nil {
      decision.goalCheck = .init(status: .notApplicable, finding: "This fixture does not assess the render.")
    }
    return decision
  }
  func reviewUnconfirmedReply(request: String, kind: AssistantDecision.Kind, draft: String,
                              observations: [AssistantReplyObservation], visualEvidenceShown: Bool) async throws -> AssistantReplyVerdict {
    reviewed += 1
    reviewedObservations.append(observations)
    reviewedVisualEvidence.append(visualEvidenceShown)
    return try review(request, kind, draft)
  }
  static func decision(_ kind: AssistantDecision.Kind, _ operation: String? = nil, _ args: [String: Any] = [:],
                       text: String? = nil, route: AssistantDecision.Route? = nil,
                       status: AssistantDecision.SubgoalStatus? = nil, assessment: AssistantDecision.Assessment? = nil,
                       goalCheck: AssistantDecision.GoalCheck? = nil,
                       orientationCheck: AssistantDecision.OrientationCheck? = nil) throws -> AssistantDecision {
    .init(kind: kind, operation: operation, arguments: try VoiceAgentPolicy.encoded(args),
          focus: "intensity evidence", text: text, route: route, subgoalStatus: status, assessment: assessment,
          goalCheck: goalCheck, orientationCheck: orientationCheck)
  }
}

@main
@MainActor
struct AssistantCoreTests {
  static func main() async throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let knowledge = try AssistantKnowledge.load(data)
    try await testVisibilityGraph(knowledge, data: data)
    try await testPoseBoxGuidance(knowledge)
    try await testOrientationWorkflow(knowledge)
    try await testOrientationWorkflowInterruption(knowledge)
    try await testLanguageIndependentGuidance(knowledge, data: data)
    try await testGuidanceBeforeDirectChange(knowledge)
    try await testSparseThresholdTransitions(knowledge)
    try await testSettledThresholdCandidates(knowledge)
    let available: Set<String> = ["inspect.intensity_bands", "set_transfer_function_component"]
    let sweepRules = knowledge.guidancePlan(for: "inspect.intensity_bands")
    let opacityRules = knowledge.guidance(sweepRules.after, for: available).map(\.text)
    try check(opacityRules.contains { $0.contains("threshold to opaque_from") && $0.contains("skip it when the interval is already known") } &&
              opacityRules.contains { $0.contains("component 3") && $0.contains("anchor it outside that band") },
              "the opacity guidance did not connect evidence to a targeted edit")
    let changeRules = knowledge.guidancePlan(for: "set_transfer_function")
    let rgbaRules = knowledge.guidance(changeRules.before, for: ["set_transfer_function"]).map(\.text)
    try check(rgbaRules.contains { $0.contains("prefer adjusting RGB and alpha together") &&
                                  $0.contains("Respect explicit requests to change only certain components") },
              "the RGBA default or its explicit override was missing with only the full TF tool available")
    let viewTools = available.union(["rotate_view", "set_transform", "set_clipping", "set_render_mode", "set_lighting",
                                     "edit_volume", "capture_screenshot"])
    let viewRules = knowledge.guidance(knowledge.initialRuleIDs, for: viewTools).map(\.text)
    try check(viewRules.contains { $0.contains("before choosing a method") &&
                                  $0.contains("translate or rotate") && $0.contains("reversible clipping") &&
                                  $0.contains("adjust the transfer function") && $0.contains("render modes or lighting") &&
                                  $0.contains("Edit voxels only when the user requests a change to the volume data") },
              "the visibility goal did not prioritize choosing between the available methods")
    try check(opacityRules.contains { $0.hasPrefix("If the transfer function is the chosen way") &&
                                  $0.contains("material can disappear or reveal material behind it") &&
                                  $0.contains("If target and occluder overlap in intensity") },
              "visibility guidance did not account for occlusion and overlapping intensities")
    let rulesWithoutSweep = knowledge.guidance(changeRules.before, for: ["set_transfer_function_component"]).map(\.text)
    try check(rulesWithoutSweep.contains { $0.contains("component 3") } &&
              !rulesWithoutSweep.contains { $0.contains("inspect.intensity_bands") },
              "a workflow was recommended when unavailable, or its absence suppressed unrelated guidance")
    let replaced = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "intensityScan", with: "shell").utf8)
    do { _ = try AssistantKnowledge.load(replaced); throw Failure.unexpected("unknown operation accepted") }
    catch is DecodingError {}

    let app = Workspace()
    var chosen: String?
    var alternative: String?
    var chosenOpacity: VoiceAgentPreviewOpacity?
    let model = Model { step, input in
      switch step {
        case 0:
          try check(input.catalog.contains { $0["name"] as? String == "inspect.intensity_bands" } &&
                    !input.system.contains("An image difference is not a structure label") && !input.context.contains("expert_guidance") &&
                    !input.context.contains("use apply_preview with its id only"),
                    "the available workflow was missing or its guidance was sent before it was selected")
          try check(input.system.contains("Internal tool results are not a user interface"), "Missing general collaboration instruction")
          return try Model.decision(.investigate, "inspect.intensity_bands")
        case 1:
          let expectedCurves = (0...100).map { step in
            let threshold = Double(step) / 100
            let curve = VoiceAgentPreviewOpacity(.smoothstep, low: threshold, high: threshold + Workspace.sweepTransitionWidth)!
            return (0...256).map { index in
              let value = Int((255 * curve.alpha(at: Float(index) / 256)).rounded())
              return [value, value, value, value]
            }
          }
          try check(app.scans == expectedCurves &&
                    app.changes == app.scans + [Workspace.originalTF] && app.transferFunction == Workspace.originalTF,
                    "Sweep did not advance in one-percent steps with linked RGBA or restore the exact original")
          try check(!input.images.isEmpty && input.images.count <= 2, "preview image not attached")
          let context = try VoiceAgentPolicy.decode(input.context)
          let guidance = context["expert_guidance"] as? [[String: String]] ?? []
          let notes = context["decision_notes"] as? [String] ?? []
          try check(Set(guidance.compactMap { $0["id"] }) == ["intensity.unknown", "intensity.component"] &&
                    guidance.contains { $0["text"]?.contains("not internal preview IDs") == true } &&
                    !input.system.contains("Compare the rendered candidates after the transitions"),
                    "sweep evidence did not carry the observation and adjustment rules without unrelated rules")
          try check(notes.contains { $0.contains("use apply_preview with its id only") &&
                     $0.contains("Do not generate samples or component points") && $0.contains("partial edit") },
                    "A matching preview was not the default once an image was shown")
          let events = context["events"] as? [[String: Any]] ?? []
          let report = events.last?["result"] as? [String: Any]
          let transitions = report?["transitions"] as? [[String: Any]] ?? []
          try check(report?["mode"] as? String == "smoothstep" && transitions.count == 2,
                    "the sweep missed a color-only transition or kept unchanged frames")
          guard let first = transitions.first, let below = first["below"] as? Double, let above = first["above"] as? Double,
                let candidate = first["candidate_threshold"] as? Double else {
            throw Failure.unexpected("missing transition bounds")
          }
          try check(below < 0.23 && above >= 0.23 && abs(above - below - 0.01) < 1e-9 &&
                    abs(candidate - above - 0.04) < 1e-9 &&
                    input.images.map(\.id) == transitions.compactMap { $0["candidate_id"] as? String },
                    "Only one settled frame should amass per significant transition, four steps after it ends")
          chosen = input.images[0].id
          alternative = input.images[1].id
          chosenOpacity = VoiceAgentPreviewOpacity(.smoothstep, low: candidate, high: candidate + Workspace.sweepTransitionWidth)
          return try Model.decision(.apply, "apply_preview", ["id": chosen!])
        case 2:
          try check(app.changes.count == app.scans.count + 2 && input.context.contains("Applied the intensity settings"), "selection not confirmed")
          let context = try VoiceAgentPolicy.decode(input.context)
          let event = (context["events"] as? [[String: Any]])?.last { $0["status"] as? String == "confirmed_change" }
          let guidance = context["expert_guidance"] as? [[String: String]] ?? []
          try check(event?["status"] as? String == "confirmed_change" && event?["arguments_omitted"] as? Bool == true &&
                    Set(guidance.compactMap { $0["id"] }) == ["intensity.component", "render.verify"] &&
                    event?["arguments"] == nil && input.images.map(\.id) == ["current_render"],
                    "the receipt contained a large TF table or the fresh live image was missing")
          return try Model.decision(.apply, "apply_preview", ["id": alternative!])
        default:
          try check(!input.finalReplyOnly && input.images.map(\.id) == ["current_render"] &&
                    app.changes.count == app.scans.count + 3, "An already inspected alternative could not be tried")
          return try Model.decision(.finish, text: "Selected the observed threshold.")
      }
    }
    let outcome = try await BorgVRAssistantCore(workspace: app, model: model, knowledge: knowledge, imagesAllowed: true).run("Show the bones")
    try check(outcome.applied == 2 && app.changes.count == app.scans.count + 3, "An alternative preview could not be applied")
    guard let chosenOpacity else { throw Failure.unexpected("No preview was selected") }
    let chosenStep = Int((chosenOpacity.low * 100).rounded())
    try check(app.changes[app.scans.count + 1] == app.scans[chosenStep], "The applied RGBA curve differed from the observed Smoothstep")

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
    try check(asked.awaitingAnswer && fresh.changes == fresh.scans + [Workspace.originalTF], "stale change applied")

    let interrupted = Workspace()
    interrupted.cancelSweep = true
    interrupted.sweepRenderSignature = Data([0])
    let interruptedCache = AssistantSweepCache()
    let sweepTask = Task {
      try await BorgVRAssistantCore(workspace: interrupted, model: Model { _, _ in
        try Model.decision(.investigate, "inspect.intensity_bands")
      }, knowledge: knowledge, imagesAllowed: true, sweepCache: interruptedCache).run("Stop during the sweep")
    }
    do { _ = try await sweepTask.value; throw Failure.unexpected("cancelled sweep returned success") }
    catch is CancellationError {}
    try check(interrupted.scans.count == 1 && interrupted.changes == interrupted.scans &&
              interrupted.transferFunction == interrupted.scans.first && interruptedCache.last == nil,
              "Stop did not leave the visible curve in place or cached an incomplete sweep")

    let failedSweep = Workspace()
    failedSweep.failSweep = true
    _ = try await BorgVRAssistantCore(workspace: failedSweep, model: Model { step, _ in
      if step == 0 { return try Model.decision(.investigate, "inspect.intensity_bands") }
      return try Model.decision(.finish, text: "Sweep unavailable.")
    }, knowledge: knowledge, imagesAllowed: true).run("Inspect the intensity bands")
    try check(failedSweep.scans.count == 1 && failedSweep.changes == failedSweep.scans + [Workspace.originalTF],
              "An ordinary screenshot error did not restore the TF")

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
      try check(input.images.isEmpty && !input.catalog.contains { $0["name"] as? String == "inspect.intensity_bands" } &&
                !input.system.contains("An image difference is not a structure label"), "image workflow exposed without permission")
      return try Model.decision(.finish, text: "Text only")
    }
    _ = try await BorgVRAssistantCore(workspace: textOnly, model: noImages, knowledge: knowledge, imagesAllowed: false).run("Do not share images")
    let request = AssistantModelInput(system: "rules", context: "work", images: [("demo", Data([1, 2, 3]))],
                                      catalog: [["name": "rotate_view"], ["name": "list_measurements"]])
    let vllm = String(decoding: try VoiceAgentModelClient.body(request, model: "local"), as: UTF8.self)
    try check(vllm.contains("structured_outputs") && vllm.contains("image_url") && !vllm.contains("input_image"), "bad vLLM payload")
    let local = try JSONSerialization.jsonObject(with: Data(vllm.utf8)) as! [String: Any]
    try check(local["max_tokens"] == nil && local["max_completion_tokens"] == nil,
              "normal vLLM decisions must leave the output token budget to the server")
    let localFormat = local["structured_outputs"] as? [String: String]
    let grammar = try AssistantDecision.vllmGrammar(operations: ["list_measurements", "rotate_view"])
    try check(localFormat == ["grammar": grammar] &&
              grammar.contains(#"ws ::= " "?"#) && grammar.contains(#""\"arguments\"" colon object"#) &&
              grammar.contains(#"terminal ::= "{" ws "\"kind\"" colon"#) &&
              grammar.contains(#"action ::= "{" ws "\"kind\"" colon"#) &&
              grammar.contains(#"operation ::= "\"list_measurements\"" | "\"rotate_view\"""#) &&
              (local["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false,
              "vLLM must distinguish replies from actions and constrain tool names")
    let reviewInput = AssistantModelInput(system: "review", context: "draft", images: [])
    let review = try JSONSerialization.jsonObject(with: VoiceAgentModelClient.body(reviewInput, model: "local",
                                                                                   reviewingReply: true)) as! [String: Any]
    let reviewFormat = review["structured_outputs"] as? [String: String]
    let reviewGrammar = reviewFormat?["grammar"] ?? ""
    try check(reviewFormat?["json"] == nil && reviewGrammar.contains("verdict") &&
              reviewGrammar.contains("action_in_text") && reviewGrammar.contains("unsupported_content_claim") &&
              reviewGrammar.contains(#"ws ::= " "?"#) && review["max_tokens"] as? Int == 128,
              "reply reviews must use a separate bounded grammar and budget")
    let cloud = try JSONSerialization.jsonObject(with: VoiceAgentModelClient.body(request, model: "cloud", provider: .openAI)) as! [String: Any]
    try check(cloud["max_output_tokens"] as? Int == 4096, "the vLLM experiment changed the OpenAI budget")
    let format = (cloud["text"] as? [String: Any])?["format"] as? [String: Any]
    let schema = format?["schema"] as? [String: Any]
    let operations = (schema?["properties"] as? [String: [String: Any]])?["operation"]?["enum"] as? [Any] ?? []
    try check(operations.compactMap { $0 as? String } == ["list_measurements", "rotate_view"] && operations.last is NSNull,
              "OpenAI must allow only supported tools or a reply without one")
    let content = ((cloud["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
    try check(cloud["store"] as? Bool == false && content.last?["type"] as? String == "input_image", "bad OpenAI payload or persistence enabled")
    for (provider, output) in [(VoiceAgentModelProvider.vllm, #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"kind\":\"finish\",\"text\":\"ok\"}"}}]}"#),
                               (.openAI, #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"kind\":\"finish\",\"operation\":null,\"arguments\":null,\"focus\":null,\"text\":\"ok\"}"}]}]}"#)] {
      let decision = try VoiceAgentModelClient.decision(from: Data(output.utf8), provider: provider)
      try check(decision.kind == .finish && decision.text == "ok", "provider output did not decode to the shared decision")
    }
    try await testConfirmedChanges(knowledge)
    try await testTrialFindings(knowledge)
    try await testGoalVerification(knowledge)
    try await testControlImageCompletion(knowledge)
    try await testTaskPlan(knowledge)
    try await testSeparateStateUpdates(knowledge)
    try await testStateUpdateRepair(knowledge)
    try await testAuxiliaryRequestScopes()
    try await testCachedSweepFollowup(knowledge)
    try await testUnconfirmedReply(knowledge)
    try await testReadEvidenceHandoff(knowledge)
    try await testTransferReadHandoff(knowledge)
    try await testReplyRepairAfterObservation(knowledge)
    try await testReplyReviewKnowsAvailableObservations(knowledge)
    try await testUnsupportedClaimAndActionAnnouncement(knowledge)
    try await testStepText(knowledge)
    try await testNoProgress(knowledge)
    try await testDecisionFailures(knowledge)
    try await testTransferFunctionArgumentRepair(knowledge)
    try await testModelList()
    print("Swift assistant: sweep, exact application, stale evidence, cancellation, permissions, rules, and both provider contracts passed.")
  }

  private static func testLanguageIndependentGuidance(_ knowledge: AssistantKnowledge, data: Data) async throws {
    let bundled = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let rules = bundled["rules"] as! [[String: Any]]
    try check(rules.allSatisfy { $0["topics"] == nil }, "The bundled guidance still has keyword lists")
    var legacy = bundled
    legacy["rules"] = rules.map { rule in
      var copy = rule
      copy["topics"] = ["knochen", "fixture_keyword"]
      return copy
    }
    let imported = try AssistantKnowledge.load(JSONSerialization.data(withJSONObject: legacy))
    var prefix: String?
    for (index, request) in ["Zeig mir die Knochen", "Fais ressortir la couche externe", "Can we see what's beneath that?"].enumerated() {
      let workspace = Workspace()
      let model = Model { _, input in
        let context = try VoiceAgentPolicy.decode(input.context)
        try check(context["request"] as? String == request && context["expert_guidance"] == nil &&
                  input.system.contains("For a visibility goal in a loaded volume") &&
                  !input.system.contains("An image difference is not a structure label") &&
                  !input.system.contains("prefer adjusting RGB and alpha together") &&
                  !input.system.contains("Red increases along local +X"),
                  "A request preloaded leaf rules or missed general guidance")
        if let prefix { try check(input.system == prefix, "Language or legacy topics changed the guidance prefix") }
        prefix = input.system
        return try Model.decision(.finish, text: "Done.")
      }
      _ = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: index == 0 ? knowledge : imported,
                                       imagesAllowed: true).run(request)
    }
    var oversized = bundled
    oversized["rules"] = (0..<8).map { ["id": "fixture.rule\($0)", "operations": [String](),
                                       "text": String(repeating: "a", count: 1600)] as [String: Any] }
    do {
      _ = try AssistantKnowledge.load(JSONSerialization.data(withJSONObject: oversized))
      throw Failure.unexpected("An oversized guidance prefix was accepted")
    } catch VoiceAgentError.protocolViolation {}

    var distributed = legacy
    distributed.removeValue(forKey: "decisionGraph")
    let operations = ["rotate_view", "set_clipping", "edit_volume", "set_render_mode", "set_lighting",
                      "set_transfer_function", "set_transform", "set_bounding_box"]
    distributed["rules"] = (0..<operations.count).map { ["id": "fixture.rule\($0)", "operations": [operations[$0]],
                               "topics": ["irrelevant"], "text": String(repeating: "a", count: 1600)] as [String: Any] }
    let large = try AssistantKnowledge.load(JSONSerialization.data(withJSONObject: distributed))
    try check(large.initialRuleIDs.isEmpty && large.guidancePlan(for: "rotate_view").before == ["fixture.rule0"],
              "A larger legacy pack must select unlinked rules by operation, without keywords")

    var dangling = bundled
    var graph = dangling["decisionGraph"] as! [String: Any]
    var nodes = graph["nodes"] as! [[String: Any]]
    let index = nodes.firstIndex { $0["id"] as? String == "tf.adjust" }!
    nodes[index]["ruleIDs"] = ["missing.rule"]
    graph["nodes"] = nodes
    dangling["decisionGraph"] = graph
    do {
      _ = try AssistantKnowledge.load(JSONSerialization.data(withJSONObject: dangling))
      throw Failure.unexpected("An unknown rule reference was accepted")
    } catch VoiceAgentError.protocolViolation {}
  }

  private static func testGuidanceBeforeDirectChange(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    let operation = "set_transfer_function_component"
    let args: [String: Any] = ["channel": 0, "component": 3, "points": [[0, 0], [0.4, 1], [1, 1]]]
    var announced: [String] = []
    var prefix: String?
    let model = Model { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      let guidance = (context["expert_guidance"] as? [[String: String]] ?? []).compactMap { $0["id"] }
      try check(guidance.allSatisfy { $0 == "intensity.component" }, "Direct change got rules from an unrelated leaf")
      switch step {
        case 0:
          try check(guidance.isEmpty, "Leaf guidance was included before the initial decision")
          prefix = input.system
          return try Model.decision(.apply, operation, args, text: "First proposal.",
                                    route: .init(method: "visibility.transform", directive: nil))
        case 1:
          try check(input.system == prefix && guidance == ["intensity.component"] && workspace.componentChanges.isEmpty &&
                    announced.isEmpty && input.context.contains("proposed change has not run"),
                    "The off-path tool did not receive its rule before execution, or its proposal was reported as work")
          return try Model.decision(.apply, operation, args, text: "Updating alpha.")
        default:
          try check(workspace.componentChanges.count == 1, "The reviewed proposal did not execute exactly once")
          return try Model.decision(.finish, text: "Updated alpha.")
      }
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                               imagesAllowed: false).run("Ramp opacity upwards from forty percent.", progress: { _, text in
      if let text { announced.append(text) }
    })
    try check(result.applied == 1 && model.step == 3 && announced == ["Updating alpha."],
              "A direct change required more than one decision with loaded guidance")
  }

  private static func testVisibilityGraph(_ knowledge: AssistantKnowledge, data: Data) async throws {
    guard let root = knowledge.decisionGraph?.root else { throw Failure.unexpected("missing visibility graph") }
    let rootPath = [root]
    let tfPath = rootPath + ["visibility", "visibility.tf"]
    let target = ["axis": [0, 1, 0], "degrees": 15] as [String: Any]

    func checkRoot(_ context: [String: Any]) throws {
      let graph = context["decision_graph"] as? [String: Any]
      let goal = (graph?["goals"] as? [[String: Any]])?.first
      let options = (goal?["methods"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
      try check(graph?["path"] as? [String] == rootPath && graph?["method_origin"] as? String == "open" &&
                options == ["visibility.transform", "visibility.clipping", "visibility.tf"],
                "visibility planning did not start at the root with the available methods")
    }

    let open = Workspace()
    let openModel = Model { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      if step == 0 {
        try checkRoot(context)
        return try Model.decision(.apply, "rotate_view", target,
                                  route: .init(method: "visibility.transform", directive: "not a user quote"))
      }
      let graph = context["decision_graph"] as? [String: Any]
      if step == 1 {
        try check(graph?["method_origin"] as? String == "assistant" &&
                  graph?["path"] as? [String] == rootPath + ["visibility", "visibility.transform"],
                  "the open prompt did not record a provisional choice from the root")
        return try Model.decision(.apply, "set_clipping", route: .init(method: "visibility.clipping", directive: nil))
      }
      try check(graph?["path"] as? [String] == rootPath + ["visibility", "visibility.clipping"], "the assistant could not reconsider its own choice")
      return try Model.decision(.finish, text: "Ansicht angepasst.")
    }
    let openResult = try await BorgVRAssistantCore(workspace: open, model: openModel, knowledge: knowledge,
                                                 imagesAllowed: true).run("Zeig mir die Haut")
    try check(openResult.applied == 2 && open.rotations.count == 1 && open.clips == 1 && open.scans.isEmpty,
              "the open visibility request was forced into a sweep or dispatched an invalid choice")

    let fixed = Workspace()
    var band: [String: Any]?
    var systemPrefix: String?
    var scopedPrefix: String?
    let fixedModel = Model { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      let body = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture"), as: UTF8.self))
      let messages = body["messages"] as? [[String: Any]]
      let system = messages?.first?["content"] as? String
      let cloud = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture", provider: .openAI), as: UTF8.self))
      try check(system != nil && system == cloud["instructions"] as? String && context["operations"] == nil &&
                !input.catalog.isEmpty && system?.contains("\"name\":\"set_bounding_box\"") == true,
                "the providers did not place the tool schemas in the system prefix")
      if step == 0 {
        try checkRoot(context)
        systemPrefix = system
        let catalogSection = system?.split(separator: "\n").last ?? ""
        let native = fixed.operations()
        let expected = native + knowledge.workflows.map(\.definition) + input.catalog.filter {
          ["inspect.previews", "apply_preview"].contains($0["name"] as? String ?? "")
        }
        let sorted = expected.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        let expectedCatalog = try VoiceAgentPolicy.encoded(["operations": sorted])
        try check(catalogSection == expectedCatalog, "the stable prefix omitted or changed a tool schema")
        fixed.reverseCatalog = true
        let grammar = (body["structured_outputs"] as? [String: String])?["grammar"] ?? ""
        let format = (cloud["text"] as? [String: Any])?["format"] as? [String: Any]
        let schema = format?["schema"] as? [String: Any]
        let route = (schema?["properties"] as? [String: Any])?["route"] as? [String: Any]
        try check(grammar.contains("(comma route)?") && route?["type"] as? [String] == ["object", "null"] &&
                  Set(context["unavailable_operations"] as? [String] ?? []) == ["apply_preview", "inspect.previews"],
                  "routing metadata must be optional and preview availability must be explicit")
        return try Model.decision(.investigate, "inspect.intensity_bands",
                                  route: .init(method: "visibility.tf", directive: "Ändere die TF"))
      }
      let tool = input.catalog.first { $0["name"] as? String == "set_bounding_box" }
      if step == 1 {
        scopedPrefix = system
        try check((system?.utf8.count ?? 0) < (systemPrefix?.utf8.count ?? 0), "The selected route did not reduce the catalog")
      }
      if step < 5 {
        try check(system == scopedPrefix && tool?["inputSchema"] == nil, "Off-route schemas or transient evidence enlarged the route prefix")
      } else {
        try check(tool?["inputSchema"] != nil, "Argument repair did not restore the off-route schema")
      }
      let graph = context["decision_graph"] as? [String: Any]
      let previews = context["preview_evidence"] as? [String: Any]
      let steps = (graph?["steps"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
      try check(graph?["path"] as? [String] == tfPath && graph?["method_origin"] as? String == "user" &&
                steps == ["tf.observe_bands", "tf.read_curve", "tf.adjust", "visibility.verify"],
                "the user-specified TF route was not retained as guidance")
      switch step {
        case 1:
          let id = input.images.first?.id
          let events = context["events"] as? [[String: Any]] ?? []
          let report = events.first(where: { $0["operation"] as? String == "inspect.intensity_bands" })?["result"] as? [String: Any]
          let points = report?["previews"] as? [[String: Any]] ?? []
          band = points.first(where: { $0["id"] as? String == id })
          try check(id != nil && band?["channel"] as? Int == 0 &&
                    (previews?["previously_provided_ids"] as? [String])?.isEmpty == true,
                    "rendered candidates were not distinguished from previews already provided")
          return try Model.decision(.investigate, "list_measurements", route: .init(method: "unknown", directive: nil))
        case 2:
          try check((previews?["previously_provided_ids"] as? [String])?.contains(band?["id"] as? String ?? "") == true,
                    "shown preview was missing from evidence state")
          return try Model.decision(.investigate, "get_transfer_function")
        case 3:
          guard let low = band?["threshold"] as? Double, let high = band?["opaque_from"] as? Double else {
            throw Failure.unexpected("preview missing typed intensity interval")
          }
          return try Model.decision(.apply, "set_transfer_function_component",
                                    ["channel": 0, "component": 3, "points": [[0, 0], [low, 1], [high, 1], [1, 0]]])
        case 4: return try Model.decision(.apply, "set_bounding_box", ["visible": "yes"])
        case 5:
          try check(fixed.boundingBoxes.isEmpty && input.context.contains("arguments do not match"),
                    "an off-path action bypassed schema validation")
          return try Model.decision(.apply, "set_bounding_box", ["visible": true])
        case 6: return try Model.decision(.investigate, "capture_screenshot")
        default:
          try check(input.images.map(\.id) == ["current_render"], "the TF route did not verify the live render")
          return try Model.decision(.finish, text: "Opazität angepasst.")
      }
    }
    let fixedResult = try await BorgVRAssistantCore(workspace: fixed, model: fixedModel, knowledge: knowledge,
                                                  imagesAllowed: true).run("Ändere die TF, zeig den Begrenzungsrahmen und prüfe die Messungen")
    try check(fixedResult.applied == 2 && fixed.componentChanges.first?["component"] as? Int == 3 &&
              fixed.boundingBoxes == [true] && fixed.measurementReads == 1 && !fixed.scans.isEmpty,
              "the TF recommendation blocked an independent observation or mutation")

    var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    legacy.removeValue(forKey: "decisionGraph")
    let old = try AssistantKnowledge.load(JSONSerialization.data(withJSONObject: legacy))
    try check(old.decisionGraph == nil, "older knowledge packages must still load")
    let dangling = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"children\": [\"visibility\"]",
                                                                                                with: "\"children\": [\"missing\"]").utf8)
    do {
      _ = try AssistantKnowledge.load(dangling)
      throw Failure.unexpected("a dangling graph edge was accepted")
    } catch VoiceAgentError.protocolViolation {}
  }

  private static func testPoseBoxGuidance(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    workspace.supportsLitRenderMode = true
    let method = AssistantDecision.Route(method: "visibility.transform", directive: nil)
    let model = Model { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      let graph = context["decision_graph"] as? [String: Any]
      let rendering = (context["state"] as? [String: Any])?["renderingOptions"] as? [String: Any]
      switch step {
        case 0:
          let methods = (graph?["goals"] as? [[String: Any]])?.flatMap { $0["methods"] as? [[String: Any]] ?? [] }
          let pose = methods?.first { $0["id"] as? String == method.method }
          let description = pose?["description"] as? String ?? ""
          try check(description.contains("show the XYZ bounding box if hidden") &&
                    description.contains("Use inspect.orientation") &&
                    rendering?["datasetBoundingBoxVisible"] as? Bool == false,
                    "A named pose did not expose its lighting and bounding-box aids")
          return try Model.decision(.apply, "set_bounding_box", ["visible": true], route: method)
        case 1:
          let steps = graph?["steps"] as? [[String: Any]]
          try check(steps?.contains { $0["id"] as? String == "transform.reference_box" &&
                                      $0["operations"] as? [String] == ["set_bounding_box"] } == true &&
                    steps?.contains { $0["id"] as? String == "transform.verify_pose" &&
                                      ($0["operations"] as? [String])?.contains("inspect.orientation") == true } == true &&
                    rendering?["datasetBoundingBoxVisible"] as? Bool == true,
                    "The caption or live state did not make the box available for the pose screenshot")
          let workflow = input.catalog.first { $0["name"] as? String == "inspect.orientation" }
          try check(workflow?["inputSchema"] != nil, "The pose route omitted its workflow schema")
          return try Model.decision(.investigate, "inspect.orientation")
        case 2:
          let guidance = context["expert_guidance"] as? [[String: String]] ?? []
          let rule = guidance.first { $0["id"] == "geometry.pose" }?["text"] ?? ""
          let comparison = guidance.first { $0["id"] == "geometry.pose_lighting" }?["text"] ?? ""
          try check(input.images.map(\.id) == ["orientation_unlit", "orientation_lit"] &&
                    rule.contains("Red increases along local +X") && rule.contains("green along +Y") &&
                    rule.contains("blue along +Z") && rule.contains("do not identify anatomical front") &&
                    rule.contains("scale only") && rule.contains("retaining the desired rotation") &&
                    comparison.contains("Do not assemble the comparison yourself"),
                    "Live pose evidence lacked the color legend, lighting, zoom fallback or restoration guidance")
          return try Model.decision(.apply, "set_bounding_box", ["visible": false], orientationCheck: .init(images: [
            "orientation_unlit": .init(status: .met, finding: "Die unbeleuchtete Aufnahme zeigt die Vorderseite klar."),
            "orientation_lit": .init(status: .unmet, finding: "Mit Licht sieht es wie eine andere Seite aus."),
          ], blockedReason: nil))
        case 3:
          let confirmation = context["confirmed_orientation"] as? [String: Any]
          try check(input.images.isEmpty && confirmation?["status"] as? String == "met" &&
                    rendering?["datasetBoundingBoxVisible"] as? Bool == false,
                    "Restoring the bounding box lost the confirmed pose")
          return try Model.decision(.apply, "rotate_view", ["axis": [1, 0, 0], "degrees": 180])
        default: throw Failure.unexpected("The confirmed pose did not close the goal")
      }
    }
    _ = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                     imagesAllowed: true).run("Drehe den Datensatz so, dass ich von vorne auf ihn schaue.")
    try check(workspace.boundingBoxes == [true, false] && workspace.screenshots.count == 2 && workspace.rotations.isEmpty &&
                workspace.renderModes == ["transfer_function_lighting", "transfer_function"] &&
                workspace.transferFunction == Workspace.originalTF,
              "A conflicting lighting result changed the pose or the workflow lost the original rendering settings")
  }

  private static func testOrientationWorkflow(_ knowledge: AssistantKnowledge) async throws {
    for iso in [false, true] {
      let workspace = Workspace()
      workspace.initialRenderMode = iso ? "isovalue" : "transfer_function_lighting"
      workspace.supportsLitRenderMode = !iso
      let imageIDs = iso ? ["orientation_iso"] : ["orientation_lit", "orientation_unlit"]
      let model = Model { step, input in
        if step == 0 {
          try check(input.catalog.contains { $0["name"] as? String == "inspect.orientation" }, "Orientation workflow is unavailable")
          return try Model.decision(.investigate, "inspect.orientation")
        }
        let context = try VoiceAgentPolicy.decode(input.context)
        try check(step == 1 && input.images.map(\.id) == imageIDs && input.orientationImageIDs == imageIDs && !input.requiresGoalCheck &&
                    (context["state"] as? [String: Any])?["renderMode"] as? String == workspace.initialRenderMode,
                  "The images were split across requests or sent before restoration")
        if !iso {
          try check(input.images[0].png != input.images[1].png, "The two modes gave the model duplicate images")
        }
        let vllm = try VoiceAgentModelClient.body(input, model: "fixture")
        let vllmBody = try VoiceAgentPolicy.decode(String(decoding: vllm, as: UTF8.self))
        let grammar = (vllmBody["structured_outputs"] as? [String: String])?["grammar"] ?? ""
        let cloud = try VoiceAgentModelClient.body(input, model: "fixture", provider: .openAI)
        let cloudBody = try VoiceAgentPolicy.decode(String(decoding: cloud, as: UTF8.self))
        let format = (cloudBody["text"] as? [String: Any])?["format"] as? [String: Any]
        let schema = format?["schema"] as? [String: Any]
        let field = (schema?["properties"] as? [String: [String: Any]])?["orientation_check"]
        let imageSchema = (field?["properties"] as? [String: [String: Any]])?["images"]
        try check(grammar.contains("ws orientation_check comma") && imageIDs.allSatisfy(grammar.contains) &&
                  (schema?["required"] as? [String])?.contains("orientation_check") == true &&
                  imageSchema?["required"] as? [String] == imageIDs, "Providers did not require each attached image's result")
        let findings = Dictionary(uniqueKeysWithValues: imageIDs.map {
          ($0, AssistantDecision.OrientationCheck.Image(status: $0 == imageIDs.last ? .met : .inconclusive,
                                                        finding: $0 == imageIDs.last ? "Draufsicht bestaetigt." : "Unklar."))
        })
        return try Model.decision(.apply, "set_transform", ["rotation": [1, 0, 0, 0]],
                                  orientationCheck: .init(images: findings, blockedReason: nil))
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: true)
        .run("Zeig den Datensatz von oben.")
      try check(result.text == "Draufsicht bestaetigt." && result.applied == 0 && model.step == 2 &&
                workspace.renderModes == (iso ? [] : ["transfer_function", "transfer_function_lighting"]) &&
                workspace.screenshotModes == (iso ? ["isovalue"] : ["transfer_function_lighting", "transfer_function"]),
                "An ISO capture switched modes, or a single matching image did not keep the pose")
    }

    let workspace = Workspace()
    workspace.supportsLitRenderMode = true
    let correction = Model { step, input in
      switch step {
        case 0, 2: return try Model.decision(.investigate, "inspect.orientation")
        case 1:
          let mismatch = AssistantDecision.OrientationCheck.Image(status: .unmet, finding: "Keine Draufsicht.")
          return try Model.decision(.apply, "rotate_view", ["axis": [1, 0, 0], "degrees": 90],
                                    orientationCheck: .init(images: ["orientation_unlit": mismatch, "orientation_lit": mismatch],
                                                            blockedReason: nil))
        default:
          try check(input.orientationImageIDs.count == 2 && workspace.rotations.count == 1, "An unmatched pose was not corrected and recaptured")
          let match = AssistantDecision.OrientationCheck.Image(status: .met, finding: "Draufsicht.")
          return try Model.decision(.finish, text: "Draufsicht eingestellt.",
                                    orientationCheck: .init(images: ["orientation_unlit": match, "orientation_lit": match],
                                                            blockedReason: nil))
      }
    }
    let corrected = try await BorgVRAssistantCore(workspace: workspace, model: correction, knowledge: knowledge, imagesAllowed: true)
      .run("Zeig den Datensatz von oben.")
    try check(corrected.applied == 1 && correction.step == 4 && workspace.screenshots.count == 4,
              "A mismatch did not allow a normal corrective action")
  }

  private static func testOrientationWorkflowInterruption(_ knowledge: AssistantKnowledge) async throws {
    for reason in ["failure", "stop", "takeover"] {
      let workspace = Workspace()
      workspace.supportsLitRenderMode = true
      workspace.onScreenshot = { count in
        guard count == 2 else { return }
        switch reason {
          case "failure": throw VoiceAgentError.timedOut
          case "stop": withUnsafeCurrentTask { $0?.cancel() }
          default:
            workspace.renderModes.append("isovalue")
            workspace.revision += 1
        }
      }
      let model = Model { step, input in
        if step == 0 { return try Model.decision(.investigate, "inspect.orientation") }
        try check(input.images.isEmpty && input.orientationImageIDs.isEmpty, "A partial or stale pair reached the model")
        return try Model.decision(.finish, text: "Keine Orientierung bestaetigt.")
      }
      let core = BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: true)
      do {
        _ = try await Task { try await core.run("Zeig den Datensatz von oben.") }.value
        try check(reason != "stop", "Stopped workflow returned success")
      } catch is CancellationError {
        try check(reason == "stop" && model.step == 1, "Cancellation was not confined to Stop")
      }
      let finalMode = reason == "takeover" ? "isovalue" : "transfer_function"
      try check(workspace.renderModes == ["transfer_function_lighting", finalMode] && !core.effectInFlight,
                "Render-mode cleanup failed or overwrote the user's manual mode")
    }
  }

  private static func testCachedSweepFollowup(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    workspace.sweepRenderSignature = Data([1])
    let cache = AssistantSweepCache()
    let sweep = "inspect.intensity_bands"
    func rotation(_ degrees: Float) -> SIMD4<Float> {
      let half = degrees * .pi / 360
      return .init(0, sin(half), 0, cos(half))
    }
    func readReport(_ input: AssistantModelInput) throws -> [String: Any] {
      let context = try VoiceAgentPolicy.decode(input.context)
      let events = context["events"] as? [[String: Any]] ?? []
      return events.last { $0["operation"] as? String == sweep }?["result"] as? [String: Any] ?? [:]
    }
    var previewIDs: [String] = []
    let bones = Model { step, input in
      switch step {
        case 0: return try Model.decision(.investigate, sweep)
        case 1:
          try check(try readReport(input)["source"] as? String == "live_sweep", "Initial sweep was not live")
          previewIDs = input.images.map(\.id)
          return try Model.decision(.apply, "apply_preview", ["id": previewIDs[1]])
        default:
          try check(input.images.map(\.id) == ["current_render"], "No live control image after selecting bones")
          return try Model.decision(.finish, text: "Knochen sichtbar.")
      }
    }
    _ = try await BorgVRAssistantCore(workspace: workspace, model: bones, knowledge: knowledge,
                                     imagesAllowed: true, sweepCache: cache).run("Zeig die Knochen")
    let boneCurve = workspace.transferFunction
    let before = workspace.changes.count
    workspace.sweepRotation = -rotation(3)
    workspace.sweepTranslation.x = 0.01
    workspace.revision += 1
    let skin = Model { step, input in
      switch step {
        case 0: return try Model.decision(.investigate, sweep, ["channel": 0])
        case 1:
          let report = try readReport(input)
          try check(report["source"] as? String == "cached_sweep" && input.images.map(\.id) == previewIDs &&
                    workspace.transferFunction == boneCurve && workspace.changes.count == before && workspace.scans.count == 101,
                    "The follow-up rendered again or altered the live view instead of providing the cached candidates")
          return try Model.decision(.apply, "apply_preview", ["id": previewIDs[0]])
        case 2:
          try check(!input.finalReplyOnly && input.images.map(\.id) == ["current_render"] &&
                    workspace.screenshotTFs.last == workspace.transferFunction && workspace.transferFunction != boneCurve,
                    "The follow-up did not verify the selected live skin curve")
          return try Model.decision(.investigate, sweep)
        default:
          let report = try readReport(input)
          try check(!input.finalReplyOnly && report["source"] as? String == "cached_sweep" &&
                    input.images.map(\.id) == previewIDs, "A new request for cached candidates was treated as an error")
          return try Model.decision(.finish, text: "Haut sichtbar.")
      }
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: skin, knowledge: knowledge,
                                               imagesAllowed: true, sweepCache: cache).run("Und jetzt die Haut")
    try check(result.applied == 1 && workspace.changes.count == before + 1 && workspace.scans.count == 101 &&
              workspace.transferFunction != boneCurve && workspace.screenshots.count == 2,
              "The confirmed skin result was changed again")

    for scenario in ["rotation", "translation", "clipping or edit", "new opening", "channel", "scan configuration"] {
      guard let entry = cache.last else { throw Failure.unexpected("No completed sweep in cache") }
      let view = entry.view
      let changed = AssistantSweepView(opening: scenario == "new opening" ? UUID() : view.opening,
        rotation: scenario == "rotation" ? rotation(6) : view.rotation,
        translation: scenario == "translation" ? SIMD3(0.016, 0.016, 0) : view.translation,
        renderSignature: scenario == "clipping or edit" ? Data([2]) : view.renderSignature)
      let scan = scenario == "scan configuration"
        ? AssistantKnowledge.Scan(initialBands: nil, maxPreviews: nil, minWidth: nil,
                                  differenceThreshold: 0.2, palette: "rainbow", transitionWidth: 0.06) : entry.scan
      try check(cache.lookup(view: changed, channel: scenario == "channel" ? 1 : 0, scan: scan) == nil,
                "The sweep was reused after a change to \(scenario)")
    }
    workspace.sweepRotation = rotation(6)
    let rotated = Model { step, input in
      if step == 0 { return try Model.decision(.investigate, sweep) }
      try check(try readReport(input)["source"] as? String == "live_sweep", "The rotated view did not make a fresh sweep")
      return try Model.decision(.finish, text: "Ansicht geprüft.")
    }
    _ = try await BorgVRAssistantCore(workspace: workspace, model: rotated, knowledge: knowledge,
                                     imagesAllowed: true, sweepCache: cache).run("Prüfe die neue Ansicht")
    try check(workspace.scans.count == 202, "Expected one new sweep in the rotated view")
  }

  private static func testSparseThresholdTransitions(_ knowledge: AssistantKnowledge) async throws {
    for extent in [1, 4] {
      let workspace = Workspace()
      workspace.sparsePreviewSize = extent
      let model = Model { step, input in
        if step == 0 { return try Model.decision(.investigate, "inspect.intensity_bands") }
        let context = try VoiceAgentPolicy.decode(input.context)
        let event = (context["events"] as? [[String: Any]])?.last
        let result = event?["result"] as? [String: Any]
        try check(result?["significant_change"] as? Bool == (extent == 4) && workspace.scans.count == 101,
                  "A small surviving region should be detected without treating a one-pixel change as significant")
        return try Model.decision(.finish, text: "Reviewed the previews.")
      }
      _ = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                       imagesAllowed: true).run("Inspect how the volume changes")
    }
  }

  private static func testSettledThresholdCandidates(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    func frame(_ step: Int) throws -> Data {
      let stripes: [CGFloat] = switch step {
        case 0..<20: [0, 0, 0, 0]
        case 20: [0.4, 0, 0, 0]
        case 21: [0, 0.4, 0.4, 0]
        case 22..<25: [0.4, 0.4, 0.4, 0]
        case 25..<99: [0.4, 0.4, 0.4, 0.4]
        case 99: [0, 0, 0.4, 0.4]
        default: [0, 0, 0, 0]
      }
      return try Workspace.image(visible: true, stripes: stripes)
    }
    workspace.sweepImage = frame
    let model = Model { step, input in
      if step == 0 { return try Model.decision(.investigate, "inspect.intensity_bands") }
      let context = try VoiceAgentPolicy.decode(input.context)
      let events = context["events"] as? [[String: Any]] ?? []
      let report = events.first { $0["operation"] as? String == "inspect.intensity_bands" }?["result"] as? [String: Any]
      let transitions = report?["transitions"] as? [[String: Any]] ?? []
      try check(transitions.count == 3 &&
                transitions.compactMap { $0["below"] as? Double } == [0.19, 0.98, 0.24] &&
                transitions.compactMap { $0["above"] as? Double } == [0.22, 1, 0.25] &&
                transitions.first?["peak_to"] as? Double == 0.21 &&
                transitions.compactMap { $0["candidate_threshold"] as? Double } == [0.24, 1, 0.29] &&
                transitions.compactMap { $0["delay_steps"] as? Int } == [2, 0, 4],
                "consecutive changes were not grouped, ranked by their peak, or capped at the next transition or sweep end")
      if step == 1 {
        try check(input.images.map(\.png) == [try frame(24), try frame(100)],
                  "the first two images must be the delayed candidates of the strongest transitions")
        return try Model.decision(.investigate, "inspect.previews")
      }
      try check(input.images.map(\.png) == [try frame(29)], "the remaining settled frame was not delivered")
      return try Model.decision(.finish, text: "Reviewed the settled frames.")
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                              imagesAllowed: true).run("Inspect how the volume changes")
    try check(result.applied == 0 && model.step == 3, "reading candidate images should not change the restored TF")
  }

  private static func testNoProgress(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    workspace.sweepImage = { step in try Workspace.image(visible: true, gray: (step / 15).isMultiple(of: 2) ? 0.2 : 0.7) }
    var seen: Set<String> = []
    var requested: [String] = []
    var expectedCount = 0
    let revisits = Model { step, input in
      try check(step <= 10, "already seen previews kept the task running")
      if step == 0 { return try Model.decision(.investigate, "inspect.intensity_bands") }
      let context = try VoiceAgentPolicy.decode(input.context)
      let evidence = context["preview_evidence"] as? [String: Any]
      let previous = Set(evidence?["previously_provided_ids"] as? [String] ?? [])
      let unseen = evidence?["unseen_ids"] as? [String] ?? []
      let attached = input.images.map(\.id)
      try check(previous == seen && !attached.isEmpty && attached.count <= 2 && seen.isDisjoint(with: attached) &&
                Set(unseen).isDisjoint(with: seen.union(attached)), "the preview cursor resent an image or lost its delivery state")
      seen.formUnion(attached)
      if step == 1 {
        guard let first = attached.first, let preferred = unseen.last else { throw Failure.unexpected("missing fixture previews") }
        requested = [first, preferred]
        expectedCount = seen.count + unseen.count
      }
      if step == 2 { try check(attached.first == requested.last, "a still-unseen preferred preview was not prioritized") }
      let unavailable = context["unavailable_operations"] as? [String] ?? []
      try check(unavailable.contains("inspect.previews") == unseen.isEmpty, "exhausted preview tool stayed available")
      if unseen.isEmpty {
        try check(evidence?["status"] as? String == "no_unseen_previews_remain", "preview exhaustion was not signaled")
        return try Model.decision(.finish, text: "No candidate could be confirmed.")
      }
      // Repeat the same old IDs to mirror the real model trace. The workspace advances regardless.
      return try Model.decision(.investigate, "inspect.previews", ["ids": requested])
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: revisits, knowledge: knowledge,
                                               imagesAllowed: true).run("Inspect the intensity bands")
    try check(result.applied == 0 && expectedCount == 4 && seen.count == expectedCount && workspace.transferFunction == Workspace.originalTF,
              "repeated requests must consume all evidence at most once without inventing a change")

    let noOpWorkspace = Workspace()
    noOpWorkspace.acceptsRotation = false
    let repeatedNoOp = Model { step, _ in
      try check(step < 3, "non-applied commands kept the task running")
      return try Model.decision(.apply, "rotate_view", ["axis": [0, 1, 0], "degrees": (step + 1) * 10])
    }
    do {
      _ = try await BorgVRAssistantCore(workspace: noOpWorkspace, model: repeatedNoOp, knowledge: knowledge,
                                       imagesAllowed: false).run("Apply a view change")
      throw Failure.unexpected("non-applied commands counted as progress")
    } catch AssistantRunFailure.modelStalled {}
    try check(repeatedNoOp.step == 3 && noOpWorkspace.rotations.isEmpty, "a no-op reset the stall count")
  }

  private static func testTaskPlan(_ knowledge: AssistantKnowledge) async throws {
    let request = "Ändere die TF so dass die Knochen sichtbar werden und drehe den Datensatz so dass ich vorne auf ihn schaue."
    let goals = ["Knochen sichtbar machen", "Vorderansicht einstellen"]
    let rotation: [String: Any] = ["axis": [0, 1, 0], "degrees": -45]
    let workspace = Workspace()
    let model = Model(intake: { message in
      try check(message == request, "The intake did not receive the raw message")
      return goals.map { .init(kind: .task, text: $0) }
    }) { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      let vllm = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture"), as: UTF8.self))
      let grammar = (vllm["structured_outputs"] as? [String: String])?["grammar"] ?? ""
      let cloud = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture", provider: .openAI), as: UTF8.self))
      let format = (cloud["text"] as? [String: Any])?["format"] as? [String: Any]
      let schema = (format?["schema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
      let kinds = schema?["kind"]?["enum"] as? [String] ?? []
      try check(!input.finalReplyOnly && context["request"] as? String == goals[step < 4 ? 0 : 1] &&
                  context["task_plan"] == nil && context["recent_conversation"] == nil &&
                  !grammar.contains("subgoals ::=") && schema?["subgoals"] == nil && schema?["conversation_state"] == nil,
                "Execution did not stay separate from intake and state updates")
      if step < 4 {
        try check(input.allowsAdvance && !input.allowsFinish && !input.context.contains(goals[1]) &&
                    grammar.contains("advance ::=") && kinds.contains("advance") &&
                    !kinds.contains("finish") && schema?["subgoal_status"] != nil && workspace.rotations.isEmpty,
                  "The first goal could be skipped or the second lost")
      } else {
        let completed = context["completed_outcomes"] as? [[String: String]]
        try check(input.allowsFinish && !input.allowsAdvance &&
                    completed?.first?["goal"] == goals[0] && kinds.contains("finish") && !kinds.contains("advance"),
                  "The rotation goal was not activated with the earlier result")
      }
      switch step {
        case 0: return try Model.decision(.investigate, "inspect.intensity_bands")
        case 1: return try Model.decision(.apply, "apply_preview", ["id": input.images[0].id])
        case 2:
          try check(input.images.map(\.id) == ["current_render"], "No live view after the TF change")
          return try Model.decision(.finish, text: "Knochen sichtbar.")
        case 3: return try Model.decision(.advance, text: "Knochen in der Live-Ansicht sichtbar.", status: .complete)
        case 4: return try Model.decision(.apply, "rotate_view", rotation)
        case 5: return try Model.decision(.investigate, "capture_screenshot")
        default: return try Model.decision(.finish, text: "Knochen sichtbar und Vorderansicht eingestellt.")
      }
    }
    // Once intake is done, a single request can choose an action on its first execution decision.
    let simple = Workspace()
    let single = Model { step, input in
      try check(!input.allowsAdvance && input.allowsFinish, "A simple request acquired multiple tasks")
      return step == 0 ? try Model.decision(.apply, "rotate_view", rotation) : try Model.decision(.finish, text: "Gedreht.")
    }
    _ = try await BorgVRAssistantCore(workspace: simple, model: single, knowledge: knowledge,
                                     imagesAllowed: false).run("Drehe um 45 Grad nach links.")
    try check(single.parsedMessages.count == 1 && single.stateInputs.count == 2 && single.step == 2 &&
                simple.rotations.count == 1, "A direct task did not use intake, state and execution independently")

    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                               imagesAllowed: true).run(request)
    try check(result.applied == 2 && workspace.scans.count == 101 && workspace.screenshots.count == 2 &&
              workspace.rotations.count == 1 && workspace.changes.count == 103, "The plan did not leave both changes in place")

    let blockedWorkspace = Workspace()
    let blocked = Model(intake: { _ in
      ["Locate missing dataset", "Rotate that dataset"].map { .init(kind: .task, text: $0) }
    }) { step, _ in
      if step == 0 {
        return try Model.decision(.investigate, "list_measurements")
      }
      return try Model.decision(.advance, text: "Dataset not found; it was not rotated.", status: .blocked)
    }
    let stopped = try await BorgVRAssistantCore(workspace: blockedWorkspace, model: blocked, knowledge: knowledge,
                                                imagesAllowed: false).run("Locate the dataset and rotate it.")
    try check(stopped.applied == 0 && blocked.step == 2 && blockedWorkspace.rotations.isEmpty && stopped.text.contains("not rotated"),
              "A blocked goal ran dependent operations or lost its explanation")
  }

  private static func testSeparateStateUpdates(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    let prompt = "Das ist unten. Stelle die Vorderansicht ein."
    let request = "Stelle die Vorderansicht ein."
    let initial = "User described the initial view as bottom."
    let revised = "User's correction referred to the earlier view."
    var committed: [[String]] = []
    let model = Model(intake: { text in
      try check(text == prompt, "Intake received more than the live user message")
      return [.init(kind: .information, text: "Das ist unten."), .init(kind: .task, text: request)]
    }, update: { step, input in
      let events = input.updates
      let manual = events.first { $0["source"] as? String == "external" }
      let changes = manual?["changes"] as? [String: Any]
      switch step {
        case 0:
          try check(input.notes.isEmpty && input.application["app_phase"] as? String == "rendering_dataset" &&
                    input.application["transform"] != nil && events.count == 1 &&
                    events.first?["text"] as? String == "Das ist unten.",
                    "The initial state did not receive just the snapshot and extracted knowledge")
          return [initial]
        case 1:
          try check(input.notes == [initial] && manual?["domains"] as? [String] == ["transform"] &&
                    changes?["transform"] != nil, "The updater did not see the manual pose change")
          workspace.revision += 1
          workspace.manualDomains["transfer_function"] = workspace.revision
          return ["Stale note that must not be committed."]
        case 2:
          try check(input.notes == [initial] && manual?["domains"] as? [String] == ["transfer_function", "transform"],
                    "A stale state result was committed or a manual TF edit was lost")
          return [revised]
        case 3:
          try check(input.notes == [revised] &&
                    events.contains { $0["source"] as? String == "assistant" && $0["operation"] as? String == "rotate_view" },
                    "The updater did not receive the performed operation")
          return input.notes
        default: throw Failure.unexpected("The updater was called without new information")
      }
    }) { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      let notes = context["conversation_state"] as? [String]
      try check(context["request"] as? String == request && !input.context.contains(prompt), "Execution received the unparsed prompt")
      if step == 0 {
        try check(notes == [initial], "Execution started before the initial state update")
        workspace.manualRotation = 35
        workspace.revision += 1
        workspace.manualDomains["transform"] = workspace.revision
        return try Model.decision(.apply, "rotate_view", ["axis": [0, 1, 0], "degrees": 90])
      }
      try check(notes == [revised] && context["state"] != nil, "Execution resumed with old notes or no state")
      if step == 1 {
        try check(input.context.contains("user_state_changed") && workspace.rotations.isEmpty, "The stale rotation ran")
        return try Model.decision(.apply, "rotate_view", ["axis": [0, 1, 0], "degrees": -35])
      }
      return try Model.decision(.finish, text: "Vorderansicht eingestellt.")
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: false)
      .run(prompt, onConversationStateChange: { committed.append($0?.notes ?? []) })
    try check(result.applied == 1 && workspace.rotations.first?["degrees"] as? Int == -35 &&
                committed == [[initial], [revised]] && model.parsedMessages == [prompt] && model.stateInputs.count == 4,
              "Manual changes were not reconciled before execution resumed")

    let menu = Workspace()
    menu.rendererReady = false
    let information = Model(intake: { [.init(kind: .information, text: $0)] }, update: { step, input in
      try check(input.application["app_phase"] as? String == (step == 0 ? "main_menu" : "loading_dataset") &&
                input.updates.first?["source"] as? String == "user", "The initial application phase was not reported")
      return step == 0 ? ["An initial note."] : []
    }) { _, _ in throw Failure.unexpected("An information-only message reached execution") }
    let core = BorgVRAssistantCore(workspace: menu, model: information, knowledge: knowledge, imagesAllowed: false)
    var notes: AssistantConversationState?
    _ = try await core.run("A fact.", onConversationStateChange: { notes = $0 })
    try check(notes != nil, "The app did not receive the new notes")
    menu.datasetDescription = "A dataset waiting for its first frame"
    let acknowledgement = try await core.run("That fact has been corrected.", onConversationStateChange: { notes = $0 })
    try check(notes == nil && information.step == 0 && information.reviewed == 0 && acknowledgement.applied == 0,
              "A pure correction ran a tool or failed to clear notes")
  }

  private static func testStateUpdateRepair(_ knowledge: AssistantKnowledge) async throws {
    let previous = ["A prior working note."]
    let corrected = ["A corrected working note."]
    let tooMany = (1...10).map { "Note \($0)." }
    let userFact = "The earlier orientation was wrong."
    let request = "Rotate the dataset by 15 degrees."
    for recovers in [true, false] {
      let workspace = Workspace()
      var committed: [[String]] = []
      let model = Model(intake: { _ in
        [.init(kind: .information, text: userFact), .init(kind: .task, text: request)]
      }, update: { attempt, input in
        switch attempt {
          case 0:
            try check(input.retryFeedback == nil && input.notes == previous, "The first update already contains repair feedback")
            return tooMany
          case 1:
            let retry = try VoiceAgentModelClient.stateUpdateInput(input)
            try check(retry.system.contains("You returned 10 notes; the maximum is 8") && input.notes == previous &&
                      input.updates.first?["text"] as? String == userFact,
                      "The retry did not tell the model what to correct or lost the evidence")
            return recovers ? corrected : tooMany
          case 2:
            try check(input.retryFeedback == nil && ((input.updates.first?["text"] as? String == userFact) == !recovers),
                      "The next update repeated the old error or lost unmerged user information")
            return input.notes
          default: throw Failure.unexpected("State update retried indefinitely")
        }
      }) { step, input in
        let context = try VoiceAgentPolicy.decode(input.context)
        try check(context["request"] as? String == request && context["state"] != nil &&
                  context["conversation_state"] as? [String] == (recovers ? corrected : previous),
                  "Execution did not receive the live snapshot and valid notes after state update repair")
        if step == 0 {
          let raw = context["unmerged_user_information"] as? [[String: Any]]
          try check(recovers ? raw == nil : raw?.first?["text"] as? String == userFact,
                    "Unmerged user information was lost or was sent after it had already been merged")
          return try Model.decision(.apply, "rotate_view", ["axis": [0, 1, 0], "degrees": 15])
        }
        return try Model.decision(.finish, text: "Rotated.")
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
        imagesAllowed: false, conversationState: AssistantConversationState(previous)).run(request, onConversationStateChange: {
          committed.append($0?.notes ?? [])
        })
      try check(result.applied == 1 && result.text == "Rotated." && workspace.rotations.count == 1 &&
                committed == (recovers ? [corrected] : []) && model.stateInputs.count == 3,
                "Rejecting the working notes aborted execution or replaced valid notes")
    }

    let workspace = Workspace()
    let offline = Model(update: { _, _ in throw URLError(.notConnectedToInternet) }) { _, _ in
      throw Failure.unexpected("A lost connection did not stop execution")
    }
    do {
      _ = try await BorgVRAssistantCore(workspace: workspace, model: offline, knowledge: knowledge,
                                       imagesAllowed: false).run(request)
      throw Failure.unexpected("A connection error was suppressed")
    } catch let error as URLError {
      try check(error.code == .notConnectedToInternet && offline.stateInputs.count == 1,
                "A connection error was retried as an invalid model answer")
    }
  }

  private static func testAuxiliaryRequestScopes() async throws {
    let message = "Only the current user message."
    let intake = VoiceAgentModelClient.intakeInput(message)
    let state = try VoiceAgentModelClient.stateUpdateInput(.init(
      application: ["transform": ["rotation": [0, 0, 0, 1]]], notes: ["previous note"],
      updates: [["source": "user", "text": "new fact"]]))
    let stateContext = try VoiceAgentPolicy.decode(state.context)
    try check(Set(stateContext.keys) == ["app_state", "previous_notes", "new_information"] &&
                intake.context == message && !state.context.contains(message), "The state request received unrelated inputs")
    for (input, phase, field) in [(intake, VoiceAgentModelClient.AuxiliaryPhase.intake, "items"),
                                  (state, .stateUpdate, "notes")] {
      for provider in VoiceAgentModelProvider.allCases {
        let body = try VoiceAgentModelClient.body(input, model: "fixture", provider: provider, phase: phase)
        let request = try VoiceAgentPolicy.decode(String(decoding: body, as: UTF8.self))
        let messages = request[provider == .vllm ? "messages" : "input"] as? [[String: Any]]
        let content = messages?.last?["content"] as? [[String: Any]]
        try check(content?.count == 1 && content?.first?["text"] as? String == input.context &&
                    !String(decoding: body, as: UTF8.self).contains("Operation catalog"),
                  "An auxiliary model request received tools, images or extra input")
        if provider == .vllm {
          let grammar = (request["structured_outputs"] as? [String: String])?["grammar"] ?? ""
          try check(grammar.contains(field) && !grammar.contains("operation ::="), "vLLM auxiliary grammar could emit an operation")
        } else {
          let format = (request["text"] as? [String: Any])?["format"] as? [String: Any]
          let schema = format?["schema"] as? [String: Any]
          try check(schema?["required"] as? [String] == [field] && format?["strict"] as? Bool == true,
                    "The auxiliary OpenAI schema was not dedicated to its phase")
        }
      }
    }
    for provider in VoiceAgentModelProvider.allCases {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [ModelAPIFixture.self]
      let endpoint = try VoiceAgentEndpoint(provider == .vllm ? "https://vllm.example" : "https://api.openai.com")
      let client = VoiceAgentModelClient(endpoint: endpoint, token: provider == .vllm ? "local-key" : "phase-key",
                                       session: URLSession(configuration: configuration), provider: provider, configuredModel: "fixture")
      let items = try await client.parseInput("Das ist unten.").validated()
      let notes = try await client.updateState(.init(application: [:], notes: [], updates: []))
      try check(items.count == 1 && items.first?.kind == .information && items.first?.text == "Das ist unten." &&
                notes == ["A model note."], "The provider's auxiliary response did not decode")
    }
  }

  private static func testControlImageCompletion(_ knowledge: AssistantKnowledge) async throws {
    let rotation: [String: Any] = ["axis": [0, 1, 0], "degrees": 90]
    let width = ["max_width": 1024]
    let reply = "Ich habe die Ansicht gedreht und das Ergebnis geprüft."
    for mode in ["finish_as_tool", "equivalent_screenshot", "invalid_completion"] {
      let workspace = Workspace()
      let model = Model { step, input in
        switch step {
          case 0: return try Model.decision(.apply, "rotate_view", rotation)
          case 1: return try Model.decision(.investigate, "capture_screenshot", width)
          case 2:
            try check(!input.finalReplyOnly && input.requiresGoalCheck && input.context.contains("Assess the attached current_render"),
                      "the control image was not identified during normal planning")
            return mode == "equivalent_screenshot"
              ? try Model.decision(.investigate, "capture_screenshot", ["max_width": 1024, "include_alpha": true])
              : try Model.decision(.apply, "finish")
          case 3:
            if mode == "equivalent_screenshot" {
              try check(!input.finalReplyOnly && workspace.screenshots.count == 2, "A repeat read forced an early completion")
              return try Model.decision(.finish, text: reply)
            }
            let context = try VoiceAgentPolicy.decode(input.context)
            let receipts = context["receipts"] as? [[String: Any]] ?? []
            let local = try JSONSerialization.jsonObject(with: VoiceAgentModelClient.body(input, model: "test")) as? [String: Any]
            let grammar = (local?["structured_outputs"] as? [String: String])?["grammar"] ?? ""
            let cloud = try JSONSerialization.jsonObject(with: VoiceAgentModelClient.body(input, model: "test", provider: .openAI)) as? [String: Any]
            let format = (cloud?["text"] as? [String: Any])?["format"] as? [String: Any]
            let schema = format?["schema"] as? [String: Any]
            let properties = schema?["properties"] as? [String: Any] ?? [:]
            try check(input.finalReplyOnly && input.catalog.isEmpty && input.images.map(\.id) == ["current_render"] &&
                      receipts.first?["operation"] as? String == "rotate_view" &&
                      context["response_length"] as? String == VoiceAgentResponseLength.detailed.guidance &&
                      grammar.hasPrefix(#"root ::= "{" ws "\"text\"""#) && !grammar.contains("action ::=") &&
                      Set(properties.keys) == ["kind", "text"], "the constrained final reply did not get just the receipt and existing evidence")
            if mode == "invalid_completion" { return try Model.decision(.apply, "rotate_view", rotation) }
            return try Model.decision(.finish, text: reply)
          default: throw Failure.unexpected("completion got stuck or dispatched another action")
        }
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                                 imagesAllowed: true).run("Drehe die Ansicht und prüfe das Ergebnis.", responseLength: .detailed)
      try check(result.applied == 1 && workspace.screenshots.count == (mode == "equivalent_screenshot" ? 2 : 1) && workspace.rotations.count == 1 &&
                model.step == 4 && !result.awaitingAnswer, "parallel completion or a repeated screenshot escaped the harness")
      try check(result.text == (mode == "invalid_completion" ? "Changes were applied. I could not reliably assess the final view." : reply),
                "an invalid final reply hid the confirmed change or passed through")
    }

    let workspace = Workspace()
    let followup = Model { step, input in
      try check(!input.finalReplyOnly, "a new change was blocked after inspection")
      switch step {
        case 0: return try Model.decision(.apply, "rotate_view", rotation)
        case 1, 3: return try Model.decision(.investigate, "capture_screenshot", width)
        case 2: return try Model.decision(.apply, "set_clipping")
        default: return try Model.decision(.finish, text: "Ich habe die Ansicht gedreht und geclippt.")
      }
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: followup, knowledge: knowledge,
                                               imagesAllowed: true).run("Drehe die Ansicht, prüfe sie und clippe sie bei Bedarf.")
    try check(result.applied == 2 && workspace.screenshots.count == 2 && workspace.clips == 1,
              "the assistant could not verify a new state after a justified follow-up")
  }

  private static func testUnconfirmedReply(_ knowledge: AssistantKnowledge) async throws {
    let goal = "Dreh um 90 Grad."
    let promise = "Ich drehe den Datensatz um 90 Grad."
    let question = "Um welche Achse?"
    let workspace = Workspace()
    let wantsChange = Model(review: { request, kind, draft in
      try check(request == goal, "the review received the wrong objective")
      if draft == promise { return .revise }
      try check(kind == .ask && draft == question, "the revised reply did not ask for the missing input")
      return .accept
    }) { step, input in
      if step == 0 { return try Model.decision(.finish, text: promise) }
      try check(input.context.contains("Your last reply draft was rejected"), "the rejected reply did not trigger a correction")
      return try Model.decision(.ask, text: question)
    }
    let asked = try await BorgVRAssistantCore(workspace: workspace, model: wantsChange, knowledge: knowledge,
                                              imagesAllowed: false).run(goal)
    try check(asked.text == question && asked.awaitingAnswer && workspace.rotations.isEmpty && wantsChange.reviewed == 2,
              "the ungrounded announcement was returned or executed instead of asking")

    let explicitWorkspace = Workspace()
    let explicitAction = Model(review: { _, _, _ in .revise }) { step, _ in
      switch step {
        case 0: return try Model.decision(.finish, text: promise)
        case 1: return try Model.decision(.apply, "rotate_view", ["axis": [0, 1, 0], "degrees": 90])
        default: return try Model.decision(.finish, text: "Der Datensatz wurde um 90 Grad gedreht.")
      }
    }
    let applied = try await BorgVRAssistantCore(workspace: explicitWorkspace, model: explicitAction, knowledge: knowledge,
                                                imagesAllowed: false).run("Drehe um 90 Grad um die Y-Achse.")
    try check(applied.applied == 1 && explicitWorkspace.rotations.count == 1 && explicitAction.reviewed == 1,
              "an ungrounded answer to an explicit action was not corrected and confirmed")

    let plainText = Model { _, _ in try Model.decision(.finish, text: "bereit") }
    let reply = try await BorgVRAssistantCore(workspace: workspace, model: plainText, knowledge: knowledge,
                                             imagesAllowed: false).run("Antworte nur mit bereit.")
    try check(reply.text == "bereit" && reply.applied == 0 && plainText.step == 1 && plainText.reviewed == 1,
              "an informational reply without changes was not accepted")

    let stillMisleading = Model(review: { _, _, _ in .revise }) { _, _ in try Model.decision(.ask, text: promise) }
    let fallback = try await BorgVRAssistantCore(workspace: workspace, model: stillMisleading, knowledge: knowledge,
                                                 imagesAllowed: false).run(goal)
    try check(fallback.applied == 0 && !fallback.awaitingAnswer && fallback.text != promise && stillMisleading.reviewed == 2,
              "the false announcement escaped review or was retried without a limit")
  }

  private static func testReadEvidenceHandoff(_ knowledge: AssistantKnowledge) async throws {
    for readTwice in [false, true] {
      let workspace = Workspace()
      let reply = "No measurements were saved."
      let model = Model(review: { _, _, draft in draft == reply ? .accept : .revise }) { step, input in
        let context = try VoiceAgentPolicy.decode(input.context)
        let events = context["events"] as? [[String: Any]] ?? []
        let notes = context["decision_notes"] as? [String] ?? []
        switch step {
          case 0: return try Model.decision(.finish, text: "I will list the measurements.")
          case 1:
            try check(notes.contains { $0.contains("draft was rejected") }, "missing active repair instruction")
            return try Model.decision(.investigate, "list_measurements")
          default:
            let observation = events.first { $0["operation"] as? String == "list_measurements" }
            let result = observation?["result"] as? [String: Any]
            try check(observation?["status"] as? String == "observation_returned" &&
                      (result?["measurements"] as? [Any])?.isEmpty == true &&
                      events.allSatisfy { $0["operation"] as? String != "unconfirmed_reply" } &&
                      notes.contains { $0.contains("An empty result can be the answer") } &&
                      !notes.contains { $0.contains("draft was rejected") } && !input.finalReplyOnly,
                      "the read did not retire repair context, preserve evidence or allow another investigation")
            if step == 2 && readTwice { return try Model.decision(.investigate, "get_transfer_function") }
            if readTwice {
              try check(events.last?["operation"] as? String == "get_transfer_function",
                        "the second investigation did not reach the decision loop")
            }
            return try Model.decision(.finish, text: reply)
        }
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                                imagesAllowed: false).run("Which measurements are saved?")
      try check(result.text == reply && result.applied == 0 && !result.awaitingAnswer && workspace.measurementReads == 1,
                "the read-only task failed to finish or made a change")
    }
  }

  private static func testTransferReadHandoff(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    let original = (0..<4096).map { [100 + $0 % 156, 200, 210, 255] }
    workspace.transferFunction = original
    let model = Model { step, input in
      if step == 0 { return try Model.decision(.investigate, "get_transfer_function", ["channel": 0]) }
      let context = try VoiceAgentPolicy.decode(input.context)
      let events = context["events"] as? [[String: Any]] ?? []
      let observation = events.last
      let result = observation?["result"] as? [String: Any]
      let samples = result?["samples"] as? [[Int]] ?? []
      try check(observation?["operation"] as? String == "get_transfer_function" &&
                observation?["result_truncated"] == nil && result?["samplesArePreview"] as? Bool == true &&
                result?["originalSampleCount"] as? Int == original.count &&
                samples.count == VoiceAgentPolicy.maximumTransferPreviewSamples &&
                samples.first == original.first && samples.last == original.last,
                "A TF read with long RGBA rows was not passed back as a complete structured preview")
      return try Model.decision(.finish, text: "The curve was read.")
    }
    let outcome = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                               imagesAllowed: false).run("Read the current transfer function.")
    try check(outcome.applied == 0 && workspace.transferFunction == original, "Reading the TF changed it")
  }

  private static func testReplyRepairAfterObservation(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    workspace.sweepImage = { step in try Workspace.image(visible: true, gray: (step / 25).isMultiple(of: 2) ? 0.2 : 0.7) }
    let firstAnnouncement = "Ich suche zuerst das Intensitätsband."
    let secondAnnouncement = "Ich prüfe noch die übrigen Vorschauen."
    let report = "Ich konnte die Zielstruktur nicht sicher erkennen und habe nichts verändert."
    var initialPreviewIDs: Set<String> = []
    let model = Model(review: { _, kind, draft in
      if kind == .ask && [firstAnnouncement, secondAnnouncement].contains(draft) { return .revise }
      try check(kind == .finish && draft == report, "unexpected draft reached the reviewer")
      return .accept
    }) { step, input in
      let repairing = input.context.contains("Your last reply draft was rejected")
      try check(repairing == [1, 3].contains(step), "the correction was not scoped to the current progress state")
      switch step {
        case 0:
          return try Model.decision(.ask, text: firstAnnouncement,
                                    route: .init(method: "visibility.tf", directive: "ändere die TF"))
        case 1: return try Model.decision(.investigate, "inspect.intensity_bands")
        case 2:
          initialPreviewIDs = Set(input.images.map(\.id))
          try check(!initialPreviewIDs.isEmpty && !workspace.scans.isEmpty, "the first correction did not perform the investigation")
          return try Model.decision(.ask, text: secondAnnouncement)
        case 3: return try Model.decision(.investigate, "inspect.previews")
        case 4:
          try check(!input.images.isEmpty && initialPreviewIDs.isDisjoint(with: input.images.map(\.id)),
                    "the second correction did not receive new evidence")
          return try Model.decision(.finish, text: report)
        default: throw Failure.unexpected("the reply repair retried without a bound")
      }
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                               imagesAllowed: true).run("ändere die TF so dass die Haut undurchsichtig ist")
    try check(result.text == report && !result.awaitingAnswer && result.applied == 0 &&
              workspace.componentChanges.isEmpty && model.reviewed == 3,
              "a rejected draft from before the sweep ended a later investigation")
  }

  private static func testReplyReviewKnowsAvailableObservations(_ knowledge: AssistantKnowledge) async throws {
    let goal = "ändere die TF so dass nur die knochen sichtbar sind"
    let confirmation = "Soll ich die Intensitätsbänder untersuchen?"
    let userQuestion = "Kannst du die gewünschte Struktur in der aktuellen Ansicht beschreiben?"
    let report = "Ich habe die Vorschauen geprüft, konnte das Ziel aber nicht sicher erkennen. Ich habe nichts verändert."
    for imagesAllowed in [true, false] {
      let workspace = Workspace()
      let model = Model(review: { _, kind, draft in
        if draft == confirmation { return .revise }
        try check((imagesAllowed && kind == .finish && draft == report) ||
                  (!imagesAllowed && kind == .ask && draft == userQuestion), "the reply fabricated a result or unnecessary approval")
        return .accept
      }) { step, input in
        switch step {
          case 0: return try Model.decision(.ask, text: confirmation,
                                             route: .init(method: "visibility.tf", directive: "ändere die TF"))
          case 1:
            try check(input.context.contains("Do not ask for extra confirmation"),
                      "the corrected decision did not distinguish observation from approval")
            return imagesAllowed ? try Model.decision(.investigate, "inspect.intensity_bands") :
                                   try Model.decision(.ask, text: userQuestion)
          default: return try Model.decision(.finish, text: report)
        }
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                                 imagesAllowed: imagesAllowed).run(goal)
      let firstReview = model.reviewedObservations.first ?? []
      try check(firstReview.contains { $0.operation == "list_measurements" } &&
                !firstReview.contains { $0.operation == "rotate_view" || $0.operation == "set_transfer_function_component" },
                "the reviewer must see off-path observations but not mutations")
      if imagesAllowed {
        let initial = firstReview.first { $0.operation == "inspect.intensity_bands" }
        let later = model.reviewedObservations.last?.first { $0.operation == "inspect.intensity_bands" }
        try check(initial?.attempted == false && !(initial?.description.isEmpty ?? true) && later?.attempted == true &&
                  result.text == report && !result.awaitingAnswer && result.applied == 0 && !workspace.scans.isEmpty,
                  "the reviewer could not distinguish an available observation from one already attempted")
        let input = try VoiceAgentModelClient.replyReviewInput(request: goal, kind: .ask, draft: confirmation,
                                                               observations: firstReview, visualEvidenceShown: false)
        let context = try VoiceAgentPolicy.decode(input.context)
        let raw = context["available_read_only_observations"] as? [[String: Any]] ?? []
        try check(input.images.isEmpty && context["visual_evidence_shown"] as? Bool == false &&
                  raw.contains { $0["operation"] as? String == "inspect.intensity_bands" && $0["attempted"] as? Bool == false },
                  "the review request did not transmit availability and attempt state")
      } else {
        try check(!firstReview.contains { $0.operation == "inspect.intensity_bands" || $0.operation == "capture_screenshot" } &&
                  result.awaitingAnswer && result.text == userQuestion && workspace.scans.isEmpty,
                  "reply review treated disabled image sharing as permission to investigate")
      }
    }
  }

  private static func testUnsupportedClaimAndActionAnnouncement(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    let catalogLabel = "Rotor only"
    workspace.datasetDescription = catalogLabel
    let unsupported = "The catalog says rotor only, so the mounting bracket is not in the volume."
    let announcement = "The preview shows the bracket. I will adjust its opacity."
    let reported = "I adjusted the transfer function and checked the view."
    let model = Model(review: { _, _, draft in
      if draft == unsupported { return .unsupportedContentClaim }
      if draft == announcement { return .actionInText }
      throw Failure.unexpected("Unexpected draft sent to the reviewer")
    }) { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      switch step {
        case 0:
          let state = context["state"] as? [String: Any]
          let dataset = state?["dataset"] as? [String: Any]
          try check(dataset?["description"] as? String == catalogLabel && input.images.isEmpty &&
                    input.system.contains("do not establish what structures the loaded samples contain"),
                    "catalog provenance was not distinguished from render evidence")
          return try Model.decision(.finish, text: unsupported)
        case 1:
          try check(context["reply_review"] as? String == "unsupported_content_claim" && !input.allowsFinish,
                    "a catalog-only content claim did not trigger a bounded repair decision")
          return try Model.decision(.investigate, "inspect.intensity_bands")
        case 2:
          try check(input.allowsFinish && !input.images.isEmpty && context["reply_review"] == nil,
                    "new observation should retire the previous correction")
          return try Model.decision(.finish, text: announcement)
        case 3:
          try check(context["reply_review"] as? String == "action_in_text" && !input.allowsFinish && !input.images.isEmpty,
                    "the action correction lost the sweep evidence or left the finish branch open")
          let local = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "local"), as: UTF8.self))
          let grammar = (local["structured_outputs"] as? [String: String])?["grammar"] ?? ""
          try check(grammar.contains(#"colon "\"ask\"" comma"#) && !grammar.contains(#""\"finish\"""#),
                    "vLLM still allows finish during an action correction")
          let cloud = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "cloud", provider: .openAI), as: UTF8.self))
          let format = (cloud["text"] as? [String: Any])?["format"] as? [String: Any]
          let schema = format?["schema"] as? [String: Any]
          let kind = (schema?["properties"] as? [String: [String: Any]])?["kind"]
          try check(kind?["enum"] as? [String] == ["investigate", "apply", "ask"],
                    "OpenAI still allows finish during an action correction")
          return try Model.decision(.apply, "set_transfer_function_component",
                                    ["channel": 0, "component": 3, "points": [[0, 0], [0.24, 1], [1, 1]]])
        case 4: return try Model.decision(.investigate, "capture_screenshot")
        case 5:
          try check(input.allowsFinish && input.images.map(\.id) == ["current_render"], "finish was not restored after real progress")
          return try Model.decision(.finish, text: reported)
        default: throw Failure.unexpected("Unexpected extra decision")
      }
    }
    let goal = "Change the transfer function so the mounting bracket is visible."
    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                              imagesAllowed: true).run(goal)
    try check(result.text == reported && result.applied == 1 && workspace.componentChanges.count == 1 &&
              model.reviewedVisualEvidence == [false, true], "the draft drove execution without a separate validated action")

    let noImageWorkspace = Workspace()
    let noImageModel = Model(review: { _, _, draft in draft == unsupported ? .unsupportedContentClaim : .accept }) { step, input in
      if step == 0 { return try Model.decision(.finish, text: unsupported) }
      try check(input.allowsFinish && input.images.isEmpty, "a content correction should not require an unavailable image")
      return try Model.decision(.finish, text: "I cannot verify that from the catalog alone.")
    }
    let noImageResult = try await BorgVRAssistantCore(workspace: noImageWorkspace, model: noImageModel,
                                                     knowledge: knowledge, imagesAllowed: false).run(goal)
    try check(noImageResult.applied == 0 && noImageResult.text.contains("cannot verify"),
              "an honest limitation was not allowed without image access")
  }

  private static func testStepText(_ knowledge: AssistantKnowledge) async throws {
    let wire = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"kind\":\"investigate\",\"operation\":\"list_measurements\",\"arguments\":{},\"text\":\"I will read the saved measurements.\"}"}}]}"#
    let parsed = try VoiceAgentModelClient.decision(from: Data(wire.utf8), provider: .vllm)
    let actionGrammar = try AssistantDecision.vllmGrammar(operations: ["list_measurements"]).split(separator: "\n")
      .first { $0.hasPrefix("action ::=") } ?? ""
    try check(parsed.text == "I will read the saved measurements." && actionGrammar.contains(#"(comma "\"text\"" colon string)?"#),
              "VLLM does not accept optional action text")

    for length in VoiceAgentResponseLength.allCases {
      let workspace = Workspace()
      let model = Model(review: { _, _, _ in .actionInText }) { step, input in
        let context = try VoiceAgentPolicy.decode(input.context)
        try check(context["response_length"] as? String == length.guidance &&
                  input.system.contains("Do not add or suppress progress updates"),
                  "response length was not sent as a text-only preference")
        switch step {
          case 0: return try Model.decision(.finish, text: "Not a completed answer.")
          case 1: return try Model.decision(.apply, "set_bounding_box", ["visible": "yes"], text: "Rejected arguments.")
          case 2: return try Model.decision(.investigate, "list_measurements", text: "  I will read\n the measurements. ")
          case 3: return try Model.decision(.investigate, "list_measurements", text: "Repeated observation.")
          case 4: return try Model.decision(.apply, "set_bounding_box", ["visible": true], text: String(repeating: "x", count: 300))
          default: return try Model.decision(.finish, text: "Finished.")
        }
      }
      var steps: [String] = [], messages: [String] = []
      let core = BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: false)
      let result = try await core.run("Read the saved measurements and show the bounding box.",
                                      responseLength: length, progress: { operation, text in
        steps.append(operation)
        if let text { messages.append(text) }
      })
      try check(result.text == "Finished." && result.applied == 1 && steps == ["list_measurements", "list_measurements", "set_bounding_box"] &&
                messages == ["I will read the measurements.", "Repeated observation.", String(repeating: "x", count: length == .concise ? 140 : 280)],
                "Only dispatched steps should publish progress, independent of response length")
    }
  }

  private static func testConfirmedChanges(_ knowledge: AssistantKnowledge) async throws {
    let args: [String: Any] = ["axis": [0, 1, 0], "degrees": 90]
    let goal = "Drehe den Datensatz um 90 Grad."
    for accepted in [true, false] {
      let workspace = Workspace()
      workspace.acceptsRotation = accepted
      let model = Model(intake: { [.init(kind: $0 == goal ? .task : .answer, text: $0)] }) { step, input in
        switch step {
          case 0: return try Model.decision(.ask, text: "Um welche Achse?")
          case 1:
            try check(!input.context.contains("what you just changed"), "receipt instructions leaked into action planning")
            return try Model.decision(.apply, "rotate_view", args)
          default:
            let context = try VoiceAgentPolicy.decode(input.context)
            let events = context["events"] as? [[String: Any]] ?? []
            let receipts = events.filter { $0["status"] as? String == "confirmed_change" }
            if accepted {
              try check(input.context.contains("what you just changed"), "receipt instructions did not describe a fresh change")
              let recorded = receipts.first?["arguments"] as? [String: Any]
              try check(receipts.count == step - 1 && receipts.first?["operation"] as? String == "rotate_view" &&
                        recorded?["degrees"] as? Int == 90 && recorded?["axis"] as? [Int] == [0, 1, 0],
                        "the final decision did not receive the confirmed arguments")
              if step == 2 { return try Model.decision(.apply, "rotate_view", args) }
            } else {
              try check(receipts.isEmpty, "a rejected action received a confirmation")
            }
            return try Model.decision(.finish, text: accepted ? "Um die Y-Achse gedreht." : "Keine Drehung ausgeführt.")
        }
      }
      let core = BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: false)
      let asked = try await core.run(goal)
      try check(asked.awaitingAnswer && workspace.rotations.isEmpty, "the clarification caused a mutation")
      let result = try await core.run("Um die Y-Achse.", answering: asked.text)
      let expected = accepted ? 2 : 0
      try check(!result.awaitingAnswer && result.applied == expected && workspace.rotations.count == expected &&
                model.reviewed == (accepted ? 1 : 2),
                "the clarified action was replayed or falsely confirmed")
    }
  }

  private static func testTrialFindings(_ knowledge: AssistantKnowledge) async throws {
    let workspace = Workspace()
    var firstID: Int?
    let model = Model { step, input in
      let context = try VoiceAgentPolicy.decode(input.context)
      let events = context["events"] as? [[String: Any]] ?? []
      let findings = context["trial_findings"] as? [[String: Any]] ?? []
      let rotate: (Int) -> [String: Any] = { ["axis": [0, 1, 0], "degrees": $0] }
      switch step {
        case 0:
          try check(!input.allowsAssessment, "No attempt existed to assess")
          return try Model.decision(.apply, "rotate_view", rotate(1))
        case 1:
          let trial = events.last
          let view = trial?["view_change"] as? [String: Any]
          firstID = trial?["attempt_id"] as? Int
          try check(trial?["execution"] as? String == "applied" && firstID != nil && view?["before"] != nil &&
                    view?["after"] != nil && findings.isEmpty && input.allowsAssessment,
                    "Execution was not kept separate from the as-yet-unknown finding")
          let body = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture"), as: UTF8.self))
          let grammar = (body["structured_outputs"] as? [String: String])?["grammar"] ?? ""
          let cloud = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture", provider: .openAI), as: UTF8.self))
          let format = (cloud["text"] as? [String: Any])?["format"] as? [String: Any]
          let schema = (format?["schema"] as? [String: Any])?["properties"] as? [String: [String: Any]]
          try check(grammar.contains("assessment ::=") && schema?["assessment"] != nil,
                    "The finding is not accepted in the same model decision on both providers")
          return try Model.decision(.investigate, "capture_screenshot")
        case 2:
          try check(events.last?["execution"] as? String == "observed" &&
                    events.last?["image_ids"] as? [String] == ["current_render"] && findings.isEmpty,
                    "A result was mislabeled as a visual judgment")
          return try Model.decision(.apply, "rotate_view", rotate(-1),
                                    assessment: .init(attemptID: firstID!, outcome: .notHelpful, finding: "The control image is still oblique."))
        case 3...12:
          try check(findings.count == 1 && findings.first?["attempt_id"] as? Int == firstID &&
                    findings.first?["outcome"] as? String == "not_helpful" &&
                    findings.first?["view_change"] != nil,
                    "The finding vanished or was recorded as a failure")
          let invalid = step == 3
            ? AssistantDecision.Assessment(attemptID: 9999, outcome: .helpful, finding: "No such attempt.") : nil
          return try Model.decision(.apply, "rotate_view", rotate(1), assessment: invalid)
        default:
          try check(findings.count == 1 && events.allSatisfy { $0["attempt_id"] as? Int != firstID },
                    "The finding did not outlive the rolling event window")
          return try Model.decision(.finish, text: "Views compared.")
      }
    }
    let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                               imagesAllowed: true).run("Try a different view, then compare ten one-degree steps.")
    try check(result.applied == 12 && workspace.rotations.count == 12 && workspace.screenshots.count == 1 && model.step == 14,
              "The return or an intentional repeat was blocked, or assessment added a call")

    let reads = Workspace()
    reads.failNextMeasurementRead = true
    let reader = Model { step, input in
      if step > 0 {
        let context = try VoiceAgentPolicy.decode(input.context)
        let events = context["events"] as? [[String: Any]] ?? []
        try check(events.last?["execution"] as? String == (step == 1 ? "failed" : "observed"),
                  "The read failure and its successful retry were not distinguished")
        if step == 1 {
          try check(input.context.contains("timed out without a usable result"), "The model did not see the recoverable error")
        }
      }
      return step < 2 ? try Model.decision(.investigate, "list_measurements") : try Model.decision(.finish, text: "No measurements saved.")
    }
    _ = try await BorgVRAssistantCore(workspace: reads, model: reader, knowledge: knowledge,
                                     imagesAllowed: false).run("Read saved measurements.")
    try check(reads.measurementReads == 2 && reader.step == 3, "A failed read could not be retried")
  }

  private static func testGoalVerification(_ knowledge: AssistantKnowledge) async throws {
    let request = "Stelle die Vorderansicht ein."
    let rotate: (Int) -> [String: Any] = { ["axis": [1, 0, 0], "degrees": $0] }
    let wrong = AssistantDecision.GoalCheck(status: .unmet, finding: "Die sichtbaren Konturen zeigen eine Unteransicht.")
    let right = AssistantDecision.GoalCheck(status: .met, finding: "Die vorderen Merkmale sind frontal zu sehen.")
    for prematureFinish in [false, true] {
      let workspace = Workspace()
      let model = Model(fillsGoalCheck: false) { step, input in
        let context = try VoiceAgentPolicy.decode(input.context)
        try check(context["request"] as? String == request && !input.finalReplyOnly, "Verification lost the active goal")
        switch step {
          case 0:
            try check(!input.requiresGoalCheck, "A visual check was required before any image was available")
            return try Model.decision(.apply, "rotate_view", rotate(90))
          case 1:
            return try Model.decision(.investigate, "capture_screenshot")
          case 2:
            try check(input.requiresGoalCheck && input.images.map(\.id) == ["current_render"] &&
                        (context["events"] as? [[String: Any]])?.last?["execution"] as? String == "observed" &&
                        context["last_goal_check"] == nil, "Capturing an image was treated as confirming the goal")
            let local = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture"), as: UTF8.self))
            let cloud = try VoiceAgentPolicy.decode(String(decoding: VoiceAgentModelClient.body(input, model: "fixture", provider: .openAI), as: UTF8.self))
            let grammar = (local["structured_outputs"] as? [String: String])?["grammar"] ?? ""
            let format = (cloud["text"] as? [String: Any])?["format"] as? [String: Any]
            let schema = format?["schema"] as? [String: Any]
            try check(grammar.contains("ws goal_check comma") && grammar.contains("goal_check ::=") &&
                        (schema?["required"] as? [String])?.contains("goal_check") == true,
                      "Both providers must require a goal check with a live image")
            if prematureFinish {
              return try Model.decision(.finish, text: "Ich habe die Ansicht geprüft.", goalCheck: wrong)
            }
            return try Model.decision(.apply, "rotate_view", rotate(-90), goalCheck: wrong)
          case 3 where prematureFinish:
            let verification = context["last_goal_check"] as? [String: Any]
            try check(verification?["status"] as? String == "unmet" && verification?["finding"] as? String == wrong.finding &&
                        workspace.rotations.count == 1 && input.context.contains("choose a justified correction"),
                      "An explicit mismatch did not return to the executor")
            return try Model.decision(.apply, "rotate_view", rotate(-90), goalCheck: wrong)
          case let captureStep where captureStep == (prematureFinish ? 4 : 3):
            let verification = context["last_goal_check"] as? [String: Any]
            try check(!input.requiresGoalCheck && verification?["status"] as? String == "unmet" &&
                        workspace.rotations.count == 2 && input.context.contains("A subsequent command receipt is not a recheck"),
                      "The failed view blocked the correction or was misrepresented as evidence of the new view")
            return try Model.decision(.investigate, "capture_screenshot")
          default:
            try check(input.requiresGoalCheck && workspace.screenshots.count == 2, "The corrected view was not checked")
            return try Model.decision(.finish, text: "Vorderansicht eingestellt.", goalCheck: right)
        }
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: true).run(request)
      let checks = model.stateInputs.flatMap(\.updates).filter { $0["type"] as? String == "goal_check" }
      try check(result.text == "Vorderansicht eingestellt." && result.applied == 2 && model.step == (prematureFinish ? 6 : 5) &&
                  workspace.rotations.compactMap { $0["degrees"] as? Int } == [90, -90] &&
                  checks.compactMap { $0["status"] as? String } == ["unmet", "met"] &&
                  checks[0]["render_attempt_id"] as? Int != checks[1]["render_attempt_id"] as? Int,
                "The mismatch or confirmation was lost, or the ordinary path added an execution call")
    }

    for explicitBlock in [false, true] {
      let workspace = Workspace()
      var verification = wrong
      if explicitBlock { verification.blockedReason = "Mir fehlt ein erkennbares Merkmal, das die Korrekturrichtung vorgibt." }
      let model = Model(fillsGoalCheck: false) { step, _ in
        if step == 0 { return try Model.decision(.apply, "rotate_view", rotate(90)) }
        if step == 1 { return try Model.decision(.investigate, "capture_screenshot") }
        return try Model.decision(.finish, text: "Vorderansicht eingestellt.", goalCheck: verification)
      }
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: true).run(request)
      try check(result.text.contains(wrong.finding) && !result.text.contains("Vorderansicht eingestellt.") &&
                  model.step == (explicitBlock ? 3 : 4) && workspace.rotations.count == 1,
                "An unresolved view claimed success, retried indefinitely, or provoked an unjustified action")
    }

    let workspace = Workspace()
    let information = Model(fillsGoalCheck: false) { step, _ in
      step == 0 ? try Model.decision(.investigate, "capture_screenshot") :
        try Model.decision(.finish, text: "Du siehst den Datensatz von unten.",
                           goalCheck: .init(status: .notApplicable, finding: "Die Frage verlangt keine Änderung."))
    }
    let answer = try await BorgVRAssistantCore(workspace: workspace, model: information, knowledge: knowledge,
                                               imagesAllowed: true).run("Von wo sehe ich den Datensatz?")
    try check(answer.applied == 0 && workspace.rotations.isEmpty && information.step == 2,
              "The verification required a mutation for a read-only question")
  }

  private static func testDecisionFailures(_ knowledge: AssistantKnowledge) async throws {
    let cases: [(String, AssistantRunFailure)] = [
      (#"{"choices":[{"finish_reason":"length","message":{"content":"{\"operation\":\"synthetic_partial","reasoning":"synthetic_hidden"}}]}"#, .modelOutputLimit),
      (#"{"choices":[{"finish_reason":"stop","message":{"content":" "}}]}"#, .modelDecisionMissing),
      (#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"kind\":\"unknown\"}"}}]}"#, .modelDecisionInvalid),
      (#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"operation\":\"get_transfer_function\",\"arguments\":\"not JSON\",\"kind\":\"investigate\"}"}}]}"#, .modelDecisionInvalid),
      (#"{"choices":[{}]}"#, .modelResponseInvalid),
    ]
    for (response, failure) in cases {
      do {
        _ = try VoiceAgentModelClient.decision(from: Data(response.utf8), provider: .vllm)
        throw Failure.unexpected("invalid decision was accepted")
      } catch let error as AssistantRunFailure {
        try check(error == failure, "wrong decision failure class")
      }
    }
    let component = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"operation\":\"set_transfer_function_component\",\"arguments\":{\"channel\":0,\"component\":3,\"points\":[[0,0],[0.25,1],[1,1]]},\"kind\":\"apply\"}"}}]}"#
    let action = try VoiceAgentModelClient.decision(from: Data(component.utf8), provider: .vllm)
    let arguments = try VoiceAgentPolicy.decode(action.arguments ?? "{}")
    try check(action.kind == .apply && arguments["channel"] as? Int == 0 &&
              arguments["component"] as? Int == 3 && arguments["points"] as? [[Double]] == [[0,0],[0.25,1],[1,1]],
              "vLLM object arguments did not round-trip to the local argument validator")
    let withAssessment = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"kind\":\"apply\",\"operation\":\"rotate_view\",\"arguments\":{\"axis\":[0,1,0],\"degrees\":-1},\"assessment\":{\"attempt_id\":2,\"outcome\":\"not_helpful\",\"finding\":\"Still oblique.\"}}"}}]}"#
    let assessed = try VoiceAgentModelClient.decision(from: Data(withAssessment.utf8), provider: .vllm)
    try check(assessed.assessment?.attemptID == 2 && assessed.assessment?.outcome == .notHelpful &&
              assessed.operation == "rotate_view", "vLLM finding and next command did not decode together")
    for kind in [AssistantDecision.Kind.finish, .ask] {
      let model = Model { step, input in
        if step == 0 { return .init(kind: kind, operation: nil, arguments: nil, focus: nil, text: "  ") }
        try check(input.context.contains("did not contain text"), "An empty reply was not reported back to the model")
        return try Model.decision(kind, text: "Corrected answer.")
      }
      let workspace = Workspace()
      let result = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge,
                                                 imagesAllowed: false).run("Return a reply")
      try check(result.text == "Corrected answer." && workspace.changes.isEmpty && model.step == 2,
                "An empty reply reached the user or changed the dataset")
    }
    let malformed = Model { step, input in
      if step == 0 { throw AssistantRunFailure.modelDecisionInvalid }
      try check(input.context.contains("did not contain a usable structured decision"), "Parse error was not sent back for correction")
      return try Model.decision(.finish, text: "Valid reply.")
    }
    let repairWorkspace = Workspace()
    let repaired = try await BorgVRAssistantCore(workspace: repairWorkspace, model: malformed, knowledge: knowledge,
                                                 imagesAllowed: false).run("Return a reply")
    try check(repaired.text == "Valid reply.", "A parse error reached the user before correction")
    let offline = Model { _, _ in throw VoiceAgentError.connection }
    let offlineWorkspace = Workspace()
    do {
      _ = try await BorgVRAssistantCore(workspace: offlineWorkspace, model: offline, knowledge: knowledge,
                                       imagesAllowed: false).run("Return a reply")
      throw Failure.unexpected("a connection failure was swallowed")
    } catch VoiceAgentError.connection {}
    try check(offline.step == 1, "A connection failure was treated as a prompt correction")
    let workspace = Workspace()
    let incomplete = Model { step, input in
      if step > 0 { try check(input.context.contains("finish or ask with text"), "recovery only offered another tool") }
      return .init(kind: .apply, operation: nil, arguments: nil, focus: nil, text: nil)
    }
    do {
      _ = try await BorgVRAssistantCore(workspace: workspace, model: incomplete, knowledge: knowledge,
                                       imagesAllowed: false).run("Test repeated incomplete decision")
      throw Failure.unexpected("a stalled model unexpectedly succeeded")
    } catch AssistantRunFailure.modelStalled {}
    try check(incomplete.step == 3 && workspace.changes.isEmpty, "stalled decisions were executed or retried indefinitely")
  }

  private static func testTransferFunctionArgumentRepair(_ knowledge: AssistantKnowledge) async throws {
    let request = "Aendere die TF so, dass die Knochen sichtbar werden."
    let invalid: [String: Any] = ["channel": 0, "samples": [
      [0, 0, 0, 0], [0.1, 0, 0, 0], [0.101, 255, 255, 255], [0.6, 255, 255, 255], [0.601, 0, 0, 0], [1, 0, 0, 0],
    ]]
    let workspace = Workspace()
    var previewID: String?
    let model = Model { step, input in
      switch step {
        case 0:
          return try Model.decision(.investigate, "inspect.intensity_bands",
                                    route: .init(method: "visibility.tf", directive: nil))
        case 1:
          previewID = input.images.first?.id
          return try Model.decision(.apply, "set_transfer_function", invalid)
        case 2:
          let context = try VoiceAgentPolicy.decode(input.context)
          let last = (context["events"] as? [[String: Any]])?.last
          let result = last?["result"] as? String ?? ""
          guard let previewID else { throw Failure.unexpected("Sweep was not delivered") }
          try check(last?["execution"] as? String == "not_applied" && result.contains("arguments.samples[1][0]") &&
                    result.contains("expected an integer, got 0.1") && result.contains("[R,G,B,A]") &&
                    result.contains("0...255") && result.contains("row index, not a column") &&
                    result.contains("use apply_preview") && input.images.contains { $0.id == previewID } &&
                    workspace.transferFunction == Workspace.originalTF,
                    "The actual malformed request did not return a precise, recoverable error")
          return try Model.decision(.apply, "apply_preview", ["id": previewID])
        default:
          return try Model.decision(.finish, text: "Die Vorschau wurde angewendet.")
      }
    }
    let outcome = try await BorgVRAssistantCore(workspace: workspace, model: model, knowledge: knowledge, imagesAllowed: true).run(request)
    try check(outcome.applied == 1 && model.step == 4 && workspace.changes.count == workspace.scans.count + 2 &&
              workspace.transferFunction != Workspace.originalTF, "The model could not recover without another sweep")

    let repeatedWorkspace = Workspace()
    let repeated = Model { step, input in
      if step > 0 {
        let context = try VoiceAgentPolicy.decode(input.context)
        let last = (context["events"] as? [[String: Any]])?.last
        let result = last?["result"] as? String ?? ""
        try check(result.contains("arguments.samples[1][0]") && !result.contains("apply_preview"),
                  "The repair did not identify the error or suggested an unavailable preview")
      }
      return try Model.decision(.apply, "set_transfer_function", invalid)
    }
    let declined = try await BorgVRAssistantCore(workspace: repeatedWorkspace, model: repeated, knowledge: knowledge, imagesAllowed: false).run(request)
    try check(declined.applied == 0 && declined.text == "I could not find valid parameters for the requested change." &&
              repeated.step == 3 && repeatedWorkspace.changes.isEmpty, "Repeated safe rejections surfaced as a thrown error or ran a change")
  }

  private static func testModelList() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ModelAPIFixture.self]
    let cloud = try VoiceAgentEndpoint("https://api.openai.com")
    func client(_ token: String, selected: String = "") -> VoiceAgentModelClient {
      .init(endpoint: cloud, token: token, session: URLSession(configuration: config),
            provider: .openAI, configuredModel: selected)
    }

    let draft = client("draft-key", selected: "gpt-manual")
    let choices = try await draft.listOpenAIModels()
    try check(choices == ["gpt-5.4-mini-2026-03-17", "gpt-6.2-sol"], "picker did not intersect available and documented compatible IDs")
    try check(draft.model == "gpt-manual", "fetch replaced the model selection")
    let empty = try await client("incompatible-key").listOpenAIModels()
    try check(empty.isEmpty, "picker offered an incompatible fallback")
    do {
      _ = try await client("forbidden-key").listOpenAIModels()
      throw Failure.unexpected("a refused list request succeeded")
    } catch VoiceAgentError.connection {}

    let verified = try await client("vision-key", selected: "gpt-manual").testConnection()
    try check(verified == "gpt-manual", "an unlisted model could not be tested")
    do {
      _ = try await client("wrong-color", selected: "gpt-manual").testConnection()
      throw Failure.unexpected("structured response without the expected image result was accepted")
    } catch VoiceAgentError.protocolViolation {}

    let local = VoiceAgentModelClient(endpoint: try VoiceAgentEndpoint("https://vllm.example"), token: "local-key",
                                      session: URLSession(configuration: config))
    let model = try await local.discover()
    try check(model == "Qwen/local", "vLLM discovery did not keep the first served ID")
  }
}
