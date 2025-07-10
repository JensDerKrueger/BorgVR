import SwiftUI

struct TrackedView<Content: View>: View {
  @Environment(AppModel.self) private var appModel

  let name: String
  let content: () -> Content

  var body: some View {
    content()
      .onAppear {
        appModel.registerView(name: name)
      }
      .onDisappear {
        appModel.unregisterView(name: name)
      }
  }
}

extension View {
  func trackView(name: String) -> some View {
    TrackedView(name: name) { self }
  }
}
