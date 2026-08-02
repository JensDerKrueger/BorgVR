import SwiftUI

enum DockablePanelID: String, CaseIterable, Identifiable {
  case renderControls
  case transferFunctionEditor
  case isoEditor

  var id: String { rawValue }
  var windowID: String { "dockable.\(rawValue)" }

  var title: LocalizedStringKey {
    switch self {
      case .renderControls:
        return "Render UI"
      case .transferFunctionEditor:
        return "Transfer Function"
      case .isoEditor:
        return "Isowert"
    }
  }

  var dockedIcon: String {
    "rectangle.on.rectangle"
  }

  var detachedIcon: String {
    "rectangle.compress.vertical"
  }
}

@MainActor
final class DockingController: ObservableObject {
  @Published private var visiblePanels: Set<DockablePanelID> = [.renderControls]
  @Published private var detachedPanels: Set<DockablePanelID> = []

  func isVisible(_ panel: DockablePanelID) -> Bool {
    visiblePanels.contains(panel)
  }

  func isDetached(_ panel: DockablePanelID) -> Bool {
    detachedPanels.contains(panel)
  }

  func isDockedVisible(_ panel: DockablePanelID) -> Bool {
    isVisible(panel) && !isDetached(panel)
  }

  func show(_ panel: DockablePanelID) {
    visiblePanels.insert(panel)
  }

  func hide(_ panel: DockablePanelID) {
    visiblePanels.remove(panel)
  }

  func toggleVisibility(_ panel: DockablePanelID) {
    if isVisible(panel) {
      hide(panel)
    } else {
      show(panel)
    }
  }

  func detach(_ panel: DockablePanelID) {
    visiblePanels.insert(panel)
    detachedPanels.insert(panel)
  }

  func dock(_ panel: DockablePanelID) {
    detachedPanels.remove(panel)
  }

  func close(_ panel: DockablePanelID) {
    hide(panel)
    dock(panel)
  }

  func resetForDatasetClose() {
    detachedPanels.removeAll()
    visiblePanels = [.renderControls]
  }

  func showEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      hide(.transferFunctionEditor)
      show(.isoEditor)
    } else {
      hide(.isoEditor)
      show(.transferFunctionEditor)
    }
  }

  func toggleEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      hide(.transferFunctionEditor)
      toggleVisibility(.isoEditor)
    } else {
      hide(.isoEditor)
      toggleVisibility(.transferFunctionEditor)
    }
  }

  func hideIncompatibleEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      hide(.transferFunctionEditor)
    } else {
      hide(.isoEditor)
    }
  }
}

struct DockToggleButton: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  let panel: DockablePanelID

  var body: some View {
    Button {
      if docking.isDetached(panel) {
        docking.dock(panel)
        dismissWindow(id: panel.windowID)
      } else {
        docking.detach(panel)
        openWindow(id: panel.windowID)
      }
    } label: {
      Image(systemName: docking.isDetached(panel) ? panel.detachedIcon : panel.dockedIcon)
    }
    .help(docking.isDetached(panel) ? "Panel andocken" : "Panel abdocken")
    .accessibilityLabel(docking.isDetached(panel) ? "Panel andocken" : "Panel abdocken")
    .buttonStyle(.bordered)
  }
}

struct DetachedDockablePanel<Content: View>: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.dismissWindow) private var dismissWindow

  let panel: DockablePanelID
  let minWidth: CGFloat
  let minHeight: CGFloat
  @ViewBuilder var content: () -> Content

  init(
    panel: DockablePanelID,
    minWidth: CGFloat = 360,
    minHeight: CGFloat = 180,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.panel = panel
    self.minWidth = minWidth
    self.minHeight = minHeight
    self.content = content
  }

  var body: some View {
    Group {
      if docking.isDetached(panel) && docking.isVisible(panel) {
        content()
          .padding()
          .frame(minWidth: minWidth, minHeight: minHeight)
      } else {
        Color.clear
          .frame(width: 1, height: 1)
          .onAppear {
            dismissWindow(id: panel.windowID)
          }
      }
    }
    .onDisappear {
      docking.dock(panel)
    }
  }
}

struct DockableEditorPanel<Content: View>: View {
  let panel: DockablePanelID
  let maxWidth: CGFloat?
  let showsTitle: Bool
  @ViewBuilder var content: () -> Content

  init(
    panel: DockablePanelID,
    maxWidth: CGFloat? = nil,
    showsTitle: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.panel = panel
    self.maxWidth = maxWidth
    self.showsTitle = showsTitle
    self.content = content
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        if showsTitle {
          Text(panel.title)
            .font(.headline)
        }
        Spacer()
        DockToggleButton(panel: panel)
      }
      content()
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .frame(maxWidth: maxWidth)
  }
}

struct DetachedPanelContent: View {
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject private var docking: DockingController

  let panel: DockablePanelID

  var body: some View {
    switch panel {
      case .renderControls:
        DetachedDockablePanel(panel: panel, minWidth: 620, minHeight: 220) {
          RenderControlsPanel(isDetachedWindow: true)
        }

      case .transferFunctionEditor:
        DetachedDockablePanel(panel: panel, minWidth: 760, minHeight: 260) {
          if renderingParameters.renderMode == .isoValue {
            unavailableEditorMessage
          } else {
            DockableEditorPanel(panel: panel, maxWidth: 720, showsTitle: false) {
              TransferFunctionEditorView(usesPanelBackground: false) {
                docking.close(panel)
              }
            }
          }
        }

      case .isoEditor:
        DetachedDockablePanel(panel: panel, minWidth: 520, minHeight: 150) {
          if renderingParameters.renderMode == .isoValue {
            DockableEditorPanel(panel: panel, maxWidth: 520, showsTitle: false) {
              IsovalueEditorView(usesPanelBackground: false) {
                docking.close(panel)
              }
            }
          } else {
            unavailableEditorMessage
          }
        }
    }
  }

  private var unavailableEditorMessage: some View {
    VStack(spacing: 12) {
      Text("Dieser Editor ist im aktuellen Rendermodus nicht verfügbar.")
        .foregroundStyle(.secondary)
      DockToggleButton(panel: panel)
    }
    .padding()
  }
}
