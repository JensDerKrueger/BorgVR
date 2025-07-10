import SwiftUI

struct IsovalueEditorView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RenderingParamaters.self) private var renderingParamaters

  var body: some View {
    VStack(spacing: 20) {
      Text("Isovalue Editor")
        .font(.title)
        .bold()

      // Slider for adjusting isovalue between 0 and 1
      Slider(value: Binding(
        get: { renderingParamaters.normIsoValue },
        set: { renderingParamaters.normIsoValue = $0 }
      ), in: 0.0...1.0)
      .padding()

      Text(String(format: "Normalized Value: %.2f", renderingParamaters.normIsoValue))
        .foregroundColor(.secondary)
    }
    .padding()
  }
}
