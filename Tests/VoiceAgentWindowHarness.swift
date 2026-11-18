import AppKit
import SwiftUI
@testable import BorgVR

@main
struct VoiceAgentWindowHarness: App {
  @StateObject private var agent: VoiceAgentController
  @StateObject private var appModel: AppModel

  init() {
    let defaults = UserDefaults(suiteName: "BorgVR.VoiceWindowHarness.\(UUID())")!
    defaults.set(true, forKey: "voiceAgent.enabled")
    let appModel = AppModel()
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("c60_32.data")
    let metadata = try! BORGVRMetaData(url: url)
    let dataset = AppModel.DatasetEntry(identifier: url.path, description: "Window test", source: .local,
                                        uniqueId: metadata.uniqueID)
    appModel.openDataset(dataset, automaticallyLoadState: false)
    guard case .opening(_, let id) = appModel.datasetSessionState else { fatalError("Dataset did not open") }
    appModel.prepareDatasetRenderer(key: appModel.activeDatasetRenderKey, metadata: metadata, requestID: id)
    _ = appModel.markRenderedDataset(key: appModel.activeDatasetRenderKey, requestID: id)
    let session = ScreenBorgVRSession.screen(appModel: appModel, renderingParameters: RenderingParameters(),
                                            appSettings: AppSettings())
    let agent = VoiceAgentController(settings:
      VoiceAgentSettings(defaults: defaults, tokenAccount: "voice-window-harness"))
    agent.configure(service: BorgVRScreenCommandService(session: session)) {
      guard case .rendering(let dataset, let id) = appModel.datasetSessionState else { return nil }
      return VoiceAgentContext(datasetID: dataset.uniqueId, openingID: id, editStateID: nil)
    }
    _agent = StateObject(wrappedValue: agent)
    _appModel = StateObject(wrappedValue: appModel)
  }

  var body: some Scene {
    Window("Voice Window Test", id: "main") {
      VoiceHarnessContent(agent: agent, closeDataset: { appModel.closeDataset(destination: .datasetSelection) })
        .environmentObject(agent)
        .onChange(of: appModel.datasetSessionState) { _, _ in agent.invalidateContext() }
    }
    .defaultSize(width: 700, height: 700)

    BorgVRUtilityWindow(title: "AI Assistant Test", id: VoiceAgentView.windowID, width: 580, height: 580) {
      VoiceAgentView(agent: agent)
    }
  }
}

private struct VoiceHarnessContent: View {
  @ObservedObject var agent: VoiceAgentController
  let closeDataset: () -> Void
  @State private var actions = 0
  @State private var report = ""
  @State private var settings = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VoiceAgentButton(agent: agent)
        Button("Renderer action") { actions += 1 }
        Text("Actions: \(actions)")
        Button("Close dataset", action: closeDataset)
        Toggle("Settings", isOn: $settings)
      }
      Button("Inspect assistant windows") {
        let windows = NSApp.windows.filter { $0.identifier?.rawValue == VoiceAgentView.windowID && $0.isVisible }
        report = "Windows: \(windows.count), floating: \(windows.allSatisfy { ($0 as? NSPanel)?.isFloatingPanel == true }), modal: \(NSApp.modalWindow != nil), sheet: \(windows.contains { $0.sheetParent != nil }), active: \(NSApp.isActive)\n" +
          NSApp.windows.map { "\($0.title) [\($0.identifier?.rawValue ?? "nil")] visible=\($0.isVisible)" }.joined(separator: "\n")
      }
      Text(report)
      Divider()
      ScrollView {
        if settings { VoiceAgentSettingsView(agent: agent) }
        else {
          VoiceAgentMarkdownText("# Head bones\n\nShowing **only the skull**, with *soft tissue hidden*.\n\n- Clipping enabled\n- Transfer function adjusted\n  - Bone opacity: **high**\n\n1. Read the current state\n2. Inspect the screenshot\n\n> The final check confirms the current view.\n\n```gsc\nrotate 20\nclip true\n```\n\n| Channel | State |\n| --- | --- |\n| R | visible |\n| A | opaque |")
        }
      }
    }
    .padding(20)
    .frame(minWidth: 500, minHeight: 450)
  }
}
