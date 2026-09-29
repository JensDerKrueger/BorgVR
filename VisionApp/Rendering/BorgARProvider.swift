import ARKit
import RealityKit
import CompositorServices
import GameController
import simd

public struct BorgAnchorSample {
  public let originFromDevice: simd_float4x4?
  public let originFromWorldAnchor: simd_float4x4?
  public let deviceAnchor: DeviceAnchor?
  public let worldAnchor: WorldAnchor?
}

struct BorgSpatialStylusSample {
  let tipPosition: SIMD3<Float>
  let isDrawing: Bool
  /// Normalized pressure when drawing with the tip; nil for in-air drawing.
  let tipPressure: Float?
  let isAdjustingRadius: Bool
}

enum BorgSpatialInputSource: Sendable {
  case stylus
  case controller
}

enum BorgSpatialInputChirality: Sendable {
  case left
  case right
  case unspecified
}

/// Device-independent input consumed by the immersive interaction layer.
struct BorgSpatialInputSample: Sendable {
  let id: UUID
  let source: BorgSpatialInputSource
  let chirality: BorgSpatialInputChirality
  let aimTransform: simd_float4x4
  let gripTransform: simd_float4x4
  let primaryValue: Float
  let modifierPressed: Bool
  let adjustment: SIMD2<Float>
  let tipPressure: Float?

  var primaryPressed: Bool { primaryValue > 0.05 }
  var position: SIMD3<Float> {
    SIMD3<Float>(gripTransform.columns.3.x,
                 gripTransform.columns.3.y,
                 gripTransform.columns.3.z)
  }
  var aimOrigin: SIMD3<Float> {
    SIMD3<Float>(aimTransform.columns.3.x,
                 aimTransform.columns.3.y,
                 aimTransform.columns.3.z)
  }
  var aimDirection: SIMD3<Float> {
    simd_normalize(-SIMD3<Float>(
      aimTransform.columns.2.x,
      aimTransform.columns.2.y,
      aimTransform.columns.2.z
    ))
  }
}

final class BorgARProvider {

  private let logger: LoggerBase?
  let session: ARKitSession
  let provider: WorldTrackingProvider
  private var updatesTask: Task<Void, Never>?
  private var sharingAvailabilityTask: Task<Void, Never>?
  private var accessoryConnectionTasks: [Task<Void, Never>] = []
  private var isHost: Bool = false

  private(set) var currentWorldAnchor: WorldAnchor?
  private let stateQueue = DispatchQueue(label: "BorgARProvider.state", qos: .userInitiated)
  private var latestWorldAnchorTransform: simd_float4x4?
  private var worldAnchorCreationInProgress: Bool = false
  private var sharingIsAvailable: Bool = false
  private enum SpatialAccessoryDevice {
    case stylus(GCStylus)
    case controller(GCController)
  }

  private struct TrackedSpatialAccessory {
    let accessory: Accessory
    let device: SpatialAccessoryDevice
  }

  private var trackedSpatialAccessories: [TrackedSpatialAccessory] = []
  private var accessoryTrackingProvider: AccessoryTrackingProvider?

  init(logger: LoggerBase?, groupSessionHost: Bool) {
    self.logger = logger
    self.provider = WorldTrackingProvider()
    self.session = ARKitSession()
    self.isHost = groupSessionHost
  }

