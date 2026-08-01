import SwiftUI

struct TrackedView<Content: View>: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  let name: String
  let content: () -> Content

  var body: some View {
    content()
      .onAppear {
        runtimeAppModel.registerView(name: name)
      }
      .onDisappear {
        runtimeAppModel.unregisterView(name: name)
      }
  }
}

extension View {
  func trackView(name: String) -> some View {
    TrackedView(name: name) { self }
  }
}
