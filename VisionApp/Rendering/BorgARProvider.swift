import ARKit
import RealityKit
import CompositorServices
import Foundation
import GameController
import simd

public struct BorgAnchorSample {
  public let originFromDevice: simd_float4x4?
  public let originFromWorldAnchor: simd_float4x4?
  public let deviceAnchor: DeviceAnchor?
  public let worldAnchor: WorldAnchor?
  public let worldAnchorIsShared: Bool
}

struct BorgSpatialStylusSample {
  let tipPosition: SIMD3<Float>
  let aimTransform: simd_float4x4
  let isDrawing: Bool
  /// Normalized pressure from the tip or large drawing button.
  let drawingPressure: Float?
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
  /// Both Muse side buttons are held; the rear power button is not exposed by GameController.
  let toolTogglePressed: Bool
  let adjustment: SIMD2<Float>
  /// Normalized pressure from the active Muse drawing input.
  let drawingPressure: Float?
  let pressedFaceButtons: Set<SpatialControllerFaceButton>

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

  private final class WeakReference: @unchecked Sendable {
    weak var value: BorgARProvider?

    init(_ value: BorgARProvider) {
      self.value = value
    }
  }

  private let logger: LoggerBase?
  private let spatialAnchorSessionState: SpatialAnchorSessionState
  let session: ARKitSession
  let provider: WorldTrackingProvider
  private var updatesTask: Task<Void, Never>?
  private var sharingAvailabilityTask: Task<Void, Never>?
  private var accessoryConnectionObservers: [NSObjectProtocol] = []
  private let stateQueue = DispatchQueue(label: "BorgARProvider.state", qos: .userInitiated)

  private struct PendingWorldAnchorCreation {
    let token: UUID
    let anchor: WorldAnchor
    let transform: simd_float4x4
    let isShared: Bool
  }

  private struct WorldAnchorState {
    var current: WorldAnchor?
    var latestTransform: simd_float4x4?
    var currentIsShared = false
    var sharingIsAvailable = false
    var pendingCreation: PendingWorldAnchorCreation?
    var sharedAnchors: [UUID: WorldAnchor] = [:]
  }

  private var worldAnchorState = WorldAnchorState()
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
  @MainActor private var connectedSpatialStyli: [ObjectIdentifier: GCStylus] = [:]
  @MainActor private var connectedSpatialControllers: [ObjectIdentifier: GCController] = [:]
  @MainActor private var accessoryReconfigurationInProgress = false
  @MainActor private var accessoryReconfigurationRequested = false
  @MainActor private var accessoryRegistrationPending = false

  init(logger: LoggerBase?, spatialAnchorSessionState: SpatialAnchorSessionState) {
    self.logger = logger
    self.spatialAnchorSessionState = spatialAnchorSessionState
    self.provider = WorldTrackingProvider()
    self.session = ARKitSession()
  }

  deinit {
    updatesTask?.cancel()
    sharingAvailabilityTask?.cancel()
    accessoryConnectionObservers.forEach(NotificationCenter.default.removeObserver)
    updatesTask = nil
    sharingAvailabilityTask = nil
    accessoryConnectionObservers.removeAll()
    session.stop()
  }

  // MARK: - Rendering access (non-async)

  public func getAnchors(for drawable: LayerRenderer.Drawable) -> BorgAnchorSample {
    let t = LayerRenderer.Clock.Instant.epoch
      .duration(to: drawable.frameTiming.presentationTime)
      .timeInterval

    let deviceAnchor = provider.queryDeviceAnchor(atTimestamp: t)
    drawable.deviceAnchor = deviceAnchor

    if let deviceAnchor {
      reconcileWorldAnchor(originFromDevice: deviceAnchor.originFromAnchorTransform)
    }

    let anchorSnapshot = stateQueue.sync {
      (
        worldAnchorState.latestTransform,
        worldAnchorState.current,
        worldAnchorState.currentIsShared
      )
    }
    return .init(
      originFromDevice: deviceAnchor?.originFromAnchorTransform,
      originFromWorldAnchor: anchorSnapshot.0,
      deviceAnchor: deviceAnchor,
      worldAnchor: anchorSnapshot.1,
      worldAnchorIsShared: anchorSnapshot.2
    )
  }

