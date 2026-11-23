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
    for address in ["https://ai1", "https://192.168.1.50:8766", "https://localhost:8766/v1"] {
      let endpoint = try VoiceAgentEndpoint(address)
      try expect(endpoint.origin.scheme == "https" && endpoint.origin.path.isEmpty, "Invalid endpoint")
    }
    for address in ["http://ai1", "https://user:token@ai1", "https://ai1/path", "https://ai1?token=x",
                    "https://ai1#fragment", "https://0.0.0.0", "https://ai1:0", "https://ai1:99999"] {
      try rejects { _ = try VoiceAgentEndpoint(address) }
    }
    try rejects { try VoiceAgentEndpoint.validateToken("short") }
    try rejects { try VoiceAgentEndpoint.validateToken(String(repeating: "a", count: 64) + "\r\nInjected") }
    let projection = VoiceAgentVolumePreview(width: 2, height: 1, depth: 2, samples: [0.1, 0.6, 0.8, 0.55])
    try expect(try previewRGBA(projection.render(low: 0, high: 0.2, rainbow: false)) == [26, 26, 26, 255, 0, 0, 0, 0],
               "An isolated opacity band leaked another band")
    try expect(try previewRGBA(projection.render(low: 0.5, high: 0.7, rainbow: false)) == [0, 0, 0, 0, 153, 153, 153, 255],
               "Only the first sample inside the band should color a projection ray")
    let colored = try previewRGBA(projection.render(low: 0.5, high: 0.7, rainbow: true))
    try expect(colored[7] == 255 && colored[4] != colored[6], "The rainbow palette did not color the visible pixel")

    let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
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
    let scanTimer = ContinuousClock()
    let scanStart = scanTimer.now
    let preview = try VoiceAgentVolumePreview.read(BORGVRFileData(filename: CommandLine.arguments[1]), channel: 0)
    let loadTime = scanStart.duration(to: scanTimer.now)
    try expect(preview.samples.max() ?? 0 > 0 && preview.samples.min() != preview.samples.max(), "Dataset preview is blank")
    let imagesStart = scanTimer.now
    for i in 0..<5 {
      let png = try preview.render(low: Double(i) / 5, high: Double(i + 1) / 5, rainbow: false)
      try expect(CGImageSourceCreateWithData(png as CFData, nil) != nil, "Dataset preview did not encode as PNG")
    }
    print("Isolated intensity preview: load=\(loadTime), five previews=\(imagesStart.duration(to: scanTimer.now))")
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
    let before = session.currentSnapshot().transform
    do {
      _ = try await router.callTool(name: "rotate_view", arguments: ["axis": [0, 1, 0], "degrees": 30],
                                   validateContext: { throw VoiceAgentError.contextChanged })
      throw Failure.failed("Stale agent context was dispatched")
    } catch is VoiceAgentError {}
    try expect(session.currentSnapshot().transform == before, "Context check happened after mutation")
    let definitions = router.toolDefinitions + VoiceAgentPolicy.importCatalog + [VoiceAgentPolicy.intensityPreviewTool]
    let catalog = VoiceAgentPolicy.catalog(definitions, vision: false, transferFunctions: true, images: true)
    let applicationCatalog = VoiceAgentPolicy.catalog(definitions, vision: false,
      transferFunctions: true, images: true, datasetReady: false)
    let diagnosticTools = catalog + applicationCatalog.filter {
      VoiceAgentPolicy.conversionTools.contains($0["name"] as? String ?? "")
    }
    let names = Set(diagnosticTools.compactMap { $0["name"] as? String })
    try expect(names == VoiceAgentPolicy.allowed.union(VoiceAgentPolicy.additionalTools), "Safe tools differ from the actual MCP catalog")
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
    let resized = try BorgVRAssistantCore.imageForModel(png as Data)
    try expect(resized.width <= 1024 && resized.height <= 1024 && resized.data.count <= 2097152, "Image bounds exceeded")
    let positionBuffer = BorgVRScreenshotPositions(depth: Data(count: 1600 * 1200 * 4), depthBytesPerRow: 1600 * 4,
      clipToVolume: matrix_identity_float4x4, columns: Array(repeating: 0.5, count: 1600),
      rows: Array(repeating: 0.5, count: 1200))
    app.renderScreenshotHandler = { id, url, _, maxWidth, completion in
      do {
        guard let url else { throw Failure.failed("No screenshot destination") }
        let image = try maxWidth.map { try BorgVRAssistantCore.imageForModel(png as Data, sizes: [$0]).data }
        try (image ?? png as Data).write(to: url)
        app.screenshotCache.begin(id)
        app.screenshotCache.store(positionBuffer, id: id, renderedFrame: app.completedRenderFrameCount)
        completion(.success(url))
      } catch { completion(.failure(error)) }
    }
    let suite = "BorgVRVoiceTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let account = "voice-agent-test-\(UUID())"
    let legacyToken = String(repeating: "a", count: 64)
    let legacyCloud = String(repeating: "o", count: 64)
    defaults.set("https://localhost:8766", forKey: "voiceAgent.address")
    defaults.set(der, forKey: "voiceAgent.certificate")
    defaults.set("gpt-6.2-sol", forKey: "assistant.openAIModel")
    try KeychainSecretStore.setString(legacyToken, account: account)
    try KeychainSecretStore.setString(legacyCloud, account: account + "-openai")
    defer { defaults.removePersistentDomain(forName: suite); try? KeychainSecretStore.delete(account: account) }
    let settings = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    func isolatedConversationStore(_ name: String) -> VoiceAgentConversationStore {
      .init(file: fixture.appendingPathComponent("conversation-\(name)/conversation.sealed"),
            keyAccount: "\(account)-conversation-\(name)")
    }
    try expect(settings.workMinutes == 60, "Default work time changed")
    try expect(settings.hasToken && settings.profiles.count == 2, "Existing provider settings did not migrate")
    guard let local = settings.selectedProfile, let cloud = settings.profiles.first(where: { $0.provider == .openAI }) else {
      throw Failure.failed("Missing migrated profiles")
    }
    try expect(local.trustedCertificate == der && settings.hasSavedToken(for: cloud) && !cloud.sharesImages,
               "Certificate, credential, or consent was not isolated in the migration")
    var differentHost = local
    differentHost.address = "https://ai2.example.org:8766"
    try expect(!settings.hasSavedToken(for: differentHost) && differentHost.trustedCertificate.isEmpty,
               "A draft endpoint change reused the old token or certificate")
    try rejects { _ = try settings.modelClient(for: differentHost) }
    var ai2 = VoiceAgentProfile(provider: .vllm, name: "ai2")
    ai2.address = differentHost.address
    ai2.sharesImages = true
    let ai2Token = String(repeating: "b", count: 64)
    try settings.saveProfile(ai2, token: ai2Token)
    defer { try? settings.removeProfile(ai2.id) }
    var secondCloud = VoiceAgentProfile(provider: .openAI, name: "Second cloud model")
    secondCloud.model = "alternate-model"
    try settings.saveProfile(secondCloud, token: nil)
    try expect(!settings.hasSavedToken(for: secondCloud) && settings.selectedProfileID == local.id,
               "Adding a profile inherited a key or automatically switched models")
    settings.selectProfile(ai2.id)
    let reopened = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    try expect(reopened.selectedProfileID == ai2.id && reopened.sharesProviderImages && reopened.hasToken,
               "Selected model profile did not persist")
    try settings.removeProfile(ai2.id)
    try expect(settings.selectedProfileID == local.id && settings.hasToken && settings.hasSavedToken(for: cloud),
               "Removing ai2 cleared another model profile")
    let serialized = defaults.data(forKey: "assistant.modelProfiles").map { String(decoding: $0, as: UTF8.self) } ?? ""
    try expect(!serialized.contains(legacyToken) && !serialized.contains(legacyCloud) && !serialized.contains(ai2Token),
               "Model credentials leaked to preferences")
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
    settings.selectProfile(cloud.id)
    try expect(settings.hasToken && !settings.sharesProviderImages, "OpenAI reused local render consent")
    settings.selectProfile(local.id)
    defer { try? KeychainSecretStore.delete(account: account + "-openai") }
    let initialIdentity = settings.identity
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
    let store = isolatedConversationStore("core")
    defer { try? store.remove() }
    var archive = VoiceAgentCommandHistory<VoiceAgentContext?>()
    archive.appendMessage(scope: bridge.context, user: true, text: "Keep a local record.")
    try store.save(archive, owner: settings.archiveOwnerID)
    try expect(try store.load(owner: settings.archiveOwnerID)?.transcript.first?.text == "Keep a local record.",
               "Local opt-in conversation did not round-trip")
    for profile in settings.profiles { try settings.removeProfile(profile.id) }
    let empty = VoiceAgentSettings(defaults: defaults, tokenAccount: account)
    try expect(empty.profiles.isEmpty && empty.selectedProfileID == nil && !empty.hasToken,
               "Deleted profiles were recreated from legacy settings")
    app.closeDataset(destination: .datasetSelection)
    try await testImportWorkflow(fixture: fixture, service: service, model: app)
    print("Native assistant tests passed: TLS trust, provider separation, local policy, screenshots, import and fusion")
  }

  static func previewRGBA(_ data: Data) throws -> [UInt8] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.failed("Invalid preview PNG") }
    var pixels = [UInt8](repeating: 0, count: 8)
    try pixels.withUnsafeMutableBytes { pointer in
      guard let canvas = CGContext(data: pointer.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw Failure.failed("Could not decode preview") }
      canvas.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
    }
    return pixels
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
