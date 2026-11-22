import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Security
import AVFoundation
import Combine
import simd
@testable import BorgVR

private enum Failure: Error { case failed(String) }
private func expect(_ condition: Bool, _ message: String) throws {
  if !condition { throw Failure.failed(message) }
}
private func rejects(_ block: () throws -> Void) throws {
  do { try block() } catch { return }
  throw Failure.failed("Invalid input was accepted")
}

@MainActor
@main
struct VoiceAgentTests {
  static func main() async throws {
    for address in ["https://ai1", "https://192.168.1.50:8766", "wss://localhost:8766/"] {
      let endpoint = try VoiceAgentEndpoint(address)
      try expect(endpoint.socket.scheme == "wss" && endpoint.socket.path == "/v1/session", "Invalid endpoint")
    }
    for address in ["http://ai1", "https://user:token@ai1", "https://ai1/path", "https://ai1?token=x",
                    "https://ai1#fragment", "https://0.0.0.0", "https://ai1:0", "https://ai1:99999"] {
      try rejects { _ = try VoiceAgentEndpoint(address) }
    }
    try rejects { try VoiceAgentEndpoint.validateToken("short") }
    try rejects { try VoiceAgentEndpoint.validateToken(String(repeating: "a", count: 64) + "\r\nInjected") }
    var ledger = VoiceAgentCallLedger()
    try expect(try ledger.begin(id: "call", signature: "original") == nil, "First call already cached")
    try expect(try ledger.begin(id: "call", signature: "original")?.reply == nil, "Pending replay has a result")
    try ledger.finish(id: "call", reply: "actual-result")
    try expect(try ledger.begin(id: "call", signature: "original")?.reply == "actual-result", "Lost cached result")
    try rejects { _ = try ledger.begin(id: "call", signature: "changed-arguments") }

    let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
    let ready = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("ready.json"))) as! [String: Int]
    let cert = try Data(contentsOf: fixture.appendingPathComponent("runtime/tls/server.crt"))
    let der = try VoiceAgentTLS.certificateData(cert)
    try rejects { _ = try VoiceAgentTLS.certificateData(Data("not a certificate".utf8)) }
    let certificate = SecCertificateCreateWithData(nil, der as CFData)!
    var trust: SecTrust?
    SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "localhost" as CFString), &trust)
    let tls = VoiceAgentTLS(endpoint: try VoiceAgentEndpoint("https://localhost"), anchor: der)
    try expect(tls.accepts(trust!, host: "localhost"), "Pinned local TLS certificate rejected")
    var ipTrust: SecTrust?
    SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &ipTrust)
    let ipTLS = VoiceAgentTLS(endpoint: try VoiceAgentEndpoint("https://127.0.0.1"), anchor: der)
    try expect(ipTLS.accepts(ipTrust!, host: "127.0.0.1"), "Pinned IP TLS certificate rejected")
    try expect(!tls.accepts(trust!, host: "wrong.example.org"), "Wrong host accepted")
    let bad = VoiceAgentTLS(endpoint: try VoiceAgentEndpoint("https://wrong.example.org"), anchor: der)
    try expect(!bad.accepts(trust!, host: "wrong.example.org"), "Certificate hostname was not verified")
    let system = VoiceAgentTLS(endpoint: try VoiceAgentEndpoint("https://localhost"), anchor: Data())
    var untrusted: SecTrust?
    SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "localhost" as CFString), &untrusted)
    try expect(!system.accepts(untrusted!, host: "localhost"), "Untrusted self-signed certificate accepted")

    let metadata = try BORGVRMetaData(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    let app = AppModel(), parameters = RenderingParameters(), appSettings = AppSettings()
    let entry = AppModel.DatasetEntry(identifier: CommandLine.arguments[1], description: "Synthetic agent test",
      source: .local, uniqueId: metadata.uniqueID)
    app.openDataset(entry, automaticallyLoadState: false)
    guard case .opening(_, let openingID) = app.datasetSessionState else { fatalError() }
    app.prepareDatasetRenderer(key: app.activeDatasetRenderKey, metadata: metadata, requestID: openingID)
    _ = app.markRenderedDataset(key: app.activeDatasetRenderKey, requestID: openingID)
    app.recordCompletedRenderFrame(datasetKey: app.activeDatasetRenderKey, missingBrickCount: 0)
    let session = ScreenBorgVRSession.screen(appModel: app, renderingParameters: parameters, appSettings: appSettings)
    let service = BorgVRScreenCommandService(session: session)
    let scaledMeasurement = BorgVRMeasurementCommandState(id: UUID(), name: "Anisotropic scale", kind: .length,
      points: [.init(id: UUID(), position: .zero), .init(id: UUID(), position: SIMD3(0.25, 0.5, 0))])
    let scaledValue = try scaledMeasurement.measurement(physicalExtent: SIMD3(2, 3, 4)).geometry.value
    try expect(abs((scaledValue ?? -1) - sqrt(2.5)) < 1e-6, "Measurement scaling ignored anisotropic physical extents")
    var boneMetadata = BorgVRMCPDatasetMetadata(metadata)
    boneMetadata.longDescription = "Synthetic bone and skull test volume"
    boneMetadata.meta = "Knochen https://private.example/?token=secret /Users/private/scan.data"
    boneMetadata.provenance = [.init("Donated test bones")]
    let bone = BorgVRMCPDatasetCatalogEntry(id: entry.uniqueId, description: "Bone test", metadata: boneMetadata,
      metadataError: nil, sources: [.init(kind: "remote", address: "private.example", port: 9999, passwordProtected: true)])
    let secondBone = BorgVRMCPDatasetCatalogEntry(id: "second-bone", description: "Bone second", metadata: boneMetadata,
      metadataError: nil, sources: [])
    let missing = BorgVRMCPDatasetCatalogEntry(id: "missing", description: "Unknown", metadata: nil,
      metadataError: "Private /Users/secret", sources: [])
    let search = BorgVRDatasetSearch()
    let firstPage = try await search.search(query: "BONE", limit: 1, cursor: nil) { [bone, secondBone, missing] }
    try expect(firstPage["totalMatches"] as? Int == 2 && firstPage["metadataUnavailableCount"] as? Int == 1,
               "Metadata search counted the wrong matches or hid missing metadata")
    let cursor = firstPage["nextCursor"] as! String
    let nextPage = try await search.search(query: "BONE", limit: 1, cursor: cursor) { throw Failure.failed("Reloaded a paginated snapshot") }
    try expect(nextPage["hasMore"] as? Bool == false, "Search pagination did not terminate")
    let safeResult = try await search.search(query: "Knöchen", limit: 20, cursor: nil) { [bone] }
    let safeJSON = try VoiceAgentPolicy.encoded(safeResult)
    try expect(!safeJSON.contains("private.example") && !safeJSON.contains("/Users/") && !safeJSON.contains("token=secret") &&
               safeResult["totalMatches"] as? Int == 1, "Search leaked connection data or failed accent-insensitive matching")
    let router = BorgVRMCPToolRouter(commandService: service)
    var commandEvents: [BorgVRCommandEvent] = []
    let commandObservation = session.commandEvents.sink { commandEvents.append($0) }
    defer { commandObservation.cancel() }
    let bridge = BorgVRVoiceAgentBridge(service: service) {
      .init(datasetID: entry.uniqueId, openingID: openingID, editStateID: nil)
    }
    var manualChanges: [VoiceAgentApplicationChange] = []
    let changesObservation = bridge.changes.sink { manualChanges.append($0) }
    defer { changesObservation.cancel() }
    _ = try await bridge.executeTool(name: "rotate_view", arguments: ["axis": [0, 1, 0], "degrees": 5], validateContext: {})
    try expect(!commandEvents.isEmpty && manualChanges.isEmpty, "Agent's own command was mistaken for a human change")
    try service.rotate(axis: [0, 1, 0], degrees: 5)
    try expect(manualChanges.count == 1 && manualChanges[0].domain == "transform", "Manual command missing without GSC recording")
    session.publishRenderSnapshot()
    session.publishRenderSnapshot()
    try expect(manualChanges.count == 1, "Unchanged render snapshots duplicated a manual command")
    parameters.pan.x += 0.01
    session.publishRenderSnapshot()
    try expect(manualChanges.count == 2, "Legacy manual input was not observed")
    session.publishRenderSnapshot()
    try expect(manualChanges.count == 2, "Legacy mutation was reported twice")
    var restoredTransform = session.currentSnapshot().transform
    restoredTransform.translation.x += 0.02
    try session.perform(.setTransform(restoredTransform), source: .stateRestore)
    session.publishRenderSnapshot()
    try expect(manualChanges.count == 2, "Automatic state restore was reported as a human intervention")
    let lifecycleStart = commandEvents.count
    do {
      try await session.performAction(.discardVolumeEdits, source: .userInterface) { () async throws -> Void in
        MainActor.preconditionIsolated()
        try expect(BorgVRCommandExecutionContext.executingAction && BorgVRCommandExecutionContext.source == .userInterface,
                   "Async action lost its task-local command context")
        await Task.yield()
        MainActor.preconditionIsolated()
        try expect(BorgVRCommandExecutionContext.executingAction && BorgVRCommandExecutionContext.source == .userInterface,
                   "Async action lost its command context after suspension")
        throw Failure.failed("Synthetic edit failure")
      }
      throw Failure.failed("Failed action was swallowed")
    } catch Failure.failed(let message) {
      try expect(message == "Synthetic edit failure", "Wrong async action failure")
    }
    let lifecycle = Array(commandEvents.dropFirst(lifecycleStart))
    try expect(lifecycle.count == 2 && lifecycle[0].phase == .began && lifecycle[1].phase == .failed &&
               lifecycle[0].id == lifecycle[1].id, "Manual async action did not publish a paired lifecycle")
    let resolvedStart = commandEvents.count
    try await session.performResolvedAction(.discardVolumeEdits, source: .mcp) {
      MainActor.preconditionIsolated()
      try expect(BorgVRCommandExecutionContext.executingAction && BorgVRCommandExecutionContext.source == .mcp,
                 "Resolved action lost its task-local command context")
      await Task.yield()
      MainActor.preconditionIsolated()
      try expect(BorgVRCommandExecutionContext.executingAction && BorgVRCommandExecutionContext.source == .mcp,
                 "Resolved action lost its command context after suspension")
      return .discardVolumeEdits
    }
    let resolvedLifecycle = Array(commandEvents.dropFirst(resolvedStart))
    try expect(resolvedLifecycle.count == 2 && resolvedLifecycle[0].phase == .began &&
               resolvedLifecycle[1].phase == .committed && resolvedLifecycle[0].id == resolvedLifecycle[1].id &&
               resolvedLifecycle.allSatisfy { $0.source == .mcp }, "Resolved action lost its lifecycle or source")
    try expect(!BorgVRCommandExecutionContext.executingAction && BorgVRCommandExecutionContext.source == .userInterface,
               "Async action leaked task-local context to its caller")
    let recorder = WorkflowDemonstrationRecorder()
    let demonstrationContext = VoiceAgentContext(datasetID: entry.uniqueId, openingID: openingID, editStateID: nil)
    let demonstrationObservation = bridge.demonstrationActions.sink { action in
      recorder.record(action, context: demonstrationContext)
    }
    defer { demonstrationObservation.cancel() }
    recorder.start(goal: .inspectValues, context: demonstrationContext)
    _ = try await bridge.executeTool(name: "rotate_view", arguments: ["axis": [0, 1, 0], "degrees": 1], validateContext: {})
    try session.perform(.setTransform(session.currentSnapshot().transform), source: .stateRestore)
    try await session.performAction(.discardVolumeEdits, source: .mcp) { () async throws -> Void in await Task.yield() }
    do {
      try await session.performAction(.discardVolumeEdits, source: .userInterface) { () async throws -> Void in
        await Task.yield()
        throw Failure.failed("Rejected demonstration action")
      }
    } catch Failure.failed("Rejected demonstration action") {}
    recorder.finish()
    try expect(recorder.completed == nil, "Demonstration captured an agent, restore, MCP or failed command")
    recorder.start(goal: .inspectValues, context: demonstrationContext)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 1), source: .mouse)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 2), source: .userInterface)
    recorder.finish(outcome: .reached)
    guard let demonstration = recorder.completed else { throw Failure.failed("Manual demonstration was not recorded") }
    let record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(demonstration)) as? [String: Any]
    try expect(demonstration.actions == [.transform] && demonstration.goal == .inspectValues &&
               demonstration.outcome == .reached && Set(record?.keys.map { $0 } ?? []) ==
                 ["version", "id", "goal", "actions", "outcome", "end"],
               "Demonstration did not coalesce steps or exported private fields")
    recorder.discard()
    guard let viewBefore = bridge.workflowViewEvidence() else {
      throw Failure.failed("Ready renderer did not expose allowed view settings")
    }
    let evidenceObservation = bridge.demonstrationEvidenceInvalidations.sink { recorder.invalidateEvidence() }
    defer { evidenceObservation.cancel() }
    recorder.start(goal: .exposeRegion, context: demonstrationContext, before: viewBefore)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 5), source: .mouse)
    guard let viewAfter = bridge.workflowViewEvidence() else { throw Failure.failed("Missing final view settings") }
    recorder.finish(after: viewAfter)
    guard let detailed = recorder.completed else { throw Failure.failed("Missing opt-in demonstration") }
    let detailRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detailed)) as? [String: Any]
    let pair = detailRecord?["evidence"] as? [String: [String: Any]]
    try expect(detailed.version == 2 && detailed.evidence?.before == viewBefore &&
               detailed.evidence?.after == viewAfter && viewBefore != viewAfter &&
               Set(pair?.keys.map { $0 } ?? []) == ["before", "after"] &&
               Set(pair?["before"]?.keys.map { $0 } ?? []) == ["clip_minimum", "clip_maximum", "rotation"],
               "Opt-in demonstration did not contain exactly the permitted view settings")
    recorder.discard()
    recorder.start(goal: .exposeRegion, context: demonstrationContext, before: viewBefore)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 5), source: .mouse)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 10), source: .mcp)
    recorder.finish(after: bridge.workflowViewEvidence())
    try expect(recorder.completed?.version == 1 && recorder.completed?.evidence == nil,
               "Foreign command was included in the evidence pair")
    recorder.discard()
    recorder.start(goal: .exposeRegion, context: demonstrationContext, before: viewBefore)
    recorder.record(.clipping, context: demonstrationContext)
    recorder.record(.volume, context: nil)
    try expect(!recorder.active && recorder.completed?.end == .interrupted &&
               recorder.completed?.actions == [.clipping] && recorder.completed?.evidence == nil,
               "Capture crossed a dataset boundary")
    recorder.discard()
    recorder.start(goal: .exposeRegion, context: demonstrationContext)
    for index in 0...WorkflowDemonstrationRecorder.maximumActions {
      recorder.record(index.isMultiple(of: 2) ? .transform : .clipping, context: demonstrationContext)
    }
    try expect(!recorder.active && recorder.completed?.end == .limit &&
               recorder.completed?.actions.count == WorkflowDemonstrationRecorder.maximumActions, "Capture was unbounded")
    let before = session.currentSnapshot().transform
    do {
      _ = try await router.callTool(name: "rotate_view", arguments: ["axis": [0, 1, 0], "degrees": 30],
                                   validateContext: { throw VoiceAgentError.contextChanged })
      throw Failure.failed("Stale agent context was dispatched")
    } catch is VoiceAgentError {}
    try expect(session.currentSnapshot().transform == before, "Context check happened after mutation")
    let definitions = router.toolDefinitions + VoiceAgentPolicy.importCatalog
    let catalog = VoiceAgentPolicy.catalog(definitions, vision: false, transferFunctions: true, images: true)
    let applicationCatalog = VoiceAgentPolicy.catalog(definitions, vision: false,
      transferFunctions: true, images: true, datasetReady: false)
    let diagnosticTools = VoiceAgentPolicy.wireCatalog(catalog + applicationCatalog.filter {
      VoiceAgentPolicy.conversionTools.contains($0["name"] as? String ?? "")
    }, typed: false)
    let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BorgVRAgentServer/diagnostic_catalog.json")
    if ProcessInfo.processInfo.environment["BORGVR_WRITE_AGENT_CATALOG"] == "1" {
      try JSONSerialization.data(withJSONObject: diagnosticTools, options: [.sortedKeys, .prettyPrinted]).write(to: catalogURL)
    }
    let diagnosticCatalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
    try expect(try JSONSerialization.data(withJSONObject: diagnosticTools, options: [.sortedKeys]) ==
      JSONSerialization.data(withJSONObject: diagnosticCatalog, options: [.sortedKeys]),
      "Server diagnostic catalog differs from the native tools")
    let names = Set(diagnosticTools.compactMap { $0["name"] as? String })
    try expect(names == VoiceAgentPolicy.allowed, "Safe tools differ from the actual MCP catalog")
    try expect(Set(applicationCatalog.compactMap { $0["name"] as? String }) == VoiceAgentPolicy.applicationTools,
               "Renderer commands exposed without a dataset")
    let screenshot = catalog.first { $0["name"] as? String == "capture_screenshot" }!["inputSchema"] as! [String: Any]
    try rejects { try VoiceAgentPolicy.validate(["output_path": "/tmp/forbidden.png"], schema: screenshot) }
    try rejects { try VoiceAgentPolicy.validate(["include_alpha": 1], schema: screenshot) }
    try VoiceAgentPolicy.validate(["include_alpha": false], schema: screenshot)
    try VoiceAgentPolicy.validate(["max_width": 100], schema: screenshot)
    try rejects { try VoiceAgentPolicy.validate(["max_width": 0], schema: screenshot) }
    try rejects { try VoiceAgentPolicy.validate(["max_width": true], schema: screenshot) }
    let loadView = catalog.first { $0["name"] as? String == "load_visualization_state" }!["inputSchema"] as! [String: Any]
    try VoiceAgentPolicy.validate([:], schema: loadView)
    try rejects { try VoiceAgentPolicy.validate(["input_path": "/tmp/forbidden.json"], schema: loadView) }
    let deleteState = catalog.first { $0["name"] as? String == "delete_edit_state" }!["inputSchema"] as! [String: Any]
    try rejects { try VoiceAgentPolicy.validate(["id": UUID().uuidString, "confirm": true], schema: deleteState) }
    let rotate = catalog.first { $0["name"] as? String == "rotate_view" }!["inputSchema"] as! [String: Any]
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1, 0], "degrees": true], schema: rotate) }
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1], "degrees": 30], schema: rotate) }
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1, 0], "degrees": Double.infinity], schema: rotate) }
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1, 0], "degrees": 30, "path": "/secret"], schema: rotate) }
    let rgb = VoiceAgentPolicy.catalog(router.toolDefinitions, vision: true, transferFunctions: false, images: false)
    try expect(!rgb.contains { ["set_transfer_function", "set_transfer_function_component", "set_render_mode",
      "capture_screenshot", "pick_screenshot_positions",
                               "set_screen_projection", "set_background"].contains($0["name"] as? String ?? "") }, "Unsupported tools exposed")
    let rgbReset = rgb.first { $0["name"] as? String == "reset_state" }!["inputSchema"] as! [String: Any]
    try VoiceAgentPolicy.validate(["scope": "clipping"], schema: rgbReset)
    try rejects { try VoiceAgentPolicy.validate(["scope": "transfer_function"], schema: rgbReset) }
    try rejects { try VoiceAgentPolicy.validate([String: Any](), schema: rgbReset) }
    try session.perform(.setClipping(minimum: SIMD3(0.1, 0, 0), maximum: .one), source: .mouse)
    _ = try await bridge.executeTool(name: "reset_state", arguments: ["scope": "clipping"], validateContext: {})
    try expect(service.applicationState().clipMinimum == [0, 0, 0], "The agent did not reset the requested scope")
    let editStatus = try await bridge.executeTool(name: "get_volume_edit_state", arguments: [:], validateContext: {})
    let status = editStatus["structuredContent"] as? [String: Any]
    try expect(status?["mode"] != nil && status?["pendingBrickCount"] != nil &&
               status?["datasetID"] == nil && status?["savedStates"] as? [[String: String]] != nil,
               "Edit status leaked private data or omitted saved state summaries")

    let cg = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    cg.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
    let png = NSMutableData()
    let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
    try expect(CGImageDestinationFinalize(destination), "PNG fixture failed")
    let resized = try VoiceAgentController.agentImage(png as Data)
    try expect(resized.width <= 1024 && resized.height <= 1024 && resized.data.count <= 2097152, "Image bounds exceeded")
    let positionBuffer = BorgVRScreenshotPositions(depth: Data(count: 1600 * 1200 * 4), depthBytesPerRow: 1600 * 4,
      clipToVolume: matrix_identity_float4x4, columns: Array(repeating: 0.5, count: 1600),
      rows: Array(repeating: 0.5, count: 1200))
    app.renderScreenshotHandler = { id, url, _, maxWidth, completion in
      do {
        guard let url else { throw Failure.failed("No screenshot destination") }
        let image = try maxWidth.map { try VoiceAgentController.agentImage(png as Data, sizes: [$0]).data }
        try (image ?? png as Data).write(to: url)
        app.screenshotCache.begin(id)
        app.screenshotCache.store(positionBuffer, id: id, renderedFrame: app.completedRenderFrameCount)
        completion(.success(url))
      } catch { completion(.failure(error)) }
    }
    let suite = "BorgVRVoiceTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let account = "voice-agent-test-\(UUID())"
    defer { defaults.removePersistentDomain(forName: suite); try? KeychainSecretStore.delete(account: account) }
    defaults.set(512, forKey: "voiceAgent.maximumCalls")
    let settings = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    func isolatedConversationStore(_ name: String) -> VoiceAgentConversationStore {
      .init(file: fixture.appendingPathComponent("conversation-\(name)/conversation.sealed"),
            keyAccount: "\(account)-conversation-\(name)")
    }
    let conversationStore = isolatedConversationStore("main")
    defer { try? conversationStore.remove() }
    try expect(settings.workMinutes == 60 && defaults.object(forKey: "voiceAgent.maximumCalls") == nil,
               "Default work time or stale call-budget migration failed")
    try expect(!settings.savesConversation && settings.confirmsVolumeEdits,
               "Conversation must be opt-in and edits must ask by default")
    settings.workMinutes = 75
    let persisted = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    try expect(persisted.workMinutes == 75, "Execution settings not persisted")
    settings.workMinutes = 999
    try expect(settings.workMinutes == 180, "Execution settings not bounded")
    settings.workMinutes = 1
    try expect(settings.workMinutes == 5, "Work time must not be shorter than five minutes")
    settings.workMinutes = 180
    try expect(settings.speechRateMultiplier == 1, "Default speech rate changed")
    let initialIdentity = settings.identity
    try settings.rememberRule("  Prefer a clear side view.  ")
    try settings.rememberRule("Prefer a clear side view.")
    try expect(settings.knowledgeRules.count == 1 && settings.identity == initialIdentity, "Rule was duplicated or disconnected the agent")
    try expect(VoiceAgentSettings(defaults: defaults, tokenAccount: account).knowledgeRules == settings.knowledgeRules,
               "Confirmed rules were not saved locally")
    try rejects { try settings.rememberRule(String(repeating: "x", count: 501)) }
    settings.forgetRule(id: settings.knowledgeRules[0].id)
    try expect(VoiceAgentSettings(defaults: defaults, tokenAccount: account).knowledgeRules.isEmpty, "Removed rule was still persisted")
    settings.speechRateMultiplier = 1.6
    try expect(VoiceAgentSettings(defaults: defaults, tokenAccount: account).speechRateMultiplier == 1.6,
               "Speech rate was not persisted")
    try expect(settings.identity == initialIdentity, "Changing speech rate reconnects the agent")
    let spoken = VoiceAgentSpeech.utterance("**Bones** and `head`", rateMultiplier: settings.speechRateMultiplier)
    try expect(spoken.speechString == "Bones and head", "Speech reads Markdown markers")
    try expect(abs(spoken.rate - AVSpeechUtteranceDefaultSpeechRate * 1.6) < 0.001, "Speech rate not applied")
    settings.speechRateMultiplier = .nan
    try expect(settings.speechRateMultiplier == 1, "Invalid persisted speech rate")
    try expect(VoiceAgentSpeech.utterance("text", rateMultiplier: 1).rate == AVSpeechUtteranceDefaultSpeechRate,
               "Existing utterance rate changed")
    settings.enabled = true
    settings.speaks = false
    let workflowAgent = VoiceAgentController(settings: settings, conversationStore: isolatedConversationStore("workflow"))
    workflowAgent.configure(bridge: bridge)
    var shotCount = 0
    let screenshotHandler = app.renderScreenshotHandler
    app.renderScreenshotHandler = { id, url, access, maxWidth, completion in
      shotCount += 1
      screenshotHandler?(id, url, access, maxWidth, completion)
    }
    workflowAgent.startDemonstration(goal: .exposeRegion, includeViewSettings: true)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 1), source: .mouse)
    await workflowAgent.finishDemonstration()
    try expect(shotCount == 0 && workflowAgent.demonstrations.screenshotExport == nil,
               "A demonstration without image consent captured a screenshot")
    workflowAgent.demonstrations.discard()

    let frames = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(20))
        app.recordCompletedRenderFrame(datasetKey: app.activeDatasetRenderKey, missingBrickCount: 0)
      }
    }
    defer { frames.cancel() }
    await workflowAgent.startScreenshotDemonstration(goal: .exposeRegion)
    try expect(workflowAgent.demonstrations.active && shotCount == 1, "The first consented render was not captured")
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 2), source: .mouse)
    await workflowAgent.finishDemonstration(outcome: .reached)
    guard let screenshotExport = workflowAgent.demonstrations.screenshotExport,
          let numericExport = workflowAgent.demonstrations.completed else {
      throw Failure.failed("Missing finished screenshot pair")
    }
    let paired = try JSONSerialization.jsonObject(with: JSONEncoder().encode(screenshotExport)) as? [String: Any]
    let encodedShots = paired?["screenshots"] as? [String: String]
    let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(numericExport)) as? [String: Any]
    try expect(shotCount == 2 && screenshotExport.screenshots.before.count <= 512 * 1024 &&
               screenshotExport.screenshots.after.count <= 512 * 1024 &&
               encodedShots?["before_png_base64"].flatMap { Data(base64Encoded: $0) } != nil &&
               encodedShots?["after_png_base64"].flatMap { Data(base64Encoded: $0) } != nil &&
               plain?["screenshots"] == nil, "Screenshot export was incomplete, oversized, or uploadable")
    workflowAgent.demonstrations.discard()

    await workflowAgent.startScreenshotDemonstration(goal: .exposeRegion)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 2), source: .mouse)
    try session.perform(.rotate(axis: [0, 1, 0], degrees: 3), source: .mcp)
    await workflowAgent.finishDemonstration()
    try expect(shotCount == 3 && workflowAgent.demonstrations.screenshotExport == nil,
               "A foreign change left exportable screenshots")
    workflowAgent.demonstrations.discard()
    frames.cancel()
    app.renderScreenshotHandler = screenshotHandler
    settings.address = "https://127.0.0.1:\(ready["port"]!)"
    try settings.importCertificate(cert)
    try settings.setToken(String(contentsOf: fixture.appendingPathComponent("runtime/secrets/agent_token"), encoding: .utf8))
    try expect(!String(describing: defaults.dictionaryRepresentation()).contains(try settings.token()), "Token leaked to preferences")
    let workflowAccounts = try JSONDecoder().decode([[String: String]].self,
      from: Data(contentsOf: fixture.appending(path: "workflow-fixture.json")))
    let workflowKey = "workflow-test-" + UUID().uuidString
    defer { try? KeychainSecretStore.delete(account: workflowKey) }
    let outbox = WorkflowOutbox(file: fixture.appending(path: "outbox.json"))
    let workflow = WorkflowUpload(keychainAccount: workflowKey, outbox: outbox)
    await workflow.link(try settings.token(), settings: settings)
    try expect(workflow.destination(for: settings) == nil, "Chat credentials linked to workflow storage")
    await workflow.link(workflowAccounts[0]["token"]!, settings: settings)
    guard let ownerA = workflow.destination(for: settings) else {
      throw Failure.failed("Workflow profile A could not link: \(workflow.errorText ?? "")")
    }
    try expect(ownerA.profileID == UUID(uuidString: workflowAccounts[0]["profile_id"]!) &&
               workflow.enqueue(demonstration, capturedFor: ownerA, settings: settings),
               "Demonstration did not enter its original profile queue")
    let restarted = WorkflowUpload(keychainAccount: workflowKey, outbox: outbox)
    try expect(restarted.pendingCount == 1, "Restart lost a queued demonstration")
    await restarted.link(workflowAccounts[1]["token"]!, settings: settings)
    guard let ownerB = restarted.destination(for: settings) else { throw Failure.failed("Workflow profile B could not link") }
    try expect(ownerA != ownerB && restarted.pendingCount == 0 &&
               !restarted.enqueue(demonstration, capturedFor: ownerA, settings: settings),
               "Profile B could claim a capture from profile A")
    recorder.discard()
    recorder.start(goal: .inspectValues, context: demonstrationContext, destination: ownerA)
    recorder.record(.clipping, context: demonstrationContext)
    recorder.checkDestination(ownerB)
    recorder.record(.annotations, context: demonstrationContext)
    try expect(!recorder.active && recorder.completed == nil && recorder.destination == nil,
               "An unqueued draft remained available after switching profiles")
    await restarted.sync(settings: settings)
    await restarted.refreshReport(settings: settings)
    try expect(restarted.analysis?.status == .empty, "Profile B received profile A's report")
    try expect(try outbox.pending(for: ownerA).map(\.episode.id) == [demonstration.id] && outbox.pending(for: ownerB).isEmpty,
               "Profile switch retagged or uploaded another user's data")
    await restarted.link(workflowAccounts[0]["token"]!, settings: settings)
    await restarted.sync(settings: settings)
    try expect(restarted.errorText == nil && restarted.pendingCount == 0 && outbox.load().isEmpty,
               "Acknowledged demonstration was not removed from its queue")
    try await wait { !restarted.busy }
    for _ in 0..<20 {
      await restarted.refreshReport(settings: settings)
      if restarted.analysis?.status == .ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try expect(restarted.analysis?.report?.episodes == 1 && restarted.analysis?.report?.patterns.isEmpty == true,
               "The native workflow report did not reflect its own uploaded demonstration")
    guard let portableState = await restarted.exportState(settings: settings) else {
      throw Failure.failed("Workflow state could not be exported")
    }
    let stateFile = fixture.appending(path: "workflow-state.json")
    try portableState.write(to: stateFile, options: .atomic)
    await restarted.link(workflowAccounts[1]["token"]!, settings: settings)
    await restarted.importState(stateFile, capturedFor: ownerA, settings: settings)
    try expect(restarted.errorText != nil, "A profile change silently redirected a workflow import")
    await restarted.refreshReport(settings: settings)
    try expect(restarted.analysis?.status == .empty, "An unconfirmed workflow import modified the other profile")
    await restarted.importState(stateFile, capturedFor: ownerB, settings: settings)
    try expect(restarted.errorText == nil, "An explicit workflow import failed")
    for _ in 0..<30 {
      await restarted.refreshReport(settings: settings)
      if restarted.analysis?.status == .ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    try expect(restarted.analysis?.report?.episodes == 1, "Imported workflow evidence was not analyzed")
    let replacement = WorkflowDestination(origin: ownerA.origin, certificateDigest: ownerA.certificateDigest,
                                          profileID: ownerA.profileID, corpusID: UUID())
    try outbox.enqueue(demonstration, for: ownerA)
    try expect(try outbox.pending(for: replacement).isEmpty, "Old corpus queue was retagged after deletion")
    try outbox.clear(for: replacement)
    try expect(try outbox.load().isEmpty, "Old corpus queue could not be removed by its profile")
    let emptyApp = AppModel()
    let emptySession = ScreenBorgVRSession.screen(appModel: emptyApp,
      renderingParameters: RenderingParameters(), appSettings: AppSettings())
    let startAgent = VoiceAgentController(settings: settings, conversationStore: isolatedConversationStore("start"))
    startAgent.configure(service: BorgVRScreenCommandService(session: emptySession)) { nil }
    await startAgent.submit("application-state")
    try await wait { !startAgent.busy }
    try expect(startAgent.errorText == nil && startAgent.messages.last?.text == "Start menu ready." &&
               emptyApp.activeDataset == nil && !emptyApp.rendererHasActiveDataset && !startAgent.speech.isRecording,
               "Startup assistant required a previously initialized renderer or started listening")
    startAgent.cancel()
    for turn in 1...2 {
      let acknowledgement = voiceAgentText("Request is being processed.")
      let before = startAgent.messages.filter { !$0.user && $0.text == acknowledgement }.count
      await startAgent.submit("slow-acknowledgement")
      try await wait { startAgent.messages.filter { !$0.user && $0.text == acknowledgement }.count > before }
      try expect(startAgent.busy && startAgent.messages.last?.text == acknowledgement,
                 "Acknowledgement waited for the slow model response")
      try await wait { !startAgent.busy }
      try expect(startAgent.errorText == nil && startAgent.messages.last?.text == "Slow request completed.",
                 "Acknowledgement interfered with final response on turn \(turn)")
      try expect(startAgent.messages.filter { !$0.user && $0.text == acknowledgement }.count == before + 1,
                 "Request acknowledgement was duplicated")
    }
    for turn in 1...2 {
      let text = "I'm checking the current state."
      let before = startAgent.messages.filter { !$0.user && $0.text == text }.count
      await startAgent.submit("duplicate-response")
      try await wait { !startAgent.busy }
      try expect(startAgent.errorText == nil &&
                 startAgent.messages.filter { !$0.user && $0.text == text }.count == before + 1,
                 "Repeated progress/final answer was not collapsed on turn \(turn)")
      try expect(!startAgent.messages.contains { !$0.user && $0.text.hasPrefix("  " + text) },
                 "Whitespace-only response variation was duplicated")
    }
    let distinctStart = startAgent.messages.count
    await startAgent.submit("distinct-responses")
    try await wait { !startAgent.busy }
    let distinctReplies = startAgent.messages.dropFirst(distinctStart).filter { !$0.user }.map(\.text)
    try expect(startAgent.errorText == nil && distinctReplies.contains("I'm checking the result.") &&
               distinctReplies.contains("Distinct final answer."), "Different progress/final answers were suppressed")
    startAgent.cancel()
    var openCount = 0
    var simulateReady = true
    var toolsReady = true
    var openingEditStateID: UUID?
    var waitBeforeOpen = false
    var preflightStarted = false
    let catalogService = BorgVRScreenCommandService(session: emptySession, datasetListProvider: { [bone] },
      datasetOpener: { id, validate, didBegin in
        try validate()
        if waitBeforeOpen {
          preflightStarted = true
          try await Task.sleep(for: .milliseconds(300))
          try validate()
        }
        openCount += 1
        toolsReady = false
        openingEditStateID = nil
        emptyApp.openDataset(entry, automaticallyLoadState: false)
        try didBegin()
        guard case .opening(_, let request) = emptyApp.datasetSessionState else { fatalError() }
        if simulateReady {
          emptyApp.prepareDatasetRenderer(key: emptyApp.activeDatasetRenderKey, metadata: metadata, requestID: request)
          _ = emptyApp.markRenderedDataset(key: emptyApp.activeDatasetRenderKey, requestID: request)
          Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            openingEditStateID = UUID()
            try? await Task.sleep(for: .milliseconds(200))
            toolsReady = true
          }
        }
      })
    let searchToolResult = try await BorgVRMCPToolRouter(commandService: catalogService)
      .callTool(name: "search_datasets", arguments: ["query": "bone"])
    let searchText = (searchToolResult["content"] as! [[String: Any]])[0]["text"] as! String
    let searchTextObject = try VoiceAgentPolicy.decode(searchText)
    try expect(searchTextObject["totalMatches"] as? Int == 1,
               "MCP clients without structuredContent did not receive the search results")
    let catalogAgent = VoiceAgentController(settings: settings, conversationStore: isolatedConversationStore("catalog"))
    catalogAgent.configure(service: catalogService, isReady: { toolsReady }) {
      switch emptyApp.datasetSessionState {
        case .opening(let dataset, let request), .rendering(let dataset, let request):
          return .init(datasetID: dataset.uniqueId, openingID: request, editStateID: openingEditStateID)
        default: return nil
      }
    }
    let catalogObservation = emptyApp.$datasetSessionState.sink { _ in
      Task { @MainActor in catalogAgent.invalidateContext() }
    }
    defer { catalogObservation.cancel() }
    await catalogAgent.submit("catalog-search")
    try await wait { !catalogAgent.busy }
    try expect(catalogAgent.errorText == nil && openCount == 0 && emptyApp.activeDataset == nil,
               "Searching opened a dataset or failed")
    await catalogAgent.submit("catalog-open")
    try await wait { !catalogAgent.busy }
    try expect(catalogAgent.errorText == nil && openCount == 1 && emptyApp.rendererHasActiveDataset &&
               toolsReady && openingEditStateID != nil &&
               catalogAgent.messages.last?.text == "Catalog dataset opened and fresh state verified.",
               "Planned opening failed or was repeated: \(catalogAgent.errorText ?? "")")
    catalogAgent.newConversation()
    emptyApp.closeDataset(destination: .start)
    simulateReady = false
    await Task.yield()
    await catalogAgent.submit("catalog-open-wait")
    try await wait { openCount == 2 }
    try expect(catalogAgent.busy && !emptyApp.rendererHasActiveDataset, "Opening claimed success before the renderer was ready")
    emptyApp.closeDataset(destination: .start)
    catalogAgent.invalidateContext()
    try expect(!catalogAgent.busy && catalogAgent.connectionState == .disconnected,
               "Manual close during planned opening did not stop the agent")
    try await Task.sleep(for: .milliseconds(100))
    try expect(openCount == 2, "Interrupted opening was automatically replayed")
    catalogObservation.cancel()
    catalogAgent.newConversation()
    waitBeforeOpen = true
    await catalogAgent.submit("catalog-open-wait")
    try await wait { preflightStarted }
    emptyApp.openDataset(entry, automaticallyLoadState: false)
    guard case .opening(_, let manualOpening) = emptyApp.datasetSessionState else { fatalError() }
    // Deliberately omit invalidateContext: the function-level preflight must also protect this race.
    try await wait { !catalogAgent.busy }
    try expect(openCount == 2 && catalogAgent.connectionState == .disconnected,
               "A delayed agent opener replaced the user's manual selection")
    guard case .opening(_, let retainedOpening) = emptyApp.datasetSessionState else { fatalError() }
    try expect(manualOpening == retainedOpening, "Manual opening identity was overwritten")
    let testStrategies = ProcessInfo.processInfo.environment["BORGVR_STRATEGY_TEST_ENCODER"] != nil
    let expertKnowledge = CommandLine.arguments.dropFirst(3).first.flatMap { Bundle(path: $0) }
      .flatMap(VoiceAgentExpertKnowledge.load(from:))
    if testStrategies {
      try expect(expertKnowledge?.contains("[inspection.preview]") == true, "Expert TOML was not bundled with the app")
    }
    let agent = VoiceAgentController(settings: settings, conversationStore: conversationStore,
                                     expertKnowledgeSource: expertKnowledge)
    var context: VoiceAgentContext? = .init(datasetID: entry.uniqueId, openingID: openingID, editStateID: nil)
    let activeAgentBridge = BorgVRVoiceAgentBridge(service: service) { context }
    agent.configure(bridge: activeAgentBridge)
    var activeAgentUserChanges = 0
    let activeAgentObservation = activeAgentBridge.changes.sink { _ in activeAgentUserChanges += 1 }
    defer { activeAgentObservation.cancel() }
    try expect(agent.datasetOpeningID == openingID, "Unconnected assistant lost its dataset owner")
    agent.newConversation()
    try expect(agent.datasetOpeningID == openingID, "Disconnecting the agent changed dataset ownership")
    try await agent.testServer()
    try expect(agent.errorText == nil && agent.model == "Qwen/Qwen3.6-35B-A3B", "Readiness failed: \(agent.errorText ?? "")")
    let eventsBeforeRecording = commandEvents.count
    session.startCommandRecording()
    try await session.waitForRecordingPreparation()
    try expect(commandEvents.count == eventsBeforeRecording, "GSC baseline priming was reported as manual activity")
    await agent.submit("roundtrip")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil, "Native agent failed: \(agent.errorText ?? "")")
    try expect(agent.messages.last?.text == "Native voice agent roundtrip passed.", "No final answer/image acknowledgement")
    try expect(agent.messages.contains { $0.text == "I'm inspecting the current view." }, "Progress message missing")
    let expected = session.currentSnapshot().transform
    let expectedTF = try service.transferFunction(channel: 0)
    try expect(expectedTF.samples.last == [255, 64, 32, 255], "TF tool did not apply")
    try await session.finishCommandRecording()
    let gsc = try session.recordedGSCScript()
    let commands = try BorgVRRecordedGSC.commands(in: Data(gsc.utf8))
    try expect(commands.count > 2 && commands.contains {
      if case .action(.captureScreenshot) = $0 { return true }; return false
    }, "Agent screenshot command was not recorded")
    try expect(commands.contains { if case .setTransferFunction = $0 { return true }; return false },
               "Agent TF command was not recorded")
    try service.reset(.all)
    try await service.replayCommandRecording(Data(gsc.utf8))
    try expect(session.currentSnapshot().transform == expected, "Agent transform GSC roundtrip changed state")
    try expect(try service.transferFunction(channel: 0).samples == expectedTF.samples, "Agent TF GSC roundtrip changed state")
    agent.newConversation()
    await agent.submit("pick-position")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Screenshot position verified.",
               "Agent picking did not use the screenshot's position buffer: \(agent.errorText ?? "")")
    if testStrategies {
      for prompt in ["Mach einen kleinen Screenshot mit 100 Pixeln Breite.",
                     "Take a low-resolution screenshot for a quick preview."] {
        await agent.submit(prompt)
        try await wait { !agent.busy }
        try expect(agent.errorText == nil && agent.messages.last?.text == "Preview strategy selected.",
                   "Expert strategy did not survive the native hello: \(agent.errorText ?? "")")
      }
    }
    agent.newConversation()
    await agent.submit("invalid-clipping-recovery")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.connectionState == .ready &&
               agent.messages.last?.text == "Clipping rejected safely and corrected.",
               "Rejected clipping disconnected the assistant as an uncertain mutation: \(agent.errorText ?? "")")
    try expect(abs(service.applicationState().clipMinimum[0] - 0.2) < 0.001 &&
               abs(service.applicationState().clipMaximum[0] - 0.8) < 0.001, "Corrected clipping not applied")
    agent.newConversation()
    let annotationsBefore = service.listObjects().count + service.listMeasurements().count
    let rejectedAnnotation = try await bridge.executeTool(name: "upsert_measurement", arguments: [
      "kind": "area", "points": [["position": [0.1, 0.1, 0.1]], ["position": [0.2, 0.1, 0.1]],
        ["position": [0.3, 0.1, 0.1]]]], validateContext: {})
    try expect((rejectedAnnotation["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
               service.listObjects().count + service.listMeasurements().count == annotationsBefore,
               "Degenerate annotation was applied or reported uncertain")
    session.startCommandRecording()
    try await session.waitForRecordingPreparation()
    let manualChangesBeforeAnnotations = activeAgentUserChanges
    await agent.submit("annotation-roundtrip")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Agent annotations created, edited and verified.",
               "Native annotation capability failed: \(agent.errorText ?? "")")
    try expect(activeAgentUserChanges == manualChangesBeforeAnnotations, "Agent annotations were reported as manual user changes")
    let objects = service.listObjects(), measurements = service.listMeasurements()
    try expect(objects.count == 2 && measurements.count == 3, "Edits created duplicates or lost annotations")
    let physical = metadata.physicalExtentMeters
    let expectedValues = ["length": Double(0.5 * physical.x), "area": Double(0.06 * physical.x * physical.y),
                          "volume": Double(0.01 * physical.x * physical.y * physical.z)]
    let page = try await bridge.executeTool(name: "list_measurements", arguments: ["limit": 2], validateContext: {})
    let pageState = page["structuredContent"] as! [String: Any]
    try expect(pageState["truncated"] as? Bool == true && pageState["nextOffset"] as? Int == 2,
               "Annotation pagination lost completeness information")
    let allMeasurements = try await bridge.executeTool(name: "list_measurements", arguments: [:], validateContext: {})
    for measurement in (allMeasurements["structuredContent"] as! [String: Any])["measurements"] as! [[String: Any]] {
      let kind = measurement["kind"] as! String
      let expectedValue = expectedValues[kind]!
      try expect(abs((measurement["value"] as! Double) - expectedValue) < max(1e-12, abs(expectedValue) * 1e-5),
                 "Measurement does not use the dataset's physical scale")
    }
    try await session.finishCommandRecording()
    let annotationGSC = try session.recordedGSCScript()
    if case .marker(var oversized) = objects[0] {
      oversized.name = String(repeating: "x", count: 100_000)
      try service.upsertObject(.marker(oversized))
      let summary = try await bridge.executeTool(name: "list_objects", arguments: ["limit": 1], validateContext: {})
      let summaryRows = (summary["structuredContent"] as! [String: Any])["objects"] as! [[String: Any]]
      try expect(summaryRows[0]["detailsOmitted"] as? Bool == true, "Large annotation was not explicitly summarized")
      let unsafeReplacement = try await bridge.executeTool(name: "upsert_sphere_marker", arguments: [
        "id": oversized.id.uuidString, "position": [0.1, 0.1, 0.1]], validateContext: {})
      try expect((unsafeReplacement["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
                 service.listObjects()[0] == .marker(oversized), "A summary overwrote full annotation data")
      try service.upsertObject(objects[0])
    }
    let unknownMarker = try await bridge.executeTool(name: "upsert_sphere_marker", arguments: [
      "id": UUID().uuidString, "position": [0.1, 0.1, 0.1]], validateContext: {})
    try expect((unknownMarker["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
               service.listObjects() == objects, "Unknown edit UUID created an unintended annotation")
    try service.clearObjects()
    try service.clearMeasurements()
    try await service.replayCommandRecording(Data(annotationGSC.utf8))
    try expect(service.listObjects() == objects && service.listMeasurements() == measurements,
               "Annotation Command/GSC roundtrip changed identities, points or geometry")
    agent.newConversation()
    session.startCommandRecording()
    try await session.waitForRecordingPreparation()
    await agent.submit("annotation-delete-one")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.annotationDeletion == nil &&
               agent.messages.last?.text == "Target annotations deleted and verified.", "Individual annotation deletion failed")
    let remainingObjects = service.listObjects(), remainingMeasurements = service.listMeasurements()
    try expect(remainingObjects == Array(objects.dropFirst()) && remainingMeasurements == Array(measurements.dropFirst()),
               "Individual deletion removed unrelated annotations")
    try await session.finishCommandRecording()
    let individualDeletionGSC = try session.recordedGSCScript()
    try service.clearObjects()
    try service.clearMeasurements()
    try await service.replayCommandRecording(Data(individualDeletionGSC.utf8))
    try expect(service.listObjects() == remainingObjects && service.listMeasurements() == remainingMeasurements,
               "Individual deletion GSC roundtrip changed remaining annotations")
    let directBulk = try await activeAgentBridge.executeTool(name: "clear_annotations",
      arguments: ["scope": "all", "confirm": true], validateContext: {})
    try expect((directBulk["structuredContent"] as? [String: Any])?["code"] as? String == "confirmation_required" &&
               service.listObjects() == remainingObjects, "A model confirmation flag bypassed local approval")
    do {
      _ = try await router.callTool(name: "clear_annotations", arguments: [:])
      throw Failure.failed("MCP bulk deletion accepted missing confirmation")
    } catch BorgVRMCPCommandError.invalidArgument { }
    try expect(service.listObjects() == remainingObjects && service.listMeasurements() == remainingMeasurements,
               "Missing MCP confirmation changed annotations")
    let directLastMarker = try await activeAgentBridge.executeTool(name: "remove_object",
      arguments: ["id": remainingObjects[0].id.uuidString], validateContext: {})
    try expect((directLastMarker["structuredContent"] as? [String: Any])?["code"] as? String == "confirmation_required",
               "Individual calls bypassed confirmation when removing the last marker")
    agent.newConversation()
    await agent.submit("annotation-delete-all")
    try await wait { agent.annotationDeletion != nil }
    let declinedPreview = agent.annotationDeletion!
    try expect(declinedPreview.markerCount == 1 && declinedPreview.measurementCount == 2 &&
               service.listObjects() == remainingObjects && service.listMeasurements() == remainingMeasurements,
               "Bulk deletion happened before human approval or showed incorrect counts")
    agent.resolveAnnotationDeletion(id: declinedPreview.id, accepted: false)
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Deletion declined safely." &&
               service.listObjects() == remainingObjects && service.listMeasurements() == remainingMeasurements,
               "Declined deletion changed annotations or was bypassed")
    let stalePreview = try activeAgentBridge.prepareAnnotationDeletion(scope: "all", targetID: nil)!
    if case .marker(var changed) = remainingObjects[0] {
      changed.name = "Changed after preview"
      try service.upsertObject(.marker(changed))
      let staleResult = try await activeAgentBridge.executeAnnotationDeletion(stalePreview, validateContext: {})
      try expect((staleResult["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
                 service.listObjects()[0] == .marker(changed), "Stale approval deleted edited annotations")
      try service.upsertObject(remainingObjects[0])
    }
    let replayedApproval = try await activeAgentBridge.executeAnnotationDeletion(stalePreview, validateContext: {})
    try expect((replayedApproval["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true,
               "Consumed approval could be replayed")
    agent.newConversation()
    await agent.submit("annotation-delete-all")
    try await wait { agent.annotationDeletion != nil }
    agent.cancel()
    try expect(agent.annotationDeletion == nil && service.listObjects() == remainingObjects &&
               service.listMeasurements() == remainingMeasurements, "Cancelling a question deleted annotations")
    agent.newConversation()
    session.startCommandRecording()
    try await session.waitForRecordingPreparation()
    await agent.submit("annotation-delete-all")
    try await wait { agent.annotationDeletion != nil }
    let acceptedPreview = agent.annotationDeletion!
    agent.resolveAnnotationDeletion(id: acceptedPreview.id, accepted: true)
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "All annotations deleted and verified." &&
               service.listObjects().isEmpty && service.listMeasurements().isEmpty, "Approved bulk deletion failed")
    try await session.finishCommandRecording()
    let bulkDeletionGSC = try session.recordedGSCScript()
    try await service.replayCommandRecording(Data(bulkDeletionGSC.utf8))
    try expect(service.listObjects().isEmpty && service.listMeasurements().isEmpty, "Bulk deletion GSC roundtrip failed")
    // The fixture mesh needs no GPU asset: deletion must preserve even non-rendered instances.
    let fixtureMesh = SceneMeshInstance(name: "Keep this mesh", asset: SceneMeshReference(assetID: UUID(),
      name: "Fixture", assetDescription: "Test only", boundsMinimum: .zero, boundsMaximum: .one))
    app.sceneMeshInstances = [fixtureMesh]
    try service.upsertObject(objects[0])
    try service.upsertMeasurement(measurements[0])
    let markerOnly = try activeAgentBridge.prepareAnnotationDeletion(scope: "markers", targetID: nil)!
    _ = try await activeAgentBridge.executeAnnotationDeletion(markerOnly, validateContext: {})
    try expect(app.sceneMeshInstances == [fixtureMesh] && service.listMeasurements() == [measurements[0]],
               "Marker deletion removed a mesh or a measurement")
    let measurementOnly = try activeAgentBridge.prepareAnnotationDeletion(scope: "measurements", targetID: nil)!
    _ = try await activeAgentBridge.executeAnnotationDeletion(measurementOnly, validateContext: {})
    try expect(service.listMeasurements().isEmpty && app.sceneMeshInstances == [fixtureMesh],
               "Measurement deletion removed a mesh")
    let removeMesh = try await activeAgentBridge.executeTool(name: "remove_object", arguments: ["id": fixtureMesh.id.uuidString], validateContext: {})
    try expect((removeMesh["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
               app.sceneMeshInstances == [fixtureMesh], "Agent removed a mesh through marker deletion")
    app.sceneMeshInstances = []
    agent.newConversation()
    await agent.submit("collaborate")
    try await wait { agent.collaborationQuestion != nil }
    try service.rotate(axis: [1, 0, 0], degrees: 15)
    let userTransform = session.currentSnapshot().transform
    try expect(agent.userIsInteracting, "Manual change did not pause the active agent")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Collaborative task completed without undoing your change.",
               "Collaborative run failed: \(agent.errorText ?? "")")
    try expect(session.currentSnapshot().transform == userTransform, "Agent undid the manual rotation")
    try expect(agent.collaborationQuestion == nil && agent.ruleProposals.isEmpty && settings.knowledgeRules.isEmpty,
               "Manual help left a pending question or recorded a preference")
    agent.newConversation()
    await agent.submit("long-run")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Long native run passed.",
               "More than 24 BorgVR calls failed: \(agent.errorText ?? "")")

    agent.newConversation()
    await agent.submit("replace-source")
    try await wait { agent.messages.contains { $0.text == "I'm waiting for the updated view." } }
    await agent.submit("replacement-target")
    try await wait { !agent.busy && !agent.interrupting }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Native voice agent roundtrip passed.",
               "New prompt did not interrupt model generation: \(agent.errorText ?? "")")
    try expect(agent.messages.filter { $0.user }.map(\.text) == ["replace-source", "replacement-target"],
               "Interrupted conversation transcript was lost or duplicated")

    agent.newConversation()
    await agent.submit("replace-at-tool")
    try await Task.sleep(for: .milliseconds(400))
    await agent.submit("replacement-target")
    try expect(agent.interrupting, "Replacement did not wait for active renderer command")
    app.recordCompletedRenderFrame(datasetKey: app.activeDatasetRenderKey, missingBrickCount: 0)
    try await wait { !agent.busy && !agent.interrupting }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Native voice agent roundtrip passed.",
               "Replacement after completed renderer command failed: \(agent.errorText ?? "")")

    agent.newConversation()
    await agent.submit("replace-at-tool")
    try await Task.sleep(for: .milliseconds(400))
    await agent.submit("must-not-run")
    agent.cancel()
    app.recordCompletedRenderFrame(datasetKey: app.activeDatasetRenderKey, missingBrickCount: 0)
    try await Task.sleep(for: .milliseconds(200))
    try expect(agent.connectionState == .disconnected && !agent.busy && !agent.interrupting &&
               !agent.messages.contains { $0.user && $0.text == "must-not-run" },
               "Explicit cancellation allowed a queued replacement to start")
    agent.newConversation()
    await agent.submit("context-before-change")
    try await wait { !agent.busy }
    try expect(!agent.canResume && agent.connectionState == .disconnected && agent.errorText == nil &&
               agent.messages.last?.text == voiceAgentText("I couldn't complete the task and didn't make any changes. Try asking for one step at a time."),
               "Unrecoverable failure was not explained in the conversation")
    for prompt in ["context-after-change", "verification-failed"] {
      agent.newConversation()
      await agent.submit(prompt)
      try await wait { !agent.busy }
      let partialTransform = session.currentSnapshot().transform
      try expect(agent.canResume && agent.errorText == nil && agent.connectionState == .ready &&
                 agent.messages.last?.text.hasSuffix(voiceAgentText("Would you like me to continue?")) == true,
                 "Expected a resumable partial result for \(prompt)")
      await agent.resumePartialTask()
      try await wait { !agent.busy }
      try expect(!agent.canResume && agent.errorText == nil && agent.connectionState == .ready &&
                 agent.messages.last?.text == "Continued without repeating the change." &&
                 session.currentSnapshot().transform == partialTransform,
                 "Continue repeated the already confirmed rotation or lost the task")
    }
    agent.newConversation()
    await agent.submit("wait")
    try await Task.sleep(for: .milliseconds(400))
    context = .init(datasetID: entry.uniqueId, openingID: UUID(), editStateID: nil)
    agent.invalidateContext()
    try expect(!agent.busy && agent.connectionState == .disconnected, "Reopening the same UUID did not cancel the agent")
    try await Task.sleep(for: .milliseconds(100))
    try expect(agent.connectionState == .disconnected, "Agent unexpectedly reconnected")
    try expect(agent.datasetOpeningID == context?.openingID, "Reopened dataset retained the old window owner")
    context = nil
    app.closeDataset(destination: .datasetSelection)
    agent.invalidateContext()
    try expect(agent.datasetOpeningID == nil, "Dataset closure did not notify an unconnected assistant window")
    agent.newConversation()
    try expect(agent.isAvailable && !agent.hasDataset, "Assistant unavailable in the start menu")
    await agent.submit("application-state")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Start menu ready." &&
               agent.connectionState == .ready, "Dataset-free app session failed: \(agent.errorText ?? "")")
    let startMessages = agent.messages.count
    app.openDataset(entry, automaticallyLoadState: false)
    guard case .opening(_, let newOpening) = app.datasetSessionState else { fatalError() }
    app.prepareDatasetRenderer(key: app.activeDatasetRenderKey, metadata: metadata, requestID: newOpening)
    _ = app.markRenderedDataset(key: app.activeDatasetRenderKey, requestID: newOpening)
    context = .init(datasetID: entry.uniqueId, openingID: newOpening, editStateID: nil)
    agent.invalidateContext()
    try await wait { agent.connectionState != .connecting }
    try expect(agent.connectionState == .ready && agent.messages.count == startMessages && agent.errorText == nil,
               "Opening a dataset lost the app conversation: \(agent.errorText ?? "")")
    await agent.submit("application-state")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Dataset ready.", "Dataset context did not update")

    let editURL = fixture.appendingPathComponent("native-agent-edit.data")
    let originalData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    try originalData.write(to: editURL)
    let editSource = try BORGVRFileData(filename: editURL.path)
    _ = app.volumeBrush.open(editSource, datasetURL: editURL)
    try await app.volumeBrush.waitForStateReady()
    let editContext = app.volumeBrush.editingContextID
    try expect(editContext != nil && app.volumeBrush.activeState == nil,
               "Fresh original dataset lacks its own stable working edit identity")
    context = .init(datasetID: entry.uniqueId, openingID: newOpening, editStateID: editContext)
    agent.invalidateContext()
    try await wait { agent.connectionState != .connecting }
    let initialEditRevision = app.volumeBrush.editRevision
    let rejectedEdit = try await activeAgentBridge.executeTool(name: "edit_volume", arguments: [:], validateContext: {})
    try expect((rejectedEdit["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
               app.volumeBrush.editRevision == initialEditRevision, "Direct edit dispatch bypassed local approval")

    await agent.submit("volume-edit-declined")
    try await wait { agent.volumeEditApproval != nil || !agent.busy }
    guard let declinedEdit = agent.volumeEditApproval else { throw Failure.failed("No volume edit approval was shown") }
    agent.resolveVolumeEditApproval(id: declinedEdit.id, accepted: false)
    try await wait { !agent.busy }
    try expect(agent.messages.last?.text == "Volume edit declined safely." &&
               app.volumeBrush.editRevision == initialEditRevision && agent.volumeBrickStatus == nil,
               "Declined volume edit changed data or reported completion")

    try expect(!FileManager.default.fileExists(atPath: conversationStore.file.path),
               "Opted-out conversation wrote an archive")
    let approvalConnection = settings.identity
    settings.savesConversation = true
    await agent.submit("volume-edit-erase")
    try await wait { agent.volumeEditApproval != nil || !agent.busy }
    guard let pendingEdit = agent.volumeEditApproval else { throw Failure.failed("Missing erase approval") }
    try expect(pendingEdit.erase && pendingEdit.sampleCount == 1, "Approval did not describe the exact edit")
    agent.resolveVolumeEditApproval(id: pendingEdit.id, accepted: true, alwaysApprove: true)
    try await wait { !agent.busy }
    try await wait { agent.volumeBrickStatus == .ready }
    try expect(!settings.confirmsVolumeEdits && settings.identity == approvalConnection &&
               agent.messages.last?.text == "Edited bricks are ready." && agent.errorText == nil,
               "Always approve did not persist or interrupted the pending edit")
    try expect(!(try await app.volumeBrush.stateSnapshot()).mask.isOriginal &&
               app.volumeBrush.editingContextID == editContext, "Erase did not update the edit mask")
    agent.disconnect()

    let sealed = try Data(contentsOf: conversationStore.file)
    try expect(sealed.range(of: Data("volume-edit-erase".utf8)) == nil &&
               (try conversationStore.load(owner: UUID())) == nil, "Archive leaked text or crossed an owner boundary")
    let recoveredSettings = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    try expect(recoveredSettings.savesConversation && !recoveredSettings.confirmsVolumeEdits &&
               recoveredSettings.archiveOwnerID == settings.archiveOwnerID, "Local settings did not survive reload")
    let recovered = VoiceAgentController(settings: recoveredSettings, conversationStore: conversationStore)
    try expect(recovered.messages.contains { $0.user && $0.text == "volume-edit-erase" },
               "Chat transcript was not loaded from the local archive")
    context = .init(datasetID: entry.uniqueId, openingID: UUID(), editStateID: editContext)
    recovered.configure(bridge: activeAgentBridge)
    await recovered.submit("volume-edit-restore")
    try await wait { recovered.volumeEditApproval != nil || !recovered.busy }
    try expect(recovered.volumeEditApproval == nil && recovered.errorText == nil &&
               recovered.messages.last?.text == "Edited bricks are ready.",
               "Restore did not use archived receipts without a second confirmation: \(recovered.errorText ?? "")")
    try await wait { recovered.volumeBrickStatus == .ready }
    try expect((try await app.volumeBrush.stateSnapshot()).mask.isOriginal &&
               app.volumeBrush.editingContextID == editContext, "Restore did not recover the original mask")
    recoveredSettings.confirmsVolumeEdits = true
    await recovered.submit("volume-edit-declined")
    try await wait { recovered.volumeEditApproval != nil || !recovered.busy }
    guard let askedAgain = recovered.volumeEditApproval else { throw Failure.failed("Re-enabled approval did not ask") }
    recovered.resolveVolumeEditApproval(id: askedAgain.id, accepted: false)
    try await wait { !recovered.busy }
    try expect(try Data(contentsOf: editURL) == originalData, "Agent edited the original .data file")
    let changedChannels = try await activeAgentBridge.executeTool(name: "configure_volume_brush",
      arguments: ["channels": [1]], validateContext: {})
    try expect((changedChannels["structuredContent"] as? [String: Any])?["channels"] as? [Int] == [1],
               "Brush command did not use the existing one-based channel selection")
    let localSave = try await activeAgentBridge.executeFileTool(name: "save_visualization_state", arguments: ["filename": "view"],
      select: { _ in fixture }, validateContext: {}, willCommit: {})
    try expect((localSave["structuredContent"] as? [String: Any])?["saved"] as? Bool == true &&
               FileManager.default.fileExists(atPath: fixture.appendingPathComponent("view.json").path) &&
               !(try VoiceAgentPolicy.encoded(localSave)).contains(fixture.path), "Save did not write locally or leaked the directory")
    let requestedExport = try await activeAgentBridge.executeFileTool(name: "export_edited_dataset",
      arguments: ["filename": "edited-export"], select: { _ in fixture }, validateContext: {}, willCommit: {})
    let exportJob = (requestedExport["structuredContent"] as? [String: Any])?["export"] as? [String: Any]
    guard let exportID = (exportJob?["id"] as? String).flatMap(UUID.init(uuidString:)) else {
      throw Failure.failed("Volume export did not return a job receipt")
    }
    _ = try await app.volumeBrush.waitForVolumeExport(id: exportID)
    try expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("edited-export.data").path) &&
               (try Data(contentsOf: editURL)) == originalData, "Export changed its source or didn't write the result")
    try await app.volumeBrush.duplicateState(name: "Test edit state")
    guard let savedID = app.volumeBrush.activeState?.id else { throw Failure.failed("No saved edit state") }
    let original = try await activeAgentBridge.executeTool(name: "select_edit_state",
      arguments: ["id": "original"], validateContext: {})
    try expect((original["structuredContent"] as? [String: Any])?["activeStateID"] == nil &&
               app.volumeBrush.activeState == nil, "Could not select the original edit state")
    let selected = try await activeAgentBridge.executeTool(name: "select_edit_state",
      arguments: ["id": savedID.uuidString], validateContext: {})
    let selectedStatus = selected["structuredContent"] as? [String: Any]
    try expect(selectedStatus?["activeStateID"] as? String == savedID.uuidString &&
               app.volumeBrush.activeState?.id == savedID, "Could not select a saved edit state")
    let managerBridge = BorgVRVoiceAgentBridge(service: service) {
      .init(datasetID: entry.uniqueId, openingID: newOpening, editStateID: app.volumeBrush.editingContextID)
    }
    let manager = VoiceAgentController(settings: recoveredSettings, conversationStore: isolatedConversationStore("edit-manager"))
    manager.configure(bridge: managerBridge)
    defer { manager.newConversation() }

    let savedView = fixture.appendingPathComponent("view.json")
    let savedClipping = service.applicationState().clipMinimum
    try service.setClipping(minimum: SIMD3(0.35, 0.35, 0.35), maximum: .one)
    let modifiedClipping = service.applicationState().clipMinimum
    let invalid = fixture.appendingPathComponent("bad-view.json")
    try Data("{}".utf8).write(to: invalid)
    var committed = false
    let invalidLoad = try await managerBridge.executeFileTool(name: "load_visualization_state", arguments: [:],
      select: { _ in invalid }, validateContext: {}, willCommit: { committed = true })
    try expect(!committed && (invalidLoad["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
               service.applicationState().clipMinimum == modifiedClipping, "Invalid visualization changed the renderer")
    await manager.submit("cancel-load-view")
    try await wait { manager.fileSelection != nil || !manager.busy }
    guard let skippedFile = manager.fileSelection else { throw Failure.failed("No local load picker") }
    manager.resolveFileSelection(id: skippedFile.id, url: nil)
    try await wait { !manager.busy }
    try expect(service.applicationState().clipMinimum == modifiedClipping &&
               manager.messages.last?.text == "View selection cancelled.", "Cancelling the picker changed the view")
    await manager.submit("load-view")
    try await wait { manager.fileSelection != nil || !manager.busy }
    guard let viewPicker = manager.fileSelection else { throw Failure.failed("No local visualization picker") }
    try expect(viewPicker.kind == .visualization, "Visualization loader did not request a JSON file")
    manager.resolveFileSelection(id: viewPicker.id, url: savedView)
    try await wait { !manager.busy }
    try expect(service.applicationState().clipMinimum == savedClipping && manager.messages.last?.text == "View loaded.",
               "Picking a saved view did not restore the original visualization")

    manager.newConversation()
    await manager.submit("edit-state-create")
    try await wait { !manager.busy }
    guard let emptyState = app.volumeBrush.activeState else { throw Failure.failed("Created state did not become active") }
    let emptyMask = try await app.volumeBrush.stateSnapshot().mask
    try expect(manager.connectionState == .ready && manager.messages.last?.text == "New edit state active." &&
               emptyState.name == "Assistant empty" && emptyState.id != savedID &&
               emptyMask.isOriginal, "Empty state or verified context switch failed: \(manager.messages.last?.text ?? "")")
    let extent = SIMD3<Double>(metadata.physicalExtentMeters)
    try await app.volumeBrush.editVolume(mode: .erase, samples: [
      .init(center: extent / 2, radius: min(extent.x, extent.y, extent.z) / 5)
    ])
    try expect(!(try await app.volumeBrush.stateSnapshot()).mask.isOriginal, "Edit fixture was empty")
    manager.newConversation()
    await manager.submit("edit-state-duplicate")
    try await wait { !manager.busy }
    guard let copy = app.volumeBrush.activeState else { throw Failure.failed("Duplicate did not become active") }
    let copyMask = try await app.volumeBrush.stateSnapshot().mask
    try expect(manager.connectionState == .ready && manager.messages.last?.text == "New edit state active." &&
               copy.id != emptyState.id && copy.name == "Assistant duplicate" &&
               !copyMask.isOriginal, "Duplicate did not preserve the edit mask: \(manager.messages.last?.text ?? "")")

    await manager.submit("edit-state-rename")
    try await wait { !manager.busy }
    try expect(manager.messages.last?.text == "Edit state renamed." && app.volumeBrush.activeState?.id == copy.id,
               "Renaming an inactive state changed selection")
    let bypass = try await managerBridge.executeTool(name: "delete_edit_state",
      arguments: ["id": emptyState.id.uuidString, "confirm": true], validateContext: {})
    try expect((bypass["structuredContent"] as? [String: Any])?["code"] as? String == "confirmation_required" &&
               managerBridge.prepareEditStateDeletion(id: copy.id) == nil, "Nonlocal or active-state deletion was allowed")
    guard let stale = managerBridge.prepareEditStateDeletion(id: emptyState.id) else { throw Failure.failed("Missing deletion preview") }
    try app.volumeBrush.renameState(emptyState.id, name: "Assistant delete target")
    let staleResult = try await managerBridge.executeEditStateDeletion(stale, validateContext: {})
    try expect((staleResult["structuredContent"] as? [String: Any])?["code"] as? String == "edit_state_changed",
               "A stale local confirmation deleted a renamed edit state")
    manager.newConversation()
    await manager.submit("edit-state-decline-delete")
    try await wait { manager.editStateDeletion != nil || !manager.busy }
    guard let declined = manager.editStateDeletion else { throw Failure.failed("No edit-state deletion confirmation") }
    manager.resolveEditStateDeletion(id: declined.id, accepted: false)
    try await wait { !manager.busy }
    try expect(manager.messages.last?.text == "Edit state deletion declined." &&
               app.volumeBrush.states.contains(where: { $0.id == emptyState.id }), "Declining did not preserve the targeted state")
    await manager.submit("edit-state-delete")
    try await wait { manager.editStateDeletion != nil || !manager.busy }
    guard let approved = manager.editStateDeletion else { throw Failure.failed("New request did not ask for local approval") }
    try expect(approved.stateID == emptyState.id && approved.name == "Assistant delete target",
               "Confirmation did not identify the exact inactive state")
    manager.resolveEditStateDeletion(id: approved.id, accepted: true)
    try await wait { !manager.busy }
    try expect(manager.messages.last?.text == "Edit state deleted." &&
               !app.volumeBrush.states.contains(where: { $0.id == emptyState.id }) &&
               app.volumeBrush.activeState?.id == copy.id && (try Data(contentsOf: editURL)) == originalData,
               "Deletion removed the wrong state or changed the source file")
    manager.newConversation()
    context = nil
    app.closeDataset(destination: .datasetSelection)
    recovered.invalidateContext()
    try await wait { recovered.connectionState != .connecting }
    await recovered.submit("application-state")
    try await wait { !recovered.busy }
    try expect(recovered.errorText == nil && recovered.messages.last?.text == "Start menu ready." &&
               recovered.messages.filter { $0.user }.count == 7 && recovered.volumeBrickStatus == nil,
               "Closing the dataset destroyed the app session or retained stale edit status")
    recovered.cancel()
    try expect(recovered.messages.count >= 6 && !recovered.speech.isRecording, "Session cancellation cleared conversation or started the microphone")
    recoveredSettings.savesConversation = false
    try await wait { !FileManager.default.fileExists(atPath: conversationStore.file.path) }
    try expect(!recovered.messages.isEmpty, "Turning off disk storage cleared the current in-memory conversation")
    recoveredSettings.savesConversation = true
    try await wait { FileManager.default.fileExists(atPath: conversationStore.file.path) }
    recovered.newConversation()
    try expect(recovered.messages.isEmpty && !FileManager.default.fileExists(atPath: conversationStore.file.path),
               "New conversation retained saved chat or receipts")
    try await testImportWorkflow(fixture: fixture, service: service, model: app)
    print("Voice agent tests passed: TLS/WSS, Command events and GSC roundtrip, collaboration, local save/export, import and fusion")
  }

  private static func testImportWorkflow(fixture: URL, service: BorgVRScreenCommandService, model: AppModel) async throws {
    let source = fixture.appendingPathComponent("tiny-registration.nrrd")
    var raw = Data("NRRD0005\ntype: uint8\ndimension: 3\nsizes: 12 12 12\nspacings: 1 1 1\nencoding: raw\n\n".utf8)
    for index in 0..<1728 {
      let value = (index * 37 + index / 13) % 251
      raw.append(UInt8(value))
    }
    try raw.write(to: source)
    let bridge = BorgVRVoiceAgentBridge(service: service, beginImport: {
      let id = try model.beginBackgroundImport()
      return .init(directory: fixture, brickSize: 32, overlap: 2, compression: true, borderMode: "border",
                   quantize: false, colorCompression: 0, filter: .trilinear, release: { model.finishBackgroundImport(id) })
    }) { nil }
    var status: VoiceAgentImportStatus?
    let observation = bridge.importUpdates.sink { status = $0 }
    defer { observation.cancel() }
    let cancelled = try await bridge.executeFileTool(name: "import_volume", arguments: ["filename": "cancelled", "source_kind": "file"],
      select: { _ in nil }, validateContext: {}, willCommit: {})
    try expect((cancelled["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true &&
               model.backgroundImportID == nil && status == nil, "Declined picker left an active import")
    let arguments = ["filename": "test-import", "source_kind": "file"]
    let receipt = try await bridge.executeFileTool(name: "import_volume", arguments: arguments,
      select: { _ in source }, validateContext: {}, willCommit: {})
    try expect((receipt["structuredContent"] as? [String: Any])?["status"] as? String == "running" &&
               model.backgroundImportID != nil, "Import did not acquire its renderer lease")
    try await wait { status?.active == false }
    let imported = fixture.appendingPathComponent("test-import.data")
    try expect(status?.phase == .completed && model.backgroundImportID == nil &&
               FileManager.default.fileExists(atPath: imported.path), "Native import failed: \(status?.detail ?? "")")
    let importedID = try BORGVRMetaData(url: imported).uniqueID
    let repeated = try await bridge.executeFileTool(name: "import_volume", arguments: arguments,
      select: { _ in source }, validateContext: {}, willCommit: {})
    try expect((repeated["structuredContent"] as? [String: Any])?["code"] as? String == "destination_exists" &&
               (try BORGVRMetaData(url: imported)).uniqueID == importedID, "Import overwrote an existing dataset")
    var picked = 0
    _ = try await bridge.executeFileTool(name: "fuse_volumes",
      arguments: ["filename": "test-fusion", "reference_kind": "file", "moving_kind": "file"],
      select: { _ in
        picked += 1
        return picked == 1 ? source : imported
      }, validateContext: {}, willCommit: {})
    try await wait(timeout: 60) { status?.active == false }
    let fused = try BORGVRMetaData(url: fixture.appendingPathComponent("test-fusion.data"))
    try expect(picked == 2 && status?.phase == .completed && fused.componentCount == 2 &&
               model.backgroundImportID == nil, "Fusion did not use both local inputs or release its renderer lease")
  }

  private static func wait(timeout: Int = 20, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while !condition() {
      if ContinuousClock.now > deadline { throw Failure.failed("Native agent test timed out at line \(line)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
