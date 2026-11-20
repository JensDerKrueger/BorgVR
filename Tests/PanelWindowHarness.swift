import AppKit
import SwiftUI

enum RenderMode { case transferFunction1D, transferFunction1DWithLighting, isoValue }

@main
struct PanelWindowHarness: App {
  @StateObject private var docking = DockingController(
    defaults: UserDefaults(suiteName: "BorgVR.PanelHarness.\(UUID().uuidString)")!)

  var body: some Scene {
    WindowGroup("Panel Window Test", id: "main") {
      HarnessCanvas()
        .environmentObject(docking)
        .frame(minWidth: 1000, minHeight: 650)
    }
    .defaultSize(width: 900, height: 650)

    panelWindow(.renderControls)
    panelWindow(.transferFunctionEditor)
    panelWindow(.isoEditor)
    panelWindow(.markerEditor)
    panelWindow(.measurementEditor)
    panelWindow(.lightingEditor)
    panelWindow(.volumeBrushEditor)

    BorgVRUtilityWindow(title: "Performance Test", id: "PerformanceGraphView", width: 500, height: 300) {
      Text("Performance utility window").frame(minWidth: 400, minHeight: 200)
    }
    BorgVRUtilityWindow(title: "Script Log Test", id: "ScriptLogView", width: 500, height: 300) {
      Text("Dataset script log").frame(minWidth: 400, minHeight: 200)
    }
    BorgVRUtilityWindow(title: "Assistant Test", id: "assistant-test", width: 500, height: 300) {
      Text("App-wide assistant placeholder").frame(minWidth: 400, minHeight: 200)
    }
  }

  private func panelWindow(_ panel: DockablePanelID) -> some Scene {
    DockableUtilityWindow(panel: panel, width: 500, height: 350) {
      DetachedDockablePanel(panel: panel, minWidth: 240, minHeight: 200) {
        DockableEditorPanel(panel: panel, detached: true) { HarnessControls(panel: panel) }
      }
      .environmentObject(docking)
    }
  }
}

