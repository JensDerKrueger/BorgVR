import CompositorServices
import Spatial
import SwiftUI

enum SpatialSceneObjectPreview {
  case sphere(VolumeMarkerPoint)
  case mesh(SceneMeshInstance)
}

class ImmersiveInteraction {
  private let volumeSnapMaximumDepthDifferenceMeters: Float = 0.05
  private let volumeSnapDepthSmoothingNewSampleWeight: Float = 0.15
  var sharedAppModel: SharedAppModel
  var storedAppModel: StoredAppModel
  var transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState
  private let toggleTransferFunctionChannelFromAccessory: @MainActor (Int) -> Void
  private let performControllerFaceButtonFromAccessory: @MainActor (
    SpatialControllerFaceButton,
    BorgSpatialInputChirality
  ) -> Void
  private let volumeInteractionDepthLock = NSLock()
  private var volumeInteractionDepthSnapshot: VolumeInteractionDepthSnapshot?
  private var frozenStrokeInteractionDepthSnapshot: VolumeInteractionDepthSnapshot?
  private var pendingStrokeProjectionFreezeTokens: Set<UUID> = []
  private var activeStrokeProjectionFreezeTokens: Set<UUID> = []

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
  private var markerDragStartPositions: [UUID: SIMD3<Float>] = [:]
  private var markerDragHandStart: SIMD3<Float>?
  private var markerScaleID: UUID?
  private var markerScaleStartDistance: Float = 0
  private var markerScaleStartRadii: [UUID: Float] = [:]
  private var handStrokeID: UUID?
  private var quickMarkerDragActive = false
  private var quickMarkerCandidateTime: Date?
  private var quickMarkerCandidatePosition: SIMD3<Float>?
  private let quickMarkerMaxDistance: Float = 0.15
  private var measurementDragMeasurementID: UUID?
  private var measurementDragPointID: UUID?
  private var measurementDragHandStart: SIMD3<Float>?
  private var measurementDragPointStart: SIMD3<Float>?
  private var lastMeasurementTap: (pointID: UUID, time: Date)?
  private let measurementDoubleClickInterval: TimeInterval = 0.35
  private struct SpatialAccessoryAction {
    enum Kind {
      case model
      case clipping
      case markerSphere
      case markerStroke
      case sceneMesh
      case measurementPoint
      case screenView
      case transferFunction
    }

    let sourceID: UUID
    let kind: Kind
    let startTransform: simd_float4x4
    let startModelTranslation: SIMD3<Float>
    let startModelRotation: simd_quatf
    let startClippingTranslation: SIMD3<Float>
    let markerID: UUID?
    let markerStartPositions: [UUID: SIMD3<Float>]
    let measurementID: UUID?
    let measurementPointID: UUID?
    let transferFunctionStart: SIMD2<Float>?
    let markerStrokeUsesModifierButton: Bool
  }
  private var spatialAccessoryActions: [UUID: SpatialAccessoryAction] = [:]
  private var activeSpatialStylusID: UUID?
  private var activeSpatialStylusMeasurementID: UUID?
  private var activeSpatialStylusMeasurementPointID: UUID?
  private var spatialStylusStartsNewMeasurement = false
  private var spatialStylusModifierStates: [UUID: Bool] = [:]
  private var lastSpatialStylusModifierPressTimes: [UUID: TimeInterval] = [:]
  private var suppressedSpatialStylusModifierIDs: Set<UUID> = []
  private var spatialStylusToolToggleStates: [UUID: Bool] = [:]
  private var suppressedSpatialStylusToolToggleIDs: Set<UUID> = []
  private var pendingSpatialStylusMeasurementStarts: [UUID: TimeInterval] = [:]
  private let spatialStylusDoubleClickInterval: TimeInterval = 0.35
  private var spatialAccessoryPrimaryStates: [UUID: Bool] = [:]
  private var spatialAccessoryModifierStates: [UUID: Bool] = [:]
  private var spatialAccessoryFaceButtonStates: [UUID: Set<SpatialControllerFaceButton>] = [:]
  private var spatialAccessoryMeasurementIDs: [UUID: UUID] = [:]
  private var lastSpatialAccessoryAdjustmentTime: TimeInterval?
  private enum ActiveSceneObjectPlacement {
    case sphere(UUID)
    case mesh(UUID)
  }
  private struct SceneMeshDragState {
    let instanceID: UUID
    let inputStartPositionMeters: SIMD3<Float>
    let inputStartRotation: simd_quatf
    let instanceStartTranslationMeters: SIMD3<Float>
    let instanceStartRotation: simd_quatf
  }
  private var activeSceneObjectPlacement: ActiveSceneObjectPlacement?
  private var activeSceneObjectPlacementSourceID: UUID?
  private var activeSceneObjectPlacementUsesHand = false

  func updateVolumeInteractionDepthSnapshot(
    _ snapshot: VolumeInteractionDepthSnapshot?
  ) {
    volumeInteractionDepthLock.lock()
    volumeInteractionDepthSnapshot = snapshot
    if snapshot == nil {
      frozenStrokeInteractionDepthSnapshot = nil
      pendingStrokeProjectionFreezeTokens.removeAll()
      activeStrokeProjectionFreezeTokens.removeAll()
    } else if !pendingStrokeProjectionFreezeTokens.isEmpty {
      frozenStrokeInteractionDepthSnapshot = snapshot?.frozenCopy()
      activeStrokeProjectionFreezeTokens.formUnion(pendingStrokeProjectionFreezeTokens)
      pendingStrokeProjectionFreezeTokens.removeAll()
    }
    volumeInteractionDepthLock.unlock()
  }

  func beginStrokeProjectionFreeze(token: UUID) {
    volumeInteractionDepthLock.lock()
    if activeStrokeProjectionFreezeTokens.isEmpty &&
       pendingStrokeProjectionFreezeTokens.isEmpty {
      pendingStrokeProjectionFreezeTokens.insert(token)
    } else if pendingStrokeProjectionFreezeTokens.isEmpty {
      activeStrokeProjectionFreezeTokens.insert(token)
    } else {
      pendingStrokeProjectionFreezeTokens.insert(token)
    }
    volumeInteractionDepthLock.unlock()
  }

  func endStrokeProjectionFreeze(token: UUID) {
    volumeInteractionDepthLock.lock()
    pendingStrokeProjectionFreezeTokens.remove(token)
    activeStrokeProjectionFreezeTokens.remove(token)
    if pendingStrokeProjectionFreezeTokens.isEmpty &&
       activeStrokeProjectionFreezeTokens.isEmpty {
      frozenStrokeInteractionDepthSnapshot = nil
    }
    volumeInteractionDepthLock.unlock()
  }

  func pendingStrokeProjectionCaptureMarkerIDs() -> Set<UUID> {
    volumeInteractionDepthLock.lock()
    let markerIDs = pendingStrokeProjectionFreezeTokens
    volumeInteractionDepthLock.unlock()
    return markerIDs
  }

  func projectedVolumePosition(
    toward worldPosition: SIMD3<Float>,
    smoothingDepthFrom previousPosition: SIMD3<Float>? = nil
  ) -> SIMD3<Float>? {
    volumeInteractionDepthLock.lock()
    let snapshot = frozenStrokeInteractionDepthSnapshot ?? volumeInteractionDepthSnapshot
    volumeInteractionDepthLock.unlock()
    return snapshot?.normalizedVolumePosition(
      projectingToward: worldPosition,
      smoothingDepthFrom: previousPosition,
      maximumWorldDepthDifference: volumeSnapMaximumDepthDifferenceMeters,
      depthSmoothingNewSampleWeight: volumeSnapDepthSmoothingNewSampleWeight
    )
  }

  private func interactionPosition(
    fromWorldPosition worldPosition: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    projectsOntoVolume: Bool,
    smoothingDepthFrom previousPosition: SIMD3<Float>? = nil
  ) -> SIMD3<Float> {
    if projectsOntoVolume,
       let position = projectedVolumePosition(
         toward: worldPosition,
         smoothingDepthFrom: previousPosition
       ) {
      return position
    }
    return markerPosition(fromWorldPosition: worldPosition, datasetInfo: datasetInfo)
  }

  private func interactionTransform(
    _ transform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    projectsOntoVolume: Bool
  ) -> simd_float4x4 {
    guard projectsOntoVolume else { return transform }
    let worldPosition = SIMD3<Float>(
      transform.columns.3.x,
      transform.columns.3.y,
      transform.columns.3.z
    )
    guard let normalizedPosition = projectedVolumePosition(toward: worldPosition) else {
      return transform
    }
    let projectedWorldPosition = transformPoint(
      markerVolumeMatrix(for: datasetInfo),
      normalizedPosition - SIMD3<Float>(repeating: 0.5)
    )
    var result = transform
    result.columns.3 = SIMD4<Float>(projectedWorldPosition, 1)
    return result
  }
  private var sceneMeshDragState: SceneMeshDragState?

