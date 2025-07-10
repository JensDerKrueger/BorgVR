import ARKit
import RealityKit

import CompositorServices

final class BorgARProvider {

  /// An optional logger for FPS logging.
  private let logger: LoggerBase?
  /// An ARKit session for augmented reality tracking.
  let session: ARKitSession
  /// A world tracking provider for AR spatial tracking.
  let provider: WorldTrackingProvider

  init(logger: LoggerBase?) {
    self.logger = logger
    self.provider = WorldTrackingProvider()
    self.session = ARKitSession()
  }

  public func updateAnchor(drawable: LayerRenderer.Drawable) -> simd_float4x4 {
    let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
    let deviceAnchor = provider.queryDeviceAnchor(atTimestamp: time)

    drawable.deviceAnchor = deviceAnchor

    if let deviceAnchor = deviceAnchor {
      return deviceAnchor.originFromAnchorTransform
    } else {
      return matrix_identity_float4x4
    }
  }


  /**
   Starts the AR session required for rendering.

   This method attempts to run the AR session using a world tracking
   configuration. If initialization fails, an error is logged and a fatal
   error is triggered.
   */
  public func startARSession() async {
    do {
      //let authorizationResult = await session.requestAuthorization(for: [.worldSensing])
      try await session.run([provider])
    } catch {
      logger?.error("ARSession failed to start: \(error)")
      fatalError("Failed to initialize ARSession")
    }
  }

}


/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use, copy,
 modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 to permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

