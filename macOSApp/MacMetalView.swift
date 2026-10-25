import AppKit
import MetalKit
import SwiftUI

struct RenderDragUpdate {
  let delta: CGSize
  let location: CGPoint
  let viewSize: CGSize
  let isDirectPointer: Bool
  var modifierFlags: NSEvent.ModifierFlags = []
}

struct MacMetalView: NSViewRepresentable {
  @EnvironmentObject private var storedAppModel: StoredAppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  @EnvironmentObject private var session: ScreenBorgVRSession
  var onDragDelta: (CGSize) -> Void = { _ in }
  var onDragUpdate: (RenderDragUpdate) -> Void = { _ in }
  var onDragEnded: () -> Void = {}
  var onPointerDown: (RenderDragUpdate) -> Void = { _ in }
  var onMagnificationDelta: (CGFloat) -> Void = { _ in }
  var onMagnificationEnded: () -> Void = {}
  var onDoubleClick: () -> Bool = { false }
  var onKeyboardShortcut: (MacRenderShortcut) -> Void = { _ in }
  var onModifierFlagsChanged: (NSEvent.ModifierFlags) -> Void = { _ in }
  var onPointerHover: (RenderDragUpdate?) -> Void = { _ in }
  var tracksPointerHover = false

  func makeCoordinator() -> MacVolumeRenderer {
    MacVolumeRenderer(
      session: session,
      storedAppModel: storedAppModel,
      sharePlay: sharePlay
    )
  }

  func makeNSView(context: Context) -> InteractiveMTKView {
    let view = InteractiveMTKView()
    view.device = MTLCreateSystemDefaultDevice()
    view.colorPixelFormat = .bgra8Unorm_srgb
    view.depthStencilPixelFormat = .depth32Float
    view.clearDepth = 0
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.framebufferOnly = false
    view.preferredFramesPerSecond = 60
    view.delegate = context.coordinator
    configureInteractionCallbacks(for: view)
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ view: InteractiveMTKView, context: Context) {
    configureInteractionCallbacks(for: view)
    let coordinator = context.coordinator
    DispatchQueue.main.async {
      coordinator.updateIfNeeded(for: view)
    }
  }

  private func configureInteractionCallbacks(for view: InteractiveMTKView) {
    view.onDragDelta = onDragDelta
    view.onDragUpdate = onDragUpdate
    view.onDragEnded = onDragEnded
    view.onPointerDown = onPointerDown
    view.onMagnificationDelta = onMagnificationDelta
    view.onMagnificationEnded = onMagnificationEnded
    view.onDoubleClick = onDoubleClick
    view.onKeyboardShortcut = onKeyboardShortcut
    view.onModifierFlagsChanged = onModifierFlagsChanged
    view.onPointerHover = onPointerHover
    view.tracksPointerHover = tracksPointerHover
  }
}

final class InteractiveMTKView: MTKView {
  var onDragDelta: (CGSize) -> Void = { _ in }
  var onDragUpdate: (RenderDragUpdate) -> Void = { _ in }
  var onDragEnded: () -> Void = {}
  var onPointerDown: (RenderDragUpdate) -> Void = { _ in }
  var onMagnificationDelta: (CGFloat) -> Void = { _ in }
  var onMagnificationEnded: () -> Void = {}
  var onDoubleClick: () -> Bool = { false }
  var onKeyboardShortcut: (MacRenderShortcut) -> Void = { _ in }
  var onModifierFlagsChanged: (NSEvent.ModifierFlags) -> Void = { _ in }
  var onPointerHover: (RenderDragUpdate?) -> Void = { _ in }
  var tracksPointerHover = false {
    didSet {
      guard tracksPointerHover != oldValue else { return }
      DispatchQueue.main.async { [weak self] in self?.updatePointerHover() }
    }
  }

  private var lastDragLocation: CGPoint?
  private var hoverTrackingArea: NSTrackingArea?