  deinit {
    updatesTask?.cancel()
    sharingAvailabilityTask?.cancel()
    accessoryConnectionTasks.forEach { $0.cancel() }
    updatesTask = nil
    sharingAvailabilityTask = nil
    accessoryConnectionTasks.removeAll()
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

  func getSpatialStylusSample(atTimestamp timestamp: TimeInterval) -> BorgSpatialStylusSample? {
    guard let sample = getSpatialInputSamples(atTimestamp: timestamp).first(where: {
      $0.source == .stylus
    }) else { return nil }
    return BorgSpatialStylusSample(
      tipPosition: sample.aimOrigin,
      isDrawing: sample.primaryPressed,
      tipPressure: sample.tipPressure,
      isAdjustingRadius: !sample.primaryPressed && sample.modifierPressed
    )
  }

  func getSpatialInputSamples(atTimestamp timestamp: TimeInterval) -> [BorgSpatialInputSample] {
    let state = stateQueue.sync {
      (trackedSpatialAccessories, accessoryTrackingProvider)
    }
    guard let accessoryTrackingProvider = state.1,
          accessoryTrackingProvider.state == .running else {
      return []
    }

    return accessoryTrackingProvider.latestAnchors.compactMap { latestAnchor in
      guard let tracked = state.0.first(where: {
        $0.accessory.id == latestAnchor.accessory.id
      }) else { return nil }

      let anchor = accessoryTrackingProvider.predictAnchor(
        for: latestAnchor,
        at: timestamp
      ) ?? latestAnchor
      switch anchor.trackingState {
        case .positionOrientationTracked, .positionOrientationTrackedLowAccuracy:
          break
        case .untracked, .orientationTracked:
          return nil
        @unknown default:
          return nil
      }

      let aimTransform = anchor.coordinateSpace(
        for: .aim,
        correction: .rendered
      ).ancestorFromSpaceTransformFloat().matrix
      let gripTransform: simd_float4x4
      if tracked.accessory.locations.contains(.grip) {
        gripTransform = anchor.coordinateSpace(
          for: .grip,
          correction: .rendered
        ).ancestorFromSpaceTransformFloat().matrix
      } else {
        gripTransform = aimTransform
      }

      let chirality: BorgSpatialInputChirality
      switch anchor.heldChirality ?? tracked.accessory.inherentChirality {
        case .left: chirality = .left
        case .right: chirality = .right
        case .unspecified: chirality = .unspecified
        @unknown default: chirality = .unspecified
      }

      switch tracked.device {
        case .stylus(let stylus):
          let input = stylus.input
          let tipInput = input?.buttons[.stylusTip]?.pressedInput
          let tipPressure = min(1, max(0, tipInput?.value ?? 0))
          let tipPressed = tipPressure > 0.001
          let sideDraw = input?.buttons[.stylusSecondaryButton]?.pressedInput.isPressed ?? false
          let modifier = input?.buttons[.stylusPrimaryButton]?.pressedInput.isPressed ?? false
          return BorgSpatialInputSample(
            id: tracked.accessory.id,
            source: .stylus,
            chirality: chirality,
            aimTransform: aimTransform,
            gripTransform: gripTransform,
            primaryValue: tipPressed || sideDraw ? max(tipPressure, 1) : 0,
            modifierPressed: modifier,
            adjustment: .zero,
            tipPressure: tipPressed ? tipPressure : nil
          )

        case .controller(let controller):
          let input = controller.input
          let trigger = input.buttons[.trigger]?.pressedInput.value ?? 0
          let grip = input.buttons[.grip]?.pressedInput.value ?? 0
          let thumbstick = input.dpads[.thumbstick]
          return BorgSpatialInputSample(
            id: tracked.accessory.id,
            source: .controller,
            chirality: chirality,
            aimTransform: aimTransform,
            gripTransform: gripTransform,
            primaryValue: min(1, max(0, trigger)),
            modifierPressed: grip > 0.05,
            adjustment: SIMD2<Float>(
              thumbstick?.xAxis.value ?? 0,
              thumbstick?.yAxis.value ?? 0
            ),
            tipPressure: nil
          )
      }
    }
  }

  // MARK: - Session

  @MainActor
  public func startARSession() async {
    currentWorldAnchor = nil
    latestWorldAnchorTransform = nil
    worldAnchorCreationInProgress = false
    do {
      try await reconfigureSpatialAccessories()
      startWorldAnchorListener()
      startSharingAvailabilityListener()
      startSpatialAccessoryListeners()
    } catch {
      logger?.error("ARSession failed to start: \(error)")
      fatalError("Failed to initialize ARSession")
    }
  }

  public func stopARSession() {
    updatesTask?.cancel()
    sharingAvailabilityTask?.cancel()
    accessoryConnectionTasks.forEach { $0.cancel() }
    accessoryConnectionTasks.removeAll()

    currentWorldAnchor = nil
    latestWorldAnchorTransform = nil
    worldAnchorCreationInProgress = false
    sharingIsAvailable = false
    stateQueue.sync {
      trackedSpatialAccessories.removeAll()
      accessoryTrackingProvider = nil
    }
    session.stop()
  }

  @MainActor
  private func reconfigureSpatialAccessories() async throws {
    let styli = GCStylus.styli.filter {
      $0.productCategory == GCProductCategorySpatialStylus
    }
    let controllers = GCController.controllers().filter {
      $0.productCategory == GCProductCategorySpatialController
    }

    var tracked: [TrackedSpatialAccessory] = []
    for stylus in styli {
      do {
        tracked.append(.init(
          accessory: try await Accessory(device: stylus),
          device: .stylus(stylus)
        ))
      } catch {
        logger?.warning("Spatial stylus is unavailable: \(error)")
      }
    }
    for controller in controllers {
      do {
        tracked.append(.init(
          accessory: try await Accessory(device: controller),
          device: .controller(controller)
        ))
      } catch {
        logger?.warning("Spatial controller is unavailable: \(error)")
      }
    }

    let accessoryProvider: AccessoryTrackingProvider?
    if tracked.isEmpty {
      accessoryProvider = nil
      try await session.run([provider])
    } else {
      let newProvider = AccessoryTrackingProvider(accessories: tracked.map(\.accessory))
      accessoryProvider = newProvider
      try await session.run([provider, newProvider])
    }
    stateQueue.sync {
      trackedSpatialAccessories = tracked
      accessoryTrackingProvider = accessoryProvider
    }
    logger?.info(
      "Tracking \(styli.count) spatial stylus device(s) and \(controllers.count) spatial controller(s)"
    )
  }

  @MainActor
  private func reconfigureSpatialAccessoriesAfterConnectionChange() async {
    do {
      try await reconfigureSpatialAccessories()
    } catch {
      logger?.error("Failed to reconfigure spatial accessory tracking: \(error)")
    }
  }

  @MainActor
  private func startSpatialAccessoryListeners() {
    accessoryConnectionTasks.forEach { $0.cancel() }
    accessoryConnectionTasks.removeAll()

    accessoryConnectionTasks.append(Task { @MainActor [weak self] in
      for await notification in NotificationCenter.default.notifications(
        named: .GCStylusDidConnect
      ) {
        guard let self,
              let stylus = notification.object as? GCStylus,
              stylus.productCategory == GCProductCategorySpatialStylus else {
          continue
        }
        await self.reconfigureSpatialAccessoriesAfterConnectionChange()
      }
    })

    accessoryConnectionTasks.append(Task { @MainActor [weak self] in
      for await notification in NotificationCenter.default.notifications(
        named: .GCStylusDidDisconnect
      ) {
        guard let self,
              notification.object is GCStylus else {
          continue
        }
        await self.reconfigureSpatialAccessoriesAfterConnectionChange()
      }
    })

    accessoryConnectionTasks.append(Task { @MainActor [weak self] in
      for await notification in NotificationCenter.default.notifications(
        named: .GCControllerDidConnect
      ) {
        guard let self,
              let controller = notification.object as? GCController,
              controller.productCategory == GCProductCategorySpatialController else {
          continue
        }
        await self.reconfigureSpatialAccessoriesAfterConnectionChange()
      }
    })

    accessoryConnectionTasks.append(Task { @MainActor [weak self] in
      for await notification in NotificationCenter.default.notifications(
        named: .GCControllerDidDisconnect
      ) {
        guard let self,
              let controller = notification.object as? GCController,
              controller.productCategory == GCProductCategorySpatialController else {
          continue
        }
        await self.reconfigureSpatialAccessoriesAfterConnectionChange()
      }
    })
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
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
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
