import SwiftUI

struct PrivateApplicationView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel

  var body: some View {
    VStack(spacing: 20) {
      Text("Rendering and Interaction Settings")
        .font(.title)
        .bold()

      Picker("Interaction", selection: Binding(
        get: { runtimeAppModel.interactionMode.rawValue},
        set: { (value:String) in
          switch value {
            case "model":
              runtimeAppModel.interactionMode = .model
            case "clipping":
              runtimeAppModel.interactionMode = .clipping
            default:
              break
          }
        }
      )) {
        Text("Model").tag("model")
        Text("Clipping").tag("clipping")
      }
      .pickerStyle(.segmented)

    }
    .padding()
  }
}
