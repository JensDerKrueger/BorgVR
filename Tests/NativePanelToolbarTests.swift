import AppKit
import SwiftUI

enum RenderMode { case transferFunction1D, transferFunction1DWithLighting, isoValue }

@main
@MainActor
struct NativePanelToolbarTests {
  static func main() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let model = PanelWindow(panel: .markerEditor)
    let owner = UUID()
    var configuration = PanelWindowConfiguration.standard(
      reset: .button("reset", icon: "arrow.counterclockwise", text: "Reset", action: {}),
      load: .button("load", icon: "folder", text: "Load", action: {}),
      save: .button("save", icon: "square.and.arrow.down", text: "Save", action: {}),
      additional: [.menu("files", icon: "shippingbox", text: "Files", items: [
        .button("sample", icon: "doc", text: "Sample", action: {})
      ])])
    model.register(configuration, owner: owner)
    let coordinator = NativePanelToolbar.Coordinator(panel: .markerEditor)
    coordinator.update(model, dock: {})
    coordinator.attach(to: window)
    try await Task.sleep(for: .milliseconds(30))
    let identifiers = coordinator.toolbar.items.map(\.itemIdentifier)
    precondition(Set(identifiers).count == identifiers.count, "Toolbar identifiers must be unique")
    let files = coordinator.toolbar.items.first { $0.label == "Files" }!
    precondition(files.view is NSButton && files.menuFormRepresentation?.submenu?.items.first?.title == "Sample",
      "The Files menu must not be overwritten by the standard files spacer")
    for index in 0..<20 {
      configuration.title = "Updated \(index)"
      configuration.actions[0].isEnabled = index % 2 == 0
      model.register(configuration, owner: owner)
      coordinator.update(model, dock: {})
      try await Task.sleep(for: .milliseconds(10))
      precondition(coordinator.toolbar.items.first { $0.label == "Files" } === files,
        "Content-only updates must not rebuild toolbar items")
      precondition(coordinator.toolbar.items.first { $0.label == "Reset" }?.isEnabled == (index % 2 == 0))
    }
    configuration.actions += [
      .button("same", icon: "plus", text: "First same", action: {}),
      .button("same", icon: "minus", text: "Second same", action: {})
    ]
    model.register(configuration, owner: owner)
    coordinator.update(model, dock: {})
    try await Task.sleep(for: .milliseconds(30))
    let duplicateActions = coordinator.toolbar.items.filter { $0.label.hasSuffix(" same") }
    precondition(duplicateActions.count == 2 && duplicateActions[0].itemIdentifier != duplicateActions[1].itemIdentifier,
      "Repeated action names must retain both controls without duplicate native identifiers")
    coordinator.attach(to: nil)
    window.toolbar = nil
    window.close()
    print("Native toolbar Files-menu collisions, repeated IDs, stable updates and enabled state passed")
  }
}
