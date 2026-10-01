import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    routedView
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        Color(.systemBackground)
          .ignoresSafeArea()
      }
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
