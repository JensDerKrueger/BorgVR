import SwiftUI

struct TrackedView<Content: View>: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  let name: String
  var onLastDisappear: (() -> Void)? = nil
  let content: () -> Content

  var body: some View {
    content()
      .onAppear {
        runtimeAppModel.registerView(name: name)
      }
      .onDisappear {
        runtimeAppModel.unregisterView(name: name)
        if !runtimeAppModel.isViewOpen(name) {
          onLastDisappear?()
        }
      }
  }
}

extension View {
  func trackView(name: String, onLastDisappear: (() -> Void)? = nil) -> some View {
    TrackedView(name: name, onLastDisappear: onLastDisappear) { self }
  }
}
