import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    routedView
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
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
