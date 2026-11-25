import SwiftUI

struct ScriptDropTarget: ViewModifier {
  @EnvironmentObject private var scriptRunner: BorgVRScriptRunner
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .overlay {
        if isTargeted {
          ZStack {
            Color.black.opacity(0.42)
            VStack(spacing: 14) {
              Image(systemName: "play.circle.fill")
                .font(.system(size: 54, weight: .semibold))
              Text("modeselection_drop_script")
                .font(.title2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(28)
          }
          .allowsHitTesting(false)
          .transition(.opacity)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        scriptRunner.runDroppedScript(urls)
      } isTargeted: { targeted in
        withAnimation(.easeInOut(duration: 0.15)) {
          isTargeted = targeted
        }
      }
  }
}
