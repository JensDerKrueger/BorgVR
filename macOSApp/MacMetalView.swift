import AppKit
import MetalKit
import SwiftUI

struct RenderDragUpdate {
  let delta: CGSize
  let location: CGPoint
  let viewSize: CGSize
  let isDirectPointer: Bool
}

struct MacMetalView: NSViewRepresentable {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var storedAppModel: StoredAppModel
  var onDragDelta: (CGSize) -> Void = { _ in }
  var onDragUpdate: (RenderDragUpdate) -> Void = { _ in }
  var onDragEnded: () -> Void = {}
  var onMagnificationDelta: (CGFloat) -> Void = { _ in }
  var onMagnificationEnded: () -> Void = {}
  var onDoubleTap: () -> Void = {}

  func makeCoordinator() -> MacVolumeRenderer {
    MacVolumeRenderer(
      appModel: appModel,
      appSettings: appSettings,
      renderingParameters: renderingParameters,
      storedAppModel: storedAppModel
    )
  }

  func makeNSView(context: Context) -> InteractiveMTKView {
    let view = InteractiveMTKView()
    view.device = MTLCreateSystemDefaultDevice()
    view.colorPixelFormat = .bgra8Unorm_srgb
    view.depthStencilPixelFormat = .depth32Float
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = NSColor.clear.cgColor
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.preferredFramesPerSecond = 60
    view.delegate = context.coordinator
    configureInteractionCallbacks(for: view, renderer: context.coordinator)
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ view: InteractiveMTKView, context: Context) {
    configureInteractionCallbacks(for: view, renderer: context.coordinator)
    let coordinator = context.coordinator
    DispatchQueue.main.async {
      coordinator.updateIfNeeded(for: view)
    }
  }

  private func configureInteractionCallbacks(for view: InteractiveMTKView, renderer: MacVolumeRenderer) {
    view.onDragDelta = onDragDelta
    view.onDragUpdate = onDragUpdate
    view.onDragEnded = onDragEnded
    view.onMagnificationDelta = onMagnificationDelta
    view.onMagnificationEnded = onMagnificationEnded
    view.onDoubleTap = onDoubleTap
    view.onShaderToggle = {
      renderer.toggleShaderVariant()
    }
  }
}

final class InteractiveMTKView: MTKView {
  var onDragDelta: (CGSize) -> Void = { _ in }
  var onDragUpdate: (RenderDragUpdate) -> Void = { _ in }
  var onDragEnded: () -> Void = {}
  var onMagnificationDelta: (CGFloat) -> Void = { _ in }
  var onMagnificationEnded: () -> Void = {}
  var onDoubleTap: () -> Void = {}
  var onShaderToggle: () -> Void = {}

  private var lastDragLocation: CGPoint?

  override var acceptsFirstResponder: Bool {
    true
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    lastDragLocation = convert(event.locationInWindow, from: nil)
    if event.clickCount >= 2 {
      onDoubleTap()
      lastDragLocation = nil
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
  }

  override func rightMouseUp(with event: NSEvent) {
    lastDragLocation = nil
    onDragEnded()
  }

  override func otherMouseUp(with event: NSEvent) {
    lastDragLocation = nil
    onDragEnded()
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.momentumPhase == [] else { return }
    let delta = CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY)
    if delta != .zero {
      emitDrag(delta: delta, location: convert(event.locationInWindow, from: nil), isDirectPointer: false)
    }
    if event.phase == .ended || event.phase == .cancelled {
      onDragEnded()
    }
  }

  override func magnify(with event: NSEvent) {
    let magnificationDelta = max(0.05, 1 + event.magnification)
    onMagnificationDelta(magnificationDelta)
    if event.phase == .ended || event.phase == .cancelled {
      onMagnificationEnded()
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers?.lowercased() == "s" {
      onShaderToggle()
      return
    }

    super.keyDown(with: event)
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
    emitDrag(delta: delta, location: location, isDirectPointer: true)
    self.lastDragLocation = location
  }

  private func emitDrag(delta: CGSize, location: CGPoint, isDirectPointer: Bool) {
    onDragDelta(delta)
    onDragUpdate(
      RenderDragUpdate(
        delta: delta,
        location: location,
        viewSize: bounds.size,
        isDirectPointer: isDirectPointer
      )
    )
  }
}