private struct HarnessCanvas: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var performanceReport = ""
  @State private var datasetIsOpen = true
  @State private var isTesting = false
  @State private var lifecycleReport = ""

  var body: some View {
    VStack {
      HStack {
        Button("Show panel") { docking.dock(.lightingEditor) }
        Button("Focus window") {
          NSApp.activate(ignoringOtherApps: true)
          NSApp.windows.first {
            $0.frameAutosaveName == DockablePanelID.lightingEditor.windowFrameAutosaveName
          }?.makeKeyAndOrderFront(nil)
        }
        Button("Close dataset") {
          datasetIsOpen = false
        }
        Button("Open dataset") {
          docking.restoreForDatasetOpen()
          datasetIsOpen = true
        }
        Text("Visible: \(docking.isVisible(.lightingEditor) ? "yes" : "no")")
        Text("Detached: \(docking.isDetached(.lightingEditor) ? "yes" : "no")")
      }
      .padding()
      HStack {
        Button("Open performance") { openWindow(id: "PerformanceGraphView") }
        Button("Inspect performance windows") {
          let windows = NSApp.windows.filter { $0.title == "Performance Test" }
          let floating = windows.allSatisfy { ($0 as? NSPanel)?.isFloatingPanel == true }
          let fullscreen = windows.contains { $0.styleMask.contains(.fullScreen) }
          let mainFullscreen = NSApp.windows.first { $0.title == "Panel Window Test" }?.styleMask.contains(.fullScreen) ?? false
          performanceReport = "Performance windows: \(windows.count), floating: \(floating), fullscreen: \(fullscreen), main fullscreen: \(mainFullscreen)"
        }
        Button("Close performance") { dismissWindow(id: "PerformanceGraphView") }
      }
      Text(performanceReport).font(.caption)
      Button("Run all panel lifecycle checks") {
        Task { await runLifecycleChecks() }
      }
      .disabled(isTesting)
      ScrollView {
        Text(lifecycleReport).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 180)
      if datasetIsOpen {
        DockablePanelCanvas(panels: DockablePanelID.allCases.filter { docking.isDockedVisible($0) }) { panel in
          HarnessControls(panel: panel)
        }
        .background(Color.gray.opacity(0.15))
        .onDisappear {
          docking.closeDatasetPanels { dismissWindow(id: $0) }
        }
      } else {
        Text("Dataset closed").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { docking.show(.lightingEditor) }
  }

  @MainActor
  private func runLifecycleChecks() async {
    isTesting = true
    lifecycleReport = "Running native window lifecycle checks..."
    defer { isTesting = false }
    NSApp.activate(ignoringOtherApps: true)
    func window(_ panel: DockablePanelID) -> NSWindow? {
      NSApp.windows.first { $0.frameAutosaveName == panel.windowFrameAutosaveName }
    }
    func wait(_ label: String, until predicate: () -> Bool) async throws {
      for _ in 0..<300 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw NSError(domain: "PanelLifecycle", code: 1,
        userInfo: [NSLocalizedDescriptionKey: label])
    }
    func toggle(_ panel: DockablePanelID) {
      docking.togglePresentation(panel, openWindow: { openWindow(id: $0) },
        dismissWindow: { dismissWindow(id: $0) })
    }
    do {
      datasetIsOpen = true
      docking.detach(.lightingEditor)
      openWindow(id: DockablePanelID.lightingEditor.windowID)
      openWindow(id: "PerformanceGraphView")
      openWindow(id: "ScriptLogView")
      openWindow(id: "assistant-test")
      try await wait("Initial subset of windows did not open") {
        window(.lightingEditor)?.isVisible == true &&
          ["Performance Test", "Script Log Test", "Assistant Test"].allSatisfy { title in
            NSApp.windows.contains { $0.title == title && $0.isVisible }
          }
      }
      docking.resetForDatasetClose()
      datasetIsOpen = false
      try await wait("Closing a subset of dataset windows left an auxiliary window visible") {
        window(.lightingEditor)?.isVisible != true &&
          !NSApp.windows.contains { ["Performance Test", "Script Log Test"].contains($0.title) && $0.isVisible }
      }
      guard NSApp.windows.contains(where: { $0.title == "Panel Window Test" && $0.isVisible }) else {
        throw NSError(domain: "PanelLifecycle", code: 6,
          userInfo: [NSLocalizedDescriptionKey: "Dataset close dismissed the main window group"])
      }
      lifecycleReport += "\nPASS subset close: main window group remains visible; never-opened panel windows are harmless"
      docking.restoreForDatasetOpen()
      datasetIsOpen = true
      for panel in DockablePanelID.allCases {
        docking.detach(panel)
        openWindow(id: panel.windowID)
        try await wait("\(panel.rawValue): detached window did not open") { window(panel)?.isVisible == true }
      }
      for panel in DockablePanelID.allCases {
        for _ in 0..<2 {
          toggle(panel)
          try await wait("\(panel.rawValue): window stayed visible after toggle") { window(panel)?.isVisible != true }
          guard DockablePanelID.allCases.filter({ $0 != panel }).allSatisfy({ window($0)?.isVisible == true }) else {
            throw NSError(domain: "PanelLifecycle", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "\(panel.rawValue): another panel was closed"])
          }
          toggle(panel)
          try await wait("\(panel.rawValue): window did not reopen") { window(panel)?.isVisible == true }
        }
        window(panel)?.performClose(nil)
        try await wait("\(panel.rawValue): native close did not update model") {
          window(panel)?.isVisible != true && !docking.isVisible(panel) && !docking.isDetached(panel)
        }
        docking.detach(panel)
        openWindow(id: panel.windowID)
        try await wait("\(panel.rawValue): reopen after native close failed") { window(panel)?.isVisible == true }
        docking.dock(panel)
        dismissWindow(id: panel.windowID)
        try await wait("\(panel.rawValue): docking left its native window open") { window(panel)?.isVisible != true }
        guard docking.isDockedVisible(panel) else {
          throw NSError(domain: "PanelLifecycle", code: 5,
            userInfo: [NSLocalizedDescriptionKey: "\(panel.rawValue): native close undid explicit docking"])
        }
        docking.detach(panel)
        openWindow(id: panel.windowID)
        try await wait("\(panel.rawValue): detach after docking failed") { window(panel)?.isVisible == true }
        lifecycleReport += "\nPASS \(panel.rawValue): independent toggle, reopen, native close, docking"
      }

      // Switching TF/ISO rendering temporarily closes a window but retains its layout.
      docking.markDetachedWindowTemporarilyClosed(.transferFunctionEditor)
      dismissWindow(id: DockablePanelID.transferFunctionEditor.windowID)
      try await wait("Temporarily suspended TF window stayed visible") { window(.transferFunctionEditor)?.isVisible != true }

      openWindow(id: "PerformanceGraphView")
      openWindow(id: "ScriptLogView")
      openWindow(id: "assistant-test")
      try await wait("Auxiliary windows did not open") {
        ["Performance Test", "Script Log Test", "Assistant Test"].allSatisfy { title in
          NSApp.windows.contains { $0.title == title && $0.isVisible }
        }
      }
      // Mirror the real close path: state is reset before the render view disappears.
      docking.resetForDatasetClose()
      datasetIsOpen = false
      try await wait("Dataset close left a renderer window visible") {
        DockablePanelID.allCases.allSatisfy { window($0)?.isVisible != true } &&
          !NSApp.windows.contains { ["Performance Test", "Script Log Test"].contains($0.title) && $0.isVisible }
      }
      guard NSApp.windows.contains(where: { $0.title == "Assistant Test" && $0.isVisible }) else {
        throw NSError(domain: "PanelLifecycle", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Dataset close incorrectly closed the app-wide assistant"])
      }
      guard NSApp.windows.contains(where: { $0.title == "Panel Window Test" && $0.isVisible }) else {
        throw NSError(domain: "PanelLifecycle", code: 6,
          userInfo: [NSLocalizedDescriptionKey: "Dataset close dismissed the main window group"])
      }
      docking.restoreForDatasetOpen()
      guard DockablePanelID.allCases.allSatisfy({ docking.isDetached($0) && docking.isVisible($0) }) else {
        throw NSError(domain: "PanelLifecycle", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Dataset close erased the saved panel layout"])
      }
      lifecycleReport += "\nPASS dataset close: all seven panels, performance and script log closed; assistant remains open"
      lifecycleReport += "\nPASS saved layout preserved"
      openWindow(id: DockablePanelID.transferFunctionEditor.windowID)
      try await wait("Suspended TF window did not restore") { window(.transferFunctionEditor)?.isVisible == true }
      window(.transferFunctionEditor)?.performClose(nil)
      try await wait("Restored TF window ignored its native close after dataset switch") {
        !docking.isVisible(.transferFunctionEditor) && !docking.isDetached(.transferFunctionEditor)
      }
      lifecycleReport += "\nPASS close after restoring a mode-suspended panel\nALL NATIVE WINDOW CHECKS PASSED"
    } catch {
      lifecycleReport += "\nFAIL: \(error.localizedDescription)"
    }
  }
}

private struct HarnessControls: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  var panel: DockablePanelID = .lightingEditor
  @State private var value = 0.5
  @State private var lastAction = "None"
  @State private var toolbarReport = ""

  var body: some View {
    VStack(spacing: 16) {
      if panel == .renderControls {
        // Exercise real child-button taps, not just the direct controller test above the canvas.
        HStack {
          ForEach([DockablePanelID.lightingEditor, .transferFunctionEditor, .markerEditor,
            .measurementEditor, .volumeBrushEditor]) { target in
            Button(target.displayTitle) {
              docking.togglePresentation(target, openWindow: { openWindow(id: $0) },
                dismissWindow: { dismissWindow(id: $0) })
            }
            .buttonStyle(ScreenControlButtonStyle(accent: target.tint,
              isSelected: docking.isVisible(target), showsAccent: true))
          }
        }
      }
      Slider(value: $value)
      Text("Last action: \(lastAction)")
      HStack {
        Button("280 px") { resizeWindow(width: 280) }
        Button("340 px") { resizeWindow(width: 340) }
        Button("400 px") { resizeWindow(width: 400) }
      }
      Button("Inspect toolbar") {
        guard let window = toolWindow, let toolbar = window.toolbar else { return }
        let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        toolbarReport = "Window: \(Int(window.frame.width))\n" + toolbar.items.map {
          "\(visible.contains($0.itemIdentifier) ? "+" : "-") \($0.itemIdentifier.rawValue) " +
            "view=\(Int($0.view?.frame.width ?? 0)) host=\(Int($0.view?.superview?.frame.width ?? 0))"
        }.joined(separator: "\n")
      }
      Text(toolbarReport).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
    }
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .panelActions(.standard(
      reset: .button("reset", icon: "arrow.counterclockwise", text: "Reset") { lastAction = "Reset" },
      load: .button("load", icon: "folder", text: "Load") { lastAction = "Load" },
      save: .button("save", icon: "square.and.arrow.down", text: "Save",
        shortcutHint: MacKeyboardShortcut.saveDatasetState.displayName) { lastAction = "Save" },
      additional: [
        .button("new", icon: "plus", text: "New") { lastAction = "New" },
        .button("remove-point", icon: "minus.circle", text: "Remove point") { lastAction = "Remove point" },
        .button("delete", icon: "trash", text: "Delete") { lastAction = "Delete" }
      ]))
  }

  private func resizeWindow(width: CGFloat) {
    toolWindow?.setContentSize(CGSize(width: width, height: 500))
  }

  private var toolWindow: NSWindow? {
    NSApp.windows.first {
      $0.frameAutosaveName == panel.windowFrameAutosaveName
    }
  }
}
