import SwiftUI
#if os(macOS)
import AppKit
#endif


// MARK: - ContentView
struct ContentView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  var body: some View {
    switch runtimeAppModel.currentState {
      case .start:
        ModeSelectionView()
      case .importData:
        ConverterView()
      case .serveData:
        ServerView()
      case .settings:
        SettingsView()
    }
  }
}

