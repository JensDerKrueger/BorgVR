import AppKit
import SwiftUI

enum RenderMode { case transferFunction1D, transferFunction1DWithLighting, isoValue }

@MainActor
private final class PanelProbeRecorder {
  var mounted: Set<DockablePanelID> = []
}

private struct PanelProbe: NSViewRepresentable {
  let panel: DockablePanelID
  let recorder: PanelProbeRecorder

  func makeNSView(context: Context) -> NSView {
    recorder.mounted.insert(panel)
    return NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
  }

  func updateNSView(_ view: NSView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(panel: panel, recorder: recorder) }

  @MainActor final class Coordinator {
    let panel: DockablePanelID
    let recorder: PanelProbeRecorder

    init(panel: DockablePanelID, recorder: PanelProbeRecorder) {
      self.panel = panel
      self.recorder = recorder
    }
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.recorder.mounted.remove(coordinator.panel)
  }
}

private struct TestCanvas: View {
  @ObservedObject var docking: DockingController
  let recorder: PanelProbeRecorder

  var body: some View {
    DockablePanelCanvas(panels: DockablePanelID.allCases.filter { docking.isDockedVisible($0) }) { panel in
      PanelProbe(panel: panel, recorder: recorder).frame(height: 80)
    }
    .environmentObject(docking)
  }
}

@main
@MainActor
struct DockablePanelCanvasTests {
  static func main() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let suite = "BorgVR.CanvasTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let docking = DockingController(defaults: defaults)
    let recorder = PanelProbeRecorder()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: TestCanvas(docking: docking, recorder: recorder))
    window.contentView?.layoutSubtreeIfNeeded()
    defer { window.close() }

    func expectMounted(_ expected: Set<DockablePanelID>) async throws {
      // No forced layout, extra model changes, input events or window activation after a toggle.
      for _ in 0..<100 {
        if recorder.mounted == expected { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      preconditionFailure("Panel hierarchy did not update: expected \(expected), got \(recorder.mounted)")
    }

    try await expectMounted([.renderControls])
    let panels: [DockablePanelID] = [.lightingEditor, .transferFunctionEditor, .markerEditor,
      .measurementEditor, .volumeBrushEditor]
    var expected: Set<DockablePanelID> = [.renderControls]
    for _ in 0..<3 {
      for panel in panels {
        docking.togglePresentation(panel, openWindow: { _ in preconditionFailure("Unexpected detached window") },
          dismissWindow: { _ in preconditionFailure("Unexpected detached window") })
        expected.insert(panel)
        try await expectMounted(expected)
      }
      for panel in [DockablePanelID.markerEditor, .lightingEditor, .volumeBrushEditor,
        .transferFunctionEditor, .measurementEditor] {
        docking.togglePresentation(panel, openWindow: { _ in preconditionFailure("Unexpected detached window") },
          dismissWindow: { _ in preconditionFailure("Unexpected detached window") })
        expected.remove(panel)
        try await expectMounted(expected)
      }
    }
    docking.closeDatasetPanels { _ in }
    try await expectMounted([])
    print("Hosted panel hierarchy updates after each individual toggle and dataset close passed")
  }
}
