import Foundation
@testable import BorgVR

private enum Failure: Error { case failed(String) }

@MainActor
@main
struct VoiceAgentTypedCatalogTests {
  static func main() async throws {
    let dataset = CommandLine.arguments[1]
    let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
    let source = try String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
    let ready = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: fixture.appending(path: "ready.json")))
    guard let port = ready["port"] else { throw Failure.failed("Missing fixture port") }
    let certificate = try Data(contentsOf: fixture.appending(path: "runtime/tls/server.crt"))
    let token = try String(contentsOf: fixture.appending(path: "runtime/secrets/agent_token"), encoding: .utf8)
    let identifier = "dev.borgvr.typed-catalog." + UUID().uuidString
    let defaults = UserDefaults(suiteName: identifier)!
    let settings = VoiceAgentSettings(defaults: defaults, tokenAccount: identifier)
    defer {
      try? settings.setToken("")
      defaults.removePersistentDomain(forName: identifier)
    }
    settings.enabled = true
    settings.speaks = false
    settings.sharesImages = true
    settings.maximumCalls = 24
    settings.address = "https://127.0.0.1:\(port)"
    try settings.importCertificate(certificate)
    try settings.setToken(token)

    for rendering in [false, true] {
      let request = rendering ? "scope-renderer" : "scope-start"
      settings.workMinutes = rendering ? 180 : 60
      let app = AppModel()
      var context: VoiceAgentContext?
      if rendering {
        let metadata = try BORGVRMetaData(url: URL(fileURLWithPath: dataset))
        let entry = AppModel.DatasetEntry(identifier: dataset, description: "Synthetic catalog test",
                                          source: .local, uniqueId: metadata.uniqueID)
        app.openDataset(entry, automaticallyLoadState: false)
        guard case .opening(_, let opening) = app.datasetSessionState else {
          throw Failure.failed("Expected a test dataset")
        }
        app.prepareDatasetRenderer(key: app.activeDatasetRenderKey, metadata: metadata, requestID: opening)
        _ = app.markRenderedDataset(key: app.activeDatasetRenderKey, requestID: opening)
        app.recordCompletedRenderFrame(datasetKey: app.activeDatasetRenderKey, missingBrickCount: 0)
        context = .init(datasetID: entry.uniqueId, openingID: opening, editStateID: nil)
      }
      let session = ScreenBorgVRSession.screen(appModel: app,
        renderingParameters: RenderingParameters(), appSettings: AppSettings())
      let service = BorgVRScreenCommandService(session: session)
      let bridge = BorgVRVoiceAgentBridge(service: service, beginImport: { throw VoiceAgentError.commandFailed }) { context }
      let catalog = VoiceAgentPolicy.catalog(bridge.toolDefinitions, vision: false,
        transferFunctions: bridge.hasTransferFunctions, images: true, datasetReady: rendering)
      let expected = VoiceAgentPolicy.wireCatalog(catalog, typed: true)
      guard !VoiceAgentPolicy.wireCatalog(catalog, typed: false).contains(where: {
        $0["name"] as? String == "set_transfer_function_component"
      }) else { throw Failure.failed("TF component setter advertised to the legacy agent") }
      let component = expected.first { $0["name"] as? String == "set_transfer_function_component" }
      if rendering {
        guard let schema = component?["inputSchema"] as? [String: Any],
              Set(schema["required"] as? [String] ?? []) == ["channel", "component", "points"],
              (component?["execution"] as? [String: Any])?["kind"] as? String == "mutation" else {
          throw Failure.failed("Missing typed TF component setter")
        }
      } else if component != nil {
        throw Failure.failed("TF component setter advertised without a dataset")
      }
      try JSONSerialization.data(withJSONObject: expected).write(to: fixture.appending(path: request + ".json"))
      let expertise = source + "\n[tests.connection]\ngoal = \"Fixture only\"\nsteps = [\"\(request.uppercased())\"]\n"
      let controller = VoiceAgentController(settings: settings, expertKnowledgeSource: expertise)
      controller.configure(bridge: bridge)
      await controller.submit(request)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(20))
      while controller.busy && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      guard controller.errorText == nil, controller.messages.last?.text == "Catalog and rules received." else {
        throw Failure.failed("\(request): \(controller.errorText ?? "No response")")
      }
      controller.cancel()
    }
    print("Native typed catalog and per-connection knowledge reached the model over TLS/WSS; 60 calls completed.")
  }
}
