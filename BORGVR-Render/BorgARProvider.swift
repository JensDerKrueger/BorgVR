import ARKit
import RealityKit
import CompositorServices
import simd

public struct BorgAnchorSample {
  public let originFromDevice: simd_float4x4?
  public let originFromWorldAnchor: simd_float4x4?
  public let deviceAnchor: DeviceAnchor?
  public let worldAnchor: WorldAnchor?
}

final class BorgARProvider {

  private let logger: LoggerBase?
  let session: ARKitSession
  let provider: WorldTrackingProvider
  private var updatesTask: Task<Void, Never>?
  private var sharingAvailabilityTask: Task<Void, Never>?
  private var isHost: Bool = false

  private(set) var currentWorldAnchor: WorldAnchor?
  private let stateQueue = DispatchQueue(label: "BorgARProvider.state", qos: .userInitiated)
  private var latestWorldAnchorTransform: simd_float4x4?
  private var worldAnchorCreationInProgress: Bool = false
  private var sharingIsAvailable: Bool = false

  init(logger: LoggerBase?, groupSessionHost: Bool) {
    self.logger = logger
    self.provider = WorldTrackingProvider()
    self.session = ARKitSession()
    self.isHost = groupSessionHost
  }

  deinit {
    updatesTask?.cancel()
    sharingAvailabilityTask?.cancel()
    updatesTask = nil
    sharingAvailabilityTask = nil
    session.stop()
  }

  // MARK: - Rendering access (non-async)

  public func getAnchors(for drawable: LayerRenderer.Drawable) -> BorgAnchorSample {
    let t = LayerRenderer.Clock.Instant.epoch
      .duration(to: drawable.frameTiming.presentationTime)
      .timeInterval

    let deviceAnchor = provider.queryDeviceAnchor(atTimestamp: t)
    drawable.deviceAnchor = deviceAnchor

    //  create a world anchor as soon as we have a device pose.
    if !worldAnchorCreationInProgress  {
      if currentWorldAnchor == nil, let deviceAnchor {
        worldAnchorCreationInProgress = true
        Task { [weak self] in
          await self?.createWorldAnchor(
            using: deviceAnchor
          )
        }
      }
    }

    let worldXf = stateQueue.sync { latestWorldAnchorTransform }
    return .init(
      originFromDevice: deviceAnchor?.originFromAnchorTransform,
      originFromWorldAnchor: worldXf,
      deviceAnchor: deviceAnchor,
      worldAnchor: currentWorldAnchor
    )
  }

  // MARK: - Session

  @MainActor
  public func startARSession() async {
    currentWorldAnchor = nil
    latestWorldAnchorTransform = nil
    worldAnchorCreationInProgress = false
    do {
      try await session.run([provider])
      startWorldAnchorListener()
      startSharingAvailabilityListener()
    } catch {
      logger?.error("ARSession failed to start: \(error)")
      fatalError("Failed to initialize ARSession")
    }
  }

  public func stopARSession() {
    updatesTask?.cancel()
    sharingAvailabilityTask?.cancel()

    currentWorldAnchor = nil
    latestWorldAnchorTransform = nil
    worldAnchorCreationInProgress = false
    sharingIsAvailable = false
  }

  // MARK: - World anchor management (async)

  private func createWorldAnchor(using deviceAnchor: DeviceAnchor) async {
    #if targetEnvironment(simulator)
    return
    #else

    guard currentWorldAnchor == nil else { return }

    let originFromDevice = deviceAnchor.originFromAnchorTransform
    let intitialTranslation = float4x4(translation: SIMD3<Float>(0, 0, 0))
    let originFromWorld = originFromDevice * intitialTranslation

    let worldAnchor = WorldAnchor(originFromAnchorTransform: originFromWorld,
                                  sharedWithNearbyParticipants: sharingIsAvailable && isHost )
    do {
      try await provider.addAnchor(worldAnchor)
      currentWorldAnchor = worldAnchor
      stateQueue.sync { latestWorldAnchorTransform = originFromWorld }

      if isHost {
        if sharingIsAvailable {
          logger?.dev(
            "Created new shared WorldAnchor as host \(worldAnchor.id)"
          )
        } else {
          logger?.dev(
            "Created new local WorldAnchor as host \(worldAnchor.id)"
          )
        }
      } else {
        logger?.dev(
          "Created new local WorldAnchor as participant \(worldAnchor.id)"
        )
      }
    } catch {
      logger?.error("addAnchor failed: \(error)")
    }
    worldAnchorCreationInProgress = false
    #endif
  }

