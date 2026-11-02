import SwiftUI

struct IsovalueEditorView: View {
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
#if os(macOS)
  @EnvironmentObject private var session: ScreenBorgVRSession
#endif
  var usesPanelBackground = true
  var showsTitle = true
  var onClose: (() -> Void)?

  @ViewBuilder
  var body: some View {
    Group {
      if usesPanelBackground {
        editorContent
          .padding(12)
          .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else {
        editorContent
      }
    }
#if os(macOS)
    .panelParameters(kind: "isovalue",
      reset: .button("reset", icon: "arrow.counterclockwise", text: String(localized: "Reset Isovalue")) {
        try? session.perform(.setNormalizedIsoValue(0.1), source: .userInterface)
        sharePlay.flushSynchronization()
      },
      snapshot: { IsoPanelPreset(value: renderingParameters.normIsoValue) },
      apply: { preset in
        guard preset.value.isFinite, (0...1).contains(preset.value) else { throw PanelPresetError.invalid }
        try session.perform(.setNormalizedIsoValue(preset.value), source: .userInterface)
        sharePlay.flushSynchronization()
      })
#endif
  }

  private var editorContent: some View {
    HStack(spacing: 12) {
      if showsTitle {
        Text("Isovalue")
          .font(.headline)
      }

      Slider(value: $renderingParameters.normIsoValue, in: 0...1)
        .onChange(of: renderingParameters.normIsoValue) {
          sharePlay.synchronize(kind: .stateOnly)
        }
        .simultaneousGesture(
          DragGesture(minimumDistance: 0)
            .onEnded { _ in
              sharePlay.flushSynchronization()
            }
        )

      Text("\(renderingParameters.isoValue, specifier: "%.3f")")
        .monospacedDigit()
        .frame(minWidth: 64, alignment: .trailing)

      if let onClose {
        Button {
          onClose()
        } label: {
          Image(systemName: "xmark")
        }
        .help("Close isovalue editor")
        .accessibilityLabel("Close isovalue editor")
        .screenControlButtons()
      }
    }
  }
}
