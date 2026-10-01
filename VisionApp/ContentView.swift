import SwiftUI

/**
 A container view that derives dataset presentation from `datasetSessionState`
 and uses `navigationState` only while no dataset session is active.
 */
struct ContentView: View {
  /// The shared application model injected into the environment, holding app state.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  /// The body of the view, switching between subviews according to the current state.
  @ViewBuilder
  var body: some View {
    switch runtimeAppModel.datasetSessionState {
      case .waitingForSharePlay, .resolving:
        WaitingView()
      case .opening, .rendering:
        RenderView()
      case .closing(_, _, let destination):
        switch destination {
          case .datasetSelection:
            RenderView()
          case .sharePlayWaiting:
            WaitingView()
        }
      case .inactive:
        navigationContent
    }
  }

  @ViewBuilder
  private var navigationContent: some View {
    switch runtimeAppModel.navigationState {
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

// MARK: - Preview

#Preview {
  ContentView()
    .environment(RuntimeAppModel())
    .environment(SharedAppModel())
    .environmentObject(StoredAppModel())
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
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
