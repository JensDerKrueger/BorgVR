#if DEBUG
import AppKit
import SwiftUI

struct AppStoreScreenshotWindowFrame: NSViewRepresentable {
  final class SizingView: NSView {
    private weak var sizedWindow: NSWindow?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, sizedWindow !== window else { return }
      sizedWindow = window
      DispatchQueue.main.async { [weak self, weak window] in
        guard let window, self?.window === window, !window.styleMask.contains(.fullScreen) else { return }
        let size = window.convertFromBacking(NSRect(x: 0, y: 0, width: 2880, height: 1800)).size
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
          width: size.width, height: size.height)
        if let screen = window.screen {
          frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - size.width))
          frame.origin.y = max(screen.visibleFrame.minY, min(frame.minY, screen.visibleFrame.maxY - size.height))
        }
        // Size the outer frame, including the title bar, rather than the content view.
        window.setFrame(frame, display: true)
      }
    }
  }

  func makeNSView(context: Context) -> SizingView { SizingView() }
  func updateNSView(_ view: SizingView, context: Context) {}
}
#endif
