import SwiftUI

/**
 A SwiftUI view exposing high-level render options for BorgVR.

 This view lets the user:

 - Select the active render mode (1D transfer function with/without
 lighting, or isovalue rendering).
 - Open the interaction / private application window.
 - Optionally open profiling tools.
 - Close the currently active dataset (immersive space).

 It also ensures that the `PrivateApplicationView` is opened on first
 appearance and cleans up auxiliary windows plus voice input when the
 view disappears or the scene goes into the background.
 */
struct RenderView: View {
  /// Global runtime application model (window state, immersion state, etc.).
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  /// Shared rendering parameters (current render mode, transfer function, …).
  @Environment(SharedAppModel.self) private var sharedAppModel

  /// Persistent user settings and profiling options.
  @EnvironmentObject var storedAppModel: StoredAppModel

  /// Scene phase, used to close the dataset when the app goes to background.
  @Environment(\.scenePhase) private var scenePhase

  /// Dismisses the immersive space when requested.
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

  /// Opens auxiliary windows (editors, profiling, etc.).
  @Environment(\.openWindow) private var openWindow

  /// Dismisses auxiliary windows by identifier.
  @Environment(\.dismissWindow) private var dismissWindow

  /// Voice recognition service shared across views.
  @EnvironmentObject var voice: VoiceCommandService

  /// Text-to-speech helper used for voice feedback.
  @EnvironmentObject var speech: SpeechHelper

  var body: some View {
    VStack(spacing: 20) {
      Text("render_title")
        .font(.title)
        .bold()
        .onAppear {
          if !runtimeAppModel.isViewOpen("PrivateApplicationView") {
            openWindow(id: "PrivateApplicationView")
          }
        }

      Picker(
        "render_picker_title",
        selection: Binding(
          get: { sharedAppModel.renderMode },
          set: { newValue in
            sharedAppModel.renderMode = newValue
            sharedAppModel.synchronize(kind: .stateOnly)
          }
        )
      ) {
        Text("renderMode_transferFunction1DLighting")
          .tag(RenderMode.transferFunction1DLighting)
        Text("renderMode_transferFunction1D")
          .tag(RenderMode.transferFunction1D)
        Text("renderMode_isoValue")
          .tag(RenderMode.isoValue)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)

      Button("render_button_open_interaction") {
        if !runtimeAppModel.isViewOpen("PrivateApplicationView") {
          openWindow(id: "PrivateApplicationView")
        }
      }

      Spacer()

      HStack {
        if storedAppModel.showProfiling {
          Button(action: openProfileView) {
            Text("render_button_profiling")
              .font(.headline)
              .padding(.horizontal, 20)
              .padding(.vertical, 10)
          }
          .padding()
        }

        ShareLink(
          item: BorgVRActivity(),
          preview: SharePreview(
            NSLocalizedString(
              "render_share_preview_title",
              comment: "Title for live collaboration share preview"
            )
          )
        )
        .simultaneousGesture(
          TapGesture().onEnded {
            sharedAppModel.markLocalActivityStarter()
          }
        )
        .padding()

        Button(action: closeDataset) {
          Text("render_button_close_dataset")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(
          RoundedRectangle(cornerRadius: 30)
            .fill(Color.red)
        )
        .foregroundColor(.white)
        .padding()
      }
    }
    .onChange(of: scenePhase) { _, newPhase in
      Task { @MainActor in
        if newPhase == .background {
          closeDataset()
        }
      }
    }
    .onDisappear {
      dismissWindow(id: "TransferFunctionEditorView")
      dismissWindow(id: "IsovalueEditorView")
      dismissWindow(id: "PerformanceGraphView")
      dismissWindow(id: "LoggerView")
      dismissWindow(id: "ProfileView")
      dismissWindow(id: "PrivateApplicationView")
      dismissWindow(id: "VoiceCommandsView")
      voice.stopListening()
    }
    .padding()
  }

  /// Opens the profiling options window if it is not already visible.
  private func openProfileView() {
    if !runtimeAppModel.isViewOpen("ProfileView") {
      openWindow(id: "ProfileView")
    }
  }

  /**
   Initiates closing of the currently active dataset.

   This sets the immersive space intent to `.close`. The actual closing
   and teardown logic is handled elsewhere in the runtime model.
   */
  private func closeDataset() {
    runtimeAppModel.immersiveSpaceIntent = .close
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group,
 University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without
 limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to
 whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
