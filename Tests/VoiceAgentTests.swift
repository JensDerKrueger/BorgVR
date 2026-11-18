import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Security
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
    let router = BorgVRMCPToolRouter(commandService: service)
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
    let diagnosticCatalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))
    try expect(try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]) ==
      JSONSerialization.data(withJSONObject: diagnosticCatalog, options: [.sortedKeys]),
      "Server diagnostic catalog differs from the native tools")
    let names = Set(catalog.compactMap { $0["name"] as? String })
    try expect(names == VoiceAgentPolicy.allowed, "Safe tools differ from the actual MCP catalog")
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
    settings.enabled = true
    settings.speaks = false
    settings.address = "https://127.0.0.1:\(ready["port"]!)"
    try settings.importCertificate(cert)
    try settings.setToken(String(contentsOf: fixture.appendingPathComponent("runtime/secrets/agent_token"), encoding: .utf8))
    try expect(!String(describing: defaults.dictionaryRepresentation()).contains(try settings.token()), "Token leaked to preferences")
    let agent = VoiceAgentController(settings: settings)
    var context: VoiceAgentContext? = .init(datasetID: entry.uniqueId, openingID: openingID, editStateID: nil)
    agent.configure(service: service) { context }
    try await agent.testServer()
    try expect(agent.errorText == nil && agent.model == "Qwen/Qwen3.6-35B-A3B", "Readiness failed: \(agent.errorText ?? "")")
    session.startCommandRecording()
    try await session.waitForRecordingPreparation()
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
    await agent.submit("wait")
    try await Task.sleep(for: .milliseconds(400))
    context = .init(datasetID: entry.uniqueId, openingID: UUID(), editStateID: nil)
    agent.invalidateContext()
    try expect(!agent.busy && agent.connectionState == .disconnected, "Reopening the same UUID did not cancel the agent")
    try await Task.sleep(for: .milliseconds(100))
    try expect(agent.connectionState == .disconnected, "Agent unexpectedly reconnected")
    print("Voice agent tests passed: strict policy, TLS trust, real WSS agent loop, PNG, command/GSC roundtrip and context cancellation")
  }

  private static func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
      if ContinuousClock.now > deadline { throw Failure.failed("Native agent test timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
