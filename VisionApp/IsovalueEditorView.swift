import SwiftUI

struct IsovalueEditorView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel

  var body: some View {
    VStack(spacing: 20) {
      Text("Isovalue Editor")
        .font(.title)
        .bold()

      // Slider for adjusting isovalue between 0 and 1
      Slider(value: Binding(
        get: { sharedAppModel.normIsoValue },
        set: { sharedAppModel.normIsoValue = $0 }
      ), in: 0.0...1.0)
      .padding()

      Text(String(format: "Normalized Value: %.2f", sharedAppModel.normIsoValue))
        .foregroundColor(.secondary)
    }
    .padding()
  }
}
