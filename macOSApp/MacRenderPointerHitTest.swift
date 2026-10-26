import AppKit

enum MacRenderPointerHitTest {
  static func isOverRenderSurface(at windowPoint: NSPoint, in renderView: NSView) -> Bool {
    guard let contentView = renderView.window?.contentView,
          renderView.bounds.contains(renderView.convert(windowPoint, from: nil)) else { return false }
    // NSView.hitTest expects its superview's coordinates, not its own coordinates.
    let point = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
    guard let hit = contentView.hitTest(point) else { return false }
    return hit === renderView || hit.isDescendant(of: renderView)
  }
}
