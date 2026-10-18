import RealityKit
import simd

typealias VisionBorgVRSession = BorgVRSession<SharedAppModel, RuntimeAppModel, StoredAppModel>

extension BorgVRSession where VisualizationState == SharedAppModel,
                              RuntimeState == RuntimeAppModel,
                              SettingsState == StoredAppModel {
  static func vision(
    sharedAppModel: SharedAppModel,
    runtimeAppModel: RuntimeAppModel,
    storedAppModel: StoredAppModel
  ) -> VisionBorgVRSession {
    let session = VisionBorgVRSession(
      visualizationState: sharedAppModel,
      runtimeState: runtimeAppModel,
      settingsState: storedAppModel,
      commandHandler: { command, _ in
        switch command {
          case .setRenderMode(let mode):
            sharedAppModel.renderMode = mode
            sharedAppModel.synchronize(kind: .stateOnly)
          case .setTransform(let snapshot):
            guard simd_length_squared(snapshot.rotation) > 0.000_001 else {
              throw BorgVRSessionCommandError.invalidRotation
            }
            guard snapshot.scale.x > 0,
                  snapshot.scale.y > 0,
                  snapshot.scale.z > 0 else {
              throw BorgVRSessionCommandError.invalidScale
            }
            let transform = Transform(
              scale: snapshot.scale,
              rotation: simd_normalize(simd_quatf(vector: snapshot.rotation)),
              translation: snapshot.translation
            )
            sharedAppModel.modelTransform = transform
            sharedAppModel.lastModelTransform = transform
            sharedAppModel.synchronize(kind: .transformOnly)
          case .rotate(let axis, let degrees):
            guard simd_length_squared(axis) > 0.000_001 else {
              throw BorgVRSessionCommandError.invalidRotation
            }
            var transform = sharedAppModel.modelTransform
            let rotation = simd_quatf(
              angle: degrees * .pi / 180,
              axis: simd_normalize(axis)
            )
            transform.rotation = simd_normalize(rotation * transform.rotation)
            sharedAppModel.modelTransform = transform
            sharedAppModel.lastModelTransform = transform
            sharedAppModel.synchronize(kind: .transformOnly)
          case .setNormalizedIsoValue(let value):
            guard value.isFinite, (0...1).contains(value) else {
              throw BorgVRSessionCommandError.invalidIsoValue
            }
            sharedAppModel.normIsoValue = value
            sharedAppModel.synchronize(kind: .stateOnly)
          case .setClipping(let minimum, let maximum):
            guard validVisionClipping(minimum: minimum, maximum: maximum) else {
              throw BorgVRSessionCommandError.invalidClipping
            }
            sharedAppModel.clipMin = minimum
            sharedAppModel.clipMax = maximum
            sharedAppModel.lastTranslationClipping = .zero
            sharedAppModel.synchronize(kind: .stateOnly)
          case .setTransferFunction(let snapshot):
            guard sharedAppModel.transferFunctions.indices.contains(snapshot.channel),
                  sharedAppModel.transferFunctions[snapshot.channel].data.count ==
                    snapshot.samples.count else {
              throw BorgVRSessionCommandError.invalidTransferFunction
            }
            try sharedAppModel.transferFunctions[snapshot.channel].updateData(
              with: snapshot.samples
            )
            sharedAppModel.synchronize(kind: .full)
          case .setLighting(let direction, let ambient, let diffuse, let specular):
            if let direction {
              guard simd_length_squared(direction) > 0.000_001 else {
                throw BorgVRSessionCommandError.invalidLightDirection
              }
              sharedAppModel.lightDirection = simd_normalize(direction)
            }
            if let ambient {
              sharedAppModel.ambientLightColor = try validatedVisionLightColor(ambient)
            }
            if let diffuse {
              sharedAppModel.diffuseLightColor = try validatedVisionLightColor(diffuse)
            }
            if let specular {
              sharedAppModel.specularLightColor = try validatedVisionLightColor(specular)
            }
            sharedAppModel.synchronize(kind: .stateOnly)
          case .setAnnotationVisibility(let objects, let measurements):
            guard objects != nil || measurements != nil else {
              throw BorgVRSessionCommandError.emptyAnnotationVisibility
            }
            if let objects { sharedAppModel.objectsHidden = !objects }
            if let measurements { sharedAppModel.measurementsHidden = !measurements }
          case .upsertObject(let object):
            switch object {
              case .marker(let state):
                let marker = try state.marker()
                if let index = sharedAppModel.volumeMarkers.firstIndex(where: {
                  $0.id == marker.id
                }) {
                  sharedAppModel.volumeMarkers[index] = marker
                } else {
                  sharedAppModel.volumeMarkers.append(marker)
                }
              case .mesh(let state):
                let asset = sharedAppModel.sceneMeshAssets[state.assetID]
                  ?? SceneMeshAssetCatalog.load(assetID: state.assetID)
                guard let asset else {
                  throw BorgVRSessionCommandError.meshAssetNotFound(state.assetID)
                }
                sharedAppModel.sceneMeshAssets[asset.id] = asset
                let instance = try state.instance(asset: asset)
                if let index = sharedAppModel.sceneMeshInstances.firstIndex(where: {
                  $0.id == instance.id
                }) {
                  sharedAppModel.sceneMeshInstances[index] = instance
                } else {
                  sharedAppModel.sceneMeshInstances.append(instance)
                }
            }
            sharedAppModel.synchronizeMarkers()
          case .removeObject(let id):
            let removedMarker = sharedAppModel.removeVolumeMarkers(withIDs: [id])
            let removedMesh = sharedAppModel.removeSceneMeshInstance(id: id)
            guard removedMarker || removedMesh else {
              throw BorgVRSessionCommandError.annotationNotFound
            }
            sharedAppModel.synchronizeMarkers()
          case .clearObjects:
            sharedAppModel.volumeMarkers.removeAll()
            sharedAppModel.sceneMeshInstances.removeAll()
            sharedAppModel.clearVolumeMarkerSelection()
            sharedAppModel.selectedSceneMeshInstanceID = nil
            sharedAppModel.synchronizeMarkers()
          case .upsertMeasurement(let state):
            let measurement = try state.measurement(
              physicalExtent: runtimeAppModel.activeDatasetInfo?.physicalExtentMeters
            )
            sharedAppModel.mutateVolumeMeasurements { measurements in
              if let index = measurements.firstIndex(where: { $0.id == measurement.id }) {
                measurements[index] = measurement
              } else {
                measurements.append(measurement)
              }
            }
          case .removeMeasurement(let id):
            let removed = sharedAppModel.mutateVolumeMeasurements { measurements in
              let oldCount = measurements.count
              measurements.removeAll { $0.id == id }
              return measurements.count != oldCount
            }
            guard removed else { throw BorgVRSessionCommandError.annotationNotFound }
            if sharedAppModel.selectedVolumeMeasurementID == id {
              sharedAppModel.clearVolumeMeasurementSelection()
            }
          case .clearMeasurements:
            _ = sharedAppModel.removeAllVolumeMeasurements()
          case .reset(let scope):
            switch scope {
              case .all:
                sharedAppModel.resetModel()
                sharedAppModel.resetClipBoundsToVolume()
                for transferFunction in sharedAppModel.transferFunctions {
                  transferFunction.reset()
                }
                sharedAppModel.resetIsoValue()
                sharedAppModel.renderMode = .transferFunction1D
                sharedAppModel.brickVis = false
                applyVisionDefaultLighting(to: sharedAppModel)
                sharedAppModel.synchronize(kind: .full)
              case .transform:
                sharedAppModel.resetModel()
                sharedAppModel.synchronize(kind: .transformOnly)
              case .clipping:
                sharedAppModel.resetClipBoundsToVolume()
                sharedAppModel.synchronize(kind: .stateOnly)
              case .transferFunction:
                sharedAppModel.transferFunction(
                  channel: runtimeAppModel.selectedTransferFunctionChannel
                ).reset()
                sharedAppModel.synchronize(kind: .full)
              case .lighting:
                applyVisionDefaultLighting(to: sharedAppModel)
                sharedAppModel.synchronize(kind: .stateOnly)
            }
          case .mutation:
            break
        }
      },
      snapshotProvider: {
        let transform = sharedAppModel.modelTransform
        let measurements = sharedAppModel.volumeMeasurementsSnapshot()
        let transferFunctions = sharedAppModel.activeTransferFunctions.enumerated().map {
          channel, transferFunction in
          BorgVRTransferFunctionSnapshot(
            channel: channel,
            samples: transferFunction.data,
            revision: transferFunction.revision
          )
        }
        let visualization = BorgVRVisualizationSnapshot(
          transform: BorgVRTransformSnapshot(
            rotation: transform.rotation.vector,
            translation: transform.translation,
            scale: transform.scale
          ),
          clipMinimum: sharedAppModel.clipMin,
          clipMaximum: sharedAppModel.clipMax,
          normalizedIsoValue: sharedAppModel.normIsoValue,
          isoValue: sharedAppModel.isoValue,
          renderMode: sharedAppModel.renderMode,
          brickVisualization: sharedAppModel.brickVis,
          transferBias: sharedAppModel.transferFunction(
            channel: runtimeAppModel.selectedTransferFunctionChannel
          ).textureBias,
          lighting: BorgVRLightingSnapshot(
            direction: sharedAppModel.lightDirection,
            ambient: sharedAppModel.ambientLightColor,
            diffuse: sharedAppModel.diffuseLightColor,
            specular: sharedAppModel.specularLightColor
          ),
          objectsVisible: !sharedAppModel.objectsHidden,
          measurementsVisible: !sharedAppModel.measurementsHidden,
          objectCount: sharedAppModel.volumeMarkers.count + sharedAppModel.sceneMeshInstances.count,
          measurementCount: measurements.count,
          transferFunctionRevisions: sharedAppModel.activeTransferFunctions.map(\.revision)
        )
        let maximumExtent: Float
        if let dataset = runtimeAppModel.activeDatasetInfo {
          let extent = dataset.physicalExtentMeters
          maximumExtent = max(extent.x, max(extent.y, extent.z))
        } else {
          maximumExtent = 1
        }
        return BorgVRFrameSnapshot(
          visualization: visualization,
          transferFunctions: transferFunctions,
          annotations: BorgVRRenderAnnotationsSnapshot(
            markers: sharedAppModel.volumeMarkers,
            meshAssets: sharedAppModel.sceneMeshAssets,
            meshInstances: sharedAppModel.sceneMeshInstances,
            measurements: measurements,
            remoteToolPreviews: sharedAppModel.activeRemoteSpatialToolPreviews(),
            selectedMarkerIDs: sharedAppModel.selectedVolumeMarkerIDs,
            selectedMeasurementID: sharedAppModel.selectedVolumeMeasurementID,
            selectedMeasurementPointID: sharedAppModel.selectedVolumeMeasurementPointID,
            datasetMaximumExtentMeters: maximumExtent,
            localToolColor: sharedAppModel.defaultVolumeStrokeColor
          ),
          spatialViews: BorgVRSpatialViewsSnapshot(
            participants: sharedAppModel.sharePlayParticipants,
            sharedView: sharedAppModel.screenSharePlayViewState,
            detachedViews: sharedAppModel.detachedScreenSharePlayViewStates,
            namesVisible: sharedAppModel.screenViewNamesVisible,
            interactionActive: sharedAppModel.screenViewInteractionActive
          ),
          settings: BorgVRRenderSettingsSnapshot(
            sampleJitter: storedAppModel.sampleJitter,
            transferFunctionDisplayMode: storedAppModel.tfMode,
            purgeAtlas: sharedAppModel.purgeAtlas
          )
        )
      },
      annotationSnapshotProvider: {
        BorgVRAnnotationSnapshot(
          markers: sharedAppModel.volumeMarkers,
          meshInstances: sharedAppModel.sceneMeshInstances,
          measurements: sharedAppModel.volumeMeasurementsSnapshot()
        )
      },
      transferFunctionSnapshotProvider: {
        sharedAppModel.activeTransferFunctions.enumerated().map { channel, transferFunction in
          BorgVRTransferFunctionSnapshot(
            channel: channel,
            samples: transferFunction.data,
            revision: transferFunction.revision
          )
        }
      }
    )
    session.trackRenderSnapshotChanges(from: [storedAppModel.objectWillChange])
    session.trackObservedRenderSnapshotChanges()
    return session
  }
}

private func validVisionClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) -> Bool {
  minimum.x >= 0 && minimum.y >= 0 && minimum.z >= 0 &&
    maximum.x <= 1 && maximum.y <= 1 && maximum.z <= 1 &&
    minimum.x <= maximum.x && minimum.y <= maximum.y && minimum.z <= maximum.z
}

private func validatedVisionLightColor(_ color: SIMD3<Float>) throws -> SIMD3<Float> {
  guard color.x.isFinite, color.y.isFinite, color.z.isFinite,
        color.x >= 0, color.x <= 1,
        color.y >= 0, color.y <= 1,
        color.z >= 0, color.z <= 1 else {
    throw BorgVRSessionCommandError.invalidLightColor
  }
  return color
}

private func applyVisionDefaultLighting(to state: SharedAppModel) {
  let lighting = BorgVRLightingState.default
  state.lightDirection = lighting.direction
  state.ambientLightColor = lighting.ambientColor
  state.diffuseLightColor = lighting.diffuseColor
  state.specularLightColor = lighting.specularColor
}
