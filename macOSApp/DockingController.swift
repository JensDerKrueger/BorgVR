import AppKit
import SwiftUI

enum DockablePanelID: String, CaseIterable, Identifiable {
  case renderControls
  case transferFunctionEditor
  case isoEditor

  var id: String { rawValue }
  var windowID: String { "dockable.\(rawValue)" }
  var windowFrameAutosaveName: String { "BorgVR.\(windowID).frame" }

  var title: LocalizedStringKey {
    switch self {
      case .renderControls:
        return "Render UI"
      case .transferFunctionEditor:
        return "Transfer Function"
      case .isoEditor:
        return "Isovalue"
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
  private static let visiblePanelsKey = "dockable.visiblePanels"
  private static let detachedPanelsKey = "dockable.detachedPanels"

  @Published private var visiblePanels: Set<DockablePanelID>
  @Published private var detachedPanels: Set<DockablePanelID>
  private var datasetLifecycleClosingPanels: Set<DockablePanelID> = []
  private var transientClosingPanels: Set<DockablePanelID> = []

  init() {
    visiblePanels = Self.loadPanels(
      forKey: Self.visiblePanelsKey,
      defaultValue: [.renderControls]
    )
    detachedPanels = Self.loadPanels(
      forKey: Self.detachedPanelsKey,
      defaultValue: []
    )
    visiblePanels.formUnion(detachedPanels)
  }

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
    persistLayout()
  }

  func hide(_ panel: DockablePanelID) {
    visiblePanels.remove(panel)
    persistLayout()
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
    persistLayout()
  }

  func dock(_ panel: DockablePanelID) {
    detachedPanels.remove(panel)
    visiblePanels.insert(panel)
    persistLayout()
  }

  func close(_ panel: DockablePanelID) {
    transientClosingPanels.insert(panel)
    hide(panel)
    detachedPanels.remove(panel)
    persistLayout()
  }

  func resetForDatasetClose() {
    datasetLifecycleClosingPanels.formUnion(detachedPanels)
    detachedPanels.removeAll()
    visiblePanels.removeAll()
  }

  func restoreForDatasetOpen() {
    visiblePanels = Self.loadPanels(
      forKey: Self.visiblePanelsKey,
      defaultValue: [.renderControls]
    )
    detachedPanels = Self.loadPanels(
      forKey: Self.detachedPanelsKey,
      defaultValue: []
    )
    visiblePanels.formUnion(detachedPanels)
  }

  func detachedWindowDidDisappear(_ panel: DockablePanelID) {
    if datasetLifecycleClosingPanels.remove(panel) != nil {
      return
    }
    if transientClosingPanels.remove(panel) != nil {
      return
    }
    dock(panel)
  }

  func detachedPanelsToRestore(compatibleWith renderMode: RenderMode) -> [DockablePanelID] {
    DockablePanelID.allCases.filter { panel in
      isVisible(panel) && isDetached(panel) && isCompatible(panel, with: renderMode)
    }
  }

  func detachedPanelsToTemporarilyClose(incompatibleWith renderMode: RenderMode) -> [DockablePanelID] {
    DockablePanelID.allCases.filter { panel in
      isVisible(panel) && isDetached(panel) && !isCompatible(panel, with: renderMode)
    }
  }

  func markDetachedWindowTemporarilyClosed(_ panel: DockablePanelID) {
    transientClosingPanels.insert(panel)
  }

  func showEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      show(.isoEditor)
    } else {
      show(.transferFunctionEditor)
    }
  }

  func toggleEditor(for renderMode: RenderMode) {
    if renderMode == .isoValue {
      toggleVisibility(.isoEditor)
    } else {
      toggleVisibility(.transferFunctionEditor)
    }
  }

  func hideIncompatibleEditor(for _: RenderMode) {
    // Incompatible editors are only hidden by the current render mode. The user's
    // saved docking layout must survive switching between TF and ISO rendering.
  }

  private func isCompatible(_ panel: DockablePanelID, with renderMode: RenderMode) -> Bool {
    switch panel {
      case .renderControls:
        return true
      case .transferFunctionEditor:
        return renderMode != .isoValue
      case .isoEditor:
        return renderMode == .isoValue
    }
  }

  private func persistLayout() {
    UserDefaults.standard.set(
      visiblePanels.map(\.rawValue).sorted(),
      forKey: Self.visiblePanelsKey
    )
    UserDefaults.standard.set(
      detachedPanels.map(\.rawValue).sorted(),
      forKey: Self.detachedPanelsKey
    )
  }

  private static func loadPanels(
    forKey key: String,
    defaultValue: Set<DockablePanelID>
  ) -> Set<DockablePanelID> {
    guard let rawValues = UserDefaults.standard.stringArray(forKey: key) else {
      return defaultValue
    }
    return Set(rawValues.compactMap(DockablePanelID.init(rawValue:)))
  }
}

private struct WindowFrameAutosaveAccessor: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      configure(window: view.window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      configure(window: nsView.window)
    }
  }

  private func configure(window: NSWindow?) {
    guard let window else { return }
    window.tabbingMode = .disallowed
    _ = window.setFrameUsingName(name)
    _ = window.setFrameAutosaveName(name)
  }
}

private extension View {
  func windowFrameAutosaveName(_ name: String) -> some View {
    background(WindowFrameAutosaveAccessor(name: name).frame(width: 0, height: 0))
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
    .help(docking.isDetached(panel) ? "Dock panel" : "Detach panel")
    .accessibilityLabel(docking.isDetached(panel) ? "Dock panel" : "Detach panel")
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
      docking.detachedWindowDidDisappear(panel)
    }
    .windowFrameAutosaveName(panel.windowFrameAutosaveName)
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
  @EnvironmentObject private var storedAppModel: StoredAppModel
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
            DockableEditorPanel(panel: panel, showsTitle: false) {
              TransferFunctionEditorView(
                usesPanelBackground: false,
                usesFlexibleCanvasHeight: true,
                catalogDirectoryURLs: transferFunctionCatalogDirectoryURLs
              ) {
                docking.close(panel)
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
      Text("This editor is not available in the current render mode.")
        .foregroundStyle(.secondary)
      DockToggleButton(panel: panel)
    }
    .padding()
  }

  private var transferFunctionCatalogDirectoryURLs: [URL] {
    [storedAppModel.resolvedDataDirectoryURL()]
  }
}
