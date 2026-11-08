import SwiftUI

struct InterfaceVisibilitySettingsView: View {
  @Binding var visibility: InterfaceVisibility

  var body: some View {
    group("Visible rendering modes") {
      ForEach(RenderMode.allCases) { mode in
        Toggle(mode.description, isOn: Binding(
          get: { visibility.renderModeIDs.contains(mode.rawValue) },
          set: { visibility.setRenderMode(mode.rawValue, enabled: $0) }
        ))
        .disabled(visibility.renderModeIDs == [mode.rawValue])
      }
    }
    group("Interaction controls") {
      Toggle("Show reset buttons", isOn: $visibility.showsResets)
      ForEach(InterfaceVisibility.Interaction.allCases) { mode in
        Toggle(LocalizedStringKey(mode.title), isOn: Binding(
          get: { visibility.interactionModes.contains(mode) },
          set: { visibility.setInteraction(mode, enabled: $0) }
        ))
        .disabled(visibility.interactionModes == [mode])
      }
    }
    group("Panel buttons") {
      Toggle("Show panel button row", isOn: $visibility.showsPanels)
      ForEach(InterfaceVisibility.Panel.allCases) { panel in
        Toggle(LocalizedStringKey(panel.title), isOn: Binding(
          get: { visibility.panels & panel.bit != 0 },
          set: { visibility.setPanel(panel, enabled: $0) }
        ))
        .disabled(!visibility.showsPanels)
      }
    }
  }

  @ViewBuilder
  private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
#if os(macOS)
    VStack(alignment: .leading, spacing: 14) {
      Divider().padding(.vertical, 8)
      Text(title).font(.headline)
      content()
    }
#else
    Section(title) { content() }
#endif
  }
}
