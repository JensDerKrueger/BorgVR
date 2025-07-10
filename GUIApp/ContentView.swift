import SwiftUI
#if os(macOS)
import AppKit
#endif


// MARK: - ContentView
struct ContentView: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    switch appModel.currentState {
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