  func getSpatialStylusSample(atTimestamp timestamp: TimeInterval) -> BorgSpatialStylusSample? {
    guard let sample = getSpatialInputSamples(atTimestamp: timestamp).first(where: {
      $0.source == .stylus
    }) else { return nil }
    return BorgSpatialStylusSample(
      tipPosition: sample.aimOrigin,
      aimTransform: sample.aimTransform,
      isDrawing: sample.primaryPressed,
      drawingPressure: sample.drawingPressure,
      isAdjustingRadius: !sample.primaryPressed && sample.modifierPressed
    )
  }

  func getSpatialInputSamples(atTimestamp timestamp: TimeInterval) -> [BorgSpatialInputSample] {
    stateQueue.sync {
      guard let accessoryTrackingProvider,
            accessoryTrackingProvider.state == .running else {
        return []
      }

      return accessoryTrackingProvider.latestAnchors.compactMap { latestAnchor in
        guard let tracked = trackedSpatialAccessories.first(where: {
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
            let sideInput = input?.buttons[.stylusSecondaryButton]?.pressedInput
            let sidePressure = min(1, max(0, sideInput?.value ?? 0))
            let sideDraw = sideInput?.isPressed ?? false
            let modifier = input?.buttons[.stylusPrimaryButton]?.pressedInput.isPressed ?? false
            return BorgSpatialInputSample(
              id: tracked.accessory.id,
              source: .stylus,
              chirality: chirality,
              aimTransform: aimTransform,
              gripTransform: gripTransform,
              primaryValue: tipPressed || sideDraw ? 1 : 0,
              modifierPressed: modifier,
              toolTogglePressed: sideDraw && modifier,
              adjustment: .zero,
              drawingPressure: tipPressed ? tipPressure : (sideDraw ? sidePressure : nil),
              pressedFaceButtons: []
            )

          case .controller(let controller):
            let input = controller.input
            let trigger = input.buttons[.trigger]?.pressedInput.value ?? 0
            let grip = input.buttons[.grip]?.pressedInput.value ?? 0
            let thumbstick = input.dpads[.thumbstick]
            let pressedPositions = Set(SpatialControllerFaceButton.allCases.compactMap {
              input.buttons[$0.inputName]?.pressedInput.isPressed == true ? $0.position : nil
            })
            let pressedFaceButtons = Set(pressedPositions.map {
              switch $0 {
                case .primary: SpatialControllerFaceButton.a
                case .secondary: SpatialControllerFaceButton.b
              }
            })
            return BorgSpatialInputSample(
              id: tracked.accessory.id,
              source: .controller,
              chirality: chirality,
              aimTransform: aimTransform,
              gripTransform: gripTransform,
              primaryValue: min(1, max(0, trigger)),
              modifierPressed: grip > 0.05,
              toolTogglePressed: false,
              adjustment: SIMD2<Float>(
                thumbstick?.xAxis.value ?? 0,
                thumbstick?.yAxis.value ?? 0
              ),
              drawingPressure: nil,
              pressedFaceButtons: pressedFaceButtons
            )
        }
      }
    }
  }

  // MARK: - Session

  @MainActor
  public func startARSession() async {
    stateQueue.sync { worldAnchorState = WorldAnchorState() }
    spatialAnchorSessionState.publishActiveAnchor(id: nil, isShared: false)
    do {
      // Controller discovery is asynchronous. Install the listeners before taking
      // the initial snapshot so a second accessory cannot connect in between.
      connectedSpatialStyli.removeAll()
      connectedSpatialControllers.removeAll()
      accessoryReconfigurationInProgress = false
      accessoryReconfigurationRequested = false
      accessoryRegistrationPending = false
      startSpatialAccessoryListeners()
      registerCurrentlyConnectedSpatialAccessories()
      let hasUnavailableAccessories = try await reconfigureSpatialAccessories()
      if hasUnavailableAccessories {
        logger?.info("Retrying spatial accessories that were not initially ready.")
        _ = try await reconfigureSpatialAccessories()
      }
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
    accessoryConnectionObservers.forEach(NotificationCenter.default.removeObserver)
    accessoryConnectionObservers.removeAll()

    stateQueue.sync {
      worldAnchorState = WorldAnchorState()
      trackedSpatialAccessories.removeAll()
      accessoryTrackingProvider = nil
    }
    spatialAnchorSessionState.publishActiveAnchor(id: nil, isShared: false)
    session.stop()
  }

  @MainActor
  private func reconfigureSpatialAccessories() async throws -> Bool {
    let styli = Array(connectedSpatialStyli.values)
    let controllers = assignPlayerIndicesToSpatialControllers()

    let existingTracked = stateQueue.sync { trackedSpatialAccessories }
    var tracked: [TrackedSpatialAccessory] = []
    var unavailableAccessoryCount = 0
    for stylus in styli {
      if let existing = existingTracked.first(where: { tracked in
        guard case .stylus(let existingStylus) = tracked.device else { return false }
        return existingStylus === stylus
      }) {
        tracked.append(existing)
        continue
      }
      do {
        tracked.append(.init(
          accessory: try await Accessory(device: stylus),
          device: .stylus(stylus)
        ))
      } catch {
        unavailableAccessoryCount += 1
        logger?.warning("Spatial stylus is unavailable: \(error)")
      }
    }
    for controller in controllers {
      if let existing = existingTracked.first(where: { tracked in
        guard case .controller(let existingController) = tracked.device else { return false }
        return existingController === controller
      }) {
        tracked.append(existing)
        continue
      }
      do {
        tracked.append(.init(
          accessory: try await Accessory(device: controller),
          device: .controller(controller)
        ))
      } catch {
        unavailableAccessoryCount += 1
        let name = controller.vendorName ?? controller.productCategory
        logger?.warning("Spatial controller \(name) is unavailable: \(error)")
      }
    }

    accessoryRegistrationPending = unavailableAccessoryCount > 0
    let accessories = tracked.map(\.accessory)
    let existingProvider = stateQueue.sync { accessoryTrackingProvider }
    if #available(visionOS 27.0, *), let existingProvider {
      stateQueue.sync {
        accessoryTrackingProvider = nil
      }
      do {
        try await existingProvider.updateAccessories(accessories)
      } catch {
        stateQueue.sync {
          accessoryTrackingProvider = existingProvider
        }
        throw error
      }
      stateQueue.sync {
        trackedSpatialAccessories = tracked
        accessoryTrackingProvider = existingProvider
      }
      logger?.info(
        "Updated accessory tracking: \(styli.count) stylus device(s), " +
          "\(controllers.count) spatial controller(s), \(accessories.count) tracked accessory(ies)."
      )
      return unavailableAccessoryCount > 0
    }

    let previousProvider = stateQueue.sync { () -> AccessoryTrackingProvider? in
      let previousProvider = accessoryTrackingProvider
      accessoryTrackingProvider = nil
      return previousProvider
    }
    let accessoryProvider = tracked.isEmpty ? nil : AccessoryTrackingProvider(
      accessories: tracked.map(\.accessory)
    )
    do {
      if let accessoryProvider {
        try await session.run([provider, accessoryProvider])
      } else {
        try await session.run([provider])
      }
    } catch {
      stateQueue.sync {
        accessoryTrackingProvider = previousProvider
      }
      throw error
    }
    stateQueue.sync {
      trackedSpatialAccessories = tracked
      accessoryTrackingProvider = accessoryProvider
    }
    logger?.info(
      "Started accessory tracking: \(styli.count) stylus device(s), " +
        "\(controllers.count) spatial controller(s), \(accessories.count) tracked accessory(ies)."
    )
    return unavailableAccessoryCount > 0
  }

  @MainActor
  private func reconfigureSpatialAccessoriesAfterConnectionChange() async {
    accessoryReconfigurationRequested = true
    guard !accessoryReconfigurationInProgress else { return }
    accessoryReconfigurationInProgress = true
    defer { accessoryReconfigurationInProgress = false }

    var retriedUnavailableAccessories = false
    while accessoryReconfigurationRequested {
      accessoryReconfigurationRequested = false
      do {
        let hasUnavailableAccessories = try await reconfigureSpatialAccessories()
        if hasUnavailableAccessories && !retriedUnavailableAccessories {
          retriedUnavailableAccessories = true
          accessoryReconfigurationRequested = true
          logger?.info("Retrying spatial accessories that are not ready yet.")
        }
      } catch {
        accessoryRegistrationPending = true
        logger?.error("Failed to reconfigure spatial accessory tracking: \(error)")
        if !retriedUnavailableAccessories {
          retriedUnavailableAccessories = true
          accessoryReconfigurationRequested = true
        }
      }
    }
  }

  @MainActor
  private func startSpatialAccessoryListeners() {
    accessoryConnectionObservers.forEach(NotificationCenter.default.removeObserver)
    accessoryConnectionObservers.removeAll()

    let center = NotificationCenter.default
    let weakSelf = WeakReference(self)
    accessoryConnectionObservers.append(center.addObserver(
      forName: .GCStylusDidConnect,
      object: nil,
      queue: .main
    ) { notification in
      Task { @MainActor in
        await weakSelf.value?.handleSpatialAccessoryConnectionChange(
          notification,
          connected: true
        )
      }
    })
    accessoryConnectionObservers.append(center.addObserver(
      forName: .GCStylusDidDisconnect,
      object: nil,
      queue: .main
    ) { notification in
      Task { @MainActor in
        await weakSelf.value?.handleSpatialAccessoryConnectionChange(
          notification,
          connected: false
        )
      }
    })
    accessoryConnectionObservers.append(center.addObserver(
      forName: .GCControllerDidConnect,
      object: nil,
      queue: .main
    ) { notification in
      Task { @MainActor in
        await weakSelf.value?.handleSpatialAccessoryConnectionChange(
          notification,
          connected: true
        )
      }
    })
    accessoryConnectionObservers.append(center.addObserver(
      forName: .GCControllerDidDisconnect,
      object: nil,
      queue: .main
    ) { notification in
      Task { @MainActor in
        await weakSelf.value?.handleSpatialAccessoryConnectionChange(
          notification,
          connected: false
        )
      }
    })
  }

  @MainActor
  private func registerCurrentlyConnectedSpatialAccessories() {
    connectedSpatialStyli = Dictionary(uniqueKeysWithValues: GCStylus.styli.compactMap {
      guard $0.productCategory == GCProductCategorySpatialStylus else { return nil }
      return (ObjectIdentifier($0), $0)
    })
    connectedSpatialControllers = Dictionary(
      uniqueKeysWithValues: GCController.controllers().compactMap {
        guard $0.productCategory == GCProductCategorySpatialController else { return nil }
        return (ObjectIdentifier($0), $0)
      }
    )
  }

  @MainActor
  private func assignPlayerIndicesToSpatialControllers() -> [GCController] {
    let connectedControllers = GCController.controllers().filter {
      connectedSpatialControllers[ObjectIdentifier($0)] != nil
    }
    let availableIndices: [GCControllerPlayerIndex] = [
      .index1, .index2, .index3, .index4
    ]
    var usedIndices = Set(connectedControllers.compactMap { controller in
      controller.playerIndex == .indexUnset ? nil : controller.playerIndex
    })

    for controller in connectedControllers where controller.playerIndex == .indexUnset {
      guard let index = availableIndices.first(where: { !usedIndices.contains($0) }) else {
        break
      }
      controller.playerIndex = index
      usedIndices.insert(index)
    }
    return connectedControllers
  }

  @MainActor
  private func handleSpatialAccessoryConnectionChange(
    _ notification: Notification,
    connected: Bool
  ) async {
    let previousStylusIDs = Set(connectedSpatialStyli.keys)
    let previousControllerIDs = Set(connectedSpatialControllers.keys)
    registerCurrentlyConnectedSpatialAccessories()

    if let stylus = notification.object as? GCStylus,
       stylus.productCategory == GCProductCategorySpatialStylus {
      connectedSpatialStyli[ObjectIdentifier(stylus)] = connected ? stylus : nil
    }
    if let controller = notification.object as? GCController,
       controller.productCategory == GCProductCategorySpatialController {
      connectedSpatialControllers[ObjectIdentifier(controller)] = connected ? controller : nil
    }

    let deviceSetChanged = previousStylusIDs != Set(connectedSpatialStyli.keys) ||
      previousControllerIDs != Set(connectedSpatialControllers.keys)
    guard deviceSetChanged || accessoryRegistrationPending else { return }
    await reconfigureSpatialAccessoriesAfterConnectionChange()
  }

  // MARK: - World anchor management (async)

  private func reconcileWorldAnchor(originFromDevice: simd_float4x4) {
    #if targetEnvironment(simulator)
    return
    #else
    let sessionSnapshot = spatialAnchorSessionState.snapshot()
    var replacedAnchor: WorldAnchor?
    var activatedExpectedSharedAnchor = false
    var creation: PendingWorldAnchorCreation?

    stateQueue.sync {
      if sessionSnapshot.sharePlayIsActive,
         !sessionSnapshot.localParticipantIsHost,
         let expectedID = sessionSnapshot.expectedSharedAnchorID,
         worldAnchorState.current?.id != expectedID,
         let sharedAnchor = worldAnchorState.sharedAnchors[expectedID] {
        replacedAnchor = worldAnchorState.current
        worldAnchorState.current = sharedAnchor
        worldAnchorState.latestTransform = sharedAnchor.originFromAnchorTransform
        worldAnchorState.currentIsShared = true
        worldAnchorState.pendingCreation = nil
        activatedExpectedSharedAnchor = true
      }

      guard worldAnchorState.pendingCreation == nil else { return }

      let shouldCreateShared = sessionSnapshot.sharePlayIsActive &&
        sessionSnapshot.localParticipantIsHost &&
        worldAnchorState.sharingIsAvailable
      let shouldCreateLocal = !sessionSnapshot.sharePlayIsActive ||
        (sessionSnapshot.localParticipantIsHost && !worldAnchorState.sharingIsAvailable)
      guard shouldCreateShared || shouldCreateLocal else { return }

      if worldAnchorState.current != nil,
         worldAnchorState.currentIsShared == shouldCreateShared {
        return
      }

      // Replacements use the exact previous transform so changing between local and
      // shared anchors cannot move the dataset in the physical room.
      let transform = worldAnchorState.latestTransform ?? originFromDevice
      let anchor = WorldAnchor(
        originFromAnchorTransform: transform,
        sharedWithNearbyParticipants: shouldCreateShared
      )
      let request = PendingWorldAnchorCreation(
        token: UUID(),
        anchor: anchor,
        transform: transform,
        isShared: shouldCreateShared
      )
      worldAnchorState.pendingCreation = request
      creation = request
    }

    if activatedExpectedSharedAnchor {
      let anchorDescription = sessionSnapshot.expectedSharedAnchorID?.uuidString ?? "unknown"
      logger?.dev("Activated expected shared WorldAnchor \(anchorDescription).")
      publishCurrentAnchor()
    }
    if let replacedAnchor {
      Task { [weak self] in
        try? await self?.provider.removeAnchor(replacedAnchor)
      }
    }

    if let creation {
      Task { [weak self] in
        await self?.finishCreatingWorldAnchor(creation)
      }
    }
    #endif
  }

  private func finishCreatingWorldAnchor(_ creation: PendingWorldAnchorCreation) async {
    do {
      try await provider.addAnchor(creation.anchor)
    } catch {
      logger?.error("addAnchor failed: \(error)")
      stateQueue.sync {
        if worldAnchorState.pendingCreation?.token == creation.token {
          worldAnchorState.pendingCreation = nil
        }
      }
      return
    }

    let sessionSnapshot = spatialAnchorSessionState.snapshot()
    var replacedAnchor: WorldAnchor?
    let accepted = stateQueue.sync { () -> Bool in
      guard worldAnchorState.pendingCreation?.token == creation.token else { return false }

      let sharedAnchorIsStillWanted = sessionSnapshot.sharePlayIsActive &&
        sessionSnapshot.localParticipantIsHost &&
        worldAnchorState.sharingIsAvailable
      let localAnchorIsStillWanted = !sessionSnapshot.sharePlayIsActive ||
        (sessionSnapshot.localParticipantIsHost && !worldAnchorState.sharingIsAvailable)
      guard creation.isShared ? sharedAnchorIsStillWanted : localAnchorIsStillWanted else {
        worldAnchorState.pendingCreation = nil
        return false
      }

      replacedAnchor = worldAnchorState.current
      worldAnchorState.current = creation.anchor
      worldAnchorState.latestTransform = creation.transform
      worldAnchorState.currentIsShared = creation.isShared
      worldAnchorState.pendingCreation = nil
      if creation.isShared {
        worldAnchorState.sharedAnchors[creation.anchor.id] = creation.anchor
      }
      return true
    }

    guard accepted else {
      try? await provider.removeAnchor(creation.anchor)
      return
    }

    logger?.dev(
      creation.isShared
        ? "Created and activated shared WorldAnchor \(creation.anchor.id)"
        : "Created and activated local WorldAnchor \(creation.anchor.id)"
    )
    publishCurrentAnchor()
    if let replacedAnchor, replacedAnchor.id != creation.anchor.id {
      try? await provider.removeAnchor(replacedAnchor)
    }
  }

  public func clearWorldAnchor() async {
    let existing = stateQueue.sync { () -> WorldAnchor? in
      let existing = worldAnchorState.current
      worldAnchorState.current = nil
      worldAnchorState.latestTransform = nil
      worldAnchorState.currentIsShared = false
      worldAnchorState.pendingCreation = nil
      return existing
    }
    guard let existing else { return }
    do { try await provider.removeAnchor(existing) } catch {
      logger?.error("removeAnchor failed: \(error)")
    }
    spatialAnchorSessionState.publishActiveAnchor(id: nil, isShared: false)
  }

  private func publishCurrentAnchor() {
    let snapshot = stateQueue.sync {
      (worldAnchorState.current?.id, worldAnchorState.currentIsShared)
    }
    spatialAnchorSessionState.publishActiveAnchor(id: snapshot.0, isShared: snapshot.1)
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
            var shouldRemove = false
            self.stateQueue.sync {
              if anchor.isSharedWithNearbyParticipants {
                self.worldAnchorState.sharedAnchors[anchor.id] = anchor
              }
              if anchor.id == self.worldAnchorState.current?.id {
                self.worldAnchorState.current = anchor
                self.worldAnchorState.latestTransform = anchor.originFromAnchorTransform
              } else if anchor.id != self.worldAnchorState.pendingCreation?.anchor.id,
                        !anchor.isSharedWithNearbyParticipants {
                shouldRemove = true
              }
            }
            if shouldRemove {
              try? await self.provider.removeAnchor(anchor)
            }
          case .updated:
            self.stateQueue.sync {
              if anchor.isSharedWithNearbyParticipants {
                self.worldAnchorState.sharedAnchors[anchor.id] = anchor
              }
              if anchor.id == self.worldAnchorState.current?.id {
                self.worldAnchorState.current = anchor
                self.worldAnchorState.latestTransform = anchor.originFromAnchorTransform
              }
            }
          case .removed:
            var removedCurrent = false
            self.stateQueue.sync {
              self.worldAnchorState.sharedAnchors.removeValue(forKey: anchor.id)
              if anchor.id == self.worldAnchorState.current?.id {
                self.worldAnchorState.latestTransform = nil
                self.worldAnchorState.current = nil
                self.worldAnchorState.currentIsShared = false
                removedCurrent = true
              }
            }
            if removedCurrent {
              self.spatialAnchorSessionState.publishActiveAnchor(id: nil, isShared: false)
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
          self.stateQueue.sync { self.worldAnchorState.sharingIsAvailable = true }
        } else {
          self.logger?.dev("World anchor sharing is not available: \(sharingAvailability)")
          self.stateQueue.sync { self.worldAnchorState.sharingIsAvailable = false }
        }
      }
    }
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
