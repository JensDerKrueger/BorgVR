import Foundation

enum RenderMode { case transferFunction1D, transferFunction1DWithLighting, isoValue }
enum MacCommand { case test }
struct MacCommandRequest {
  let command: MacCommand
}

@main
@MainActor
struct DockingControllerTests {
  static func main() {
    let suite = "BorgVR.PanelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let docking = DockingController(defaults: defaults)
    precondition(Set(DockablePanelID.allCases.map(\.windowFrameAutosaveName)).count == DockablePanelID.allCases.count)
    precondition(DockablePanelID.allCases.allSatisfy { $0.windowFrameAutosaveName.hasSuffix(".utility.frame") },
      "Tool windows must not restore frames from the former fullscreen-capable document windows")
    docking.registerRevealControl(for: .renderControls, icon: "eye", text: "Show UI")
    precondition(docking.revealControls.count == 1)
    let owner = UUID()
    let panel = PanelWindow(panel: .lightingEditor)
    var clicked = 0
    let action = PanelAction.button("reset", icon: "arrow.counterclockwise", text: "Reset") { clicked += 1 }
    precondition(action.helpText == "Reset")
    let hinted = PanelAction.button("save", icon: "tray.and.arrow.down", text: "Save",
      shortcutHint: "Command+S", action: {})
    precondition(hinted.text == "Save" && hinted.helpText == "Save (Command+S)",
      "Shortcut hints belong in tooltips, not button/menu titles")
    var changedHint = hinted
    changedHint.shortcutHint = "S"
    precondition(changedHint != hinted, "Updating a shortcut hint must refresh the panel configuration")
    panel.register(.standard(title: "Test dataset", reset: action,
      load: .button("load", icon: "folder", text: "Load", action: {}),
      save: .button("save", icon: "square.and.arrow.down", text: "Save", action: {}),
      additional: [.button("extra", icon: "info.circle", text: "Info", action: {})]), owner: owner)
    precondition(panel.title == "Test dataset")
    precondition(panel.configuration.titleFormat == PanelTitleFormat())
    precondition(panel.titleColor == DockablePanelID.lightingEditor.tint,
      "Panel color must remain the default when there is no format override")
    let readyConfiguration = panel.configuration
    var streamingConfiguration = readyConfiguration
    streamingConfiguration.titleFormat = PanelTitleFormat(color: .red, isItalic: true, isBold: false)
    precondition(streamingConfiguration != readyConfiguration,
      "Streaming changes must refresh the title even when its text stays unchanged")
    panel.register(streamingConfiguration, owner: owner)
    precondition(panel.configuration.titleFormat.isItalic && !panel.configuration.titleFormat.isBold &&
      panel.titleColor == .red && panel.title == "Test dataset")
    panel.register(readyConfiguration, owner: owner)
    precondition(panel.configuration.titleFormat == PanelTitleFormat() &&
      panel.titleColor == DockablePanelID.lightingEditor.tint,
      "Completion must restore the normal title appearance")
    precondition(PanelAction.groups(panel.configuration.actions).map(\.count) == [1, 2, 1])
    panel.configuration.actions.first?.perform()
    precondition(clicked == 1)
    panel.unregister(owner: UUID())
    precondition(!panel.configuration.actions.isEmpty, "An old content instance must not clear another instance's actions")
    panel.unregister(owner: owner)
    precondition(panel.configuration.actions.isEmpty)
    precondition(docking.isDockedVisible(.renderControls))

    var openedWindows: [String] = []
    var dismissedWindows: [String] = []
    func toggle(_ panel: DockablePanelID) {
      docking.togglePresentation(panel,
        openWindow: {
          precondition(docking.isDetached(panel) && docking.isVisible(panel),
            "Window content must be ready before opening its window")
          openedWindows.append($0)
        },
        dismissWindow: {
          precondition(!docking.isVisible(panel), "Hide panel content before dismissing its window")
          dismissedWindows.append($0)
          docking.detachedWindowDidDisappear(panel)
        })
    }
    for mode in [RenderMode.transferFunction1D, .transferFunction1DWithLighting, .isoValue] {
      let editor: DockablePanelID = mode == .isoValue ? .isoEditor : .transferFunctionEditor
      docking.close(editor)
      toggle(editor)
      precondition(docking.isDockedVisible(editor))
      toggle(editor)
      precondition(!docking.isVisible(editor), "A second click must hide an inline editor")
    }
    precondition(openedWindows.isEmpty && dismissedWindows.isEmpty,
      "Inline toggles must not open or dismiss native windows")
    for panel in DockablePanelID.allCases {
      docking.detach(panel)
      openedWindows.removeAll()
      dismissedWindows.removeAll()
      for _ in 0..<3 {
        toggle(panel)
        precondition(!docking.isVisible(panel) && docking.isDetached(panel),
          "Every detached panel must close on a second click and retain its placement")
        toggle(panel)
        precondition(docking.isVisible(panel) && docking.isDetached(panel))
      }
      precondition(openedWindows == Array(repeating: panel.windowID, count: 3))
      precondition(dismissedWindows == Array(repeating: panel.windowID, count: 3),
        "Each hide must dismiss the actual native window, not merely clear its content")
      docking.detachedWindowDidDisappear(panel)
      precondition(!docking.isVisible(panel) && !docking.isDetached(panel),
        "Button toggles must not suppress a subsequent close with the native close button")
    }

    docking.detach(.measurementEditor)
    docking.detachedWindowDidDisappear(.measurementEditor)
    precondition(!docking.isVisible(.measurementEditor) && !docking.isDetached(.measurementEditor),
      "Closing a native window must close it rather than docking it")
    precondition(!DockingController(defaults: defaults).isVisible(.measurementEditor))

    docking.detach(.markerEditor)
    docking.dock(.markerEditor)
    docking.detachedWindowDidDisappear(.markerEditor)
    precondition(docking.isDockedVisible(.markerEditor), "Explicit docking must survive the native window closing")

    for _ in 0..<10 {
      docking.detach(.markerEditor)
      precondition(docking.isVisible(.markerEditor) && docking.isDetached(.markerEditor))
      docking.dock(.markerEditor)
      docking.detachedWindowDidDisappear(.markerEditor)
      precondition(docking.isDockedVisible(.markerEditor), "Repeated window/panel switches must not close the panel")
    }

    docking.detach(.lightingEditor)
    docking.close(.lightingEditor)
    docking.detachedWindowDidDisappear(.lightingEditor)
    precondition(!docking.isVisible(.lightingEditor))
    docking.detach(.lightingEditor)
    docking.detachedWindowDidDisappear(.lightingEditor)
    precondition(!docking.isVisible(.lightingEditor), "A previous close must not suppress a later user close")

    docking.close(.markerEditor)
    docking.detach(.markerEditor)
    docking.detachedWindowDidDisappear(.markerEditor)
    precondition(!docking.isVisible(.markerEditor), "Closing an inline panel must not leave a pending native-window callback")

    docking.detach(.transferFunctionEditor)
    precondition(docking.detachedPanelsToTemporarilyClose(incompatibleWith: .isoValue) == [.transferFunctionEditor])
    docking.markDetachedWindowTemporarilyClosed(.transferFunctionEditor)
    docking.detachedWindowDidDisappear(.transferFunctionEditor)
    precondition(docking.isVisible(.transferFunctionEditor) && docking.isDetached(.transferFunctionEditor))
    precondition(docking.detachedPanelsToRestore(compatibleWith: .transferFunction1D) == [.transferFunctionEditor])

    docking.resetForDatasetClose()
    precondition(DockablePanelID.allCases.allSatisfy { !docking.isVisible($0) && !docking.isDetached($0) })
    docking.detachedWindowDidDisappear(.transferFunctionEditor)
    docking.restoreForDatasetOpen()
    precondition(docking.isVisible(.transferFunctionEditor) && docking.isDetached(.transferFunctionEditor),
      "Closing a dataset must preserve the user's saved panel layout")

    for panel in DockablePanelID.allCases { docking.detach(panel) }
    docking.showsLog = true
    docking.showsDatasetInfo = true
    dismissedWindows.removeAll()
    docking.closeDatasetPanels {
      precondition(DockablePanelID.allCases.allSatisfy { !docking.isVisible($0) && !docking.isDetached($0) })
      dismissedWindows.append($0)
    }
    precondition(dismissedWindows == DockablePanelID.allCases.map(\.windowID) + ["PerformanceGraphView", "ScriptLogView"],
      "Dataset cleanup must dismiss every renderer window and leave app-wide windows alone")
    precondition(!docking.showsLog && !docking.showsDatasetInfo)
    for panel in DockablePanelID.allCases { docking.detachedWindowDidDisappear(panel) }
    docking.restoreForDatasetOpen()
    precondition(DockablePanelID.allCases.allSatisfy { docking.isVisible($0) && docking.isDetached($0) },
      "Native window-close callbacks during dataset cleanup must not erase the saved layout")

    toggle(.transferFunctionEditor)
    docking.closeDatasetPanels { _ in }
    for panel in DockablePanelID.allCases where panel != .transferFunctionEditor {
      docking.detachedWindowDidDisappear(panel)
    }
    docking.restoreForDatasetOpen()
    docking.detachedWindowDidDisappear(.transferFunctionEditor)
    precondition(!docking.isVisible(.transferFunctionEditor),
      "A window hidden before dataset close must not leave a stale close callback for the next dataset")

    let lifecycle = DockingController(defaults: defaults)
    var nativeTFIsVisible = true
    lifecycle.trackDetachedWindowVisibility(.transferFunctionEditor) { nativeTFIsVisible }
    lifecycle.detach(.transferFunctionEditor)
    lifecycle.markDetachedWindowTemporarilyClosed(.transferFunctionEditor)
    nativeTFIsVisible = false
    lifecycle.detachedWindowDidDisappear(.transferFunctionEditor)
    lifecycle.markDetachedWindowTemporarilyClosed(.transferFunctionEditor)
    lifecycle.closeDatasetPanels { id in
      if id != DockablePanelID.transferFunctionEditor.windowID,
         let panel = DockablePanelID.allCases.first(where: { $0.windowID == id }) {
        lifecycle.detachedWindowDidDisappear(panel)
      }
    }
    lifecycle.restoreForDatasetOpen()
    nativeTFIsVisible = true
    lifecycle.detachedWindowDidDisappear(.transferFunctionEditor)
    precondition(!lifecycle.isVisible(.transferFunctionEditor) && !lifecycle.isDetached(.transferFunctionEditor),
      "Mode-suspended windows must not leave temporary or dataset-close flags behind")

    lifecycle.detach(.transferFunctionEditor)
    lifecycle.markDetachedWindowTemporarilyClosed(.transferFunctionEditor)
    lifecycle.resetForDatasetClose()
    nativeTFIsVisible = false
    lifecycle.detachedWindowDidDisappear(.transferFunctionEditor)
    lifecycle.restoreForDatasetOpen()
    nativeTFIsVisible = true
    lifecycle.detachedWindowDidDisappear(.transferFunctionEditor)
    precondition(!lifecycle.isVisible(.transferFunctionEditor),
      "One native close must clear both temporary and dataset-close reasons when they overlap")

    let container = CGSize(width: 1200, height: 800)
    let size = CGSize(width: 380, height: 400)
    docking.move(.markerEditor, to: CGPoint(x: 210, y: 160), panelSize: size, containerSize: container)
    docking.move(.measurementEditor, to: CGPoint(x: 210, y: 160), panelSize: size, containerSize: container)
    precondition(docking.origin(for: .markerEditor, panelSize: size, containerSize: container) ==
      docking.origin(for: .measurementEditor, panelSize: size, containerSize: container), "Panels must be allowed to overlap")
    docking.bringToFront(.markerEditor)
    precondition(docking.zIndex(for: .markerEditor) > docking.zIndex(for: .measurementEditor))
    docking.bringToFront(.measurementEditor)
    precondition(docking.zIndex(for: .measurementEditor) > docking.zIndex(for: .markerEditor))
    docking.savePanelPositions()
    let restored = DockingController(defaults: defaults)
    precondition(restored.origin(for: .markerEditor, panelSize: size, containerSize: container) == CGPoint(x: 210, y: 160))
    let resized = restored.origin(for: .markerEditor, panelSize: size, containerSize: CGSize(width: 500, height: 450))
    precondition(resized == CGPoint(x: 112, y: 42), "Window resize must keep panels inside the viewport")
    restored.move(.markerEditor, to: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), panelSize: size, containerSize: container)
    precondition(restored.origin(for: .markerEditor, panelSize: size, containerSize: container) == CGPoint(x: 210, y: 160))

