import CompositorServices

// MARK: - LayerRenderer.Clock.Instant.Duration Extension

/**
 An extension on `LayerRenderer.Clock.Instant.Duration` that provides a computed
 property to convert the duration into a `TimeInterval`.

 The conversion accounts for the attoseconds and seconds components of the
 duration.
 */
extension LayerRenderer.Clock.Instant.Duration {
  var timeInterval: TimeInterval {
    let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
    return TimeInterval(components.seconds) + (nanoseconds /
                                               TimeInterval(NSEC_PER_SEC))
  }
}

// MARK: - RendererTaskExecutor

/**
 A task executor for rendering tasks that executes jobs on a dedicated serial
 dispatch queue.

 This executor conforms to the `TaskExecutor` protocol and is used to run
 rendering jobs on a high-priority, user-interactive queue.
 */
final class RendererTaskExecutor: TaskExecutor {
  /// A serial dispatch queue dedicated to rendering tasks.
  private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

  /**
   Enqueues a job for execution on the render thread.

   - Parameter job: The unowned job to be executed.
   */
  func enqueue(_ job: UnownedJob) {
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  /**
   Converts the current executor into an unowned serial task executor.

   - Returns: An `UnownedTaskExecutor` that wraps this executor.
   */
  func asUnownedSerialExecutor() -> UnownedTaskExecutor {
    return UnownedTaskExecutor(ordinary: self)
  }

  /// A shared singleton instance of `RendererTaskExecutor`.
  static var shared: RendererTaskExecutor = RendererTaskExecutor()
}

// MARK: - Renderer Extension for AR Session and Render Loop

/**
 An extension on `Renderer` that provides methods for starting the AR session and
 the render loop.
 */
extension Renderer {
  /**
   Starts the render loop for the renderer.

   This method creates a rendering task using the shared
   `RendererTaskExecutor`. It performs the following:
   - Instantiates a `Renderer` with the provided parameters.
   - Initializes performance tracking.
   - Starts the AR session.
   - Begins the render loop.

   - Parameters:
   - layerRenderer: The layer renderer instance used for rendering.
   - runtimeAppModel: The shared application model.
   - appSetings: The application settings.
   - sharedAppModel: The parameters used for rendering.
   - timer: A CPU frame timer.
   - dataset: The dataset to be rendered.
   */
  @MainActor
  static func startRenderLoop(_ layerRenderer: LayerRenderer,
                              runtimeAppModel: RuntimeAppModel,
                              storedAppModel: StoredAppModel,
                              sharedAppModel: SharedAppModel,
                              timer: CPUFrameTimer,
                              dataset: BORGVRDatasetProtocol,
                              isHost:Bool,
                              logger: LoggerBase? = nil) {
    Task(executorPreference: RendererTaskExecutor.shared) {
      let renderer = try Renderer(
        layerRenderer,
        runtimeAppModel: runtimeAppModel,
        storedAppModel: storedAppModel,
        sharedAppModel: sharedAppModel,
        timer: timer,
        dataset: dataset,
        isHost: isHost,
        logger: logger
      )

      await renderer.initRenderLoop()
      await renderer.renderLoop()
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */
