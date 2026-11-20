import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Security
import AVFoundation
import Combine
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
    let lifecycleStart = commandEvents.count
    do {
      try await session.performAction(.discardVolumeEdits, source: .userInterface) { () async throws -> Void in
        await Task.yield()
        throw Failure.failed("Synthetic edit failure")
      }
      throw Failure.failed("Failed action was swallowed")
    } catch Failure.failed(let message) {
      try expect(message == "Synthetic edit failure", "Wrong async action failure")
    }
    let lifecycle = Array(commandEvents.dropFirst(lifecycleStart))
    try expect(lifecycle.count == 2 && lifecycle[0].phase == .began && lifecycle[1].phase == .failed &&
               lifecycle[0].id == lifecycle[1].id, "Manual async action did not publish a paired lifecycle")
    let before = session.currentSnapshot().transform
    do {
      _ = try await router.callTool(name: "rotate_view", arguments: ["axis": [0, 1, 0], "degrees": 30],
                                   validateContext: { throw VoiceAgentError.contextChanged })
      throw Failure.failed("Stale agent context was dispatched")
    } catch is VoiceAgentError {}
    try expect(session.currentSnapshot().transform == before, "Context check happened after mutation")
    let catalog = VoiceAgentPolicy.catalog(router.toolDefinitions, vision: false, transferFunctions: true, images: true)
    let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("BorgVRAgentServer/diagnostic_catalog.json")
    if ProcessInfo.processInfo.environment["BORGVR_WRITE_AGENT_CATALOG"] == "1" {
      try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys, .prettyPrinted]).write(to: catalogURL)
    }
    let diagnosticCatalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
    try expect(try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]) ==
      JSONSerialization.data(withJSONObject: diagnosticCatalog, options: [.sortedKeys]),
      "Server diagnostic catalog differs from the native tools")
    let names = Set(catalog.compactMap { $0["name"] as? String })
    try expect(names == VoiceAgentPolicy.allowed, "Safe tools differ from the actual MCP catalog")
    let applicationCatalog = VoiceAgentPolicy.catalog(router.toolDefinitions, vision: false,
      transferFunctions: true, images: true, datasetReady: false)
    try expect(Set(applicationCatalog.compactMap { $0["name"] as? String }) == VoiceAgentPolicy.applicationTools,
               "Renderer commands exposed without a dataset")
    let screenshot = catalog.first { $0["name"] as? String == "capture_screenshot" }!["inputSchema"] as! [String: Any]
    try rejects { try VoiceAgentPolicy.validate(["output_path": "/tmp/forbidden.png"], schema: screenshot) }
    try rejects { try VoiceAgentPolicy.validate(["include_alpha": 1], schema: screenshot) }
    try VoiceAgentPolicy.validate(["include_alpha": false], schema: screenshot)
    let rotate = catalog.first { $0["name"] as? String == "rotate_view" }!["inputSchema"] as! [String: Any]
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1, 0], "degrees": true], schema: rotate) }
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1], "degrees": 30], schema: rotate) }
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1, 0], "degrees": Double.infinity], schema: rotate) }
    try rejects { try VoiceAgentPolicy.validate(["axis": [0, 1, 0], "degrees": 30, "path": "/secret"], schema: rotate) }
    let rgb = VoiceAgentPolicy.catalog(router.toolDefinitions, vision: true, transferFunctions: false, images: false)
    try expect(!rgb.contains { ["set_transfer_function", "set_render_mode", "capture_screenshot",
                               "set_screen_projection", "set_background"].contains($0["name"] as? String ?? "") }, "Unsupported tools exposed")

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
    app.renderScreenshotHandler = { _, url, _, completion in
      do {
        guard let url else { throw Failure.failed("No screenshot destination") }
        try (png as Data).write(to: url)
        completion(.success(url))
      } catch { completion(.failure(error)) }
    }
    let suite = "BorgVRVoiceTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let account = "voice-agent-test-\(UUID())"
    defer { defaults.removePersistentDomain(forName: suite); try? KeychainSecretStore.delete(account: account) }
    let settings = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    try expect(settings.workMinutes == 30 && settings.maximumCalls == 256, "Long-run defaults missing")
    settings.workMinutes = 60
    settings.maximumCalls = 512
    let persisted = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    try expect(persisted.workMinutes == 60 && persisted.maximumCalls == 512, "Execution settings not persisted")
    settings.workMinutes = 999
    settings.maximumCalls = -1
    try expect(settings.workMinutes == 120 && settings.maximumCalls == 24, "Execution settings not bounded")
    settings.workMinutes = 30
    settings.maximumCalls = 256
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
    settings.address = "https://127.0.0.1:\(ready["port"]!)"
    try settings.importCertificate(cert)
    try settings.setToken(String(contentsOf: fixture.appendingPathComponent("runtime/secrets/agent_token"), encoding: .utf8))
    try expect(!String(describing: defaults.dictionaryRepresentation()).contains(try settings.token()), "Token leaked to preferences")
    let emptyApp = AppModel()
    let emptySession = ScreenBorgVRSession.screen(appModel: emptyApp,
      renderingParameters: RenderingParameters(), appSettings: AppSettings())
    let startAgent = VoiceAgentController(settings: settings)
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
    let catalogAgent = VoiceAgentController(settings: settings)
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
    let agent = VoiceAgentController(settings: settings)
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
    try expect(agent.messages.contains { $0.text == "Inspecting the synthetic volume." }, "Progress message missing")
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
    try service.clearObjects()
    try service.clearMeasurements()
    agent.newConversation()
    await agent.submit("collaborate")
    try await wait { agent.messages.contains { $0.text == "Waiting for manual edit." } }
    try service.rotate(axis: [1, 0, 0], degrees: 15)
    let userTransform = session.currentSnapshot().transform
    try expect(agent.userIsInteracting, "Manual change did not pause the active agent")
    try await wait { agent.collaborationQuestion != nil }
    try expect(agent.busy && !agent.userIsInteracting && agent.errorText == nil, "User priority lost the current task")
    await agent.submit("Yes, I wanted to show a better section.")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Collaborative task completed without undoing your change.",
               "Collaborative run failed: \(agent.errorText ?? "")")
    try expect(session.currentSnapshot().transform == userTransform, "Agent undid the manual rotation")
    try expect(settings.knowledgeRules.isEmpty && agent.ruleProposals.count == 1, "A rule was saved without user approval")
    await agent.decideRule(agent.ruleProposals[0], remember: true)
    try expect(settings.knowledgeRules.count == 1 && agent.ruleProposals.isEmpty, "Explicit approval did not save the rule")
    try expect(VoiceAgentSettings(defaults: defaults, tokenAccount: account).knowledgeRules.count == 1, "Confirmed rule missing on reload")
    agent.newConversation()
    await agent.submit("long-run")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Long native run passed.",
               "More than 24 BorgVR calls failed: \(agent.errorText ?? "")")

    agent.newConversation()
    await agent.submit("replace-source")
    try await wait { agent.messages.contains { $0.text == "Old request waiting." } }
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
    for (prompt, expectedError) in [("context-before-change", VoiceAgentError.contextLimit),
                                     ("context-after-change", .changesAppliedContextLimit),
                                     ("verification-failed", .changesAppliedVerificationFailed)] {
      agent.newConversation()
      await agent.submit(prompt)
      try await wait { !agent.busy }
      try expect(agent.errorText == expectedError.localizedDescription,
                 "Wrong partial-success/context error for \(prompt): \(agent.errorText ?? "")")
      try expect(agent.connectionState == .disconnected, "Failed request must not be replayed")
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
    context = nil
    app.closeDataset(destination: .datasetSelection)
    agent.invalidateContext()
    try await wait { agent.connectionState != .connecting }
    await agent.submit("application-state")
    try await wait { !agent.busy }
    try expect(agent.errorText == nil && agent.messages.last?.text == "Start menu ready." &&
               agent.messages.filter { $0.user }.count == 3, "Closing the dataset destroyed the app session")
    agent.cancel()
    try expect(agent.messages.count >= 6 && !agent.speech.isRecording, "Session cancellation cleared conversation or started the microphone")
    print("Voice agent tests passed: TLS/WSS, GSC roundtrip, generic Command events, user-priority collaboration, explicit local rules, long runs and safe cancellation")
  }

  private static func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
      if ContinuousClock.now > deadline { throw Failure.failed("Native agent test timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
