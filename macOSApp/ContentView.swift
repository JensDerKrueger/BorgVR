import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var scriptRunner: BorgVRScriptRunner
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    routedView
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .onChange(of: scriptRunner.scriptLogWindowRequest) { _, _ in
        openWindow(id: "ScriptLogView")
      }
      .onDisappear {
        dismissWindow(id: "ScriptLogView")
      }
  }

  @ViewBuilder
  private var routedView: some View {
    switch appModel.currentState {
      case .start:
        ModeSelectionView()
      case .settings:
        SettingsView()
      case .importData:
        ConverterView()
      case .selectData:
        OpenDatasetView()
      case .renderData:
        RenderView()
      case .waitingForHost:
        WaitingView()
    }
  }
}
