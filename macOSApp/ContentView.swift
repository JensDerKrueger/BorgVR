import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var docking: DockingController
  @EnvironmentObject private var scriptRunner: BorgVRScriptRunner
  @EnvironmentObject private var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @StateObject private var importOpenWorkflow = DatasetOpenWorkflow()
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    routedView
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .disabled(importOpenWorkflow.isOpening)
      .alert("Dataset could not be opened", isPresented: Binding(
        get: { importOpenWorkflow.openErrorMessage != nil },
        set: { if !$0 { importOpenWorkflow.openErrorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(importOpenWorkflow.openErrorMessage ?? "")
      }
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
            ConverterView(
              onClose: {
                appModel.navigationState = .start
              },
              onMeshImport: { outputURL in
                NotificationCenter.default.post(
                  name: SceneMeshAssetCatalog.didChangeNotification,
                  object: outputURL
                )
              },
              onOpenDataset: { url in
                importOpenWorkflow.startOpeningImportedDataset(
                  at: url, appModel: appModel, appSettings: appSettings, sharePlay: sharePlay,
                  storage: DatasetStorageAccess(
                    directoryURL: storedAppModel.resolvedDataDirectoryURL(),
                    beginAccess: { storedAppModel.startAccessingDataDirectory() },
                    endAccess: { storedAppModel.stopAccessingDataDirectory($0) }
                  )
                )
              }
            )
          case .selectData:
            OpenDatasetView()
        }
    }
  }
}
