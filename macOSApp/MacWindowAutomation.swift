import AppKit
import SwiftUI

/// Attached to the root content, never inferred from keyWindow (which may be a panel).
@MainActor
final class MacWindowAutomation: ObservableObject, BorgVRWindowAutomation {
  private weak var window: NSWindow?
  private var observations: [NSObjectProtocol] = []
  private var transitioning = false
  private var pending: (id: UUID, target: Bool, continuation: CheckedContinuation<Void, Error>)?
  private var timeoutTask: Task<Void, Never>?

  deinit {
    observations.forEach(NotificationCenter.default.removeObserver)
    timeoutTask?.cancel()
    pending?.continuation.resume(throwing: BorgVRMCPCommandError.rendererUnavailable)
  }

  func attach(to window: NSWindow) {
    guard self.window !== window else { return }
    transitioning = false
    finish(.failure(BorgVRMCPCommandError.rendererUnavailable))
    observations.forEach(NotificationCenter.default.removeObserver)
    observations.removeAll()
    self.window = window
    for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                 NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                 NSWindow.willCloseNotification] {
      observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
        [weak self, weak window] notification in
        let name = notification.name
        Task { @MainActor [weak self, weak window] in
          guard let self, let window, self.window === window else { return }
          self.handle(name)
        }
      })
    }
  }

  func windowState() throws -> BorgVRMCPWindowState {
    let window = try requireWindow()
    let content = window.contentRect(forFrameRect: window.frame)
    let pixels = window.convertToBacking(content).size
    let framePixels = window.convertToBacking(window.frame).size
    return .init(contentSizePoints: [content.width, content.height],
      contentSizePixels: [Int(pixels.width.rounded()), Int(pixels.height.rounded())],
      framePoints: [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height],
      frameSizePixels: [Int(framePixels.width.rounded()), Int(framePixels.height.rounded())],
      backingScaleFactor: window.backingScaleFactor,
      fullscreen: window.styleMask.contains(.fullScreen), transitioning: transitioning)
  }

  func resize(width: Int, height: Int, units: String, area: String) async throws -> BorgVRMCPWindowState {
    guard (1...16384).contains(width), (1...16384).contains(height),
          ["points", "pixels"].contains(units), ["content", "frame"].contains(area) else {
      throw BorgVRMCPCommandError.invalidArgument("Resize requires integer dimensions in 1...16384, units points|pixels, area content|frame.")
    }
    var window = try requireWindow()
    guard !transitioning, pending == nil else { throw busyError }
    if window.styleMask.contains(.fullScreen) {
      _ = try await setFullscreen(false)
      window = try requireWindow()
    }
    let requested = NSRect(x: 0, y: 0, width: width, height: height)
    let size = units == "pixels" ? window.convertFromBacking(requested).size : requested.size
    let contentSize = area == "content" ? size : window.contentRect(forFrameRect: NSRect(origin: .zero, size: size)).size
    guard contentSize.width >= window.contentMinSize.width, contentSize.height >= window.contentMinSize.height,
          contentSize.width > 0, contentSize.height > 0,
          contentSize.width <= window.contentMaxSize.width, contentSize.height <= window.contentMaxSize.height else {
      throw BorgVRMCPCommandError.invalidArgument("The requested size is outside the main window's content-size limits.")
    }
    let pixels = window.convertToBacking(NSRect(origin: .zero, size: contentSize)).size
    guard pixels.width <= 16384, pixels.height <= 16384 else {
      throw BorgVRMCPCommandError.invalidArgument("The backing image must not exceed 16384 pixels per axis.")
    }
    var frame = area == "frame" ? NSRect(origin: .zero, size: size)
      : window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY-frame.height)
    window.setFrame(frame, display: true, animate: false)
    window.contentView?.layoutSubtreeIfNeeded()
    return try windowState()
  }

  func setFullscreen(_ enabled: Bool) async throws -> BorgVRMCPWindowState {
    let window = try requireWindow()
    guard !transitioning, pending == nil else { throw busyError }
    guard window.styleMask.contains(.fullScreen) != enabled else { return try windowState() }
    guard window.attachedSheet == nil else {
      throw BorgVRMCPCommandError.invalidArgument("Close the main window's dialog before changing fullscreen.")
    }
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        pending = (id, enabled, continuation)
        beginTransition()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.toggleFullScreen(nil)
      }
    } onCancel: { [weak self] in
      Task { @MainActor in
        guard self?.pending?.id == id else { return }
        self?.finish(.failure(CancellationError()))
      }
    }
    return try windowState()
  }

  private func requireWindow() throws -> NSWindow {
    guard let window else { throw BorgVRMCPCommandError.unsupported("The BorgVR main window is not available.") }
    return window
  }

  private var busyError: BorgVRMCPCommandError {
    .invalidArgument("A main-window transition is in progress; retry after it finishes.")
  }

  private func handle(_ name: Notification.Name) {
    if name == NSWindow.willCloseNotification {
      window = nil
      transitioning = false
      finish(.failure(BorgVRMCPCommandError.rendererUnavailable))
    } else if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
      beginTransition()
    } else {
      transitioning = false
      if let pending {
        let actual = window?.styleMask.contains(.fullScreen) == true
        finish(actual == pending.target ? .success(()) : .failure(busyError))
      }
    }
  }

  private func beginTransition() {
    transitioning = true
    timeoutTask?.cancel()
    // A watchdog only; success comes from AppKit. Also covers manual/cancelled transitions.
    timeoutTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      self?.transitioning = false
      self?.finish(.failure(BorgVRMCPCommandError.invalidArgument("Fullscreen transition did not finish.")))
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    if !transitioning {
      timeoutTask?.cancel()
      timeoutTask = nil
    }
    let continuation = pending?.continuation
    pending = nil
    continuation?.resume(with: result)
  }
}

struct MacAutomationWindowReader: NSViewRepresentable {
  let automation: MacWindowAutomation

  final class Reader: NSView {
    weak var automation: MacWindowAutomation?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { automation?.attach(to: window) }
    }
  }

  func makeNSView(context: Context) -> Reader {
    let view = Reader()
    view.automation = automation
    return view
  }

  func updateNSView(_ view: Reader, context: Context) {
    view.automation = automation
    if let window = view.window { automation.attach(to: window) }
  }
}
