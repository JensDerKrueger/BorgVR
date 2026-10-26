import CompositorServices

/// Runs on the dedicated compositor executor, never on the main thread.
struct VisionRenderLoopLifecycle {
  let layerRenderer: LayerRenderer

  func run(
    renderFrame: () -> Bool,
    stateChanged: (LayerRenderer.State) -> Void,
    frameFailed: () -> Void
  ) {
    var previous: LayerRenderer.State?
    while !Task.isCancelled {
      let state = layerRenderer.state
      if state != previous {
        previous = state
        stateChanged(state)
      }
      switch state {
      case .invalidated:
        return
      case .paused:
        // Dismissing the immersive space invalidates the layer and wakes this wait.
        layerRenderer.waitUntilRunning()
      case .running:
        guard renderFrame() else {
          frameFailed()
          return
        }
      @unknown default:
        return
      }
    }
  }
}
