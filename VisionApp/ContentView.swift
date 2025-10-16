import SwiftUI

/**
 A container view that dynamically displays one of several subviews based on the current state of the application.

 This view observes the shared `AppModel` to determine which view to display:

 - `.start`: presents the `ModeSelectionView`.
 - `.settings`: presents the `SettingsView`.
 - `.importData`: presents the `ConverterView`.
 - `.selectData`: presents the `OpenDatasetView`.
 - `.renderData`: presents the `RenderView`.
 - `.waitingForHost`: presents the `WaitingView`.
 */
struct ContentView: View {
  /// The shared application model injected into the environment, holding app state.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  /// The body of the view, switching between subviews according to the current state.
  var body: some View {
    switch runtimeAppModel.currentState {
      case .start:
        /// Show the initial mode selection screen.
        ModeSelectionView()
      case .settings:
        /// Show the application settings screen.
        SettingsView()
      case .importData:
        /// Show the data conversion/import screen.
        ConverterView()
      case .selectData:
        /// Show the dataset selection screen.
        OpenDatasetView()
      case .renderData:
        /// Show the main rendering view for volumetric data.
        RenderView()
      case .waitingForHost:
        /// Show a window that tells the users that they are waiting for the host to open a dataset.
        WaitingView()
      @unknown default:
        /// Handle any future unknown states.
        Text("Unknown state")
          .foregroundColor(.red)
    }
  }
}

// MARK: - Preview

#Preview {
  ContentView()
    .environment(RuntimeAppModel())
    .environment(SharedAppModel())
    .environmentObject(StoredAppModel())
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
