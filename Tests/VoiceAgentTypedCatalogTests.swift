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
    settings.address = "https://127.0.0.1:\(port)"
    try settings.importCertificate(certificate)
    try settings.setToken(token)

    for request in ["scope-start", "scope-renderer", "scope-sweep"] {
      let rendering = request != "scope-start"
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
        if request == "scope-sweep" {
          let file = try BORGVRFileData(filename: dataset)
          _ = app.volumeBrush.open(file, datasetURL: fixture.appending(path: "test-volume.data"))
          let deadline = ContinuousClock.now + .seconds(5)
          while app.volumeBrush.isOpeningState && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
          }
          guard !app.volumeBrush.isOpeningState, app.volumeBrush.supportsIntensityPreview else {
            throw Failure.failed("Preview volume was not prepared")
          }
        }
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
      let bundleURL = URL(fileURLWithPath: CommandLine.arguments[3]).deletingLastPathComponent().appending(path: "knowledge-bundle.json")
      let bundle = request == "scope-sweep"
        ? try JSONSerialization.jsonObject(with: Data(contentsOf: bundleURL)) as? [String: Any] : nil
      let controller = VoiceAgentController(settings: settings, expertKnowledgeSource: expertise, bundledKnowledge: bundle)
      controller.configure(bridge: bridge)
      let before = session.currentSnapshot().transform
      let beforeTF = try? service.transferFunction(channel: 0).validatedSamples()
      await controller.submit(request)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(20))
      while controller.busy && clock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
      }
      let final = request == "scope-sweep" ? "Sweep completed without changing the view." : "Catalog and rules received."
      guard controller.errorText == nil, controller.messages.last?.text == final else {
        throw Failure.failed("\(request): \(controller.errorText ?? "No response")")
      }
      guard request != "scope-renderer" || session.currentSnapshot().transform != before else {
        throw Failure.failed("The new server did not execute the typed rotation")
      }
      if request == "scope-sweep" {
        let afterTF = try service.transferFunction(channel: 0).validatedSamples()
        guard controller.messages.contains(where: { $0.text == "Ich schaue, welche Strukturen sich sichtbar machen lassen." }),
              beforeTF == afterTF, session.currentSnapshot().transform == before else {
          throw Failure.failed("Sweep did not announce itself or changed the visualization")
        }
        app.volumeBrush.close()
      }
      controller.cancel()
    }
    let observer = try String(contentsOf: fixture.appending(path: "observer-token.txt"), encoding: .utf8)
    try settings.setObserverToken(observer)
    defer { try? settings.setObserverToken("") }
    let learner = VoiceAgentLearnerStore(directory: fixture.appending(path: "client-learner"))
    _ = try await learner.fetch(settings)
    guard let entry = learner.entries(settings).first, entry.guidance != nil, entry.program != nil,
          let hypotheses = learner.cached(settings)?["hypotheses"] as? [[String: Any]], hypotheses.count == 1,
          learner.offer(settings, bundled: nil) == nil else {
      throw Failure.failed("The native client did not cache an inactive hypothesis with both knowledge parts")
    }
    try learner.setApproval(true, entry: entry, part: .guidance, settings: settings)
    guard let allowed = learner.offer(settings, bundled: nil)?["entries"] as? [[String: Any]],
          allowed.count == 1, allowed[0]["guidance"] != nil, allowed[0]["procedure"] == nil else {
      throw Failure.failed("The native client did not keep the two knowledge approvals independent")
    }
    print("Native TLS/WSS catalog, 270 state reads, rotation, and read-only native intensity sweep passed.")
    print("Native learner checkpoint download and independent local approvals passed.")
  }
}
