import CompositorServices
import Spatial
import SwiftUI

class ImmersiveInteraction {
  var sharedAppModel: SharedAppModel
  var storedAppModel: StoredAppModel
  var transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState

  private var startTranslation: SIMD3<Float> = .zero
  private var startRotation: simd_quatf = .init(.identity)
  private var tmpDistance: Double = 0.0

  private var startTranslationClipping: SIMD3<Float> = .zero
  private var translationClipping: SIMD3<Float> = .zero

  private var doubleEventIsRunning = false
  private var transferFunctionPanelDragStart: SIMD2<Float>?
  private var transferFunctionPanelHandStart: SIMD3<Float>?
  private var transferFunctionPanelMarkerOpacity: Float = 1
  private var transferFunctionPanelMarkerSuppressed = false
  private var transferFunctionPanelChannelToggleActive = false
  private var markerDragID: UUID?
  private var markerDragStartPosition: SIMD3<Float> = .zero
  private var markerDragHandStart: SIMD3<Float>?
  private var markerScaleID: UUID?
  private var markerScaleStartDistance: Float = 0
  private var markerScaleStartRadius = VolumeMarkerRadius.sphereDefault
  private var quickMarkerDragActive = false
  private var quickMarkerCandidateTime: Date?
  private var quickMarkerCandidatePosition: SIMD3<Float>?
  private let quickMarkerMaxDistance: Float = 0.15

  init(sharedAppModel: SharedAppModel,
       storedAppModel: StoredAppModel,
       transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState) {
    self.sharedAppModel = sharedAppModel
    self.storedAppModel = storedAppModel
    self.transferFunctionPanelInteractionState = transferFunctionPanelInteractionState
  }

  func distanceBetweenVectors(v1: SIMD3<Double>, v2: SIMD3<Double>) -> Double {
    let deltaX = v2.x - v1.x
    let deltaY = v2.y - v1.y
    let deltaZ = v2.z - v1.z
    return sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
  }

  private func handleScaling(_ events: SpatialEventCollection) {
    doubleEventIsRunning = true
    var v1: SIMD3<Double>?
    var v2: SIMD3<Double>?
    for event in events {
      switch event.phase {
        case .active:
          if v1 == nil {
            v1 = event.inputDevicePose!.pose3D.position.vector
          } else {
            v2 = event.inputDevicePose!.pose3D.position.vector
          }
        case .cancelled, .ended:
          sharedAppModel.lastModelTransform.scale = sharedAppModel.modelTransform.scale
          sharedAppModel.synchronize(kind: .transformOnly)
          tmpDistance = 0
        default:
          break
      }
    }
    if (v1 != nil && v2 != nil) {
      let distance = distanceBetweenVectors(v1: v1!, v2: v2!)
      if tmpDistance == 0.0 {
        tmpDistance = distance
      }
      sharedAppModel.modelTransform.scale = SIMD3(repeating: sharedAppModel.lastModelTransform.scale.x * (Float(distance - tmpDistance) + 1))
      sharedAppModel.synchronize(kind: .transformOnly)
    }
  }

  private func handleTranslationAndRotation(_ event: SpatialEventCollection.Event) {

    let inverseWorld = sharedAppModel.originFromWorldAnchorMatrix.inverse

    switch event.phase {
    case .active:
      // One hand from the scaling movement is still active
      if doubleEventIsRunning {
        return
      }
      if let pose = event.inputDevicePose {
        if startTranslation == .zero {
          startTranslation = SIMD3<Float>(pose.pose3D.position.vector)
          startRotation = simd_quatf(pose.pose3D.rotation.transformed(
            by: inverseWorld,
            order: .pre
          ))
        }

        let poseRotation = simd_quatf(pose.pose3D.rotation.transformed(
          by: inverseWorld,
          order: .pre
        ))

        sharedAppModel.modelTransform.rotation =  poseRotation * startRotation.inverse * sharedAppModel.lastModelTransform.rotation

        let translate = inverseWorld.transformDirection(SIMD3<Float>(pose.pose3D.position.vector) - startTranslation)

        sharedAppModel.modelTransform.translation = sharedAppModel.lastModelTransform.translation + translate
        sharedAppModel.synchronize(kind: .transformOnly)
      }
    case .cancelled, .ended:
      sharedAppModel.lastModelTransform.translation = sharedAppModel.modelTransform.translation
      sharedAppModel.lastModelTransform.rotation = sharedAppModel.modelTransform.rotation
      startTranslation = .zero
      startRotation = .init(.identity)
      doubleEventIsRunning = false
    default:
      break
    }
  }