  init(sharedAppModel: SharedAppModel,
       storedAppModel: StoredAppModel,
       transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState,
       toggleTransferFunctionChannel: @escaping @MainActor (Int) -> Void,
       performControllerFaceButton: @escaping @MainActor (
         SpatialControllerFaceButton,
         BorgSpatialInputChirality
       ) -> Void) {
    self.sharedAppModel = sharedAppModel
    self.storedAppModel = storedAppModel
    self.transferFunctionPanelInteractionState = transferFunctionPanelInteractionState
    self.toggleTransferFunctionChannelFromAccessory = toggleTransferFunctionChannel
    self.performControllerFaceButtonFromAccessory = performControllerFaceButton
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

  private func poseMatrix(_ event: SpatialEventCollection.Event) -> simd_float4x4? {
    guard let pose = event.inputDevicePose else { return nil }
    var matrix = simd_float4x4(simd_quatf(pose.pose3D.rotation))
    let position = SIMD3<Float>(pose.pose3D.position.vector)
    matrix.columns.3 = SIMD4<Float>(position, 1)
    return matrix
  }

  private func handleScreenViewInteraction(_ event: SpatialEventCollection.Event) {
    guard let hand = poseMatrix(event),
          var state = sharedAppModel.screenSharePlayViewState else {
      sharedAppModel.screenViewInteractionActive = false
      return
    }

    switch event.phase {
      case .active:
        sharedAppModel.screenViewInteractionActive = true
        let worldFromDataset = sharedAppModel.originFromWorldAnchorMatrix *
          sharedAppModel.modelTransform.matrix
        let handFromCamera = simd_float4x4(
          simd_quatf(
            angle: -.pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
          ) *
          simd_quatf(
            angle: -.pi / 6,
            axis: SIMD3<Float>(0, 1, 0)
          ) *
          simd_quatf(
            angle: .pi / 6,
            axis: SIMD3<Float>(1, 0, 0)
          )
        )
        let datasetFromCamera = simd_inverse(worldFromDataset) * hand * handFromCamera
        let cameraPosition = SIMD3<Float>(
          datasetFromCamera.columns.3.x,
          datasetFromCamera.columns.3.y,
          datasetFromCamera.columns.3.z
        )
        let cameraOrientation = datasetFromCamera.rotationQuaternion(orthonormalize: true)
        let orientation = cameraOrientation.inverse
        let rotatedCameraPosition = orientation.act(cameraPosition)
        guard rotatedCameraPosition.z > 0.001 else { return }

        let scale = BorgVRScreenViewState.cameraDistance / rotatedCameraPosition.z
        guard scale.isFinite else { return }
        state.orientation = orientation
        state.scale = min(max(scale, 0.05), 40)
        state.pan = SIMD2<Float>(
          -state.scale * rotatedCameraPosition.x,
          -state.scale * rotatedCameraPosition.y
        )
        sharedAppModel.screenSharePlayViewState = state
        sharedAppModel.synchronizeScreenView()

      case .ended, .cancelled:
        sharedAppModel.screenViewInteractionActive = false
        sharedAppModel.synchronizeScreenView()
        sharedAppModel.flushSynchronization()

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

  private func datasetPoseMeters(
    fromWorldTransform worldTransform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> (position: SIMD3<Float>, rotation: simd_quatf) {
    let worldFromDataset = sharedAppModel.originFromWorldAnchorMatrix *
      sharedAppModel.modelTransform.matrix
    let datasetFromWorld = worldFromDataset.inverse
    let datasetTransform = datasetFromWorld * worldTransform
    let normalizedPosition = SIMD3<Float>(
      datasetTransform.columns.3.x,
      datasetTransform.columns.3.y,
      datasetTransform.columns.3.z
    )
    let maximumExtent = max(
      datasetInfo.physicalExtentMeters.x,
      max(datasetInfo.physicalExtentMeters.y, datasetInfo.physicalExtentMeters.z)
    )
    return (
      normalizedPosition * maximumExtent,
      datasetTransform.rotationQuaternion(orthonormalize: true)
    )
  }

  private func beginSceneObjectPlacement(
    prototype: SceneObjectPrototype,
    worldTransform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    directionOrigin: SIMD3<Float>?
  ) -> Bool {
    let effectiveTransform = interactionTransform(
      worldTransform,
      datasetInfo: datasetInfo,
      projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
    )
    let pose = datasetPoseMeters(
      fromWorldTransform: effectiveTransform,
      datasetInfo: datasetInfo
    )
    switch prototype {
      case .sphere:
        let worldPosition = SIMD3<Float>(
          effectiveTransform.columns.3.x,
          effectiveTransform.columns.3.y,
          effectiveTransform.columns.3.z
        )
        let position = markerPosition(
          fromWorldPosition: worldPosition,
          datasetInfo: datasetInfo
        )
        let marker = makeMarker(
          at: position,
          directionOrigin: directionOrigin.map {
            markerPosition(fromWorldPosition: $0, datasetInfo: datasetInfo)
          } ?? position
        )
        sharedAppModel.volumeMarkers.append(marker)
        sharedAppModel.selectedVolumeMarkerID = marker.id
        sharedAppModel.selectedSceneMeshInstanceID = nil
        activeSceneObjectPlacement = .sphere(marker.id)

      case .mesh(let assetID):
        guard let asset = sharedAppModel.sceneMeshAssets[assetID] else { return false }
        let instance = SceneMeshInstance(
          name: sharedAppModel.nextSceneMeshInstanceName(assetName: asset.name),
          asset: asset.reference,
          translationMeters: pose.position,
          rotation: pose.rotation
        )
        sharedAppModel.sceneMeshInstances.append(instance)
        sharedAppModel.selectedSceneMeshInstanceID = instance.id
        sharedAppModel.clearVolumeMarkerSelection()
        activeSceneObjectPlacement = .mesh(instance.id)
    }
    return true
  }

  func sceneObjectPreview(
    prototype: SceneObjectPrototype,
    worldTransform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    id: UUID
  ) -> SpatialSceneObjectPreview? {
    let effectiveTransform = interactionTransform(
      worldTransform,
      datasetInfo: datasetInfo,
      projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
    )
    switch prototype {
      case .sphere:
        let worldPosition = SIMD3<Float>(
          effectiveTransform.columns.3.x,
          effectiveTransform.columns.3.y,
          effectiveTransform.columns.3.z
        )
        return .sphere(VolumeMarkerPoint(
          position: markerPosition(
            fromWorldPosition: worldPosition,
            datasetInfo: datasetInfo
          ),
          radius: sharedAppModel.defaultVolumeMarkerRadius
        ))

      case .mesh(let assetID):
        guard let asset = sharedAppModel.sceneMeshAssets[assetID] else { return nil }
        let pose = datasetPoseMeters(
          fromWorldTransform: effectiveTransform,
          datasetInfo: datasetInfo
        )
        return .mesh(SceneMeshInstance(
          id: id,
          name: asset.name,
          asset: asset.reference,
          translationMeters: pose.position,
          rotation: pose.rotation
        ))
    }
  }

  private func updateActiveSceneObjectPlacement(
    worldTransform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    let effectiveTransform = interactionTransform(
      worldTransform,
      datasetInfo: datasetInfo,
      projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
    )
    let pose = datasetPoseMeters(
      fromWorldTransform: effectiveTransform,
      datasetInfo: datasetInfo
    )
    switch activeSceneObjectPlacement {
      case .sphere(let markerID):
        let worldPosition = SIMD3<Float>(
          effectiveTransform.columns.3.x,
          effectiveTransform.columns.3.y,
          effectiveTransform.columns.3.z
        )
        guard let index = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerID }) else {
          activeSceneObjectPlacement = nil
          return
        }
        sharedAppModel.volumeMarkers[index].position = markerPosition(
          fromWorldPosition: worldPosition,
          datasetInfo: datasetInfo
        )

      case .mesh(let instanceID):
        guard let index = sharedAppModel.sceneMeshInstances.firstIndex(where: {
          $0.id == instanceID
        }) else {
          activeSceneObjectPlacement = nil
          return
        }
        sharedAppModel.sceneMeshInstances[index].translationMeters = pose.position
        sharedAppModel.sceneMeshInstances[index].rotation = pose.rotation

      case nil:
        break
    }
  }

  private func finishSceneObjectPlacement(cancelled: Bool) {
    if cancelled {
      switch activeSceneObjectPlacement {
        case .sphere(let markerID):
          sharedAppModel.volumeMarkers.removeAll { $0.id == markerID }
          sharedAppModel.clearVolumeMarkerSelection()
        case .mesh(let instanceID):
          sharedAppModel.sceneMeshInstances.removeAll { $0.id == instanceID }
          if sharedAppModel.selectedSceneMeshInstanceID == instanceID {
            sharedAppModel.selectedSceneMeshInstanceID = nil
          }
        case nil:
          break
      }
    } else if activeSceneObjectPlacement != nil {
      sharedAppModel.synchronizeMarkers()
    }
    activeSceneObjectPlacement = nil
    activeSceneObjectPlacementSourceID = nil
    activeSceneObjectPlacementUsesHand = false
  }

  private func handleSceneObjectPlacement(
    _ event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    prototype: SceneObjectPrototype
  ) -> Bool {
    if sceneMeshDragState != nil || (
      activeSceneObjectPlacement == nil &&
      event.phase == .active &&
      selectedSceneMesh(from: event, datasetInfo: datasetInfo) != nil
    ) {
      _ = handleSceneMeshInteraction(event, datasetInfo: datasetInfo)
      return true
    }
    if markerDragID != nil || (
      activeSceneObjectPlacement == nil &&
      event.phase == .active &&
      selectedMarker(from: event, datasetInfo: datasetInfo) != nil
    ) {
      handleMarkerInteraction(event, datasetInfo: datasetInfo)
      return true
    }
    if prototype == .sphere, activeSceneObjectPlacement == nil {
      handleMarkerInteraction(
        event,
        datasetInfo: datasetInfo,
        preferExistingMarker: false
      )
      return true
    }
    switch event.phase {
      case .active:
        guard activeSceneObjectPlacementSourceID == nil else { return true }
        guard let transform = sceneObjectTransform(from: event, datasetInfo: datasetInfo) else {
          return true
        }
        if activeSceneObjectPlacement == nil {
          guard beginSceneObjectPlacement(
            prototype: prototype,
            worldTransform: transform,
            datasetInfo: datasetInfo,
            directionOrigin: ray(from: event)?.origin
          ) else { return true }
          activeSceneObjectPlacementUsesHand = true
        }
        updateActiveSceneObjectPlacement(
          worldTransform: transform,
          datasetInfo: datasetInfo
        )
        sharedAppModel.synchronizeMarkers()
      case .ended:
        if let transform = sceneObjectTransform(from: event, datasetInfo: datasetInfo) {
          updateActiveSceneObjectPlacement(
            worldTransform: transform,
            datasetInfo: datasetInfo
          )
        }
        finishSceneObjectPlacement(cancelled: false)
      case .cancelled:
        finishSceneObjectPlacement(cancelled: true)
      @unknown default:
        break
    }
    return true
  }

  func handleArmedSceneObjectPlacement(
    samples: [BorgSpatialInputSample],
    datasetInfo: RuntimeAppModel.DatasetInfo?
  ) -> Bool {
    let explicitlyArmedPrototype = sharedAppModel.armedSceneObjectPrototype
    let candidates = samples.filter { sample in
      guard sample.source == .stylus || sample.source == .controller else { return false }
      guard !sample.toolTogglePressed else { return false }
      if explicitlyArmedPrototype != nil { return true }
      switch sample.source {
        case .stylus:
          return storedAppModel.stylusTool == .objectPlacement
        case .controller:
          return storedAppModel.controllerTool(for: sample.chirality) == .objectPlacement

      }
    }
    guard !candidates.isEmpty || activeSceneObjectPlacementSourceID != nil else {
      if activeSceneObjectPlacement != nil || activeSceneObjectPlacementSourceID != nil {
        if sceneMeshDragState != nil {
          finishSceneMeshDrag(cancelled: true)
          activeSceneObjectPlacementSourceID = nil
        } else {
          finishSceneObjectPlacement(cancelled: true)
        }
      }
      return false
    }
    let prototype = explicitlyArmedPrototype
      ?? sharedAppModel.validateSelectedSceneObjectPrototype()
    guard let datasetInfo else { return false }
    if activeSceneObjectPlacementUsesHand { return true }
    if let sourceID = activeSceneObjectPlacementSourceID {
      guard let sample = candidates.first(where: { $0.id == sourceID }) else {
        if sceneMeshDragState != nil {
          finishSceneMeshDrag(cancelled: true)
          activeSceneObjectPlacementSourceID = nil
        } else {
          finishSceneObjectPlacement(cancelled: true)
        }
        return true
      }
      if sample.primaryPressed, sceneMeshDragState != nil {
        updateSceneMeshDrag(
          worldTransform: sample.aimTransform,
          datasetInfo: datasetInfo
        )
      } else if sample.primaryPressed {
        updateActiveSceneObjectPlacement(
          worldTransform: sample.aimTransform,
          datasetInfo: datasetInfo
        )
      } else {
        if sceneMeshDragState != nil {
          finishSceneMeshDrag(cancelled: false)
          activeSceneObjectPlacementSourceID = nil
        } else {
          finishSceneObjectPlacement(cancelled: false)
        }
      }
      return true
    }

    guard let sample = candidates.first(where: \.primaryPressed) else { return false }
    activeSceneObjectPlacementSourceID = sample.id
    activeSceneObjectPlacementUsesHand = false
    if let instance = sceneMeshHit(
      origin: sample.aimOrigin,
      direction: sample.aimDirection,
      datasetInfo: datasetInfo
    ) {
      beginSceneMeshDrag(
        instance: instance,
        worldTransform: sample.aimTransform,
        datasetInfo: datasetInfo
      )
      return true
    }
    if beginSceneObjectPlacement(
      prototype: prototype,
      worldTransform: sample.aimTransform,
      datasetInfo: datasetInfo,
      directionOrigin: sample.aimOrigin
    ) {
      updateActiveSceneObjectPlacement(
        worldTransform: sample.aimTransform,
        datasetInfo: datasetInfo
      )
    } else {
      finishSceneObjectPlacement(cancelled: true)
    }
    return true
  }

  private func sceneMeshHit(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> SceneMeshInstance? {
    let maximumExtent = max(
      datasetInfo.physicalExtentMeters.x,
      max(datasetInfo.physicalExtentMeters.y, datasetInfo.physicalExtentMeters.z)
    )
    guard maximumExtent.isFinite, maximumExtent > 0 else { return nil }
    let worldFromDataset = sharedAppModel.originFromWorldAnchorMatrix *
      sharedAppModel.modelTransform.matrix
    var nearest: (instance: SceneMeshInstance, distance: Float)?
    for instance in sharedAppModel.sceneMeshInstances where instance.isVisible {
      let worldFromMesh = worldFromDataset *
        scaleMatrix(SIMD3<Float>(repeating: 1 / maximumExtent)) *
        instance.transformMeters
      let meshFromWorld = worldFromMesh.inverse
      let localOrigin = transformPoint(meshFromWorld, origin)
      let localDirection = meshFromWorld.transformDirection(direction)
      guard let distance = rayBoxDistance(
        origin: localOrigin,
        direction: localDirection,
        minimum: instance.asset.boundsMinimum,
        maximum: instance.asset.boundsMaximum
      ), distance >= 0 else { continue }
      if nearest == nil || distance < nearest!.distance {
        nearest = (instance, distance)
      }
    }
    return nearest?.instance
  }

  private func nearestSceneMesh(
    to worldPosition: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> SceneMeshInstance? {
    let maximumExtent = max(
      datasetInfo.physicalExtentMeters.x,
      max(datasetInfo.physicalExtentMeters.y, datasetInfo.physicalExtentMeters.z)
    )
    guard maximumExtent.isFinite, maximumExtent > 0 else { return nil }
    let worldFromDataset = sharedAppModel.originFromWorldAnchorMatrix *
      sharedAppModel.modelTransform.matrix
    var nearest: (instance: SceneMeshInstance, distance: Float)?
    for instance in sharedAppModel.sceneMeshInstances where instance.isVisible {
      let worldFromMesh = worldFromDataset *
        scaleMatrix(SIMD3<Float>(repeating: 1 / maximumExtent)) *
        instance.transformMeters
      let localPosition = transformPoint(worldFromMesh.inverse, worldPosition)
      let closestLocalPosition = simd_clamp(
        localPosition,
        instance.asset.boundsMinimum,
        instance.asset.boundsMaximum
      )
      let closestWorldPosition = transformPoint(worldFromMesh, closestLocalPosition)
      let distance = simd_distance(worldPosition, closestWorldPosition)
      guard distance <= 0.08 else { continue }
      if nearest == nil || distance < nearest!.distance {
        nearest = (instance, distance)
      }
    }
    return nearest?.instance
  }

  private func selectedSceneMesh(
    from event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> SceneMeshInstance? {
    if storedAppModel.markerSpawnAtGaze {
      guard let selectionRay = ray(from: event) else { return nil }
      return sceneMeshHit(
        origin: selectionRay.origin,
        direction: selectionRay.direction,
        datasetInfo: datasetInfo
      )
    }
    guard let handPosition = inputWorldPosition(from: event) else { return nil }
    return nearestSceneMesh(to: handPosition, datasetInfo: datasetInfo)
  }

  private func sceneObjectTransform(
    from event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> simd_float4x4? {
    guard var transform = poseMatrix(event) else { return nil }
    if storedAppModel.projectObjectsOntoVolume {
      return transform
    }
    guard storedAppModel.markerSpawnAtGaze else { return transform }
    guard let selectionRay = ray(from: event),
          let position = rayVolumeHit(
            origin: selectionRay.origin,
            direction: selectionRay.direction,
            datasetInfo: datasetInfo
          ) else {
      return nil
    }
    let worldPosition = transformPoint(
      markerVolumeMatrix(for: datasetInfo),
      position - SIMD3<Float>(repeating: 0.5)
    )
    transform.columns.3 = SIMD4<Float>(worldPosition, 1)
    return transform
  }

  private func rayBoxDistance(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    minimum: SIMD3<Float>,
    maximum: SIMD3<Float>
  ) -> Float? {
    var nearDistance: Float = -.greatestFiniteMagnitude
    var farDistance: Float = .greatestFiniteMagnitude
    for axis in 0..<3 {
      let component = direction[axis]
      if abs(component) < 0.000_001 {
        guard origin[axis] >= minimum[axis], origin[axis] <= maximum[axis] else {
          return nil
        }
        continue
      }
      let first = (minimum[axis] - origin[axis]) / component
      let second = (maximum[axis] - origin[axis]) / component
      nearDistance = max(nearDistance, min(first, second))
      farDistance = min(farDistance, max(first, second))
      if nearDistance > farDistance { return nil }
    }
    return farDistance >= 0 ? max(0, nearDistance) : nil
  }

  private func beginSceneMeshDrag(
    instance: SceneMeshInstance,
    worldTransform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    let effectiveTransform = interactionTransform(
      worldTransform,
      datasetInfo: datasetInfo,
      projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
    )
    let pose = datasetPoseMeters(
      fromWorldTransform: effectiveTransform,
      datasetInfo: datasetInfo
    )
    sceneMeshDragState = SceneMeshDragState(
      instanceID: instance.id,
      inputStartPositionMeters: pose.position,
      inputStartRotation: pose.rotation,
      instanceStartTranslationMeters: instance.translationMeters,
      instanceStartRotation: instance.rotation
    )
    sharedAppModel.selectedSceneMeshInstanceID = instance.id
    sharedAppModel.clearVolumeMarkerSelection()
  }

  private func updateSceneMeshDrag(
    worldTransform: simd_float4x4,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    guard let drag = sceneMeshDragState,
          let index = sharedAppModel.sceneMeshInstances.firstIndex(where: {
            $0.id == drag.instanceID
          }) else {
      sceneMeshDragState = nil
      return
    }
    let effectiveTransform = interactionTransform(
      worldTransform,
      datasetInfo: datasetInfo,
      projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
    )
    let pose = datasetPoseMeters(
      fromWorldTransform: effectiveTransform,
      datasetInfo: datasetInfo
    )
    sharedAppModel.sceneMeshInstances[index].translationMeters =
      drag.instanceStartTranslationMeters + pose.position - drag.inputStartPositionMeters
    sharedAppModel.sceneMeshInstances[index].rotation =
      pose.rotation * drag.inputStartRotation.inverse * drag.instanceStartRotation
  }

  private func finishSceneMeshDrag(cancelled: Bool) {
    guard let drag = sceneMeshDragState else { return }
    if cancelled,
       let index = sharedAppModel.sceneMeshInstances.firstIndex(where: {
         $0.id == drag.instanceID
       }) {
      sharedAppModel.sceneMeshInstances[index].translationMeters =
        drag.instanceStartTranslationMeters
      sharedAppModel.sceneMeshInstances[index].rotation = drag.instanceStartRotation
    } else if !cancelled {
      sharedAppModel.synchronizeMarkers()
    }
    sceneMeshDragState = nil
  }

  private func handleSceneMeshInteraction(
    _ event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> Bool {
    switch event.phase {
      case .active:
        guard let transform = sceneObjectTransform(from: event, datasetInfo: datasetInfo) else {
          return sceneMeshDragState != nil
        }
        if sceneMeshDragState == nil,
           let instance = selectedSceneMesh(from: event, datasetInfo: datasetInfo) {
          beginSceneMeshDrag(
            instance: instance,
            worldTransform: transform,
            datasetInfo: datasetInfo
          )
        }
        guard sceneMeshDragState != nil else { return false }
        updateSceneMeshDrag(worldTransform: transform, datasetInfo: datasetInfo)
        return true

      case .ended:
        guard sceneMeshDragState != nil else { return false }
        if let transform = sceneObjectTransform(from: event, datasetInfo: datasetInfo) {
          updateSceneMeshDrag(worldTransform: transform, datasetInfo: datasetInfo)
        }
        finishSceneMeshDrag(cancelled: false)
        return true

      case .cancelled:
        guard sceneMeshDragState != nil else { return false }
        finishSceneMeshDrag(cancelled: true)
        return true

      @unknown default:
        sceneMeshDragState = nil
        return false
    }
  }

  private func markerSpawnPosition(
    from event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> SIMD3<Float>? {
    if storedAppModel.projectObjectsOntoVolume,
       let handPosition = inputWorldPosition(from: event),
       let position = projectedVolumePosition(toward: handPosition) {
      return position
    }
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

  private func selectedMarker(
    from event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> VolumeMarker? {
    if storedAppModel.markerSpawnAtGaze {
      guard let selectionRay = ray(from: event) else { return nil }
      return markerHit(
        origin: selectionRay.origin,
        direction: selectionRay.direction,
        datasetInfo: datasetInfo
      )
    }
    guard let handPosition = inputWorldPosition(from: event) else { return nil }
    return nearestMarker(to: handPosition, datasetInfo: datasetInfo)
  }

  private func beginMarkerDrag(
    marker: VolumeMarker,
    event: SpatialEventCollection.Event
  ) {
    sharedAppModel.volumeMarkers.append(marker)
    markerDragID = marker.id
    markerDragHandStart = inputWorldPosition(from: event)
    sharedAppModel.selectedVolumeMarkerID = marker.id
    sharedAppModel.selectedSceneMeshInstanceID = nil
    captureMarkerDragStartPositions()
    sharedAppModel.synchronizeMarkers()
  }

  private func makeMarker(
    at position: SIMD3<Float>,
    directionOrigin: SIMD3<Float>,
    color: SIMD4<Float>? = nil
  ) -> VolumeMarker {
    VolumeMarker(
      id: UUID(),
      name: sharedAppModel.nextVolumeMarkerName(),
      position: position,
      radius: sharedAppModel.defaultVolumeMarkerRadius,
      color: color ?? storedAppModel.markerDefaultColorSIMD,
      directionOrigin: directionOrigin,
      showsDirection: sharedAppModel.defaultVolumeMarkerShowsDirection
    )
  }

  private func handleMarkerInteraction(
    _ event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    preferExistingMarker: Bool = true,
    drawsStroke: Bool = false
  ) {
    switch event.phase {
      case .active:
        if markerDragID == nil && handStrokeID == nil {
          let selectionRay = ray(from: event)

          if preferExistingMarker,
             let existingMarker = selectedMarker(from: event, datasetInfo: datasetInfo) {
            markerDragID = existingMarker.id
            markerDragHandStart = inputWorldPosition(from: event)
            sharedAppModel.selectedVolumeMarkerID = existingMarker.id
            sharedAppModel.selectedSceneMeshInstanceID = nil
            captureMarkerDragStartPositions()
          } else if drawsStroke,
                    let handPosition = inputWorldPosition(from: event) {
            let point = VolumeMarkerPoint(
              position: interactionPosition(
                fromWorldPosition: handPosition,
                datasetInfo: datasetInfo,
                projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
              ),
              radius: sharedAppModel.defaultVolumeStrokeRadius
            )
            let marker = VolumeMarker.stroke(
              name: sharedAppModel.nextVolumeMarkerName(for: .stroke),
              firstPoint: point,
              color: storedAppModel.markerDefaultColorSIMD
            )
            if storedAppModel.projectObjectsOntoVolume {
              beginStrokeProjectionFreeze(token: marker.id)
            }
            sharedAppModel.volumeMarkers.append(marker)
            sharedAppModel.selectedVolumeMarkerID = marker.id
            sharedAppModel.selectedSceneMeshInstanceID = nil
            handStrokeID = marker.id
            sharedAppModel.synchronizeMarkers()
          } else if let spawnPosition = markerSpawnPosition(
            from: event,
            datasetInfo: datasetInfo
          ) {
            let directionOrigin = selectionRay.map {
              markerPosition(
                fromWorldPosition: $0.origin,
                datasetInfo: datasetInfo
              )
            } ?? spawnPosition
            beginMarkerDrag(
              marker: makeMarker(
                at: spawnPosition,
                directionOrigin: directionOrigin
              ),
              event: event
            )
          }
        }

        if let handStrokeID,
           let handPosition = inputWorldPosition(from: event),
           let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: {
             $0.id == handStrokeID
           }) {
          let previousPosition = sharedAppModel.volumeMarkers[markerIndex].points.last?.position
          let point = VolumeMarkerPoint(
            position: interactionPosition(
              fromWorldPosition: handPosition,
              datasetInfo: datasetInfo,
              projectsOntoVolume: storedAppModel.projectObjectsOntoVolume,
              smoothingDepthFrom: previousPosition
            ),
            radius: sharedAppModel.defaultVolumeStrokeRadius
          )
          let coordinateScale = simd_abs(sharedAppModel.modelTransform.scale) *
            datasetInfo.volumeScale
          if sharedAppModel.volumeMarkers[markerIndex].appendStrokePoint(
            point,
            coordinateScale: coordinateScale
          ) {
            sharedAppModel.synchronizeMarkers()
          }
          return
        }

        guard markerDragID != nil else {
          return
        }

        if let handStart = markerDragHandStart,
           let handPosition = inputWorldPosition(from: event) {
          if storedAppModel.projectObjectsOntoVolume,
             let markerDragID,
             let primaryIndex = sharedAppModel.volumeMarkers.firstIndex(where: {
               $0.id == markerDragID
             }),
             let projectedPosition = projectedVolumePosition(toward: handPosition) {
            let offset = projectedPosition - sharedAppModel.volumeMarkers[primaryIndex].position
            for index in sharedAppModel.volumeMarkers.indices
              where sharedAppModel.selectedVolumeMarkerIDs.contains(
                sharedAppModel.volumeMarkers[index].id
              ) {
              sharedAppModel.volumeMarkers[index].translate(by: offset)
            }
            sharedAppModel.synchronizeMarkers()
            return
          }
          let inverseVolume = markerVolumeMatrix(for: datasetInfo).inverse
          let localDelta = inverseVolume.transformDirection(handPosition - handStart)
          for index in sharedAppModel.volumeMarkers.indices {
            let markerID = sharedAppModel.volumeMarkers[index].id
            guard let startPosition = markerDragStartPositions[markerID] else { continue }
            sharedAppModel.volumeMarkers[index].position = clamp(
              startPosition + localDelta,
              BorgVRMarkerFormat.positionRange.lowerBound,
              BorgVRMarkerFormat.positionRange.upperBound
            )
          }
          sharedAppModel.synchronizeMarkers()
        }

      case .ended, .cancelled:
        if let strokeID = handStrokeID {
          endStrokeProjectionFreeze(token: strokeID)
          self.handStrokeID = nil
          sharedAppModel.synchronizeMarkers()
        }
        if markerDragID != nil {
          markerDragID = nil
          markerDragStartPositions.removeAll()
          markerDragHandStart = nil
          quickMarkerDragActive = false
          sharedAppModel.synchronizeMarkers()
        }
      @unknown default:
        if let strokeID = handStrokeID {
          endStrokeProjectionFreeze(token: strokeID)
        }
        handStrokeID = nil
        markerDragID = nil
        markerDragStartPositions.removeAll()
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
      markerScaleStartRadii.removeAll()
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
      sharedAppModel.selectedVolumeMarkerID = targetMarker.id
      markerScaleStartRadii = Dictionary(uniqueKeysWithValues: sharedAppModel.volumeMarkers.compactMap {
        sharedAppModel.selectedVolumeMarkerIDs.contains($0.id) ? ($0.id, $0.radius) : nil
      })
    }

    guard let markerScaleID,
          markerScaleStartDistance > 0.0001,
          let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: { $0.id == markerScaleID }) else {
      return
    }

    let factor = distance / markerScaleStartDistance
    for index in sharedAppModel.volumeMarkers.indices {
      let markerID = sharedAppModel.volumeMarkers[index].id
      guard let startRadius = markerScaleStartRadii[markerID] else { continue }
      sharedAppModel.volumeMarkers[index].radius = startRadius * factor
    }
    let markerKind = sharedAppModel.volumeMarkers[markerIndex].kind
    let primaryRadius = sharedAppModel.volumeMarkers[markerIndex].radius
    if markerKind == .sphere {
      sharedAppModel.defaultVolumeMarkerRadius = primaryRadius
    } else {
      sharedAppModel.defaultVolumeStrokeRadius = primaryRadius
    }
    sharedAppModel.synchronizeMarkers()

    if events.contains(where: { $0.phase == .ended || $0.phase == .cancelled }) {
      self.markerScaleID = nil
      markerScaleStartDistance = 0
      markerScaleStartRadii.removeAll()
    }
  }

  private func measurementPointHit(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> (measurementID: UUID, point: VolumeMeasurementPoint)? {
    var best: (measurementID: UUID, point: VolumeMeasurementPoint, distance: Float)?
    for measurement in sharedAppModel.volumeMeasurementsSnapshot() {
      for point in measurement.geometry.points {
        let center = markerWorldCenter(
          VolumeMarkerPoint(position: point.position, radius: 0.012),
          datasetInfo: datasetInfo
        )
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite else { continue }
        let oc = origin - center
        let radius: Float = 0.025
        let b = simd_dot(oc, direction)
        let c = simd_dot(oc, oc) - radius * radius
        let discriminant = b * b - c
        guard discriminant.isFinite, discriminant >= 0 else { continue }
        let distance = -b - sqrt(discriminant)
        guard distance.isFinite, distance >= 0 else { continue }
        if best == nil || distance < best!.distance {
          best = (measurement.id, point, distance)
        }
      }
    }
    return best.map { ($0.measurementID, $0.point) }
  }

  private func nearestMeasurementPoint(
    to worldPosition: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) -> (measurementID: UUID, point: VolumeMeasurementPoint)? {
    var best: (measurementID: UUID, point: VolumeMeasurementPoint, distance: Float)?
    for measurement in sharedAppModel.volumeMeasurementsSnapshot() {
      for point in measurement.geometry.points {
        let center = markerWorldCenter(
          VolumeMarkerPoint(position: point.position, radius: 0.012),
          datasetInfo: datasetInfo
        )
        let distance = simd_distance(center, worldPosition)
        guard distance.isFinite, distance <= 0.04 else { continue }
        if best == nil || distance < best!.distance {
          best = (measurement.id, point, distance)
        }
      }
    }
    return best.map { ($0.measurementID, $0.point) }
  }

  private func appendMeasurementPoint(
    at position: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo,
    forceNewMeasurement: Bool = false,
    kind requestedKind: VolumeMeasurementKind? = nil,
    preferredMeasurementID: UUID? = nil
  ) -> (measurementID: UUID, pointID: UUID)? {
    let selectedID = forceNewMeasurement
      ? nil
      : (preferredMeasurementID ?? sharedAppModel.selectedVolumeMeasurementID)
    let kind = requestedKind ?? sharedAppModel.measurementKind
    let name = sharedAppModel.nextVolumeMeasurementName()
    let result = sharedAppModel.mutateVolumeMeasurements { measurements -> (
      measurementID: UUID,
      pointID: UUID
    )? in
      var index = selectedID.flatMap { selectedID in
        measurements.firstIndex {
          $0.id == selectedID && $0.kind == kind
        }
      }
      if index == nil {
        measurements.append(VolumeMeasurement(name: name, kind: kind))
        index = measurements.indices.last
      }
      guard let index,
            let pointID = measurements[index].addPoint(
              at: position,
              physicalExtent: datasetInfo.physicalExtentMeters
            ) else { return nil }
      return (measurements[index].id, pointID)
    }
    guard let result else { return nil }
    let measurementID = result.measurementID
    sharedAppModel.selectedVolumeMeasurementID = measurementID
    sharedAppModel.selectedVolumeMeasurementPointID = result.pointID
    return result
  }

  private func updateMeasurementPoint(
    measurementID: UUID,
    pointID: UUID,
    position: SIMD3<Float>,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    sharedAppModel.mutateVolumeMeasurements { measurements in
      guard let index = measurements.firstIndex(where: {
        $0.id == measurementID
      }) else { return }
      measurements[index].setPoint(
        id: pointID,
        position: position,
        physicalExtent: datasetInfo.physicalExtentMeters
      )
    }
  }

  private func removeMeasurementPoint(measurementID: UUID, pointID: UUID) {
    _ = sharedAppModel.removeVolumeMeasurementPoint(
      measurementID: measurementID,
      pointID: pointID
    )
  }

  private func handleMeasurementInteraction(
    _ event: SpatialEventCollection.Event,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    switch event.phase {
      case .active:
        guard let handPosition = inputWorldPosition(from: event) else { return }
        if measurementDragPointID == nil {
          if let hit = nearestMeasurementPoint(
            to: handPosition,
            datasetInfo: datasetInfo
          ) {
            if let lastMeasurementTap,
               lastMeasurementTap.pointID == hit.point.id,
               Date().timeIntervalSince(lastMeasurementTap.time) <= measurementDoubleClickInterval {
              removeMeasurementPoint(measurementID: hit.measurementID, pointID: hit.point.id)
              self.lastMeasurementTap = nil
              return
            }
            measurementDragMeasurementID = hit.measurementID
            measurementDragPointID = hit.point.id
            measurementDragPointStart = hit.point.position
            measurementDragHandStart = handPosition
            sharedAppModel.selectedVolumeMeasurementID = hit.measurementID
            sharedAppModel.selectedVolumeMeasurementPointID = hit.point.id
          } else {
            let position = interactionPosition(
              fromWorldPosition: handPosition,
              datasetInfo: datasetInfo,
              projectsOntoVolume: storedAppModel.projectMeasurementsOntoVolume
            )
            guard let added = appendMeasurementPoint(
              at: position,
              datasetInfo: datasetInfo
            ) else { return }
            measurementDragMeasurementID = added.measurementID
            measurementDragPointID = added.pointID
            measurementDragPointStart = position
            measurementDragHandStart = handPosition
          }
        }

        guard let measurementID = measurementDragMeasurementID,
              let pointID = measurementDragPointID,
              let pointStart = measurementDragPointStart,
              let handStart = measurementDragHandStart else { return }
        if storedAppModel.projectMeasurementsOntoVolume,
           let position = projectedVolumePosition(toward: handPosition) {
          updateMeasurementPoint(
            measurementID: measurementID,
            pointID: pointID,
            position: position,
            datasetInfo: datasetInfo
          )
          return
        }
        let inverseVolume = markerVolumeMatrix(for: datasetInfo).inverse
        let localDelta = inverseVolume.transformDirection(handPosition - handStart)
        updateMeasurementPoint(
          measurementID: measurementID,
          pointID: pointID,
          position: clamp(
            pointStart + localDelta,
            BorgVRMarkerFormat.positionRange.lowerBound,
            BorgVRMarkerFormat.positionRange.upperBound
          ),
          datasetInfo: datasetInfo
        )

      case .ended, .cancelled:
        if let pointID = measurementDragPointID {
          lastMeasurementTap = (pointID, Date())
        }
        measurementDragMeasurementID = nil
        measurementDragPointID = nil
        measurementDragHandStart = nil
        measurementDragPointStart = nil

      @unknown default:
        measurementDragMeasurementID = nil
        measurementDragPointID = nil
        measurementDragHandStart = nil
        measurementDragPointStart = nil
    }
  }

  private func captureMarkerDragStartPositions() {
    markerDragStartPositions = Dictionary(uniqueKeysWithValues: sharedAppModel.volumeMarkers.compactMap {
      sharedAppModel.selectedVolumeMarkerIDs.contains($0.id) ? ($0.id, $0.position) : nil
    })
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

  private func beginSpatialAccessoryAction(
    _ sample: BorgSpatialInputSample,
    tool: SpatialToolMode,
    datasetInfo: RuntimeAppModel.DatasetInfo?
  ) {
    guard spatialAccessoryActions[sample.id] == nil,
          activeSpatialStylusID == nil,
          !handInteractionIsActive else { return }
    let transform = sample.gripTransform
    var kind: SpatialAccessoryAction.Kind
    var markerID: UUID?
    var markerStartPositions: [UUID: SIMD3<Float>] = [:]
    var measurementID: UUID?
    var measurementPointID: UUID?
    var transferFunctionStart: SIMD2<Float>?

    if let hit = transferFunctionPanelInteractionState.hitTest(
      origin: sample.aimOrigin,
      direction: sample.aimDirection
    ) {
      if let channelIndex = transferFunctionChannelIndex(for: hit) {
        var channelMask = transferFunctionPanelInteractionState.shaderState().channelMask
        channelMask ^= 1 << UInt32(channelIndex)
        transferFunctionPanelInteractionState.updateChannelMask(channelMask)
        Task { @MainActor in
          toggleTransferFunctionChannelFromAccessory(channelIndex)
        }
        return
      }
      guard hit.x >= 0, hit.x <= 1, hit.y >= 0, hit.y <= 1 else { return }
      kind = .transferFunction
      transferFunctionStart = hit
      transferFunctionPanelDragStart = hit
      transferFunctionPanelMarkerOpacity = 1
      transferFunctionPanelMarkerSuppressed = false
      transferFunctionPanelInteractionState.setFocused(true)
      transferFunctionPanelInteractionState.updateHitUV(hit)
    } else {

      switch tool.interactionMode {
        case .model:
          kind = .model
        case .clipping:
          kind = .clipping
        case .screenView:
          kind = .screenView
          sharedAppModel.screenViewInteractionActive = true
        case .drawing:
          guard let datasetInfo else { return }
          let existingMarker = markerHit(
            origin: sample.aimOrigin,
            direction: sample.aimDirection,
            datasetInfo: datasetInfo
          )
          if let existingMarker {
            sharedAppModel.selectedVolumeMarkerID = existingMarker.id
            markerID = existingMarker.id
          } else {
            let position: SIMD3<Float>
            if storedAppModel.projectObjectsOntoVolume,
               let hit = projectedVolumePosition(toward: sample.aimOrigin) {
              position = hit
            } else if storedAppModel.markerSpawnAtGaze,
               let hit = rayVolumeHit(
                origin: sample.aimOrigin,
                direction: sample.aimDirection,
                datasetInfo: datasetInfo
               ) {
              position = hit
            } else {
              position = markerPosition(
                fromWorldPosition: sample.aimOrigin,
                datasetInfo: datasetInfo
              )
            }
            let marker = makeMarker(
              at: position,
              directionOrigin: markerPosition(
                fromWorldPosition: sample.aimOrigin,
                datasetInfo: datasetInfo
              ),
              color: sharedAppModel.defaultVolumeStrokeColor
            )
            sharedAppModel.volumeMarkers.append(marker)
            sharedAppModel.selectedVolumeMarkerID = marker.id
            markerID = marker.id
            sharedAppModel.synchronizeMarkers()
          }
          markerStartPositions = Dictionary(
            uniqueKeysWithValues: sharedAppModel.volumeMarkers.compactMap {
              sharedAppModel.selectedVolumeMarkerIDs.contains($0.id)
                ? ($0.id, $0.position) : nil
            }
          )
          kind = .markerSphere
        case .objectPlacement:
          return
        case .measurement:
          guard let datasetInfo, let measurementKind = tool.measurementKind else { return }
          if let hit = measurementPointHit(
            origin: sample.aimOrigin,
            direction: sample.aimDirection,
            datasetInfo: datasetInfo
          ) {
            measurementID = hit.measurementID
            measurementPointID = hit.point.id
            spatialAccessoryMeasurementIDs[sample.id] = hit.measurementID
            sharedAppModel.selectedVolumeMeasurementID = hit.measurementID
            sharedAppModel.selectedVolumeMeasurementPointID = hit.point.id
          } else {
            let position: SIMD3<Float>
            if storedAppModel.projectMeasurementsOntoVolume,
               let hit = projectedVolumePosition(toward: sample.aimOrigin) {
              position = hit
            } else if storedAppModel.markerSpawnAtGaze,
               let hit = rayVolumeHit(
                origin: sample.aimOrigin,
                direction: sample.aimDirection,
                datasetInfo: datasetInfo
               ) {
              position = hit
            } else {
              position = markerPosition(
                fromWorldPosition: sample.aimOrigin,
                datasetInfo: datasetInfo
              )
            }
            guard let added = appendMeasurementPoint(
              at: position,
              datasetInfo: datasetInfo,
              kind: measurementKind,
              preferredMeasurementID: spatialAccessoryMeasurementIDs[sample.id]
            ) else { return }
            measurementID = added.measurementID
            measurementPointID = added.pointID
            spatialAccessoryMeasurementIDs[sample.id] = added.measurementID
          }
          kind = .measurementPoint
      }
    }

    spatialAccessoryActions[sample.id] = SpatialAccessoryAction(
      sourceID: sample.id,
      kind: kind,
      startTransform: transform,
      startModelTranslation: sharedAppModel.modelTransform.translation,
      startModelRotation: sharedAppModel.modelTransform.rotation,
      startClippingTranslation: sharedAppModel.lastTranslationClipping,
      markerID: markerID,
      markerStartPositions: markerStartPositions,
      measurementID: measurementID,
      measurementPointID: measurementPointID,
      transferFunctionStart: transferFunctionStart,
      markerStrokeUsesModifierButton: false
    )
  }

  private func beginSpatialAccessoryStroke(
    _ sample: BorgSpatialInputSample,
    datasetInfo: RuntimeAppModel.DatasetInfo?,
    usesModifierButton: Bool
  ) {
    guard spatialAccessoryActions[sample.id] == nil,
          activeSpatialStylusID == nil,
          !handInteractionIsActive,
          let datasetInfo else { return }
    let point = VolumeMarkerPoint(
      position: interactionPosition(
        fromWorldPosition: sample.aimOrigin,
        datasetInfo: datasetInfo,
        projectsOntoVolume: storedAppModel.projectObjectsOntoVolume
      ),
      radius: sharedAppModel.defaultVolumeStrokeRadius
    )
    let marker = VolumeMarker.stroke(
      name: sharedAppModel.nextVolumeMarkerName(for: .stroke),
      firstPoint: point,
      color: sharedAppModel.defaultVolumeStrokeColor
    )
    if storedAppModel.projectObjectsOntoVolume {
      beginStrokeProjectionFreeze(token: marker.id)
    }
    sharedAppModel.volumeMarkers.append(marker)
    sharedAppModel.selectedVolumeMarkerID = marker.id
    sharedAppModel.synchronizeMarkers()
    spatialAccessoryActions[sample.id] = SpatialAccessoryAction(
      sourceID: sample.id,
      kind: .markerStroke,
      startTransform: sample.gripTransform,
      startModelTranslation: sharedAppModel.modelTransform.translation,
      startModelRotation: sharedAppModel.modelTransform.rotation,
      startClippingTranslation: sharedAppModel.lastTranslationClipping,
      markerID: marker.id,
      markerStartPositions: [:],
      measurementID: nil,
      measurementPointID: nil,
      transferFunctionStart: nil,
      markerStrokeUsesModifierButton: usesModifierButton
    )
  }

  private func beginSpatialAccessorySceneMeshDrag(
    _ sample: BorgSpatialInputSample,
    instance: SceneMeshInstance,
    datasetInfo: RuntimeAppModel.DatasetInfo
  ) {
    guard spatialAccessoryActions[sample.id] == nil,
          activeSpatialStylusID == nil,
          !handInteractionIsActive else { return }
    beginSceneMeshDrag(
      instance: instance,
      worldTransform: sample.aimTransform,
      datasetInfo: datasetInfo
    )
    spatialAccessoryActions[sample.id] = SpatialAccessoryAction(
      sourceID: sample.id,
      kind: .sceneMesh,
      startTransform: sample.aimTransform,
      startModelTranslation: sharedAppModel.modelTransform.translation,
      startModelRotation: sharedAppModel.modelTransform.rotation,
      startClippingTranslation: sharedAppModel.lastTranslationClipping,
      markerID: nil,
      markerStartPositions: [:],
      measurementID: nil,
      measurementPointID: nil,
      transferFunctionStart: nil,
      markerStrokeUsesModifierButton: false
    )
  }

  private func updateSpatialAccessoryAction(
    _ sample: BorgSpatialInputSample,
    datasetInfo: RuntimeAppModel.DatasetInfo?
  ) {
    guard let action = spatialAccessoryActions[sample.id] else { return }
    let currentTransform = sample.gripTransform
    let inverseWorld = sharedAppModel.originFromWorldAnchorMatrix.inverse
    let currentAnchorTransform = inverseWorld * currentTransform
    let startAnchorTransform = inverseWorld * action.startTransform
    let translationDelta = SIMD3<Float>(currentAnchorTransform.columns.3.x,
                                        currentAnchorTransform.columns.3.y,
                                        currentAnchorTransform.columns.3.z) -
      SIMD3<Float>(startAnchorTransform.columns.3.x,
                   startAnchorTransform.columns.3.y,
                   startAnchorTransform.columns.3.z)

    switch action.kind {
      case .model:
        let startRotation = startAnchorTransform.rotationQuaternion(orthonormalize: true)
        let currentRotation = currentAnchorTransform.rotationQuaternion(orthonormalize: true)
        sharedAppModel.modelTransform.rotation = currentRotation * startRotation.inverse *
          action.startModelRotation
        sharedAppModel.modelTransform.translation = action.startModelTranslation + translationDelta
        sharedAppModel.synchronize(kind: .transformOnly)

      case .clipping:
        var localDelta = simd_float3x3(sharedAppModel.modelTransform.rotation).inverse *
          translationDelta
        localDelta = simd_clamp(
          action.startClippingTranslation + localDelta,
          SIMD3<Float>(repeating: -0.99),
          SIMD3<Float>(repeating: 0.99)
        )
        translationClipping = localDelta
        sharedAppModel.clipMin = SIMD3<Float>(
          localDelta.x >= 0 ? localDelta.x : 0,
          localDelta.y >= 0 ? localDelta.y : 0,
          localDelta.z >= 0 ? localDelta.z : 0
        )
        sharedAppModel.clipMax = SIMD3<Float>(
          localDelta.x >= 0 ? 1 : 1 + localDelta.x,
          localDelta.y >= 0 ? 1 : 1 + localDelta.y,
          localDelta.z >= 0 ? 1 : 1 + localDelta.z
        )
        sharedAppModel.synchronize(kind: .stateOnly)

      case .markerSphere:
        guard let datasetInfo else { return }
        let inverseVolume = markerVolumeMatrix(for: datasetInfo).inverse
        let localDelta = inverseVolume.transformDirection(
          SIMD3<Float>(currentTransform.columns.3.x,
                       currentTransform.columns.3.y,
                       currentTransform.columns.3.z) -
            SIMD3<Float>(action.startTransform.columns.3.x,
                         action.startTransform.columns.3.y,
                         action.startTransform.columns.3.z)
        )
        for index in sharedAppModel.volumeMarkers.indices {
          let id = sharedAppModel.volumeMarkers[index].id
          guard let startPosition = action.markerStartPositions[id] else { continue }
          sharedAppModel.volumeMarkers[index].position = clamp(
            startPosition + localDelta,
            BorgVRMarkerFormat.positionRange.lowerBound,
            BorgVRMarkerFormat.positionRange.upperBound
          )
        }
        sharedAppModel.synchronizeMarkers()

      case .markerStroke:
        guard let datasetInfo,
              let markerID = action.markerID,
              let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: {
                $0.id == markerID
              }) else { return }
        let previousPosition = sharedAppModel.volumeMarkers[markerIndex].points.last?.position
        let point = VolumeMarkerPoint(
          position: interactionPosition(
            fromWorldPosition: sample.aimOrigin,
            datasetInfo: datasetInfo,
            projectsOntoVolume: storedAppModel.projectObjectsOntoVolume,
            smoothingDepthFrom: previousPosition
          ),
          radius: sharedAppModel.defaultVolumeStrokeRadius
        )
        let scale = simd_abs(sharedAppModel.modelTransform.scale) * datasetInfo.volumeScale
        if sharedAppModel.volumeMarkers[markerIndex].appendStrokePoint(
          point,
          coordinateScale: scale
        ) {
          sharedAppModel.synchronizeMarkers()
        }

      case .sceneMesh:
        guard let datasetInfo else { return }
        updateSceneMeshDrag(
          worldTransform: sample.aimTransform,
          datasetInfo: datasetInfo
        )

      case .measurementPoint:
        guard let datasetInfo,
              let measurementID = action.measurementID,
              let pointID = action.measurementPointID else { return }
        let position: SIMD3<Float>
        if storedAppModel.projectMeasurementsOntoVolume,
           let hit = projectedVolumePosition(toward: sample.aimOrigin) {
          position = hit
        } else if storedAppModel.markerSpawnAtGaze,
           let hit = rayVolumeHit(
            origin: sample.aimOrigin,
            direction: sample.aimDirection,
            datasetInfo: datasetInfo
           ) {
          position = hit
        } else {
          position = markerPosition(
            fromWorldPosition: sample.aimOrigin,
            datasetInfo: datasetInfo
          )
        }
        updateMeasurementPoint(
          measurementID: measurementID,
          pointID: pointID,
          position: position,
          datasetInfo: datasetInfo
        )

      case .screenView:
        updateScreenView(fromWorldTransform: sample.gripTransform)

      case .transferFunction:
        guard let start = action.transferFunctionStart,
              let hit = transferFunctionPanelInteractionState.hitTest(
                origin: sample.aimOrigin,
                direction: sample.aimDirection
              ) else { return }
        let delta = hit - start
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
        let channelMask = transferFunctionPanelInteractionState.shaderState().channelMask
        let colorChannels = (0..<3).filter { channelMask & (1 << UInt32($0)) != 0 }
        var operations: [TransferFunction1D.SmoothStepOperation] = []
        if !colorChannels.isEmpty {
          operations.append(.init(
            start: center - signedShift * 0.5,
            shift: signedShift,
            channels: colorChannels
          ))
        }
        if channelMask & (1 << 3) != 0 {
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
    }
  }

  private func finishSpatialAccessoryAction(sourceID: UUID) {
    guard let action = spatialAccessoryActions[sourceID] else { return }
    switch action.kind {
      case .model:
        sharedAppModel.lastModelTransform.translation = sharedAppModel.modelTransform.translation
        sharedAppModel.lastModelTransform.rotation = sharedAppModel.modelTransform.rotation
        sharedAppModel.synchronize(kind: .transformOnly)
      case .clipping:
        sharedAppModel.lastTranslationClipping = translationClipping
        sharedAppModel.synchronize(kind: .stateOnly)
      case .markerSphere:
        sharedAppModel.synchronizeMarkers()
      case .markerStroke:
        endStrokeProjectionFreeze(token: action.markerID ?? action.sourceID)
        sharedAppModel.synchronizeMarkers()
      case .sceneMesh:
        finishSceneMeshDrag(cancelled: false)
      case .measurementPoint:
        break
      case .screenView:
        sharedAppModel.screenViewInteractionActive = false
        sharedAppModel.synchronizeScreenView()
        sharedAppModel.flushSynchronization()
      case .transferFunction:
        sharedAppModel.flushSynchronization()
        transferFunctionPanelDragStart = nil
        transferFunctionPanelHandStart = nil
        transferFunctionPanelMarkerOpacity = 1
        transferFunctionPanelMarkerSuppressed = true
        transferFunctionPanelInteractionState.updateHitUV(nil)
    }
    spatialAccessoryActions[sourceID] = nil
  }

  private func updateScreenView(fromWorldTransform transform: simd_float4x4) {
    guard var state = sharedAppModel.screenSharePlayViewState else {
      sharedAppModel.screenViewInteractionActive = false
      return
    }
    sharedAppModel.screenViewInteractionActive = true
    let worldFromDataset = sharedAppModel.originFromWorldAnchorMatrix *
      sharedAppModel.modelTransform.matrix
    let controllerFromCamera = simd_float4x4(
      simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)) *
      simd_quatf(angle: -.pi / 6, axis: SIMD3<Float>(0, 1, 0)) *
      simd_quatf(angle: .pi / 6, axis: SIMD3<Float>(1, 0, 0))
    )
    let datasetFromCamera = simd_inverse(worldFromDataset) * transform * controllerFromCamera
    let cameraPosition = SIMD3<Float>(datasetFromCamera.columns.3.x,
                                      datasetFromCamera.columns.3.y,
                                      datasetFromCamera.columns.3.z)
    let orientation = datasetFromCamera.rotationQuaternion(orthonormalize: true).inverse
    let rotatedCameraPosition = orientation.act(cameraPosition)
    guard rotatedCameraPosition.z > 0.001 else { return }
    let scale = BorgVRScreenViewState.cameraDistance / rotatedCameraPosition.z
    guard scale.isFinite else { return }
    state.orientation = orientation
    state.scale = min(max(scale, 0.05), 40)
    state.pan = SIMD2<Float>(
      -state.scale * rotatedCameraPosition.x,
      -state.scale * rotatedCameraPosition.y
    )
    sharedAppModel.screenSharePlayViewState = state
    sharedAppModel.synchronizeScreenView()
  }

  private func adjustSpatialAccessoryValues(
    _ sample: BorgSpatialInputSample,
    mode: RuntimeAppModel.InteractionMode,
    deltaTime: Float
  ) {
    guard activeSpatialStylusID == nil, !handInteractionIsActive else { return }
    let stick = sample.adjustment
    guard simd_length(stick) > 0.08 else { return }
    let rate = min(max(deltaTime, 0), 0.05)

    if let action = spatialAccessoryActions[sample.id],
       case .markerStroke = action.kind {
      if abs(stick.y) > 0.08 {
        sharedAppModel.defaultVolumeStrokeRadius = VolumeMarkerRadius.clamp(
          sharedAppModel.defaultVolumeStrokeRadius * exp(stick.y * rate * 2.5),
          for: .stroke
        )
      }
      if abs(stick.x) > 0.08 {
        let hueShift = stick.x * rate * 0.6
        sharedAppModel.defaultVolumeStrokeColor = shiftedHue(
          sharedAppModel.defaultVolumeStrokeColor,
          by: hueShift
        )
        if let markerID = action.markerID,
           let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: {
             $0.id == markerID
           }) {
          sharedAppModel.volumeMarkers[markerIndex].color =
            sharedAppModel.defaultVolumeStrokeColor
        }
      }
      sharedAppModel.synchronizeMarkers()
      return
    }

    if mode == .model {
      if abs(stick.y) > 0.08 {
        let factor = exp(-stick.y * rate * 1.8)
        sharedAppModel.modelTransform.scale = simd_clamp(
          sharedAppModel.modelTransform.scale * factor,
          SIMD3<Float>(repeating: 0.02),
          SIMD3<Float>(repeating: 50)
        )
      }
      if abs(stick.x) > 0.08 {
        let rotation = simd_quatf(
          angle: stick.x * rate * 2.4,
          axis: SIMD3<Float>(0, 1, 0)
        )
        sharedAppModel.modelTransform.rotation = rotation *
          sharedAppModel.modelTransform.rotation
      }
      sharedAppModel.lastModelTransform.scale = sharedAppModel.modelTransform.scale
      sharedAppModel.lastModelTransform.rotation = sharedAppModel.modelTransform.rotation
      sharedAppModel.synchronize(kind: .transformOnly)
      return
    }

  }

  private func shiftedHue(_ color: SIMD4<Float>, by shift: Float) -> SIMD4<Float> {
    let maximum = max(color.x, color.y, color.z)
    let minimum = min(color.x, color.y, color.z)
    let delta = maximum - minimum
    var hue: Float = 0
    if delta > 0.000_001 {
      if maximum == color.x {
        hue = (color.y - color.z) / delta / 6
      } else if maximum == color.y {
        hue = ((color.z - color.x) / delta + 2) / 6
      } else {
        hue = ((color.x - color.y) / delta + 4) / 6
      }
    }
    hue = hue + shift - floor(hue + shift)
    let sector = hue * 6
    let index = Int(floor(sector)) % 6
    let fraction = sector - floor(sector)
    let rgb: SIMD3<Float>
    switch index {
      case 0: rgb = SIMD3<Float>(1, fraction, 0)
      case 1: rgb = SIMD3<Float>(1 - fraction, 1, 0)
      case 2: rgb = SIMD3<Float>(0, 1, fraction)
      case 3: rgb = SIMD3<Float>(0, 1 - fraction, 1)
      case 4: rgb = SIMD3<Float>(fraction, 0, 1)
      default: rgb = SIMD3<Float>(1, 0, 1 - fraction)
    }
    return SIMD4<Float>(rgb, color.w)
  }

  private var handInteractionIsActive: Bool {
    startTranslation != .zero ||
      startTranslationClipping != .zero ||
      doubleEventIsRunning ||
      transferFunctionPanelDragStart != nil ||
      markerDragID != nil ||
      markerScaleID != nil ||
      handStrokeID != nil ||
      sceneMeshDragState != nil ||
      activeSceneObjectPlacement != nil ||
      measurementDragPointID != nil ||
      quickMarkerDragActive ||
      sharedAppModel.screenViewInteractionActive
  }

  func spatialStylusSample(
    from samples: [BorgSpatialInputSample],
    timestamp: TimeInterval
  ) -> BorgSpatialStylusSample? {
    let styli = samples.filter { $0.source == .stylus }
    let stylusIDs = Set(styli.map(\.id))
    spatialStylusModifierStates = spatialStylusModifierStates.filter {
      stylusIDs.contains($0.key)
    }
    lastSpatialStylusModifierPressTimes = lastSpatialStylusModifierPressTimes.filter {
      stylusIDs.contains($0.key)
    }
    suppressedSpatialStylusModifierIDs.formIntersection(stylusIDs)
    spatialStylusToolToggleStates = spatialStylusToolToggleStates.filter {
      stylusIDs.contains($0.key)
    }
    suppressedSpatialStylusToolToggleIDs.formIntersection(stylusIDs)
    pendingSpatialStylusMeasurementStarts = pendingSpatialStylusMeasurementStarts.filter {
      stylusIDs.contains($0.key)
    }
    if storedAppModel.stylusTool.isMeasurement {
      for (stylusID, pressTime) in pendingSpatialStylusMeasurementStarts
      where timestamp - pressTime > spatialStylusDoubleClickInterval {
        toggleSpatialStylusNewMeasurement()
        pendingSpatialStylusMeasurementStarts[stylusID] = nil
      }
    } else {
      pendingSpatialStylusMeasurementStarts.removeAll()
    }

    let activeSample = activeSpatialStylusID.flatMap({ activeID in
      styli.first(where: { $0.id == activeID })
    })
    if activeSpatialStylusID != nil, activeSample == nil {
      activeSpatialStylusID = nil
    }
    guard let sample = activeSample ?? styli.first else {
      activeSpatialStylusID = nil
      return nil
    }

    let toolToggleWasPressed = spatialStylusToolToggleStates[sample.id] ?? false
    if sample.toolTogglePressed, !toolToggleWasPressed {
      advanceSpatialStylusMode()
      suppressedSpatialStylusToolToggleIDs.insert(sample.id)
      pendingSpatialStylusMeasurementStarts.removeAll()
      lastSpatialStylusModifierPressTimes[sample.id] = nil
      suppressedSpatialStylusModifierIDs.remove(sample.id)
      activeSpatialStylusID = nil
      activeSpatialStylusMeasurementID = nil
      activeSpatialStylusMeasurementPointID = nil
    }
    spatialStylusToolToggleStates[sample.id] = sample.toolTogglePressed

    if !sample.primaryPressed, !sample.modifierPressed {
      suppressedSpatialStylusToolToggleIDs.remove(sample.id)
    }

    let modifierWasPressed = spatialStylusModifierStates[sample.id] ?? false
    if sample.modifierPressed, !sample.primaryPressed,
       !sample.toolTogglePressed, !modifierWasPressed {
      switch storedAppModel.stylusTool {
        case .lengthMeasurement, .areaMeasurement, .volumeMeasurement:
          if let firstPress = pendingSpatialStylusMeasurementStarts[sample.id],
             timestamp - firstPress <= spatialStylusDoubleClickInterval {
            pendingSpatialStylusMeasurementStarts[sample.id] = nil
            suppressedSpatialStylusModifierIDs.insert(sample.id)
            spatialStylusStartsNewMeasurement = false
            if !sharedAppModel.removeLastVolumeMeasurementPoint() {
              activeSpatialStylusMeasurementID = nil
              activeSpatialStylusMeasurementPointID = nil
            }
          } else {
            pendingSpatialStylusMeasurementStarts[sample.id] = timestamp
          }
        case .marker:
          if let firstPress = lastSpatialStylusModifierPressTimes[sample.id],
             timestamp - firstPress <= spatialStylusDoubleClickInterval {
            lastSpatialStylusModifierPressTimes[sample.id] = nil
            suppressedSpatialStylusModifierIDs.insert(sample.id)
            if sharedAppModel.removeLastVolumeMarker() {
              sharedAppModel.synchronizeMarkers()
            }
          } else {
            lastSpatialStylusModifierPressTimes[sample.id] = timestamp
          }
        case .objectPlacement, .model, .clipping, .screenView:
          break
      }
    } else if !sample.modifierPressed {
      suppressedSpatialStylusModifierIDs.remove(sample.id)
    }
    spatialStylusModifierStates[sample.id] = sample.modifierPressed

    if suppressedSpatialStylusToolToggleIDs.contains(sample.id) {
      return BorgSpatialStylusSample(
        tipPosition: sample.aimOrigin,
        isDrawing: false,
        drawingPressure: nil,
        isAdjustingRadius: false
      )
    }

    let requestsAction = sample.primaryPressed ||
      (storedAppModel.stylusTool == .marker && sample.modifierPressed)
    if activeSpatialStylusID == sample.id {
      if !requestsAction {
        activeSpatialStylusID = nil
      }
    } else if requestsAction,
              spatialAccessoryActions.isEmpty,
              !handInteractionIsActive {
      activeSpatialStylusID = sample.id
    }

    let ownsAction = activeSpatialStylusID == sample.id
    return BorgSpatialStylusSample(
      tipPosition: sample.aimOrigin,
      isDrawing: ownsAction && sample.primaryPressed,
      drawingPressure: ownsAction ? sample.drawingPressure : nil,
      isAdjustingRadius: ownsAction &&
        storedAppModel.stylusTool == .marker &&
        !sample.primaryPressed &&
        sample.modifierPressed &&
        !suppressedSpatialStylusModifierIDs.contains(sample.id)
    )
  }

  private func advanceSpatialStylusMode() {
    spatialStylusStartsNewMeasurement = false
    let modes = SpatialToolMode.museModes
    let currentIndex = modes.firstIndex(of: storedAppModel.stylusTool) ?? -1
    let nextMode = modes[(currentIndex + 1) % modes.count]
    storedAppModel.stylusTool = nextMode
    guard let nextKind = nextMode.measurementKind else {
      sharedAppModel.selectedVolumeMeasurementID = nil
      sharedAppModel.selectedVolumeMeasurementPointID = nil
      return
    }

    sharedAppModel.measurementKind = nextKind
    sharedAppModel.selectedVolumeMeasurementID = sharedAppModel.volumeMeasurementsSnapshot()
      .last(where: { $0.kind == nextKind })?.id
    sharedAppModel.selectedVolumeMeasurementPointID = nil
  }

  private func toggleSpatialStylusNewMeasurement() {
    spatialStylusStartsNewMeasurement.toggle()
    sharedAppModel.selectedVolumeMeasurementPointID = nil
    guard !spatialStylusStartsNewMeasurement else { return }
    guard let kind = storedAppModel.stylusTool.measurementKind else { return }
    sharedAppModel.selectedVolumeMeasurementID = sharedAppModel.volumeMeasurementsSnapshot()
      .last(where: { $0.kind == kind })?.id
  }

  var spatialStylusWillStartNewMeasurement: Bool {
    guard let kind = storedAppModel.stylusTool.measurementKind else { return false }
    if spatialStylusStartsNewMeasurement { return true }
    guard let selectedID = sharedAppModel.selectedVolumeMeasurementID else { return true }
    return !sharedAppModel.volumeMeasurementsSnapshot().contains {
      $0.id == selectedID && $0.kind == kind && !$0.points.isEmpty
    }
  }

  func handleSpatialStylusMeasurement(
    _ sample: BorgSpatialStylusSample?,
    datasetInfo: RuntimeAppModel.DatasetInfo?,
    kind: VolumeMeasurementKind
  ) {
    guard let sample, let datasetInfo else {
      activeSpatialStylusMeasurementID = nil
      activeSpatialStylusMeasurementPointID = nil
      return
    }
    guard sample.isDrawing else {
      activeSpatialStylusMeasurementID = nil
      activeSpatialStylusMeasurementPointID = nil
      return
    }

    let position = interactionPosition(
      fromWorldPosition: sample.tipPosition,
      datasetInfo: datasetInfo,
      projectsOntoVolume: storedAppModel.projectMeasurementsOntoVolume
    )
    if activeSpatialStylusMeasurementPointID == nil {
      let startsNewMeasurement = spatialStylusStartsNewMeasurement
      if !startsNewMeasurement, let nearest = nearestMeasurementPoint(
        to: sample.tipPosition,
        datasetInfo: datasetInfo
      ) {
        activeSpatialStylusMeasurementID = nearest.measurementID
        activeSpatialStylusMeasurementPointID = nearest.point.id
        sharedAppModel.selectedVolumeMeasurementID = nearest.measurementID
        sharedAppModel.selectedVolumeMeasurementPointID = nearest.point.id
      } else if let added = appendMeasurementPoint(
        at: position,
        datasetInfo: datasetInfo,
        forceNewMeasurement: startsNewMeasurement,
        kind: kind
      ) {
        spatialStylusStartsNewMeasurement = false
        activeSpatialStylusMeasurementID = added.measurementID
        activeSpatialStylusMeasurementPointID = added.pointID
      }
    }
    guard let measurementID = activeSpatialStylusMeasurementID,
          let pointID = activeSpatialStylusMeasurementPointID else { return }
    updateMeasurementPoint(
      measurementID: measurementID,
      pointID: pointID,
      position: position,
      datasetInfo: datasetInfo
    )
  }

  func handleSpatialInputSamples(
    _ samples: [BorgSpatialInputSample],
    datasetInfo: RuntimeAppModel.DatasetInfo?,
    timestamp: TimeInterval
  ) {
    let controllers = samples.filter { $0.source == .controller }
    let controllerIDs = Set(controllers.map(\.id))
    for sourceID in Array(spatialAccessoryActions.keys)
      where !controllerIDs.contains(sourceID) {
      finishSpatialAccessoryAction(sourceID: sourceID)
    }

    let deltaTime = Float(timestamp - (lastSpatialAccessoryAdjustmentTime ?? timestamp))
    lastSpatialAccessoryAdjustmentTime = timestamp
    for sample in controllers {
      if spatialAccessoryActions.isEmpty {
        let hit = transferFunctionPanelInteractionState.hitTest(
          origin: sample.aimOrigin,
          direction: sample.aimDirection
        )
        transferFunctionPanelInteractionState.setFocused(hit != nil)
        transferFunctionPanelInteractionState.updateHitUV(hit)
      }
      let wasPressed = spatialAccessoryPrimaryStates[sample.id] ?? false
      let wasModifierPressed = spatialAccessoryModifierStates[sample.id] ?? false
      let previousFaceButtons = spatialAccessoryFaceButtonStates[sample.id] ?? []
      for button in sample.pressedFaceButtons.subtracting(previousFaceButtons) {
        Task { @MainActor in
          performControllerFaceButtonFromAccessory(button, sample.chirality)
        }
      }
      let controllerTool = storedAppModel.controllerTool(for: sample.chirality)
      if sample.modifierPressed && !wasModifierPressed {
        beginSpatialAccessoryStroke(
          sample,
          datasetInfo: datasetInfo,
          usesModifierButton: true
        )
      }
      if sample.primaryPressed && !wasPressed {
        if controllerTool == .marker {
          if let datasetInfo,
             let instance = sceneMeshHit(
               origin: sample.aimOrigin,
               direction: sample.aimDirection,
               datasetInfo: datasetInfo
             ) {
            beginSpatialAccessorySceneMeshDrag(
              sample,
              instance: instance,
              datasetInfo: datasetInfo
            )
          } else {
            beginSpatialAccessoryStroke(
              sample,
              datasetInfo: datasetInfo,
              usesModifierButton: false
            )
          }
        } else {
          beginSpatialAccessoryAction(
            sample,
            tool: controllerTool,
            datasetInfo: datasetInfo
          )
        }
      }
      if let action = spatialAccessoryActions[sample.id] {
        switch action.kind {
          case .markerStroke:
            let strokePressed = action.markerStrokeUsesModifierButton
              ? sample.modifierPressed
              : sample.primaryPressed
            let strokeWasPressed = action.markerStrokeUsesModifierButton
              ? wasModifierPressed
              : wasPressed
            if strokePressed {
              updateSpatialAccessoryAction(sample, datasetInfo: datasetInfo)
            } else if strokeWasPressed {
              finishSpatialAccessoryAction(sourceID: sample.id)
            }
          case .measurementPoint:
            if sample.primaryPressed {
              updateSpatialAccessoryAction(sample, datasetInfo: datasetInfo)
            } else if wasPressed {
              finishSpatialAccessoryAction(sourceID: sample.id)
            }
          case .sceneMesh:
            if sample.primaryPressed {
              updateSpatialAccessoryAction(sample, datasetInfo: datasetInfo)
            } else if wasPressed {
              finishSpatialAccessoryAction(sourceID: sample.id)
            }
          default:
            if sample.primaryPressed {
              updateSpatialAccessoryAction(sample, datasetInfo: datasetInfo)
            } else if wasPressed {
              finishSpatialAccessoryAction(sourceID: sample.id)
            }
        }
      }
      adjustSpatialAccessoryValues(
        sample,
        mode: controllerTool.interactionMode,
        deltaTime: deltaTime
      )
      spatialAccessoryPrimaryStates[sample.id] = sample.primaryPressed
      spatialAccessoryModifierStates[sample.id] = sample.modifierPressed
      spatialAccessoryFaceButtonStates[sample.id] = sample.pressedFaceButtons
    }
    spatialAccessoryPrimaryStates = spatialAccessoryPrimaryStates.filter {
      controllerIDs.contains($0.key)
    }
    spatialAccessoryModifierStates = spatialAccessoryModifierStates.filter {
      controllerIDs.contains($0.key)
    }
    spatialAccessoryFaceButtonStates = spatialAccessoryFaceButtonStates.filter {
      controllerIDs.contains($0.key)
    }
    spatialAccessoryMeasurementIDs = spatialAccessoryMeasurementIDs.filter {
      controllerIDs.contains($0.key)
    }
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
    guard spatialAccessoryActions.isEmpty, activeSpatialStylusID == nil else { return }
    if let datasetInfo,
       events.count == 1,
       let event = events.first,
       sharedAppModel.armedSceneObjectPrototype != nil,
       handleSceneObjectPlacement(
        event,
        datasetInfo: datasetInfo,
        prototype: sharedAppModel.armedSceneObjectPrototype!
       ) {
      return
    }
    if interactionMode != .screenView {
      sharedAppModel.screenViewInteractionActive = false
    }
    if events.count == 1,
       let event = events.first,
       handleTransferFunctionPanel(
        event,
        transferEditState,
        toggleChannel: toggleChannel
       ) {
      return
    }

    if interactionMode == .drawing || interactionMode == .objectPlacement {
      resetQuickMarkerState()
    } else {
      sharedAppModel.selectedVolumeMarkerID = nil
    }

    if interactionMode != .measurement {
      sharedAppModel.selectedVolumeMeasurementPointID = nil
    }

    if interactionMode != .drawing,
       interactionMode != .objectPlacement,
       interactionMode != .screenView,
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
      case .drawing:
        guard let datasetInfo else {
          return
        }
        guard events.count == 1, let event = events.first else { return }
        handleMarkerInteraction(event, datasetInfo: datasetInfo, drawsStroke: true)
      case .objectPlacement:
        guard let datasetInfo else {
          return
        }
        switch events.count {
          case 1:
            let event = events.first!
            _ = handleSceneObjectPlacement(
              event,
              datasetInfo: datasetInfo,
              prototype: sharedAppModel.validateSelectedSceneObjectPrototype()
            )
          case 2:
            handleMarkerScaling(events, datasetInfo: datasetInfo)
          default:
            return
        }
      case .measurement:
        resetQuickMarkerState()
        guard let datasetInfo, events.count == 1, let event = events.first else { return }
        handleMeasurementInteraction(event, datasetInfo: datasetInfo)
      case .screenView:
        resetQuickMarkerState()
        guard events.count == 1, let event = events.first else {
          sharedAppModel.screenViewInteractionActive = false
          return
        }
        handleScreenViewInteraction(event)
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