    precondition(DockablePanelID.volumeBrushEditor.inlineHeight(in: container) == nil,
      "Brush collision bounds must use the visible content height, not a reserved outer frame")
    let largeContainer = CGSize(width: 1600, height: 1000)
    let expected: [PanelDockAnchor: CGPoint] = [
      .topLeading: CGPoint(x: 8, y: 8), .top: CGPoint(x: 410, y: 8), .topTrailing: CGPoint(x: 812, y: 8),
      .leading: CGPoint(x: 8, y: 200), .trailing: CGPoint(x: 812, y: 200),
      .bottomLeading: CGPoint(x: 8, y: 392), .bottom: CGPoint(x: 410, y: 392),
      .bottomTrailing: CGPoint(x: 812, y: 392)
    ]
    for anchor in PanelDockAnchor.allCases {
      let target = anchor.origin(panelSize: size, containerSize: container)
      precondition(target == expected[anchor])
      restored.move(.volumeBrushEditor, to: CGPoint(x: target.x + 12, y: target.y + 9),
        panelSize: size, containerSize: container)
      precondition(restored.snapCandidate(for: .volumeBrushEditor, panelSize: size, containerSize: container) == anchor)
      restored.finishMoving(.volumeBrushEditor, panelSize: size, containerSize: container)
      precondition(restored.dockAnchor(for: .volumeBrushEditor) == anchor)
      precondition(restored.origin(for: .volumeBrushEditor, panelSize: size, containerSize: container) == target)
      let reloaded = DockingController(defaults: defaults)
      precondition(reloaded.dockAnchor(for: .volumeBrushEditor) == anchor)
      precondition(reloaded.origin(for: .volumeBrushEditor, panelSize: size, containerSize: largeContainer) ==
        anchor.origin(panelSize: size, containerSize: largeContainer), "Anchors must track window resize")
      let tallerPanel = CGSize(width: 380, height: 460)
      precondition(reloaded.origin(for: .volumeBrushEditor, panelSize: tallerPanel, containerSize: container) ==
        anchor.origin(panelSize: tallerPanel, containerSize: container), "Anchors must track content size changes")
    }
    restored.move(.volumeBrushEditor, to: CGPoint(x: 250, y: 150), panelSize: size, containerSize: container)
    precondition(restored.dockAnchor(for: .volumeBrushEditor) == nil, "Dragging away must release the anchor")
    precondition(restored.snapCandidate(for: .volumeBrushEditor, panelSize: size, containerSize: container) == nil)
    restored.finishMoving(.volumeBrushEditor, panelSize: size, containerSize: container)
    precondition(DockingController(defaults: defaults).dockAnchor(for: .volumeBrushEditor) == nil)
    precondition(restored.origin(for: .volumeBrushEditor, panelSize: size, containerSize: largeContainer) == CGPoint(x: 250, y: 150))
    let smallContainer = CGSize(width: 200, height: 150)
    for anchor in PanelDockAnchor.allCases {
      precondition(anchor.origin(panelSize: size, containerSize: smallContainer) == CGPoint(x: 8, y: 8))
    }
    print("Panel close, layout persistence, overlap, stacking, content bounds and eight resize-aware dock anchors passed")
  }
}