  private func handleClippingTranslationAndRotation(_ event: SpatialEventCollection.Event) {
    let inverseWorld = sharedAppModel.originFromWorldAnchorMatrix.inverse

    switch event.phase {
      case .active:
        // One hand from the scaling movement is still active
        if doubleEventIsRunning {
          return
        }
        if let pose = event.inputDevicePose {

          if startTranslationClipping == .zero {
            startTranslationClipping = SIMD3<Float>(pose.pose3D.position.vector)
          }

          var translate = inverseWorld.transformDirection(SIMD3<Float>(pose.pose3D.position.vector) - startTranslationClipping)

          translate = simd_float3x3(
            sharedAppModel.modelTransform.rotation
          ).inverse * translate

          translationClipping = sharedAppModel.lastTranslationClipping + translate

          if translationClipping.x > 0.99 {translationClipping.x = 0.99}
          if translationClipping.y > 0.99 {translationClipping.y = 0.99}
          if translationClipping.z > 0.99 {translationClipping.z = 0.99}
          if translationClipping.x < -0.99 {translationClipping.x = -0.99}
          if translationClipping.y < -0.99 {translationClipping.y = -0.99}
          if translationClipping.z < -0.99 {translationClipping.z = -0.99}

          if translationClipping.x >= 0 {
            sharedAppModel.clipMax.x = 1
            sharedAppModel.clipMin.x = translationClipping.x
          } else {
            sharedAppModel.clipMin.x = 0
            sharedAppModel.clipMax.x = 1+translationClipping.x
          }

          if translationClipping.y >= 0 {
            sharedAppModel.clipMax.y = 1
            sharedAppModel.clipMin.y = translationClipping.y
          } else {
            sharedAppModel.clipMin.y = 0
            sharedAppModel.clipMax.y = 1+translationClipping.y
          }

          if translationClipping.z >= 0 {
            sharedAppModel.clipMax.z = 1
            sharedAppModel.clipMin.z = translationClipping.z
          } else {
            sharedAppModel.clipMin.z = 0
            sharedAppModel.clipMax.z = 1+translationClipping.z
          }
          
          sharedAppModel.synchronize(kind: .stateOnly)
        }
      case .cancelled, .ended:
        sharedAppModel.lastTranslationClipping = translationClipping
        startTranslationClipping = .zero
        doubleEventIsRunning = false
      default:
        break
    }
  }

  private func ray(from event: SpatialEventCollection.Event) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
    guard let selectionRay = event.selectionRay else {
      return nil
    }

    let originVector = selectionRay.origin.vector
    let directionVector = selectionRay.direction.vector
    let direction = SIMD3<Float>(
      Float(directionVector.x),
      Float(directionVector.y),
      Float(directionVector.z)
    )
    guard simd_length(direction) > 0.0001 else {
      return nil
    }

