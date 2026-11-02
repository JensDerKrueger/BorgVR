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
    panel.register(.standard(title: "Test dataset", reset: action,
      load: .button("load", icon: "folder", text: "Load", action: {}),
      save: .button("save", icon: "square.and.arrow.down", text: "Save", action: {}),
      additional: [.button("extra", icon: "info.circle", text: "Info", action: {})]), owner: owner)
    precondition(panel.title == "Test dataset")
    precondition(PanelAction.groups(panel.configuration.actions).map(\.count) == [1, 2, 1])
    panel.configuration.actions.first?.perform()
    precondition(clicked == 1)
    panel.unregister(owner: UUID())
    precondition(!panel.configuration.actions.isEmpty, "An old content instance must not clear another instance's actions")
    panel.unregister(owner: owner)
    precondition(panel.configuration.actions.isEmpty)
    precondition(docking.isDockedVisible(.renderControls))

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