  override var acceptsFirstResponder: Bool {
    true
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.acceptsMouseMovedEvents = true
      self.window?.makeFirstResponder(self)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { updatePointerHover() }
  override func mouseMoved(with event: NSEvent) { updatePointerHover() }
  override func mouseExited(with event: NSEvent) {
    if lastDragLocation == nil { onPointerHover(nil) }
  }

  private func updatePointerHover() {
    guard lastDragLocation == nil else { return }
    guard tracksPointerHover, let window, window.isKeyWindow,
          let contentView = window.contentView else { onPointerHover(nil); return }
    let point = window.mouseLocationOutsideOfEventStream
    let location = convert(point, from: nil)
    // Tracking areas also cover SwiftUI overlays. Do not show the brush over controls.
    guard bounds.contains(location),
          contentView.hitTest(contentView.convert(point, from: nil)) === self else {
      onPointerHover(nil)
      return
    }
    onPointerHover(RenderDragUpdate(delta: .zero, location: location, viewSize: bounds.size,
                                    isDirectPointer: true, modifierFlags: NSEvent.modifierFlags))
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    lastDragLocation = convert(event.locationInWindow, from: nil)
    if event.clickCount >= 2, onDoubleClick() {
      lastDragLocation = nil
      return
    }
    if let lastDragLocation {
      onPointerDown(
        RenderDragUpdate(
          delta: .zero,
          location: lastDragLocation,
          viewSize: bounds.size,
          isDirectPointer: true,
          modifierFlags: event.modifierFlags
        )
      )
    }
  }

  override func mouseDragged(with event: NSEvent) {
    handleMouseDrag(event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    handleMouseDrag(event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    handleMouseDrag(event)
  }

  override func mouseUp(with event: NSEvent) {
    lastDragLocation = nil
    onDragEnded()
    updatePointerHover()
  }

  override func rightMouseUp(with event: NSEvent) {
    lastDragLocation = nil
    onDragEnded()
    updatePointerHover()
  }

  override func otherMouseUp(with event: NSEvent) {
    lastDragLocation = nil
    onDragEnded()
    updatePointerHover()
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.momentumPhase == [] else { return }
    let delta = CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY)
    if delta != .zero {
      emitDrag(delta: delta, location: convert(event.locationInWindow, from: nil),
               isDirectPointer: false, modifierFlags: event.modifierFlags)
    }
    if event.phase == .ended || event.phase == .cancelled {
      onDragEnded()
      updatePointerHover()
    }
  }

  override func magnify(with event: NSEvent) {
    let magnificationDelta = max(0.05, 1 + event.magnification)
    onMagnificationDelta(magnificationDelta)
    if event.phase == .ended || event.phase == .cancelled {
      onMagnificationEnded()
      updatePointerHover()
    }
  }

  override func keyDown(with event: NSEvent) {
    guard let shortcut = MacRenderShortcut(event: event) else {
      super.keyDown(with: event)
      return
    }
    onKeyboardShortcut(shortcut)
  }

  override func flagsChanged(with event: NSEvent) {
    onModifierFlagsChanged(event.modifierFlags)
    super.flagsChanged(with: event)
  }

  private func handleMouseDrag(_ event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    guard let lastDragLocation else {
      self.lastDragLocation = location
      return
    }

    let delta = CGSize(
      width: location.x - lastDragLocation.x,
      height: lastDragLocation.y - location.y
    )
    emitDrag(delta: delta, location: location, isDirectPointer: true, modifierFlags: event.modifierFlags)
    self.lastDragLocation = location
  }

  private func emitDrag(delta: CGSize, location: CGPoint, isDirectPointer: Bool,
                        modifierFlags: NSEvent.ModifierFlags) {
    onDragDelta(delta)
    onDragUpdate(
      RenderDragUpdate(
        delta: delta,
        location: location,
        viewSize: bounds.size,
        isDirectPointer: isDirectPointer,
        modifierFlags: modifierFlags
      )
    )
  }
}