    return (
      SIMD3<Float>(
        Float(originVector.x),
        Float(originVector.y),
        Float(originVector.z)
      ),
      simd_normalize(direction)
    )
  }

  private func inputWorldPosition(from event: SpatialEventCollection.Event) -> SIMD3<Float>? {
    guard let pose = event.inputDevicePose else {
      return nil
    }

    let position = pose.pose3D.position.vector
    return SIMD3<Float>(
      Float(position.x),
      Float(position.y),
      Float(position.z)
    )
  }

  private func editableChannels(_ transferEditState: RuntimeAppModel.TransferEditState) -> [Int] {
    var channels: [Int] = []
    if transferEditState.red { channels.append(0) }
    if transferEditState.green { channels.append(1) }
    if transferEditState.blue { channels.append(2) }
    if transferEditState.opacity { channels.append(3) }
    return channels
  }

  private func clamp(_ value: Float, _ lower: Float = 0, _ upper: Float = 1) -> Float {
    min(max(value, lower), upper)
  }

  private func clamp(_ value: SIMD3<Float>, _ lower: Float = 0, _ upper: Float = 1) -> SIMD3<Float> {
    SIMD3<Float>(
      clamp(value.x, lower, upper),
      clamp(value.y, lower, upper),
      clamp(value.z, lower, upper)
    )
  }

  private func transformPoint(_ matrix: simd_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
    let transformed = matrix * SIMD4<Float>(point, 1)
    return SIMD3<Float>(transformed.x, transformed.y, transformed.z) / transformed.w
  }

  private func scaleMatrix(_ scale: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
      SIMD4<Float>(scale.x, 0, 0, 0),
      SIMD4<Float>(0, scale.y, 0, 0),
      SIMD4<Float>(0, 0, scale.z, 0),
      SIMD4<Float>(0, 0, 0, 1)
    )
  }

  private func markerVolumeMatrix(for datasetInfo: RuntimeAppModel.DatasetInfo) -> simd_float4x4 {
    sharedAppModel.originFromWorldAnchorMatrix *
      sharedAppModel.modelTransform.matrix *
      scaleMatrix(datasetInfo.volumeScale)
  }

  private func markerWorldCenter(_ point: VolumeMarkerPoint,
                                 datasetInfo: RuntimeAppModel.DatasetInfo) -> SIMD3<Float> {
    let matrix = markerVolumeMatrix(for: datasetInfo)
    return transformPoint(matrix, point.position - SIMD3<Float>(repeating: 0.5))
  }

  private func markerPosition(fromWorldPosition worldPosition: SIMD3<Float>,
                              datasetInfo: RuntimeAppModel.DatasetInfo) -> SIMD3<Float> {
    let inverseVolume = markerVolumeMatrix(for: datasetInfo).inverse
    return clamp(
      transformPoint(inverseVolume, worldPosition) + SIMD3<Float>(repeating: 0.5),
      BorgVRMarkerFormat.positionRange.lowerBound,
      BorgVRMarkerFormat.positionRange.upperBound
    )
  }

  private func markerSpawnPosition(
    from event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> SIMD3<Float>? {
    if storedAppModel.markerSpawnAtGaze {
      guard let ray = ray(from: event),
            let hit = rayVolumeHit(
              origin: ray.origin,
              direction: ray.direction,
              datasetInfo: datasetInfo
            ) else {
        return nil
      }
      return hit
    }

    guard let handPosition = inputWorldPosition(from: event) else {
      return nil
    }
    return markerPosition(fromWorldPosition: handPosition, datasetInfo: datasetInfo)
  }

  private func nearestMarker(to worldPosition: SIMD3<Float>,
                             datasetInfo: RuntimeAppModel.DatasetInfo) -> VolumeMarker? {
    var best: (marker: VolumeMarker, distance: Float)?
    for marker in sharedAppModel.volumeMarkers {
      for point in marker.points {
        let center = markerWorldCenter(point, datasetInfo: datasetInfo)
        let distance = simd_distance(center, worldPosition)
        let scale = sharedAppModel.modelTransform.scale
        let worldRadius = point.radius * max(scale.x, max(scale.y, scale.z))
        let pickDistance = max(worldRadius * 2, 0.08)
        guard distance <= pickDistance else { continue }
        if best == nil || distance < best!.distance {
          best = (marker, distance)
        }
      }
    }
    return best?.marker
  }

  private func rayVolumeHit(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> SIMD3<Float>? {
    let inverseVolume = markerVolumeMatrix(for: datasetInfo).inverse
    let localOrigin = transformPoint(inverseVolume, origin)
    let localDirection = simd_normalize(inverseVolume.transformDirection(direction))
    var nearT: Float = -.greatestFiniteMagnitude
    var farT: Float = .greatestFiniteMagnitude

    for axis in 0..<3 {
      let originComponent = localOrigin[axis]
      let directionComponent = localDirection[axis]
      if abs(directionComponent) < 0.00001 {
        if originComponent < -0.5 || originComponent > 0.5 {
          return nil
        }
        continue
      }

      let t0 = (-0.5 - originComponent) / directionComponent
      let t1 = (0.5 - originComponent) / directionComponent
      nearT = max(nearT, min(t0, t1))
      farT = min(farT, max(t0, t1))
    }

    guard farT >= max(nearT, 0) else {
      return nil
    }

    let hitT = max(nearT, 0)
    return clamp(localOrigin + localDirection * hitT + SIMD3<Float>(repeating: 0.5))
  }

  private func markerHit(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> VolumeMarker? {
    var best: (marker: VolumeMarker, distance: Float)?
    for marker in sharedAppModel.volumeMarkers {
      for point in marker.points {
        let center = markerWorldCenter(point, datasetInfo: datasetInfo)
        let oc = origin - center
        let scale = sharedAppModel.modelTransform.scale
        let radius = point.radius * max(scale.x, max(scale.y, scale.z))
        let b = simd_dot(oc, direction)
        let c = simd_dot(oc, oc) - radius * radius
        let discriminant = b * b - c
        guard discriminant >= 0 else { continue }
        let t = -b - sqrt(discriminant)
        guard t >= 0 else { continue }
        if best == nil || t < best!.distance {
          best = (marker, t)
        }
      }
    }
    return best?.marker
  }

  private func beginMarkerDrag(
    marker: VolumeMarker,
    event: SpatialEventCollection.Event
  ) {
    sharedAppModel.volumeMarkers.append(marker)
    markerDragID = marker.id
    markerDragStartPosition = marker.position
    markerDragHandStart = inputWorldPosition(from: event)
    sharedAppModel.selectedVolumeMarkerID = marker.id
    sharedAppModel.synchronizeMarkers()
  }

  private func makeMarker(
    at position: SIMD3<Float>,
    directionOrigin: SIMD3<Float>
  ) -> VolumeMarker {
    VolumeMarker(
      id: UUID(),
      name: sharedAppModel.nextVolumeMarkerName(),
      position: position,
      radius: sharedAppModel.defaultVolumeMarkerRadius,
      color: storedAppModel.markerDefaultColorSIMD,
      directionOrigin: directionOrigin
    )
  }

  private func handleMarkerInteraction(
    _ event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    preferExistingMarker: Bool = true
  ) {
    switch event.phase {
      case .active:
        if markerDragID == nil {
          let selectionRay = ray(from: event)

          if preferExistingMarker,
             let ray = selectionRay,
             let existingMarker = markerHit(
            origin: ray.origin,
            direction: ray.direction,
            datasetInfo: datasetInfo
          ) {
            markerDragID = existingMarker.id
            markerDragStartPosition = existingMarker.position
            markerDragHandStart = inputWorldPosition(from: event)
            sharedAppModel.selectedVolumeMarkerID = existingMarker.id
          } else if let spawnPosition = markerSpawnPosition(from: event, datasetInfo: datasetInfo),
                    let directionRay = selectionRay {
            beginMarkerDrag(
              marker: makeMarker(
                at: spawnPosition,
                directionOrigin: markerPosition(
                  fromWorldPosition: directionRay.origin,
                  datasetInfo: datasetInfo
                )
              ),
              event: event
            )
          }
        }

        guard let markerDragID,
              let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerDragID }) else {
          return
        }

        if let handStart = markerDragHandStart,
           let handPosition = inputWorldPosition(from: event) {
          let inverseVolume = markerVolumeMatrix(for: datasetInfo).inverse
          let localDelta = inverseVolume.transformDirection(handPosition - handStart)
          sharedAppModel.volumeMarkers[markerIndex].position = clamp(
            markerDragStartPosition + localDelta,
            BorgVRMarkerFormat.positionRange.lowerBound,
            BorgVRMarkerFormat.positionRange.upperBound
          )
          sharedAppModel.synchronizeMarkers()
        }

      case .ended, .cancelled:
        if markerDragID != nil {
          markerDragID = nil
          markerDragHandStart = nil
          quickMarkerDragActive = false
          sharedAppModel.synchronizeMarkers()
        }
      @unknown default:
        markerDragID = nil
        markerDragHandStart = nil
        quickMarkerDragActive = false
    }
  }

  private func handleMarkerScaling(
    _ events: SpatialEventCollection,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    let activePositions = events.compactMap { event -> SIMD3<Float>? in
      guard case .active = event.phase else {
        return nil
      }
      return inputWorldPosition(from: event)
    }

    if activePositions.count < 2 {
      markerScaleID = nil
      markerScaleStartDistance = 0
      return
    }

    let first = activePositions[0]
    let second = activePositions[1]
    let distance = simd_distance(first, second)
    guard distance > 0.0001 else {
      return
    }

    if markerScaleID == nil {
      let midpoint = (first + second) * 0.5
      let targetMarker = selectedMarker()
        ?? nearestMarker(to: midpoint, datasetInfo: datasetInfo)
      guard let targetMarker else {
        return
      }
      markerScaleID = targetMarker.id
      markerScaleStartDistance = distance
      markerScaleStartRadius = targetMarker.radius
      sharedAppModel.selectedVolumeMarkerID = targetMarker.id
    }

    guard let markerScaleID,
          markerScaleStartDistance > 0.0001,
          let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerScaleID }) else {
      return
    }

    let markerKind = sharedAppModel.volumeMarkers[markerIndex].kind
    let radius = VolumeMarkerRadius.clamp(
      markerScaleStartRadius * distance / markerScaleStartDistance,
      for: markerKind
    )
    sharedAppModel.volumeMarkers[markerIndex].radius = radius
    if markerKind == .sphere {
      sharedAppModel.defaultVolumeMarkerRadius = radius
    } else {
      sharedAppModel.defaultVolumeStrokeRadius = radius
    }
    sharedAppModel.synchronizeMarkers()

    if events.contains(where: { $0.phase == .ended || $0.phase == .cancelled }) {
      self.markerScaleID = nil
      markerScaleStartDistance = 0
    }
  }

  private func selectedMarker() -> VolumeMarker? {
    guard let selectedVolumeMarkerID = sharedAppModel.selectedVolumeMarkerID else {
      return nil
    }
    return sharedAppModel.volumeMarkers.first { $0.id == selectedVolumeMarkerID }
  }

  private func recordQuickMarkerCandidate(
    from event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    guard let handPosition = inputWorldPosition(from: event) else {
      quickMarkerCandidateTime = nil
      quickMarkerCandidatePosition = nil
      return
    }

    quickMarkerCandidateTime = Date()
    quickMarkerCandidatePosition = markerPosition(fromWorldPosition: handPosition, datasetInfo: datasetInfo)
  }

  private func shouldStartQuickMarker(
    at hitPosition: SIMD3<Float>
  ) -> Bool {
    guard let candidateTime = quickMarkerCandidateTime,
          let candidatePosition = quickMarkerCandidatePosition,
          Date().timeIntervalSince(candidateTime) <= storedAppModel.quickMarkerDoublePinchInterval else {
      return false
    }

    return simd_length(hitPosition - candidatePosition) <= quickMarkerMaxDistance
  }

  private func handleQuickMarker(
    _ event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> Bool {
    guard storedAppModel.quickMarker else {
      return false
    }

    if quickMarkerDragActive {
      handleMarkerInteraction(
        event,
        datasetInfo: datasetInfo,
        preferExistingMarker: false
      )
      return true
    }

    switch event.phase {
      case .active:
        guard markerDragID == nil,
              let handPosition = inputWorldPosition(from: event) else {
          return false
        }
        let hitPosition = markerPosition(fromWorldPosition: handPosition, datasetInfo: datasetInfo)
        guard
              shouldStartQuickMarker(at: hitPosition) else {
          return false
        }

        quickMarkerDragActive = true
        quickMarkerCandidateTime = nil
        quickMarkerCandidatePosition = nil
        guard let directionRay = ray(from: event) else { return false }
        beginMarkerDrag(
          marker: makeMarker(
            at: hitPosition,
            directionOrigin: markerPosition(
              fromWorldPosition: directionRay.origin,
              datasetInfo: datasetInfo
            )
          ),
          event: event
        )
        return true

      case .ended, .cancelled:
        recordQuickMarkerCandidate(from: event, datasetInfo: datasetInfo)
        return false

      @unknown default:
        quickMarkerCandidateTime = nil
        quickMarkerCandidatePosition = nil
        return false
    }
  }

  private func resetQuickMarkerState() {
    quickMarkerDragActive = false
    quickMarkerCandidateTime = nil
    quickMarkerCandidatePosition = nil
  }

  private func markerOpacity(forDragDelta delta: SIMD2<Float>) -> Float {
    let dragDistance = simd_length(delta)
    return clamp(1 - max(0, dragDistance - 0.01) * 20)
  }

  private func transferFunctionChannelIndex(for hit: SIMD2<Float>) -> Int? {
    transferFunctionPanelInteractionState.channelIndex(for: hit)
  }

  private func toggleTransferFunctionChannel(
    _ channelIndex: Int,
    currentState: RuntimeAppModel.TransferEditState,
    toggleChannel: @escaping @MainActor (Int) -> Void
  ) {
    var channelMask = currentState.channelMask
    channelMask ^= 1 << UInt32(channelIndex)
    transferFunctionPanelInteractionState.updateChannelMask(channelMask)
    Task { @MainActor in
      toggleChannel(channelIndex)
    }
  }

  private func handleTransferFunctionPanel(
    _ event: SpatialEventCollection.Event,
    _ transferEditState: RuntimeAppModel.TransferEditState,
    toggleChannel: @escaping @MainActor (Int) -> Void
  ) -> Bool {
    let isEditingPanel = transferFunctionPanelDragStart != nil
    let hit: SIMD2<Float>?
    if let ray = ray(from: event) {
      hit = transferFunctionPanelInteractionState.hitTest(
        origin: ray.origin,
        direction: ray.direction
      )
    } else {
      hit = nil
    }

    if isEditingPanel {
      transferFunctionPanelInteractionState.setFocused(true)
      transferFunctionPanelInteractionState.updateHitUV(
        transferFunctionPanelDragStart,
        opacity: transferFunctionPanelMarkerOpacity
      )
    } else {
      if hit == nil {
        transferFunctionPanelMarkerSuppressed = false
      }
      transferFunctionPanelInteractionState.setFocused(hit != nil)
      transferFunctionPanelInteractionState.updateHitUV(
        transferFunctionPanelMarkerSuppressed ? nil : hit
      )
    }

    switch event.phase {
      case .active:
        if transferFunctionPanelDragStart == nil {
          guard let hit else {
            return false
          }
          if let channelIndex = transferFunctionChannelIndex(for: hit) {
            if !transferFunctionPanelChannelToggleActive {
              toggleTransferFunctionChannel(
                channelIndex,
                currentState: transferEditState,
                toggleChannel: toggleChannel
              )
              transferFunctionPanelChannelToggleActive = true
            }
            transferFunctionPanelInteractionState.setFocused(true)
            transferFunctionPanelInteractionState.updateHitUV(nil)
            return true
          }
          guard hit.x >= 0,
                hit.x <= 1,
                hit.y >= 0,
                hit.y <= 1 else {
            return false
          }
          transferFunctionPanelDragStart = hit
          transferFunctionPanelMarkerOpacity = 1
          transferFunctionPanelMarkerSuppressed = false
          if let worldPosition = inputWorldPosition(from: event),
             let localPoint = transferFunctionPanelInteractionState.localPoint(forWorldPosition: worldPosition) {
            transferFunctionPanelHandStart = localPoint.point
          } else {
            transferFunctionPanelHandStart = nil
          }
          transferFunctionPanelInteractionState.setFocused(true)
          transferFunctionPanelInteractionState.updateHitUV(hit, opacity: 1)
        }

        guard let start = transferFunctionPanelDragStart else {
          return true
        }

        let delta: SIMD2<Float>
        if let handStart = transferFunctionPanelHandStart,
           let worldPosition = inputWorldPosition(from: event),
           let localPoint = transferFunctionPanelInteractionState.localPoint(forWorldPosition: worldPosition) {
          delta = SIMD2<Float>(
            (localPoint.point.x - handStart.x) / max(localPoint.size.x, 0.0001),
            (localPoint.point.y - handStart.y) / max(localPoint.size.y, 0.0001)
          )
        } else {
          delta = .zero
        }

        transferFunctionPanelMarkerOpacity = min(
          transferFunctionPanelMarkerOpacity,
          markerOpacity(forDragDelta: delta)
        )
        transferFunctionPanelInteractionState.updateHitUV(
          start,
          opacity: transferFunctionPanelMarkerOpacity
        )

        let center = clamp(start.x + delta.x)
        let signedShift = delta.y < 0
          ? clamp(-0.08 + delta.y * 2, -1, -0.01)
          : clamp(0.08 + delta.y * 2, 0.01, 1)
        let channels = editableChannels(transferEditState)
        let colorChannels = channels.filter { $0 != 3 }
        var operations: [TransferFunction1D.SmoothStepOperation] = []
        if !colorChannels.isEmpty {
          operations.append(.init(
            start: center - signedShift * 0.5,
            shift: signedShift,
            channels: colorChannels
          ))
        }
        if channels.contains(3) {
          let alphaShift = abs(signedShift)
          operations.append(.init(
            start: center - alphaShift * 0.5,
            shift: alphaShift,
            channels: [3]
          ))
        }
        sharedAppModel.transferFunction.scheduleSmoothSteps(operations) {
          self.sharedAppModel.synchronize(kind: .full)
        }
        return true

      case .ended, .cancelled:
        if isEditingPanel {
          sharedAppModel.flushSynchronization()
          transferFunctionPanelDragStart = nil
          transferFunctionPanelHandStart = nil
          transferFunctionPanelMarkerOpacity = 1
          transferFunctionPanelMarkerSuppressed = hit != nil
          transferFunctionPanelChannelToggleActive = false
          transferFunctionPanelInteractionState.setFocused(hit != nil)
          transferFunctionPanelInteractionState.updateHitUV(nil)
          return true
        }
        transferFunctionPanelChannelToggleActive = false
        return hit != nil
      @unknown default:
        transferFunctionPanelDragStart = nil
        transferFunctionPanelHandStart = nil
        transferFunctionPanelMarkerOpacity = 1
        transferFunctionPanelMarkerSuppressed = false
        transferFunctionPanelChannelToggleActive = false
        transferFunctionPanelInteractionState.setFocused(hit != nil)
        transferFunctionPanelInteractionState.updateHitUV(nil)
        return hit != nil
    }
  }


  func handleSpatialEvents(_ events: SpatialEventCollection,
                           _ interactionMode: RuntimeAppModel.InteractionMode,
                           _ transferEditState: RuntimeAppModel.TransferEditState,
                           datasetInfo: RuntimeAppModel.DatasetInfo?,
                           toggleChannel: @escaping @MainActor (Int) -> Void) {
    if events.count == 1,
       let event = events.first,
       handleTransferFunctionPanel(
        event,
        transferEditState,
        toggleChannel: toggleChannel
       ) {
      return
    }

    if interactionMode == .marker {
      resetQuickMarkerState()
    } else {
      sharedAppModel.selectedVolumeMarkerID = nil
    }

    if interactionMode != .marker,
       events.count == 1,
       let event = events.first,
       let datasetInfo,
       handleQuickMarker(event, datasetInfo: datasetInfo) {
      return
    }

    switch interactionMode {
      case .model:
        switch events.count {
        case 1:
          handleTranslationAndRotation(events.first!)
        case 2:
          handleScaling(events)
        default:
          return
        }
      case .clipping:
        switch events.count {
          case 1:
            handleClippingTranslationAndRotation(events.first!)
          case 2:
            return
          default:
            return
        }
      case .marker:
        guard let datasetInfo else {
          return
        }
        switch events.count {
          case 1:
            handleMarkerInteraction(events.first!, datasetInfo: datasetInfo)
          case 2:
            handleMarkerScaling(events, datasetInfo: datasetInfo)
          default:
            return
        }
    }
  }
}

