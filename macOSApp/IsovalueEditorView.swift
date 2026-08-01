import SwiftUI

struct IsovalueEditorView: View {
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  var onClose: (() -> Void)?

  var body: some View {
    HStack(spacing: 12) {
      Text("Isowert")
        .font(.headline)

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
        .accessibilityLabel("Isowert-Editor schließen")
        .buttonStyle(.bordered)
      }
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}
