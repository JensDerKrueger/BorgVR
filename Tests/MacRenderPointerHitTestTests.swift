import AppKit

private struct TestFailure: Error { let message: String }

private func expect(_ condition: Bool, _ message: String) throws {
  if !condition { throw TestFailure(message: message) }
}

@main
private enum MacRenderPointerHitTestTests {
  @MainActor
  static func main() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    window.contentView = content
    // A nonzero origin catches conversion to content-local coordinates before hitTest.
    content.frame = NSRect(x: 40, y: 50, width: 400, height: 300)
    let render = NSView(frame: NSRect(x: 20, y: 30, width: 300, height: 200))
    content.addSubview(render)

    let localPoint = NSPoint(x: 5, y: 5)
    let windowPoint = render.convert(localPoint, to: nil)
    try expect(!MacRenderPointerHitTest.isOverRenderSurface(at: windowPoint, in: NSView()),
      "Detached render surface accepted a hover")
    try expect(content.hitTest(content.convert(windowPoint, from: nil)) !== render,
      "Regression fixture did not expose the incorrect coordinate space")
    try expect(MacRenderPointerHitTest.isOverRenderSurface(at: windowPoint, in: render),
      "Hover disappeared at a render surface with a nonzero content origin")

    let child = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
    render.addSubview(child)
    try expect(MacRenderPointerHitTest.isOverRenderSurface(at: windowPoint, in: render),
      "A rendering subview hid the preview")

    let overlay = NSButton(frame: NSRect(x: 20, y: 30, width: 50, height: 50))
    content.addSubview(overlay)
    try expect(!MacRenderPointerHitTest.isOverRenderSurface(at: windowPoint, in: render),
      "Brush preview appeared over an overlay control")
    overlay.removeFromSuperview()
    try expect(MacRenderPointerHitTest.isOverRenderSurface(at: windowPoint, in: render),
      "Preview did not recover after removing an overlay")
    let outside = render.convert(NSPoint(x: -5, y: 5), to: nil)
    try expect(!MacRenderPointerHitTest.isOverRenderSurface(at: outside, in: render),
      "Preview remained outside the render surface")
    print("macOS render-surface hover hit tests passed")
  }
}