public enum RotationComposeOrder { case pre, post }

public extension Rotation3D {
  /// Returns `self` composed with the rotation contained in `matrix`.
  /// - Parameters:
  ///   - matrix: A 4×4 transform; only its rotational component is used.
  ///   - order: `.pre` means `matrix` is applied before `self` (M ∘ R). `.post` applies after (R ∘ M).
  ///   - orthonormalize: If true, removes any scale/shear before extracting rotation.
  func transformed(
    by matrix: simd_float4x4,
    order: RotationComposeOrder = .pre,
    orthonormalize: Bool = true
  ) -> Rotation3D {
    let qM = matrix.rotationQuaternion(orthonormalize: orthonormalize)
    let qSelfF = simd_quatf(self)
    let qOut: simd_quatf = (order == .pre) ? (qM * qSelfF) : (qSelfF * qM)
    return Rotation3D.init(qOut)
  }
}

private extension simd_float4x4 {
  /// Extracts a unit-rotation quaternion from the matrix.
  func rotationQuaternion(orthonormalize: Bool) -> simd_quatf {
    if !orthonormalize {
      return simd_quatf(self)           // assumes no shear / uniform scale
    }

    var c0 = simd_float3(columns.0.x,columns.0.y,columns.0.z)
    var c1 = simd_float3(columns.1.x,columns.1.y,columns.1.z)
    c0 = simd_normalize(c0)
    c1 = simd_normalize(c1 - simd_dot(c1, c0) * c0)
    let c2 = simd_cross(c0, c1)
    return simd_quatf(simd_float3x3(c0, c1, c2))
  }

  func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
    let v = self * SIMD4<Float>(d, 0)
    return SIMD3<Float>(v.x, v.y, v.z)
  }
}
