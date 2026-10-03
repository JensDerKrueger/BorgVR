import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var docking: DockingController
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
        closeAuxiliaryWindows()
      }
  }

  private func closeAuxiliaryWindows() {
    docking.resetForDatasetClose()
    for panel in DockablePanelID.allCases {
      dismissWindow(id: panel.windowID)
    }
    dismissWindow(id: "PerformanceGraphView")
    dismissWindow(id: "ScriptLogView")
  }

  @ViewBuilder
  private var routedView: some View {
    switch appModel.datasetSessionState {
      case .opening, .rendering, .closing:
        RenderView()
      case .waitingForSharePlay, .resolving:
        WaitingView()
      case .inactive:
        switch appModel.navigationState {
          case .start:
            ModeSelectionView()
          case .settings:
            SettingsView()
          case .importData:
            ConverterView()
          case .selectData:
            OpenDatasetView()
        }
    }
  }
}