  public func clearWorldAnchor() async {
    guard let existing = currentWorldAnchor else { return }
    do { try await provider.removeAnchor(existing) } catch {
      logger?.error("removeAnchor failed: \(error)")
    }
    currentWorldAnchor = nil
    stateQueue.sync { latestWorldAnchorTransform = nil }
  }

  // MARK: - Updates

  private func startWorldAnchorListener() {
    updatesTask?.cancel()
    updatesTask = Task.detached(priority: .high) { [weak self] in
      guard let self else { return }
      // Persisted anchors from prior runs will also
      // arrive here once the provider is running.
      for await update in self.provider.anchorUpdates {
        let anchor = update.anchor
        switch update.event {
          case .added:
            logger?.dev("anchor has been added \(anchor.id)")

            if anchor.isSharedWithNearbyParticipants && anchor.id != self.currentWorldAnchor?.id {
              if let current = currentWorldAnchor {
                logger?.dev("Switching from old anchor \(current.id) to new shared anchor \(anchor.id)")
              } else {
                logger?.dev("Switching to new shared anchor \(anchor.id)")
              }
              self.currentWorldAnchor = anchor
            }

            // delete all non-shared anchors that we have not created ourself
            if self.currentWorldAnchor != nil && anchor.id != self.currentWorldAnchor?.id {
              try? await provider.removeAnchor(anchor)
            } else {
              self.stateQueue.sync { self.latestWorldAnchorTransform = anchor.originFromAnchorTransform }
            }
          case .updated:
            if anchor.id == self.currentWorldAnchor?.id {
              self.stateQueue.sync { self.latestWorldAnchorTransform = anchor.originFromAnchorTransform }
            }
          case .removed:
            if anchor.id == self.currentWorldAnchor?.id {
              self.stateQueue.sync { self.latestWorldAnchorTransform = nil }
              self.currentWorldAnchor = nil
              self.logger?.dev("removed current anchor with id: \(anchor.id)")
            } else {
              self.logger?.dev("removed unused anchor with id: \(anchor.id)")
            }
          @unknown default:
            break
        }
      }
    }
  }

  private func startSharingAvailabilityListener() {
    sharingAvailabilityTask?.cancel()
    sharingAvailabilityTask = Task.detached(priority: .high) { [weak self] in
      guard let self else { return }
      // Iterate the non-optional async sequence for sharing availability
      for await sharingAvailability in self.provider.worldAnchorSharingAvailability {
        if sharingAvailability == .available {
          self.logger?.dev("World anchor sharing is available.")
          sharingIsAvailable = true
          if isHost {
            // TODO: remember transformation and use it for the shared anchor
            if let wa = currentWorldAnchor {
              self.logger?.dev("In preparation for a new shared world anchor, removing old world anchor \(wa.id).")
              try? await provider.removeAnchor(wa)
            }
          }
        } else {
          self.logger?.dev("World anchor sharing is not available: \(sharingAvailability)")
          sharingIsAvailable = false

          if isHost {
            // TODO: remember transformation and use it for the "normal" anchor
            if let wa = currentWorldAnchor {
              self.logger?.dev("removing old shared world anchor \(wa.id).")
              try? await provider.removeAnchor(wa)
            }
          }
        }
      }
    }
  }
}

// MARK: - Small math helper

private extension float4x4 {
  init(translation t: SIMD3<Float>) {
    self = matrix_identity_float4x4
    columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
