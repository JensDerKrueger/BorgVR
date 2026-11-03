import AppKit
import SwiftUI

enum RenderMode { case transferFunction1D, transferFunction1DWithLighting, isoValue }

@main
struct PanelWindowHarness: App {
  @StateObject private var docking = DockingController(
    defaults: UserDefaults(suiteName: "BorgVR.PanelHarness.\(UUID().uuidString)")!)

  var body: some Scene {
    Window("Panel Window Test", id: "main") {
      HarnessCanvas()
        .environmentObject(docking)
        .frame(minWidth: 700, minHeight: 450)
    }
    .defaultSize(width: 900, height: 650)

    DockableUtilityWindow(panel: .lightingEditor, width: 400, height: 320) {
      DetachedDockablePanel(panel: .lightingEditor, minWidth: 240, minHeight: 200) {
        DockableEditorPanel(panel: .lightingEditor, detached: true) { HarnessControls() }
      }
      .environmentObject(docking)
    }

    BorgVRUtilityWindow(title: "Performance Test", id: "PerformanceGraphView", width: 500, height: 300) {
      Text("Performance utility window").frame(minWidth: 400, minHeight: 200)
    }
  }
}

private struct HarnessCanvas: View {
  @EnvironmentObject private var docking: DockingController
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var performanceReport = ""

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
          docking.resetForDatasetClose()
          dismissWindow(id: DockablePanelID.lightingEditor.windowID)
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
      GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
          Color.gray.opacity(0.15)
          if docking.isDockedVisible(.lightingEditor) {
            PositionedDockablePanel(panel: .lightingEditor, containerSize: geometry.size) {
              HarnessControls()
            }
          }
        }
        .coordinateSpace(name: "dockablePanelCanvas")
      }
    }
    .onAppear { docking.show(.lightingEditor) }
  }
}

private struct HarnessControls: View {
  @State private var value = 0.5
  @State private var lastAction = "None"
  @State private var toolbarReport = ""

  var body: some View {
    VStack(spacing: 16) {
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
      $0.frameAutosaveName == DockablePanelID.lightingEditor.windowFrameAutosaveName
    }
  }
}
