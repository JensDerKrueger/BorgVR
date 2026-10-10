import CompositorServices
import Foundation
import Metal
import MetalKit
import simd
import Spatial
import Observation
import RealityKit

extension Renderer {

  private struct ScreenViewVisualization {
    var markers: [VolumeMarker] = []
    var labels: [ScreenViewLabelDescriptor] = []
  }

  private struct MeasurementVisualization {
    struct Line {
      let startAndWidth: SIMD4<Float>
      let end: SIMD4<Float>
      let color: SIMD4<Float>
    }

    struct Surface {
      let measurement: VolumeMeasurement
      let color: SIMD4<Float>
    }

    var points: [MeasurementPointRenderInstance] = []
    var lines: [Line] = []
    var labels: [ScreenViewLabelDescriptor] = []
    var surfaces: [Surface] = []
  }

  private struct ScreenViewLabelDescriptor {
    let text: String
    let color: SIMD4<Float>
    let position: SIMD3<Float>
    var depthOffsetTowardCamera: Float = 0
    var opaqueBackground = false
    var height: Float = 0.052
    var billboardOffset = SIMD2<Float>.zero
  }

  private static let screenViewVisualizationMarkerIDs: [UUID] = [
    UUID(uuidString: "EC000000-0000-0000-0000-000000000001")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000002")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000003")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000004")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000005")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000006")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000007")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000008")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000009")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000A")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000B")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000C")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000D")!
  ]
  private static let stylusMeasurementPreviewMarkerIDs: [UUID] = (1...8).map {
    UUID(uuidString: String(format: "ED000000-0000-0000-0000-%012X", $0))!
  }

  private func measurementVisualizationID(_ base: UUID, _ index: Int) -> UUID {
    var uuid = base.uuid
    withUnsafeMutableBytes(of: &uuid) { bytes in
      bytes[12] ^= 0x4D
      bytes[13] ^= UInt8(truncatingIfNeeded: index >> 16)
      bytes[14] ^= UInt8(truncatingIfNeeded: index >> 8)
      bytes[15] ^= UInt8(truncatingIfNeeded: index)
    }
    return UUID(uuid: uuid)
  }

  private func measurementColor(
    for kind: VolumeMeasurementKind,
    selected: Bool
  ) -> SIMD4<Float> {
    let base: SIMD3<Float>
    switch kind {
      case .length: base = SIMD3<Float>(1.0, 0.72, 0.12)
      case .area: base = SIMD3<Float>(0.10, 0.78, 0.92)
      case .volume: base = SIMD3<Float>(0.82, 0.30, 0.95)
    }
    let rgb = selected ? base + (SIMD3<Float>(repeating: 1) - base) * 0.22 : base
    return SIMD4<Float>(rgb, 1)
  }

  private func measurementVisualization(
    measurements: [VolumeMeasurement]
  ) -> MeasurementVisualization {
    var result = MeasurementVisualization()
    let coordinateScale = SIMD3<Float>(
      volumeScale.columns.0.x,
      volumeScale.columns.1.y,
      volumeScale.columns.2.z
    )
    func line(
      from start: SIMD3<Float>,
      to end: SIMD3<Float>,
      color: SIMD4<Float>,
      width: Float
    ) -> MeasurementVisualization.Line? {
      let localStart = (start - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      let localEnd = (end - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      guard localStart.x.isFinite, localStart.y.isFinite, localStart.z.isFinite,
            localEnd.x.isFinite, localEnd.y.isFinite, localEnd.z.isFinite else { return nil }
      return MeasurementVisualization.Line(
        startAndWidth: SIMD4<Float>(localStart, width),
        end: SIMD4<Float>(localEnd, 0),
        color: color
      )
    }

    for measurement in measurements {
      let selected = sharedAppModel.selectedVolumeMeasurementID == measurement.id
      let color = measurementColor(for: measurement.kind, selected: selected)
      let geometry = measurement.geometry

      for (pointIndex, point) in geometry.points.enumerated() {
        let pointSelected = selected &&
          sharedAppModel.selectedVolumeMeasurementPointID == point.id
        let definesAreaPlane = measurement.kind == .area && pointIndex < 3
        let outerColor: SIMD4<Float>
        if pointSelected {
          outerColor = SIMD4<Float>(1, 0.22, 0.03, 1)
        } else {
          outerColor = color
        }
        let localPosition = (point.position - SIMD3<Float>(repeating: 0.5)) *
          coordinateScale
        result.points.append(MeasurementPointRenderInstance(
          centerAndRadius: SIMD4<Float>(
            localPosition,
            pointSelected ? 9 : (definesAreaPlane ? 8 : 7)
          ),
          color: pointSelected
            ? outerColor
            : (definesAreaPlane ? SIMD4<Float>(1, 1, 1, 1) : outerColor)
        ))
      }

      for edge in geometry.edges {
        let displayLength = simd_length((edge.end - edge.start) * coordinateScale)
        guard displayLength.isFinite else { continue }
        let dashCount = max(1, Int(ceil(min(displayLength / 0.035, 4096))))
        for dash in 0..<dashCount {
          let startT = Float(dash) / Float(dashCount)
          let endT = min(1, startT + 0.62 / Float(dashCount))
          let start = edge.start + (edge.end - edge.start) * startT
          let end = edge.start + (edge.end - edge.start) * endT
          if let dashLine = line(
            from: start,
            to: end,
            color: color,
            width: selected ? 4.5 : 3.5
          ) {
            result.lines.append(dashLine)
          }
        }
      }

      if let valueText = measurement.formattedValue(),
         let firstPoint = geometry.points.first {
        result.labels.append(ScreenViewLabelDescriptor(
          text: valueText,
          color: color,
          position: firstPoint.position,
          depthOffsetTowardCamera: 0.010,
          opaqueBackground: true,
          height: 0.021,
          billboardOffset: SIMD2<Float>(0, 0.020)
        ))
      }
      if !geometry.triangleVertices.isEmpty {
        result.surfaces.append(.init(
          measurement: measurement,
          color: SIMD4<Float>(color.x, color.y, color.z, selected ? 0.34 : 0.22)
        ))
      }
    }
    return result
  }

  private func makeBillboardMatrix(position: SIMD3<Float>,
                                   camera: SIMD3<Float>,
                                   up: SIMD3<Float>,
                                   cylindrical: Bool) -> (simd_float4x4, SIMD3<Float>) {
    var forward = camera - position

    if cylindrical {
      // remove component along up -> yaw-only billboard (stays vertical)
      forward -= up * simd_dot(forward, up)
    }

    let fLen = simd_length(forward)
    let f = (fLen.isFinite && fLen > 1e-5)
      ? (forward / fLen)
      : SIMD3<Float>(0, 0, 1)

    var right = simd_cross(up, f)
    var rightLength = simd_length(right)
    if !rightLength.isFinite || rightLength <= 1e-5 {
      right = simd_cross(SIMD3<Float>(1, 0, 0), f)
      rightLength = simd_length(right)
    }
    let r = (rightLength.isFinite && rightLength > 1e-5)
      ? right / rightLength
      : SIMD3<Float>(1, 0, 0)
    let u = simd_cross(f, r) // already normalized if r,f are

    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(r.x, r.y, r.z, 0)
    m.columns.1 = SIMD4<Float>(u.x, u.y, u.z, 0)
    m.columns.2 = SIMD4<Float>(f.x, f.y, f.z, 0)
    m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
    return (m, f)
  }

  private func length3(_ c: SIMD4<Float>) -> Float {
    simd_length(SIMD3<Float>(c.x, c.y, c.z))
  }

  private func translation3(_ m: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
  }

  private func clamp(_ x: Float, _ a: Float, _ b: Float) -> Float {
    min(max(x, a), b)
  }

  // MARK: Pre-Frame Setup

  /**
   Updates the render state with view-projection uniforms and clip parameters per view.

   - Parameters:
   - drawable: The drawable from the current frame.
   - deviceAnchor: The device anchor containing the transform of the Vision Pro.
   */
  private func updateRenderState(drawable: LayerRenderer.Drawable) {
    if sharedAppModel.purgeAtlas {
      volumeAtlas.purge()
      sharedAppModel.purgeAtlas = false
    }

    let anchors = borgARProvider.getAnchors(for: drawable)
    let originFromDevice = anchors.originFromDevice ?? matrix_identity_float4x4
    let originFromWorldAnchor = anchors.originFromWorldAnchor ?? matrix_identity_float4x4

    self.lastOriginFromDevice = originFromDevice

    // Compute a head-centered transform by averaging eye translations.
    // originFromView = originFromDevice * view.transform (your existing convention)
    let leftEyeOriginFromView = originFromDevice * drawable.views[0].transform
    var headOriginFromView = leftEyeOriginFromView

    if drawable.views.count > 1 {
      let rightEyeOriginFromView = originFromDevice * drawable.views[1].transform

      let tl = SIMD3<Float>(leftEyeOriginFromView.columns.3.x,
                            leftEyeOriginFromView.columns.3.y,
                            leftEyeOriginFromView.columns.3.z)
      let tr = SIMD3<Float>(rightEyeOriginFromView.columns.3.x,
                            rightEyeOriginFromView.columns.3.y,
                            rightEyeOriginFromView.columns.3.z)

      let tc = 0.5 * (tl + tr)
      headOriginFromView.columns.3 = SIMD4<Float>(tc.x, tc.y, tc.z, 1.0)
    }

    sharedAppModel.updateSpatialReference(
      originFromHead: headOriginFromView,
      originFromWorldAnchor: originFromWorldAnchor,
      worldAnchorID: anchors.worldAnchor?.id
    )

    let spatialAnchorID = anchors.worldAnchor?.id
    runtimeAppModel.spatialAnchorSessionState.publishActiveAnchor(
      id: spatialAnchorID,
      isShared: anchors.worldAnchorIsShared
    )
    if lastSpatialAnchorID != spatialAnchorID {
      lastSpatialAnchorID = spatialAnchorID
      let sessionSnapshot = runtimeAppModel.spatialAnchorSessionState.snapshot()
      if sessionSnapshot.sharePlayIsActive && sessionSnapshot.activeAnchorIsShared {
        sharedAppModel.synchronize(kind: .transformOnly)
      }
    }

    let unscaledModelMatrix : simd_float4x4
    let modelMatrix : simd_float4x4
    if autoRotationAngle > 0 {
      let autoRotationMatrix = rotationYMatrix(degrees: autoRotationAngle)

      let rot = sharedAppModel.modelTransform.rotation
      let trans = sharedAppModel.modelTransform.translation
      let scale = sharedAppModel.modelTransform.scale

      let model = Transform(
        scale: scale,
        rotation: simd_quatf(autoRotationMatrix)*rot,
        translation: trans
      ).matrix

      unscaledModelMatrix = originFromWorldAnchor * model
      modelMatrix = unscaledModelMatrix * volumeScale
    } else {
      unscaledModelMatrix = originFromWorldAnchor * sharedAppModel.modelTransform.matrix
      modelMatrix = unscaledModelMatrix * volumeScale
    }

    // Place panel in front of head in "view" coordinates:
    // In camera/view coordinates, forward is typically -Z, so z = -distance is in front.
    let panelLocalFromPanel = Transform(
      translation: SIMD3<Float>(tfPanelXOffset, tfPanelYOffset, -tfPanelDistance)
    ).matrix

    // World/origin transform of the panel
    self.tfPanelWorldMatrix = headOriginFromView * panelLocalFromPanel

    func pos(_ m: simd_float4x4) -> SIMD3<Float> {
      SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    let leftEye = originFromDevice * drawable.views[0].transform
    var headPos = pos(leftEye)

    if drawable.views.count > 1 {
      let rightEye = originFromDevice * drawable.views[1].transform
      headPos = 0.5 * (pos(leftEye) + pos(rightEye))
    }
    self.lastHeadPosition = headPos


    func uniforms(forViewIndex viewIndex: Int) -> (VertexUniforms, FragmentUniforms) {
      let view = drawable.views[viewIndex]
      let viewMatrix = (originFromDevice * view.transform).inverse
      let projection = drawable.computeProjection(viewIndex: viewIndex)

      let viewToTexture = Transform(translation: SIMD3<Float>(0.5, 0.5, 0.5)).matrix * simd_inverse(viewMatrix * modelMatrix)
      let viewToTextureVoxelScaled = Transform(translation: SIMD3<Float>(0.5, 0.5, 0.5)).matrix * simd_inverse(viewMatrix * originFromWorldAnchor * sharedAppModel.modelTransform.matrix)

      let metadata = borgData.getMetadata()
      let borderSize = Float(metadata.overlap + 1) / SIMD3<Float>(Float(metadata.width), Float(metadata.height), Float(metadata.depth))
      let clipMin = sharedAppModel.clipMin + borderSize
      let clipMax = sharedAppModel.clipMax - borderSize

      let clipScale = (clipMax - clipMin)
      let clipMatrix = Transform(
        scale: clipScale,
        translation: 0.5 * (clipMax + clipMin - 1)
      ).matrix

      self.lastOriginFromDevice = originFromDevice
      self.lastModelMatrix = modelMatrix
      self.lastUnscaledModelMatrix = unscaledModelMatrix
      self.lastClipMatrix = clipMatrix

      return (
        VertexUniforms(modelViewProjectionMatrix: projection * viewMatrix * modelMatrix * clipMatrix,
                       clipMatrix: clipMatrix),
        FragmentUniforms(
          isoValue: sharedAppModel.isoValue,
          oversampling: activeOversampling,
          sampleJitter: storedAppModel.sampleJitter ? 1 : 0,
          transferBias: sharedAppModel.transferFunction.textureBias,
          cameraPosInTextureSpace: simd_make_float3(viewToTexture * simd_float4(0, 0, 0, 1)),
          cameraPosInTextureSpaceVoxelScaled: simd_make_float3(viewToTextureVoxelScaled * simd_float4(0, 0, 0, 1)),
          cubeBounds: (clipMin, clipMax),
          lightDirection: SIMD4<Float>(sharedAppModel.lightDirection, 0),
          ambientLightColor: SIMD4<Float>(sharedAppModel.ambientLightColor, 0),
          diffuseLightColor: SIMD4<Float>(sharedAppModel.diffuseLightColor, 0),
          specularLightColor: SIMD4<Float>(sharedAppModel.specularLightColor, 0),
          modelView: viewMatrix * modelMatrix,
          modelViewIT: simd_transpose(simd_inverse(viewMatrix * modelMatrix)),
          textureToClip: projection * viewMatrix * modelMatrix * Transform(
            translation: SIMD3<Float>(repeating: -0.5)
          ).matrix
        )
      )
    }

    (uniformBufferVertex.current.uniforms.0, uniformBufferFragment.current.uniforms.0) = uniforms(forViewIndex: 0)
    if drawable.views.count > 1 {
      (uniformBufferVertex.current.uniforms.1, uniformBufferFragment.current.uniforms.1) = uniforms(forViewIndex: 1)
    }
    currentTextureToClipMatrices = drawable.views.indices.map { index in
      index == 0
        ? uniformBufferFragment.current.uniforms.0.textureToClip
        : uniformBufferFragment.current.uniforms.1.textureToClip
    }
    currentWorldToClipMatrices = drawable.views.indices.map { index in
      let viewMatrix = (originFromDevice * drawable.views[index].transform).inverse
      return drawable.computeProjection(viewIndex: index) * viewMatrix
    }

    switch sharedAppModel.renderMode {
      case .transferFunction1D, .transferFunction1DLighting:
        volumeAtlas.updateEmptiness(transferFunction: sharedAppModel.transferFunction)
      case .isoValue:
        volumeAtlas.updateEmptiness(isoValue: sharedAppModel.isoValue)
    }
  }

  func rotationYMatrix(degrees n: Float) -> simd_float4x4 {
    let radians = n * (.pi / 180)
    let cosAngle = cos(radians)
    let sinAngle = sin(radians)

    return simd_float4x4(
      SIMD4<Float>( cosAngle, 0, -sinAngle, 0),
      SIMD4<Float>(       0, 1,        0, 0),
      SIMD4<Float>( sinAngle, 0,  cosAngle, 0),
      SIMD4<Float>(       0, 0,        0, 1)
    )
  }

  /**
   Returns memoryless multisample render targets reused across frames.

   - Parameter drawable: The drawable providing the base textures.
   - Returns: A tuple with a color and depth memoryless MTLTexture.
   */
  private func memorylessRenderTargets(
    drawable: LayerRenderer.Drawable,
    interactionDepthResolveTexture: MTLTexture
  ) -> (color: MTLTexture, depth: MTLTexture, interactionDepth: MTLTexture) {

    func renderTarget(resolveTexture: MTLTexture, cachedTexture: MTLTexture?) -> MTLTexture {
      if let cachedTexture,
         resolveTexture.width == cachedTexture.width && resolveTexture.height == cachedTexture.height {
        return cachedTexture
      } else {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: resolveTexture.pixelFormat,
                                                                  width: resolveTexture.width,
                                                                  height: resolveTexture.height,
                                                                  mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.textureType = .type2DMultisampleArray
        descriptor.sampleCount = rasterSampleCount
        descriptor.storageMode = .memoryless
        descriptor.arrayLength = resolveTexture.arrayLength
        return resolveTexture.device.makeTexture(descriptor: descriptor)!
      }
    }

    currentRenderTargetIndex = (currentRenderTargetIndex + 1) % runtimeAppModel.maxBuffersInFlight

    let cachedTargets = memorylessTargets[currentRenderTargetIndex]
    let newTargets = (
      renderTarget(
        resolveTexture: drawable.colorTextures[0],
        cachedTexture: cachedTargets?.color
      ),
      renderTarget(
        resolveTexture: drawable.depthTextures[0],
        cachedTexture: cachedTargets?.depth
      ),
      renderTarget(
        resolveTexture: interactionDepthResolveTexture,
        cachedTexture: cachedTargets?.interactionDepth
      )
    )

    memorylessTargets[currentRenderTargetIndex] = newTargets

    return newTargets
  }

  private func interactionDepthTexture(drawable: LayerRenderer.Drawable) -> MTLTexture {
    currentInteractionDepthIndex =
      (currentInteractionDepthIndex + 1) % runtimeAppModel.maxBuffersInFlight
    let source = drawable.colorTextures[0]
    let viewCount = max(drawable.views.count, 1)
    if let texture = interactionDepthTextures[currentInteractionDepthIndex],
       texture.width == source.width,
       texture.height == source.height,
       texture.arrayLength == viewCount {
      return texture
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r32Float,
      width: source.width,
      height: source.height,
      mipmapped: false
    )
    descriptor.textureType = .type2DArray
    descriptor.arrayLength = viewCount
    descriptor.storageMode = .shared
    descriptor.usage = .renderTarget
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      fatalError("Failed to create the volume interaction-depth texture")
    }
    texture.label = "Volume Interaction Depth \(currentInteractionDepthIndex)"
    interactionDepthTextures[currentInteractionDepthIndex] = texture
    return texture
  }

  private func markerRenderTargets(drawable: LayerRenderer.Drawable) -> (color: MTLTexture, depth: MTLTexture) {
    let source = drawable.colorTextures[0]
    let viewCount = max(drawable.views.count, 1)

    let needsNewColor = markerColorTexture == nil ||
      markerColorTexture!.width != source.width ||
      markerColorTexture!.height != source.height ||
      markerColorTexture!.arrayLength != viewCount
    if needsNewColor {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: layerRenderer.configuration.colorFormat,
        width: source.width,
        height: source.height,
        mipmapped: false
      )
      descriptor.textureType = .type2DArray
      descriptor.arrayLength = viewCount
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      markerColorTexture = device.makeTexture(descriptor: descriptor)
      markerColorTexture?.label = "Volume Marker Color"
    }

    let needsNewDepth = markerDepthTexture == nil ||
      markerDepthTexture!.width != source.width ||
      markerDepthTexture!.height != source.height ||
      markerDepthTexture!.arrayLength != viewCount
    if needsNewDepth {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: layerRenderer.configuration.depthFormat,
        width: source.width,
        height: source.height,
        mipmapped: false
      )
      descriptor.textureType = .type2DArray
      descriptor.arrayLength = viewCount
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      markerDepthTexture = device.makeTexture(descriptor: descriptor)
      markerDepthTexture?.label = "Volume Marker Depth"
    }

    return (markerColorTexture!, markerDepthTexture!)
  }

  private func bindRasterizationRateMap(_ rateMap: MTLRasterizationRateMap?,
                                        to renderEncoder: MTLRenderCommandEncoder) {
    guard let rateMap else { return }

    let sizeAndAlign = rateMap.parameterDataSizeAndAlign
    let bufferLength = rasterizationRateMapBuffer?.length ?? 0
    if bufferLength < sizeAndAlign.size {
      rasterizationRateMapBuffer = device.makeBuffer(length: sizeAndAlign.size, options: .storageModeShared)
      rasterizationRateMapBuffer?.label = "Rasterization Rate Map Parameters"
    }

    guard let rasterizationRateMapBuffer else { return }
    rateMap.copyParameterData(buffer: rasterizationRateMapBuffer, offset: 0)
    renderEncoder.setFragmentBuffer(rasterizationRateMapBuffer,
                                    offset: 0,
                                    index: FragmentBufferIndex.rateMap.rawValue)
  }

  /**
   Reads back the GPU hash table and pages in missing bricks.

   - Parameter commandBuffer: The command buffer from the current frame.
   */
  func readBackHashTable(commandBuffer: MTLCommandBuffer) {
    let missingBricks = hashTable.getValues(from: commandBuffer)

    if !missingBricks.isEmpty {
      let intArray = missingBricks.map { Int($0) }.sorted(by: >)
      let metadata = borgData.getMetadata()

      for entry in intArray {
        for level in (1..<metadata.levelMetadata.count).reversed() {
          if entry > metadata.levelMetadata[level].prevBricks {
            break
          }
        }
      }

      try? volumeAtlas.pageIn(IDs: intArray)
    }
  }


  /**
   Updates performance counters and appends results to the performance model history.
   */
  func updatePerformanceCounters() {
    timer.frameRendered()

    let last = timer.lastFPS
    let avg = timer.averageFPS
    let smoothed = timer.smoothedFPS

    if autoRotationAngle > 0 {
      if autoRotationAngle == 1 {
        autoRotationStartTime = CACurrentMediaTime()
      }
      autoRotationAngle += 1
      if autoRotationAngle >= 360 {
        let autoRotationEndTime = CACurrentMediaTime()
        let rotationDuration = autoRotationEndTime - autoRotationStartTime
        autoRotationAngle = 0
        self.logger?.info("Rotation Complete. Total time to complete rotation: \(rotationDuration) seconds. Avergage time per frame: \(rotationDuration / 0.360) ms")
      }
    }

    DispatchQueue.main.async {
      self.runtimeAppModel.performanceModel.history.recoveryThreshold = Double(self.recoveryFPS)
      self.runtimeAppModel.performanceModel.history.dropThreshold = Double(self.dropFPS)
      self.runtimeAppModel.performanceModel.history.add(last: last,
                                                 avg: avg,
                                                 smoothed: smoothed,
                                                 samplingRate: Double(self.activeOversampling),
                                                 baseSamplingRate: Double(self.initialOversampling))

      if self.runtimeAppModel.startRotationCapture {
        self.logger?.info("Start Rotation")
        self.autoRotationAngle = 1
        self.runtimeAppModel.startRotationCapture = false
      }

      if self.runtimeAppModel.logPerformance {
        struct State {
          static var lastTime = CACurrentMediaTime()
        }

        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - State.lastTime

        if elapsed >= 2.0 {
          self.logger?
            .info("Last FPS: \(last), Avg FPS: \(avg), Smoothed FPS: \(smoothed)")
          State.lastTime = currentTime
        }
      }
    }
  }

  // MARK: Render Function

  func updateDynamicBufferState() {
    uniformBufferVertex.advance()
    uniformBufferFragment.advance()
  }

  

  private func renderTransferfunction(_ renderEncoder: MTLRenderCommandEncoder,
                                      drawable: LayerRenderer.Drawable) {
    renderEncoder.pushDebugGroup("Transfer Function Panel (3D)")

    renderEncoder.setRenderPipelineState(pipelineStateTFHUD)   // keep your name or rename
    renderEncoder.setCullMode(.none)
    renderEncoder.setDepthStencilState(depthStateHUD)
    do {
      try sharedAppModel.transferFunction.bind(to: renderEncoder, index: 0)
    } catch {
      logger?.error("Failed to bind TF texture for panel: \(error)")
    }

    let viewCount = drawable.views.count
    var mvp = [simd_float4x4](repeating: matrix_identity_float4x4, count: viewCount)

    var panelSize : SIMD2<Float>
    var panelWorldForPicking = tfPanelWorldMatrix
    if storedAppModel.tfMode == TransferFunctionDisplayMode.HUD.rawValue {
      for i in 0..<viewCount {
        let view = drawable.views[i]
        let viewMatrix = (lastOriginFromDevice * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: i)
        mvp[i] = projection * viewMatrix * tfPanelWorldMatrix
      }
      panelSize = tfPanelSizeMeters
      panelWorldForPicking = tfPanelWorldMatrix
    } else {
      // --- Compute panel transform for Object mode ---
      let worldUp = SIMD3<Float>(0, 1, 0)

      // If you want it under the clipped volume, include clipMatrix.
      // If you want it under the full dataset bounds, use lastModelMatrix only.
      let volumeXform = lastModelMatrix * lastClipMatrix

      let volCenter = translation3(volumeXform)
      let volWidth  = length3(volumeXform.columns.0)  // world width of the cube
      let volHeight = length3(volumeXform.columns.1)

      // Panel size derived from volume width (tune clamps/ratios)
      let panelWidth  = clamp(volWidth * 1.05, 0.25, 1.20)
      let panelHeight = panelWidth * 0.35
      panelSize = SIMD2<Float>(panelWidth, panelHeight)

      // Position: under the volume bottom, with margin
      let margin: Float = 0.08
      let bottomCenter = volCenter - worldUp * (0.5 * volHeight)
      let panelPos = bottomCenter - worldUp * (margin + 0.5 * panelHeight)

      // Billboard toward the viewer. Full billboarding keeps the local panel tilt
      // visually stable when the object is moved up, down, or deeper into the scene.
      let (billboard, forward) = makeBillboardMatrix(position: panelPos,
                                                     camera: lastHeadPosition,
                                                     up: worldUp,
                                                     cylindrical: false)

      // Optional: push slightly toward the camera to avoid depth fighting with the volume
      let pushTowardCamera: Float = 0.005
      var panelWorld = billboard
      panelWorld.columns.3.x += forward.x * pushTowardCamera
      panelWorld.columns.3.y += forward.y * pushTowardCamera
      panelWorld.columns.3.z += forward.z * pushTowardCamera
      panelWorldForPicking = panelWorld

      for i in 0..<viewCount {
        let view = drawable.views[i]
        let viewMatrix = (lastOriginFromDevice * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: i)
        mvp[i] = projection * viewMatrix * panelWorld
      }
    }

    transferFunctionPanelInteractionState.updatePanel(
      matrix: panelWorldForPicking,
      size: panelSize,
      isVisible: true
    )

    // buffer(20): mvp array
    mvp.withUnsafeBytes { bytes in
      renderEncoder.setVertexBytes(bytes.baseAddress!,
                                   length: bytes.count,
                                   index: 20)
    }

    renderEncoder.setVertexBytes(&panelSize,
                                 length: MemoryLayout<SIMD2<Float>>.stride,
                                 index: 21)
    let panelInteractionShaderState = transferFunctionPanelInteractionState.shaderState()
    var isFocused: UInt32 = panelInteractionShaderState.isFocused ? 1 : 0
    var hitUV = SIMD4<Float>(
      panelInteractionShaderState.hitUV?.x ?? 0,
      panelInteractionShaderState.hitUV?.y ?? 0,
      panelInteractionShaderState.hitUV == nil ? 0 : panelInteractionShaderState.hitOpacity,
      0
    )
    var channelMask = panelInteractionShaderState.channelMask
    renderEncoder.setFragmentBytes(&panelSize,
                                   length: MemoryLayout<SIMD2<Float>>.stride,
                                   index: 21)
    renderEncoder.setFragmentBytes(&isFocused,
                                   length: MemoryLayout<UInt32>.stride,
                                   index: 22)
    renderEncoder.setFragmentBytes(&hitUV,
                                   length: MemoryLayout<SIMD4<Float>>.stride,
                                   index: 23)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.setRenderPipelineState(pipelineStateTFHUDControls)
    renderEncoder.setVertexBytes(&panelSize,
                                 length: MemoryLayout<SIMD2<Float>>.stride,
                                 index: 21)
    renderEncoder.setFragmentBytes(&channelMask,
                                   length: MemoryLayout<UInt32>.stride,
                                   index: 24)
    renderEncoder.drawPrimitives(type: .triangle,
                                 vertexStart: 0,
                                 vertexCount: 6,
                                 instanceCount: 4)
    renderEncoder.popDebugGroup()
  }

  private func drawSceneMeshes(
    _ instances: [SceneMeshInstance],
    datasetMaximumExtentMeters: Float,
    renderEncoder: MTLRenderCommandEncoder
  ) {
    sceneMeshGPUCache.retainOnly(assetIDs: Set(instances.map(\.asset.assetID)))
    guard datasetMaximumExtentMeters.isFinite, datasetMaximumExtentMeters > 0 else { return }

    renderEncoder.pushDebugGroup("Scene Meshes")
    renderEncoder.setRenderPipelineState(pipelineStateSceneMesh)
    renderEncoder.setDepthStencilState(depthStateMarker)
    renderEncoder.setCullMode(.back)
    for instance in instances where instance.isVisible {
      guard let asset = sharedAppModel.sceneMeshAssets[instance.asset.assetID],
            let gpuAsset = sceneMeshGPUCache.asset(for: asset, device: device) else {
        continue
      }
      var modelMatrix = lastUnscaledModelMatrix *
        matrixScale(SIMD3<Float>(repeating: 1 / datasetMaximumExtentMeters)) *
        instance.transformMeters
      var baseColor = asset.baseColor
      renderEncoder.setVertexBuffer(
        gpuAsset.vertexBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &baseColor,
        length: MemoryLayout<SIMD3<Float>>.stride,
        index: 23
      )
      renderEncoder.setFragmentTexture(
        gpuAsset.texture ?? sceneMeshWhiteTexture,
        index: TextureIndex.sceneMeshColor.rawValue
      )
      renderEncoder.drawIndexedPrimitives(
        type: .triangle,
        indexCount: gpuAsset.indexCount,
        indexType: .uint32,
        indexBuffer: gpuAsset.indexBuffer,
        indexBufferOffset: 0
      )
    }
    renderEncoder.popDebugGroup()
  }

  private func drawOpaqueGeometry(_ renderEncoder: MTLRenderCommandEncoder,
                                  drawable: LayerRenderer.Drawable) -> [ScreenViewLabelDescriptor] {
    let screenViews = screenViewVisualization()
    let measurementSnapshot = sharedAppModel.volumeMeasurementsSnapshot()
    let measurements = measurementVisualization(measurements: measurementSnapshot)
    let pendingProjectionCaptureMarkerIDs =
      immersiveInteraction.pendingStrokeProjectionCaptureMarkerIDs()
    let suppressLocalToolWidgets = !pendingProjectionCaptureMarkerIDs.isEmpty
    let markers = (sharedAppModel.volumeMarkers + screenViews.markers).filter {
      !pendingProjectionCaptureMarkerIDs.contains($0.id)
    }
    let toolWidgetMarkers = suppressLocalToolWidgets
      ? []
      : spatialStylusMeasurementPreviewMarkers + spatialControllerModePreviewMarkers
    let sceneMeshInstances = sharedAppModel.sceneMeshInstances +
      (suppressLocalToolWidgets ? [] : spatialSceneObjectPreviewInstances)
    let remoteToolPreviews = sharedAppModel.activeRemoteSpatialToolPreviews()
    guard !markers.isEmpty || !measurements.points.isEmpty ||
      !measurements.lines.isEmpty || !screenViews.labels.isEmpty ||
      !measurements.surfaces.isEmpty ||
      !sceneMeshInstances.isEmpty ||
      (!suppressLocalToolWidgets && spatialStylusPreviewPoint != nil) ||
      !remoteToolPreviews.isEmpty ||
      (!suppressLocalToolWidgets && !spatialControllerSamples.isEmpty) ||
      (!suppressLocalToolWidgets && !spatialControllerPreviewPoints.isEmpty) else {
      return measurements.labels
    }

    renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
    renderEncoder.setDepthStencilState(depthStateMarker)
    renderEncoder.setCullMode(.back)
    renderEncoder.setFrontFacing(.counterClockwise)

    let viewCount = drawable.views.count
    guard viewCount > 0 else { return measurements.labels }
    var mvp = [simd_float4x4](repeating: matrix_identity_float4x4, count: viewCount)
    var eyePositions = [SIMD3<Float>](repeating: .zero, count: viewCount)
    for i in 0..<viewCount {
      let view = drawable.views[i]
      let eyeMatrix = lastOriginFromDevice * view.transform
      let viewMatrix = eyeMatrix.inverse
      let projection = drawable.computeProjection(viewIndex: i)
      mvp[i] = projection * viewMatrix
      eyePositions[i] = SIMD3<Float>(
        eyeMatrix.columns.3.x,
        eyeMatrix.columns.3.y,
        eyeMatrix.columns.3.z
      )
    }

    func bindMarkerViewData() {
      mvp.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        renderEncoder.setVertexBytes(
          baseAddress,
          length: MemoryLayout<simd_float4x4>.stride * buffer.count,
          index: 20
        )
      }
      eyePositions.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        renderEncoder.setVertexBytes(
          baseAddress,
          length: MemoryLayout<SIMD3<Float>>.stride * buffer.count,
          index: 22
        )
      }
    }
    bindMarkerViewData()

    let physicalExtent = borgData.getMetadata().physicalExtentMeters
    let datasetMaximumExtentMeters = max(
      physicalExtent.x,
      max(physicalExtent.y, physicalExtent.z)
    )
    drawSceneMeshes(
      sceneMeshInstances,
      datasetMaximumExtentMeters: datasetMaximumExtentMeters,
      renderEncoder: renderEncoder
    )
    renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)

    renderEncoder.setVertexBuffer(
      markerSphereBuffer,
      offset: 0,
      index: VertexBufferIndex.meshPositions.rawValue
    )
    renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)

    let coordinateScale = SIMD3<Float>(
      volumeScale.columns.0.x,
      volumeScale.columns.1.y,
      volumeScale.columns.2.z
    )
    markerTubeMeshCache.retainOnly(
      markerIDs: Set((markers + toolWidgetMarkers).map(\.id))
    )
    measurementSurfaceMeshCache.retainOnly(
      measurementIDs: Set(measurementSnapshot.map(\.id))
    )

    func color(for marker: VolumeMarker) -> SIMD4<Float> {
      VolumeMarkerPresentation.color(
        for: marker,
        isSelected: sharedAppModel.selectedVolumeMarkerIDs.contains(marker.id)
      )
    }

    func drawSphere(_ point: VolumeMarkerPoint, color: SIMD4<Float>) {
      let markerVolumePosition = simd_make_float3(
        volumeScale * SIMD4<Float>(point.position - SIMD3<Float>(repeating: 0.5), 1.0)
      )
      var modelMatrix = lastUnscaledModelMatrix *
        Transform(translation: markerVolumePosition).matrix *
        Transform(scale: SIMD3<Float>(repeating: point.radius)).matrix
      var color = color
      renderEncoder.setVertexBuffer(
        markerSphereBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: markerSphereVertexCount
      )
    }

    func drawControllerPointer(_ sample: BorgSpatialInputSample) {
      var color = SIMD4<Float>(0.62, 0.65, 0.7, 1)
      var pointerMatrix = sample.aimTransform
      renderEncoder.setVertexBuffer(
        spatialControllerPointerBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(
        spatialControllerPointerNormalBuffer,
        offset: 0,
        index: 24
      )
      renderEncoder.setVertexBytes(
        &pointerMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: spatialControllerPointerVertexCount
      )

      var bodyMatrix = sample.aimTransform *
        Transform(translation: SIMD3<Float>(0, 0, 0.055)).matrix *
        Transform(scale: SIMD3<Float>(repeating: 0.015)).matrix
      renderEncoder.setVertexBuffer(
        markerSphereBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &bodyMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: markerSphereVertexCount
      )
    }

    func drawTube(for marker: VolumeMarker, color: SIMD4<Float>) {
      guard let tubeMesh = markerTubeMeshCache.mesh(
        for: marker,
        coordinateScale: coordinateScale,
        device: device
      ) else { return }
      var modelMatrix = lastUnscaledModelMatrix
      var color = color
      renderEncoder.setVertexBuffer(
        tubeMesh.positionBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(tubeMesh.normalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: tubeMesh.vertexCount
      )
    }

    func drawMarkerGeometry(_ markerGeometry: [VolumeMarker], groupName: String) {
      renderEncoder.pushDebugGroup(groupName)
      for marker in markerGeometry {
        let markerColor = color(for: marker)
        switch marker.geometry {
          case .sphere(let point):
            drawTube(for: marker, color: markerColor)
            drawSphere(point, color: markerColor)

          case .stroke(let points):
            drawTube(for: marker, color: markerColor)
            if let first = points.first {
              drawSphere(first, color: markerColor)
            }
            if points.count > 1, let last = points.last {
              drawSphere(last, color: markerColor)
            }
        }
      }
      renderEncoder.popDebugGroup()
    }

    func drawToolWidgets() {
      renderEncoder.pushDebugGroup("Spatial Tool Widgets")
      if !suppressLocalToolWidgets {
        drawMarkerGeometry(toolWidgetMarkers, groupName: "Tool Mode Glyphs")
        if spatialStylusMeasurementPreviewMarkers.isEmpty,
           let spatialStylusPreviewPoint {
          drawSphere(
            spatialStylusPreviewPoint,
            color: sharedAppModel.defaultVolumeStrokeColor
          )
        }
        for point in spatialControllerPreviewPoints {
          drawSphere(point, color: sharedAppModel.defaultVolumeStrokeColor)
        }
        for sample in spatialControllerSamples {
          drawControllerPointer(sample)
        }
      }
      for preview in remoteToolPreviews {
        drawSphere(preview.point, color: preview.color)
      }
      renderEncoder.popDebugGroup()
    }

    drawMarkerGeometry(markers, groupName: "Markers")
    drawToolWidgets()

    func drawMeasurements() {
      renderEncoder.pushDebugGroup("Measurements")
      if !measurements.points.isEmpty {
        let byteCount = MemoryLayout<MeasurementPointRenderInstance>.stride *
          measurements.points.count
        if measurementPointBuffer == nil || measurementPointBufferCapacity < byteCount {
          var capacity = max(measurementPointBufferCapacity, 4096)
          while capacity < byteCount {
            capacity *= 2
          }
          measurementPointBuffer = device.makeBuffer(
            length: capacity,
            options: .storageModeShared
          )
          measurementPointBufferCapacity = capacity
          measurementPointBuffer?.label = "Measurement Point Instances"
        }
        if let measurementPointBuffer {
          measurements.points.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            measurementPointBuffer.contents().copyMemory(
              from: baseAddress,
              byteCount: bytes.count
            )
          }
          var modelMatrix = lastUnscaledModelMatrix
          let viewportSizes = drawable.views.map { view in
            SIMD2<Float>(
              Float(view.textureMap.viewport.width),
              Float(view.textureMap.viewport.height)
            )
          }
          renderEncoder.setRenderPipelineState(pipelineStateMeasurementPoint)
          renderEncoder.setDepthStencilState(depthStateMarker)
          renderEncoder.setCullMode(.none)
          bindMarkerViewData()
          renderEncoder.setVertexBytes(
            &modelMatrix,
            length: MemoryLayout<simd_float4x4>.stride,
            index: 21
          )
          renderEncoder.setVertexBuffer(measurementPointBuffer, offset: 0, index: 25)
          viewportSizes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            renderEncoder.setVertexBytes(
              baseAddress,
              length: MemoryLayout<SIMD2<Float>>.stride * buffer.count,
              index: 26
            )
          }
          renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: measurements.points.count
          )
        }
      }
      if !measurements.lines.isEmpty {
      let byteCount = MemoryLayout<MeasurementVisualization.Line>.stride *
        measurements.lines.count
      if measurementLineBuffer == nil || measurementLineBufferCapacity < byteCount {
        var capacity = max(measurementLineBufferCapacity, 4096)
        while capacity < byteCount {
          capacity *= 2
        }
        measurementLineBuffer = device.makeBuffer(
          length: capacity,
          options: .storageModeShared
        )
        measurementLineBuffer?.label = "Measurement Line Instances"
        measurementLineBufferCapacity = capacity
      }
      if let measurementLineBuffer {
        measurements.lines.withUnsafeBytes { bytes in
          if let baseAddress = bytes.baseAddress {
            measurementLineBuffer.contents().copyMemory(
              from: baseAddress,
              byteCount: bytes.count
            )
          }
        }
        var modelMatrix = lastUnscaledModelMatrix
        let viewportSizes = drawable.views.map { view in
          SIMD2<Float>(
            Float(view.textureMap.viewport.width),
            Float(view.textureMap.viewport.height)
          )
        }
        renderEncoder.setRenderPipelineState(pipelineStateMeasurementLine)
        renderEncoder.setDepthStencilState(depthStateMarker)
        renderEncoder.setCullMode(.none)
        bindMarkerViewData()
        renderEncoder.setVertexBytes(
          &modelMatrix,
          length: MemoryLayout<simd_float4x4>.stride,
          index: 21
        )
        renderEncoder.setVertexBuffer(measurementLineBuffer, offset: 0, index: 25)
        viewportSizes.withUnsafeBufferPointer { buffer in
          guard let baseAddress = buffer.baseAddress else { return }
          renderEncoder.setVertexBytes(
            baseAddress,
            length: MemoryLayout<SIMD2<Float>>.stride * buffer.count,
            index: 26
          )
        }
        renderEncoder.drawPrimitives(
          type: .triangle,
          vertexStart: 0,
          vertexCount: 6,
          instanceCount: measurements.lines.count
        )
      }
    }

    let surfaceMeshes = measurements.surfaces.compactMap { surface -> (
      surface: MeasurementVisualization.Surface,
      mesh: MeasurementSurfaceGPUMesh
    )? in
      guard let mesh = measurementSurfaceMeshCache.mesh(
        for: surface.measurement,
        coordinateScale: coordinateScale,
        device: device
      ) else { return nil }
      return (surface, mesh)
    }

    func drawSurface(
      _ mesh: MeasurementSurfaceGPUMesh,
      color: SIMD4<Float>,
      cullMode: MTLCullMode,
      depthStencilState: MTLDepthStencilState
    ) {
      guard mesh.vertexCount >= 3, mesh.vertexCount.isMultiple(of: 3) else { return }
      var modelMatrix = lastUnscaledModelMatrix
      var color = color
      renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
      renderEncoder.setDepthStencilState(depthStencilState)
      renderEncoder.setCullMode(cullMode)
      // Labels use slot 22 for their float2 size. Restore the marker shader's
      // per-view eye positions before every draw that follows a label.
      bindMarkerViewData()
      renderEncoder.setVertexBuffer(
        mesh.positionBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(mesh.normalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: mesh.vertexCount
      )
    }

    // A ray through a convex hull sees at most one exit and one entry surface.
    // Rendering back faces before front faces is therefore deterministic and
    // does not rely on ambiguous triangle-centroid sorting.
    for entry in surfaceMeshes {
      if entry.surface.measurement.kind == .volume {
        drawSurface(
          entry.mesh,
          color: entry.surface.color,
          cullMode: .front,
          depthStencilState: depthStateMarkerReadOnly
        )
        drawSurface(
          entry.mesh,
          color: entry.surface.color,
          cullMode: .back,
          depthStencilState: depthStateMarkerReadOnly
        )
      } else {
        drawSurface(
          entry.mesh,
          color: entry.surface.color,
          cullMode: .none,
          depthStencilState: depthStateMarkerReadOnly
        )
      }
    }

    // Preserve the closest transparent surface depth for volume compositing without
    // blending every surface a second time.
    let transparentDepthColor = SIMD4<Float>(0, 0, 0, 0)
    for entry in surfaceMeshes {
      drawSurface(
        entry.mesh,
        color: transparentDepthColor,
        cullMode: .none,
        depthStencilState: depthStateMarker
      )
    }
      renderEncoder.setCullMode(.back)
      renderEncoder.popDebugGroup()
    }

    drawMeasurements()

    drawScreenViewLabels(
      screenViews.labels,
      renderEncoder: renderEncoder,
      depthStencilState: depthStateMarker,
      pipelineState: pipelineStateScreenViewLabel
    )
    return measurements.labels
  }

  private func drawScreenViewLabels(
    _ labels: [ScreenViewLabelDescriptor],
    renderEncoder: MTLRenderCommandEncoder,
    depthStencilState: MTLDepthStencilState,
    pipelineState: MTLRenderPipelineState
  ) {
    guard !labels.isEmpty else { return }

    for label in labels {
      drawScreenViewLabel(
        label,
        renderEncoder: renderEncoder,
        depthStencilState: depthStencilState,
        pipelineState: pipelineState
      )
    }
  }

  private func screenViewLabelWorldPosition(
    _ label: ScreenViewLabelDescriptor
  ) -> SIMD3<Float> {
    let volumePosition = simd_make_float3(
      volumeScale * SIMD4<Float>(label.position - SIMD3<Float>(repeating: 0.5), 1)
    )
    var worldPosition = simd_make_float3(
      lastUnscaledModelMatrix * SIMD4<Float>(volumePosition, 1)
    )
    guard worldPosition.x.isFinite, worldPosition.y.isFinite, worldPosition.z.isFinite else {
      return lastHeadPosition
    }
    if label.depthOffsetTowardCamera > 0 {
      let cameraDirection = lastHeadPosition - worldPosition
      let lengthSquared = simd_length_squared(cameraDirection)
      if lengthSquared.isFinite, lengthSquared > 0.000_000_1 {
        worldPosition += cameraDirection / sqrt(lengthSquared) * label.depthOffsetTowardCamera
      }
    }
    return worldPosition
  }

  private func drawScreenViewLabel(
    _ label: ScreenViewLabelDescriptor,
    renderEncoder: MTLRenderCommandEncoder,
    depthStencilState: MTLDepthStencilState,
    pipelineState: MTLRenderPipelineState
  ) {

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setDepthStencilState(depthStencilState)
    renderEncoder.setCullMode(.none)

    guard let labelTexture = screenViewLabelTextureCache.texture(
      for: label.text,
      accentColor: label.color,
      opaqueBackground: label.opaqueBackground,
      device: device
    ) else { return }

    let worldPosition = screenViewLabelWorldPosition(label)
    var modelMatrix = makeBillboardMatrix(
      position: worldPosition,
      camera: lastHeadPosition,
      up: SIMD3<Float>(0, 1, 0),
      cylindrical: false
    ).0
    modelMatrix.columns.3 += modelMatrix.columns.0 * label.billboardOffset.x +
      modelMatrix.columns.1 * label.billboardOffset.y
    let labelHeight = label.height
    var labelSize = SIMD2<Float>(
      min(labelHeight * labelTexture.aspectRatio, 0.36),
      labelHeight
    )

    renderEncoder.setVertexBytes(
      &modelMatrix,
      length: MemoryLayout<simd_float4x4>.stride,
      index: 21
    )
    renderEncoder.setVertexBytes(
      &labelSize,
      length: MemoryLayout<SIMD2<Float>>.stride,
      index: 22
    )
    renderEncoder.setFragmentTexture(
      labelTexture.texture,
      index: TextureIndex.screenViewLabel.rawValue
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
  }

  private func screenViewVisualization() -> ScreenViewVisualization {
    let screenParticipants = sharedAppModel.sharePlayParticipants.filter {
      $0.platform == .iOS || $0.platform == .macOS
    }
    guard !screenParticipants.isEmpty else { return ScreenViewVisualization() }

    var result = ScreenViewVisualization()
    if let state = sharedAppModel.screenSharePlayViewState {
      let sharedView = screenViewVisualizationMarkers(
        state: state,
        markerID: nil,
        name: String(localized: "Shared View"),
        color: ScreenViewPresentation.sharedColor,
        interactionActive: sharedAppModel.screenViewInteractionActive
      )
      result.markers += sharedView.markers
      if sharedAppModel.screenViewNamesVisible {
        result.labels.append(sharedView.label)
      }
    }

    let detachedParticipants = screenParticipants.filter {
      sharedAppModel.detachedScreenSharePlayViewStates[$0.id] != nil
    }
    for participant in detachedParticipants {
      guard let state = sharedAppModel.detachedScreenSharePlayViewStates[participant.id] else {
        continue
      }
      let detachedView = screenViewVisualizationMarkers(
        state: state,
        markerID: participant.id,
        name: participant.displayName,
        color: ScreenViewPresentation.detachedColor(for: participant.id),
        interactionActive: false
      )
      result.markers += detachedView.markers
      if sharedAppModel.screenViewNamesVisible {
        result.labels.append(detachedView.label)
      }
    }
    return result
  }

  private func screenViewVisualizationMarkers(
    state: BorgVRScreenViewState,
    markerID: UUID?,
    name: String,
    color: SIMD4<Float>,
    interactionActive: Bool
  ) -> (markers: [VolumeMarker], label: ScreenViewLabelDescriptor) {
    func id(_ index: Int) -> UUID {
      guard let markerID else {
        return Self.screenViewVisualizationMarkerIDs[index]
      }
      var uuid = markerID.uuid
      withUnsafeMutableBytes(of: &uuid) { bytes in
        bytes[14] ^= UInt8(truncatingIfNeeded: index >> 8)
        bytes[15] ^= UInt8(truncatingIfNeeded: index)
      }
      return UUID(uuid: uuid)
    }

    let aspect = min(max(state.viewportAspectRatio, 0.25), 4)
    let fieldOfView = min(max(state.verticalFieldOfView, 0.2), 2.6)
    let nearDistance: Float = 0.12
    let farDistance: Float = 3.6
    let cameraDistance = BorgVRScreenViewState.cameraDistance

    let screenFromVolume =
      Transform(translation: SIMD3<Float>(state.pan.x, state.pan.y, 0)).matrix *
      simd_float4x4(state.orientation) *
      Transform(scale: SIMD3<Float>(repeating: state.scale)).matrix *
      volumeScale
    let volumeFromScreen = simd_inverse(screenFromVolume)

    func volumePoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
      let transformed = volumeFromScreen * SIMD4<Float>(point, 1)
      return SIMD3<Float>(transformed.x, transformed.y, transformed.z) / transformed.w +
        SIMD3<Float>(repeating: 0.5)
    }

    func planeCorners(distance: Float) -> [SIMD3<Float>] {
      let halfHeight = distance * tan(fieldOfView * 0.5)
      let halfWidth = halfHeight * aspect
      let z = cameraDistance - distance
      return [
        volumePoint(SIMD3<Float>(-halfWidth, -halfHeight, z)),
        volumePoint(SIMD3<Float>( halfWidth, -halfHeight, z)),
        volumePoint(SIMD3<Float>( halfWidth,  halfHeight, z)),
        volumePoint(SIMD3<Float>(-halfWidth,  halfHeight, z))
      ]
    }

    let nearHalfHeight = nearDistance * tan(fieldOfView * 0.5)
    let labelPosition = volumePoint(SIMD3<Float>(
      0,
      nearHalfHeight + 0.052,
      cameraDistance - nearDistance
    ))
    let label = ScreenViewLabelDescriptor(text: name, color: color, position: labelPosition)

    let lineRadius: Float = 0.002

    if !interactionActive {
      let screenCorners = planeCorners(distance: nearDistance)
      var result = (0..<4).map { index in
        VolumeMarker(
          id: id(index),
          name: name,
          color: color,
          geometry: .stroke([
            VolumeMarkerPoint(position: screenCorners[index], radius: 0.004),
            VolumeMarkerPoint(position: screenCorners[(index + 1) % 4], radius: 0.004)
          ])
        )
      }

      let eyeZ = cameraDistance + 0.035
      let eyeWidth: Float = 0.085
      let eyeHeight: Float = 0.038
      let upperEye = (0...8).map { index -> VolumeMarkerPoint in
        let t = Float(index) / 8
        return VolumeMarkerPoint(
          position: volumePoint(SIMD3<Float>(
            (t - 0.5) * eyeWidth,
            sin(t * .pi) * eyeHeight,
            eyeZ
          )),
          radius: 0.003
        )
      }
      let lowerEye = (0...8).map { index -> VolumeMarkerPoint in
        let t = Float(index) / 8
        return VolumeMarkerPoint(
          position: volumePoint(SIMD3<Float>(
            (t - 0.5) * eyeWidth,
            -sin(t * .pi) * eyeHeight,
            eyeZ
          )),
          radius: 0.003
        )
      }
      result.append(VolumeMarker(
        id: id(4),
        name: name,
        color: color,
        geometry: .stroke(upperEye)
      ))
      result.append(VolumeMarker(
        id: id(5),
        name: name,
        color: color,
        geometry: .stroke(lowerEye)
      ))
      result.append(VolumeMarker(
        id: id(6),
        name: name,
        color: color,
        geometry: .sphere(VolumeMarkerPoint(
          position: volumePoint(SIMD3<Float>(0, 0, eyeZ - 0.006)),
          radius: 0.012
        ))
      ))
      return (result, label)
    }

    let near = planeCorners(distance: nearDistance)
    let far = planeCorners(distance: farDistance)
    let edges = [
      (near[0], near[1]), (near[1], near[2]),
      (near[2], near[3]), (near[3], near[0]),
      (far[0], far[1]), (far[1], far[2]),
      (far[2], far[3]), (far[3], far[0]),
      (near[0], far[0]), (near[1], far[1]),
      (near[2], far[2]), (near[3], far[3])
    ]
    var result = edges.enumerated().map { index, edge in
      VolumeMarker(
        id: id(index),
        name: name,
        color: color,
        geometry: .stroke([
          VolumeMarkerPoint(position: edge.0, radius: lineRadius),
          VolumeMarkerPoint(position: edge.1, radius: lineRadius)
        ])
      )
    }
    result.append(VolumeMarker(
      id: id(12),
      name: name,
      color: color,
      geometry: .sphere(VolumeMarkerPoint(
        position: volumePoint(SIMD3<Float>(0, 0, cameraDistance)),
        radius: 0.018
      ))
    ))
    return (result, label)
  }

  private func renderOpaqueGeometry(commandBuffer: MTLCommandBuffer,
                                    drawable: LayerRenderer.Drawable,
                                    rasterizationRateMap: MTLRasterizationRateMap?) -> (
    color: MTLTexture,
    depth: MTLTexture,
    measurementLabels: [ScreenViewLabelDescriptor]
  ) {
    let targets = markerRenderTargets(drawable: drawable)
    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = targets.color
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].storeAction = .store
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    renderPassDescriptor.depthAttachment.texture = targets.depth
    renderPassDescriptor.depthAttachment.loadAction = .clear
    renderPassDescriptor.depthAttachment.storeAction = .store
    renderPassDescriptor.depthAttachment.clearDepth = 0.0
    renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
    if layerRenderer.configuration.layout == .layered {
      renderPassDescriptor.renderTargetArrayLength = drawable.views.count
    }

    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      fatalError("Failed to create marker prepass encoder")
    }
    renderEncoder.label = "BorgVR Opaque Geometry Prepass"
    renderEncoder.pushDebugGroup("Opaque Geometry Prepass")

    let viewports = drawable.views.map { $0.textureMap.viewport }
    renderEncoder.setViewports(viewports)

    if drawable.views.count > 1 {
      var viewMappings = (0..<drawable.views.count).map {
        MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                          renderTargetArrayIndexOffset: UInt32($0))
      }
      renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
    }

    let measurementLabels = drawOpaqueGeometry(renderEncoder, drawable: drawable)

    renderEncoder.popDebugGroup()
    renderEncoder.endEncoding()
    return (targets.color, targets.depth, measurementLabels)
  }

  private func drawMeasurementLabelsOnScreen(
    _ labels: [ScreenViewLabelDescriptor],
    renderEncoder: MTLRenderCommandEncoder,
    drawable: LayerRenderer.Drawable
  ) {
    guard !labels.isEmpty, !drawable.views.isEmpty else { return }
    let mvp = drawable.views.indices.map { index in
      let view = drawable.views[index]
      let eyeMatrix = lastOriginFromDevice * view.transform
      return drawable.computeProjection(viewIndex: index) * eyeMatrix.inverse
    }
    mvp.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      renderEncoder.setVertexBytes(
        baseAddress,
        length: MemoryLayout<simd_float4x4>.stride * buffer.count,
        index: 20
      )
    }
    let sortedLabels = labels.sorted {
      simd_distance_squared(screenViewLabelWorldPosition($0), lastHeadPosition) >
        simd_distance_squared(screenViewLabelWorldPosition($1), lastHeadPosition)
    }
    drawScreenViewLabels(
      sortedLabels,
      renderEncoder: renderEncoder,
      depthStencilState: depthStateMarkerComposite,
      pipelineState: pipelineStateScreenViewOverlayLabel
    )
  }

  private func compositeOpaqueGeometry(_ renderEncoder: MTLRenderCommandEncoder,
                                       colorTexture: MTLTexture,
                                       depthTexture: MTLTexture) {
    renderEncoder.pushDebugGroup("Composite Opaque Geometry")
    renderEncoder.setRenderPipelineState(pipelineStateMarkerComposite)
    renderEncoder.setDepthStencilState(depthStateMarkerComposite)
    renderEncoder.setCullMode(.none)
    renderEncoder.setFragmentTexture(
      colorTexture,
      index: TextureIndex.markerColor.rawValue
    )
    renderEncoder.setFragmentTexture(
      depthTexture,
      index: TextureIndex.markerDepth.rawValue
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    renderEncoder.popDebugGroup()
  }

  private func finishSpatialStylusStroke() {
    let completedStroke = activeSpatialStylusStrokeID != nil
    if let activeSpatialStylusStrokeID {
      immersiveInteraction.endStrokeProjectionFreeze(token: activeSpatialStylusStrokeID)
    }
    activeSpatialStylusStrokeID = nil
    spatialStylusTipFilterState = nil
    if completedStroke {
      sharedAppModel.synchronizeMarkers()
    }
  }

  private func filteredSpatialStylusTip(
    position: SIMD3<Float>,
    pressure: Float?
  ) -> (position: SIMD3<Float>, pressure: Float?) {
    guard let pressure else {
      spatialStylusTipFilterState = nil
      return (position, nil)
    }
    guard let previous = spatialStylusTipFilterState else {
      spatialStylusTipFilterState = (position, pressure)
      return (position, pressure)
    }

    let movement = simd_distance(position, previous.position)
    let positionBlend = min(0.7, max(0.18, movement / 0.003))
    let filteredPosition = previous.position +
      (position - previous.position) * positionBlend
    let pressureBlend: Float = 0.22
    let filteredPressure = previous.pressure +
      (pressure - previous.pressure) * pressureBlend
    spatialStylusTipFilterState = (filteredPosition, filteredPressure)
    return (filteredPosition, filteredPressure)
  }

  private func spatialToolPreviewPoint(
    worldPosition: SIMD3<Float>,
    radius: Float
  ) -> VolumeMarkerPoint? {
    let volumeFromOrigin = simd_inverse(lastUnscaledModelMatrix * volumeScale)
    let local = volumeFromOrigin * SIMD4<Float>(worldPosition, 1)
    guard abs(local.w) > 0.000_001 else { return nil }
    let position = SIMD3<Float>(local.x, local.y, local.z) / local.w +
      SIMD3<Float>(repeating: 0.5)
    let modelScale = simd_abs(sharedAppModel.modelTransform.scale)
    let averageModelScale = max(
      (modelScale.x + modelScale.y + modelScale.z) / 3,
      0.000_001
    )
    return VolumeMarkerPoint(
      position: simd_clamp(
        position,
        SIMD3<Float>(repeating: -8),
        SIMD3<Float>(repeating: 8)
      ),
      // Preview points originate in world space. Compensate the model scale so
      // scaling the volume does not also resize the controller or stylus tip.
      radius: radius / averageModelScale
    )
  }

  private func spatialToolGlyphPosition(
    aimTransform: simd_float4x4,
    distanceBehindTip: Float
  ) -> SIMD3<Float> {
    let position = aimTransform * SIMD4<Float>(0, 0, distanceBehindTip, 1)
    return SIMD3<Float>(position.x, position.y, position.z)
  }

  private func spatialControllerGlyphPosition(
    aimTransform: simd_float4x4
  ) -> SIMD3<Float> {
    let bodyCenter = spatialToolGlyphPosition(
      aimTransform: aimTransform,
      distanceBehindTip: 0.055
    )
    let devicePosition = SIMD3<Float>(
      lastOriginFromDevice.columns.3.x,
      lastOriginFromDevice.columns.3.y,
      lastOriginFromDevice.columns.3.z
    )
    let towardDevice = devicePosition - bodyCenter
    guard simd_length_squared(towardDevice) > 0.000_001 else { return bodyCenter }
    return bodyCenter + simd_normalize(towardDevice) * 0.017
  }

  private func stylusMeasurementPreviewMarkers(
    worldPosition: SIMD3<Float>,
    kind: VolumeMeasurementKind,
    showsPlus: Bool,
    markerIDs: [UUID]
  ) -> [VolumeMarker] {
    let right = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.0.x,
      lastOriginFromDevice.columns.0.y,
      lastOriginFromDevice.columns.0.z
    ))
    let up = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.1.x,
      lastOriginFromDevice.columns.1.y,
      lastOriginFromDevice.columns.1.z
    ))
    let forward = -simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.2.x,
      lastOriginFromDevice.columns.2.y,
      lastOriginFromDevice.columns.2.z
    ))
    let size: Float = 0.011
    var worldVertices: [SIMD3<Float>]
    var paths: [[Int]]
    switch kind {
      case .length:
        worldVertices = [worldPosition - right * size, worldPosition + right * size]
        paths = [[0, 1]]
      case .area:
        worldVertices = [
          worldPosition + up * size,
          worldPosition - up * size * 0.7 - right * size,
          worldPosition - up * size * 0.7 + right * size
        ]
        paths = [[0, 1, 2, 0]]
      case .volume:
        worldVertices = [
          worldPosition + up * size,
          worldPosition - up * size * 0.65 - right * size,
          worldPosition - up * size * 0.65 + right * size,
          worldPosition - forward * size * 1.25
        ]
        paths = [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]]
    }
    if showsPlus {
      let center = worldPosition + right * size * 1.55 + up * size * 1.15
      let arm = size * 0.34
      let startIndex = worldVertices.count
      worldVertices.append(contentsOf: [
        center - right * arm,
        center + right * arm,
        center - up * arm,
        center + up * arm
      ])
      paths.append([startIndex, startIndex + 1])
      paths.append([startIndex + 2, startIndex + 3])
    }
    let points = worldVertices.compactMap {
      spatialToolPreviewPoint(worldPosition: $0, radius: 0.0018)
    }
    guard points.count == worldVertices.count else { return [] }
    let color = measurementColor(for: kind, selected: true)
    return paths.enumerated().map { index, path in
      VolumeMarker(
        id: markerIDs[index],
        name: "Stylus measurement preview",
        color: color,
        geometry: .stroke(path.map { points[$0] })
      )
    }
  }

  private func spatialControllerToolPreviewMarkers(
    sample: BorgSpatialInputSample,
    mode: SpatialToolMode
  ) -> [VolumeMarker] {
    let markerIDs = (0..<8).map {
      measurementVisualizationID(sample.id, 0x100 + $0)
    }
    if let kind = mode.measurementKind {
      return stylusMeasurementPreviewMarkers(
        worldPosition: spatialControllerGlyphPosition(
          aimTransform: sample.aimTransform
        ),
        kind: kind,
        showsPlus: immersiveInteraction.spatialControllerWillExtendMeasurement(
          sourceID: sample.id,
          kind: kind
        ),
        markerIDs: markerIDs
      )
    }

    let right = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.0.x,
      lastOriginFromDevice.columns.0.y,
      lastOriginFromDevice.columns.0.z
    ))
    let up = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.1.x,
      lastOriginFromDevice.columns.1.y,
      lastOriginFromDevice.columns.1.z
    ))
    let forward = -simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.2.x,
      lastOriginFromDevice.columns.2.y,
      lastOriginFromDevice.columns.2.z
    ))
    let center = spatialControllerGlyphPosition(
      aimTransform: sample.aimTransform
    )
    let size: Float = 0.011
    let worldVertices: [SIMD3<Float>]
    let paths: [[Int]]
    let color: SIMD4<Float>
    switch mode {
      case .model:
        worldVertices = [
          center - right * size, center + right * size,
          center - up * size, center + up * size,
          center - forward * size, center + forward * size
        ]
        paths = [[0, 1], [2, 3], [4, 5]]
        color = SIMD4<Float>(0.15, 0.8, 1, 1)
      case .clipping:
        worldVertices = [
          center - right * size - up * size,
          center + right * size - up * size,
          center + right * size + up * size,
          center - right * size + up * size,
          center - right * size * 1.25,
          center + right * size * 1.25
        ]
        paths = [[0, 1, 2, 3, 0], [4, 5]]
        color = SIMD4<Float>(1, 0.55, 0.1, 1)
      case .marker:
        worldVertices = [
          center - right * size - up * size * 0.55,
          center - right * size * 0.25 + up * size * 0.4,
          center + right * size * 0.35 - up * size * 0.25,
          center + right * size + up * size * 0.65
        ]
        paths = [[0, 1, 2, 3]]
        color = sharedAppModel.defaultVolumeStrokeColor
      case .objectPlacement:
        return []
      case .screenView:
        worldVertices = [
          center - right * size * 1.25 - up * size * 0.75,
          center + right * size * 1.25 - up * size * 0.75,
          center + right * size * 1.25 + up * size * 0.75,
          center - right * size * 1.25 + up * size * 0.75
        ]
        paths = [[0, 1, 2, 3, 0]]
        color = SIMD4<Float>(0.2, 1, 0.55, 1)
      case .lengthMeasurement, .areaMeasurement, .volumeMeasurement:
        return []
    }
    let points = worldVertices.compactMap {
      spatialToolPreviewPoint(worldPosition: $0, radius: 0.0018)
    }
    guard points.count == worldVertices.count else { return [] }
    return paths.enumerated().map { index, path in
      VolumeMarker(
        id: markerIDs[index],
        name: "Controller tool preview",
        color: color,
        geometry: .stroke(path.map { points[$0] })
      )
    }
  }

  private func updateSpatialStylusStroke(
    sample: BorgSpatialStylusSample?
  ) {
    guard let sample else {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = nil
      spatialStylusRadiusAdjustmentStart = nil
      return
    }
    let filteredTip = filteredSpatialStylusTip(
      position: sample.tipPosition,
      pressure: sample.drawingPressure
    )
    guard let previewPoint = spatialToolPreviewPoint(
      worldPosition: filteredTip.position,
      radius: sharedAppModel.defaultVolumeStrokeRadius
    ) else {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = nil
      spatialStylusRadiusAdjustmentStart = nil
      return
    }
    let position = previewPoint.position

    if sample.isAdjustingRadius {
      finishSpatialStylusStroke()
      if spatialStylusRadiusAdjustmentStart == nil {
        let hsv = rgbToHSV(sharedAppModel.defaultVolumeStrokeColor)
        spatialStylusRadiusAdjustmentStart = (
          position: sample.tipPosition,
          radius: sharedAppModel.defaultVolumeStrokeRadius,
          hue: hsv.hue
        )
      }
      if let start = spatialStylusRadiusAdjustmentStart {
        let deviceUp = simd_normalize(SIMD3<Float>(
          lastOriginFromDevice.columns.1.x,
          lastOriginFromDevice.columns.1.y,
          lastOriginFromDevice.columns.1.z
        ))
        let deviceRight = simd_normalize(SIMD3<Float>(
          lastOriginFromDevice.columns.0.x,
          lastOriginFromDevice.columns.0.y,
          lastOriginFromDevice.columns.0.z
        ))
        let movement = sample.tipPosition - start.position
        let verticalMovement = simd_dot(movement, deviceUp)
        let horizontalMovement = simd_dot(movement, deviceRight)
        sharedAppModel.defaultVolumeStrokeRadius = VolumeMarkerRadius.clamp(
          start.radius * exp(verticalMovement * 8),
          for: .stroke
        )
        sharedAppModel.defaultVolumeStrokeColor = hsvToRGB(
          hue: start.hue + horizontalMovement * 3,
          saturation: 1,
          value: 1
        )
      }
      spatialStylusPreviewPoint = VolumeMarkerPoint(
        position: position,
        radius: sharedAppModel.defaultVolumeStrokeRadius
      )
      return
    }

    spatialStylusRadiusAdjustmentStart = nil
    guard sample.isDrawing else {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = VolumeMarkerPoint(
        position: position,
        radius: sharedAppModel.defaultVolumeStrokeRadius
      )
      return
    }

    spatialStylusPreviewPoint = nil
    let previousPosition = activeSpatialStylusStrokeID.flatMap { strokeID in
      sharedAppModel.volumeMarkers.first(where: { $0.id == strokeID })?.points.last?.position
    }
    let strokePosition = storedAppModel.projectObjectsOntoVolume
      ? immersiveInteraction.projectedVolumePosition(
          toward: filteredTip.position,
          smoothingDepthFrom: previousPosition
        ) ?? position
      : position
    let pointRadius = filteredTip.pressure.map {
      VolumeMarkerRadius.pressureAdjustedStrokeRadius(
        maximumRadius: sharedAppModel.defaultVolumeStrokeRadius,
        pressure: $0
      )
    } ?? sharedAppModel.defaultVolumeStrokeRadius
    let point = VolumeMarkerPoint(
      position: strokePosition,
      radius: pointRadius
    )

    if let activeSpatialStylusStrokeID,
       let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: {
         $0.id == activeSpatialStylusStrokeID
       }) {
      let modelScale = simd_abs(sharedAppModel.modelTransform.scale)
      _ = sharedAppModel.volumeMarkers[markerIndex].appendStrokePoint(
        point,
        coordinateScale: SIMD3<Float>(
          volumeScale.columns.0.x,
          volumeScale.columns.1.y,
          volumeScale.columns.2.z
        ) * modelScale
      )
      return
    }

    let marker = VolumeMarker.stroke(
      name: sharedAppModel.nextVolumeMarkerName(for: .stroke),
      firstPoint: point,
      color: sharedAppModel.defaultVolumeStrokeColor
    )
    if storedAppModel.projectObjectsOntoVolume {
      immersiveInteraction.beginStrokeProjectionFreeze(token: marker.id)
    }
    sharedAppModel.volumeMarkers.append(marker)
    sharedAppModel.selectedVolumeMarkerID = marker.id
    activeSpatialStylusStrokeID = marker.id
    sharedAppModel.synchronizeMarkers()
  }

  private func updateSpatialAccessoryInteractions(drawable: LayerRenderer.Drawable) {
    let timestamp = LayerRenderer.Clock.Instant.epoch
      .duration(to: drawable.frameTiming.trackableAnchorTime)
      .timeInterval
    let samples = borgARProvider.getSpatialInputSamples(atTimestamp: timestamp)
    let inputContext = spatialInputContext.snapshot()
    let placementConsumesAccessories = immersiveInteraction.handleArmedSceneObjectPlacement(
      samples: samples,
      datasetInfo: inputContext.datasetInfo
    )
    let stylusSample = placementConsumesAccessories ? nil : immersiveInteraction.spatialStylusSample(
      from: samples,
      timestamp: timestamp
    )
    if !placementConsumesAccessories {
      immersiveInteraction.handleSpatialInputSamples(
        samples,
        datasetInfo: inputContext.datasetInfo,
        timestamp: timestamp
      )
    }
    spatialControllerSamples = samples.filter { $0.source == .controller }
    let selectedPrototype = sharedAppModel.validateSelectedSceneObjectPrototype()
    var objectPreviewInstances: [SceneMeshInstance] = []
    spatialControllerPreviewPoints = spatialControllerSamples.compactMap { sample in
      guard storedAppModel.controllerTool(for: sample.chirality) == .objectPlacement else {
        return spatialToolPreviewPoint(
          worldPosition: sample.aimOrigin,
          radius: sharedAppModel.defaultVolumeStrokeRadius
        )
      }
      guard !sample.primaryPressed, let datasetInfo = inputContext.datasetInfo else {
        return nil
      }
      switch immersiveInteraction.sceneObjectPreview(
        prototype: selectedPrototype,
        worldTransform: sample.aimTransform,
        datasetInfo: datasetInfo,
        id: sample.id
      ) {
        case .sphere(let point):
          return point
        case .mesh(let instance):
          objectPreviewInstances.append(instance)
          return nil
        case nil:
          return nil
      }
    }
    spatialControllerModePreviewMarkers = spatialControllerSamples.flatMap { sample in
      spatialControllerToolPreviewMarkers(
        sample: sample,
        mode: storedAppModel.controllerTool(for: sample.chirality)
      )
    }
    if storedAppModel.stylusTool == .objectPlacement {
      finishSpatialStylusStroke()
      spatialStylusRadiusAdjustmentStart = nil
      spatialStylusMeasurementPreviewMarkers = []
      immersiveInteraction.handleSpatialStylusMeasurement(
        nil,
        datasetInfo: nil,
        kind: .length
      )
      spatialStylusPreviewPoint = nil
      if let sample = samples.first(where: { $0.source == .stylus }),
         !sample.primaryPressed,
         let datasetInfo = inputContext.datasetInfo {
        switch immersiveInteraction.sceneObjectPreview(
          prototype: selectedPrototype,
          worldTransform: sample.aimTransform,
          datasetInfo: datasetInfo,
          id: sample.id
        ) {
          case .sphere(let point):
            spatialStylusPreviewPoint = point
          case .mesh(let instance):
            objectPreviewInstances.append(instance)
          case nil:
            break
        }
      }
    } else if let stylusMeasurementKind = storedAppModel.stylusTool.measurementKind {
      finishSpatialStylusStroke()
      spatialStylusRadiusAdjustmentStart = nil
      immersiveInteraction.handleSpatialStylusMeasurement(
        stylusSample,
        datasetInfo: inputContext.datasetInfo,
        kind: stylusMeasurementKind
      )
      spatialStylusPreviewPoint = stylusSample.flatMap {
        spatialToolPreviewPoint(worldPosition: $0.tipPosition, radius: 0.008)
      }
      spatialStylusMeasurementPreviewMarkers = stylusSample.map {
        stylusMeasurementPreviewMarkers(
          worldPosition: spatialToolGlyphPosition(
            aimTransform: $0.aimTransform,
            distanceBehindTip: 0.05
          ),
          kind: stylusMeasurementKind,
          showsPlus: immersiveInteraction.spatialStylusWillExtendMeasurement,
          markerIDs: Self.stylusMeasurementPreviewMarkerIDs
        )
      } ?? []
    } else {
      spatialStylusMeasurementPreviewMarkers = []
      immersiveInteraction.handleSpatialStylusMeasurement(
        nil,
        datasetInfo: nil,
        kind: .length
      )
      updateSpatialStylusStroke(sample: stylusSample)
    }
    spatialSceneObjectPreviewInstances = objectPreviewInstances
    var previewPoints = spatialControllerPreviewPoints
    if let spatialStylusPreviewPoint {
      previewPoints.append(spatialStylusPreviewPoint)
    }
    synchronizeSpatialToolPreviewsIfNeeded(
      previewPoints,
      at: timestamp
    )
  }

  private func synchronizeSpatialToolPreviewsIfNeeded(
    _ points: [VolumeMarkerPoint],
    at timestamp: TimeInterval
  ) {
    let sharedPoints = storedAppModel.shareSpatialStylusPosition ? points : []
    if sharedPoints.isEmpty {
      guard spatialToolPreviewsWereShared else { return }
    } else {
      guard timestamp - lastSpatialToolPreviewShareTime >= 0.05 else { return }
    }
    lastSpatialToolPreviewShareTime = timestamp
    spatialToolPreviewsWereShared = !sharedPoints.isEmpty
    sharedAppModel.synchronizeSpatialToolPreviews(
      points: sharedPoints,
      color: sharedAppModel.defaultVolumeStrokeColor
    )
  }

  private func rgbToHSV(_ color: SIMD4<Float>) -> (
    hue: Float,
    saturation: Float,
    value: Float
  ) {
    let maximum = max(color.x, color.y, color.z)
    let minimum = min(color.x, color.y, color.z)
    let delta = maximum - minimum
    let saturation = maximum > 0 ? delta / maximum : 0
    guard delta > 0.000_001 else {
      return (0, saturation, maximum)
    }

    let hue: Float
    if maximum == color.x {
      hue = (color.y - color.z) / delta / 6
    } else if maximum == color.y {
      hue = ((color.z - color.x) / delta + 2) / 6
    } else {
      hue = ((color.x - color.y) / delta + 4) / 6
    }
    return (hue - floor(hue), saturation, maximum)
  }

  private func hsvToRGB(
    hue: Float,
    saturation: Float,
    value: Float
  ) -> SIMD4<Float> {
    let wrappedHue = hue - floor(hue)
    let sector = wrappedHue * 6
    let index = Int(floor(sector)) % 6
    let fraction = sector - floor(sector)
    let p = value * (1 - saturation)
    let q = value * (1 - saturation * fraction)
    let t = value * (1 - saturation * (1 - fraction))
    let rgb: SIMD3<Float>
    switch index {
      case 0: rgb = SIMD3<Float>(value, t, p)
      case 1: rgb = SIMD3<Float>(q, value, p)
      case 2: rgb = SIMD3<Float>(p, value, t)
      case 3: rgb = SIMD3<Float>(p, q, value)
      case 4: rgb = SIMD3<Float>(t, p, value)
      default: rgb = SIMD3<Float>(value, p, q)
    }
    return SIMD4<Float>(rgb, 1)
  }

  /**
   Renders a single frame. This function manages frame lifecycle, timing, command buffer setup,
   resource binding, and final drawing and presentation.
   */
  func renderFrame() -> Bool {
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }
    guard let frame = layerRenderer.queryNextFrame() else { return true }

    frame.startUpdate()
    frame.endUpdate()

    guard let timing = frame.predictTiming() else { return true }
    LayerRenderer.Clock().wait(until: timing.optimalInputTime)

    // Closing an immersive space can happen while waiting for the predicted
    // input time. Do not submit that now-obsolete frame to the GPU.
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }

    let desc = MTLCommandBufferDescriptor()
    desc.errorOptions = .encoderExecutionStatus
    guard let commandBuffer = commandQueue.makeCommandBuffer(descriptor: desc) else {
      logger?.error("Failed to create render command buffer.")
      return false
    }
    commandBuffer.label = "BorgVR Command Buffer"

    guard let drawable = frame.queryDrawables().first else { return true }
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }

    frame.startSubmission()
    defer { frame.endSubmission() }
    self.updateDynamicBufferState()

    self.updateRenderState(drawable: drawable)
    self.updateSpatialAccessoryInteractions(drawable: drawable)

    let rasterizationRateMap = drawable.rasterizationRateMaps.first
    let opaqueGeometryTargets = renderOpaqueGeometry(
      commandBuffer: commandBuffer,
      drawable: drawable,
      rasterizationRateMap: rasterizationRateMap
    )

    let renderPassDescriptor = MTLRenderPassDescriptor()
    let interactionDepthTexture = interactionDepthTexture(drawable: drawable)

    if rasterSampleCount > 1 {
      let renderTargets = memorylessRenderTargets(
        drawable: drawable,
        interactionDepthResolveTexture: interactionDepthTexture
      )
      renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
      renderPassDescriptor.colorAttachments[0].texture = renderTargets.color
      renderPassDescriptor.colorAttachments[1].resolveTexture = interactionDepthTexture
      renderPassDescriptor.colorAttachments[1].texture = renderTargets.interactionDepth
      renderPassDescriptor.depthAttachment.resolveTexture = drawable.depthTextures[0]
      renderPassDescriptor.depthAttachment.texture = renderTargets.depth
      renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
      renderPassDescriptor.colorAttachments[1].storeAction = .multisampleResolve
      renderPassDescriptor.depthAttachment.storeAction = .multisampleResolve
    } else {
      renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
      renderPassDescriptor.colorAttachments[1].texture = interactionDepthTexture
      renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
      renderPassDescriptor.colorAttachments[0].storeAction = .store
      renderPassDescriptor.colorAttachments[1].storeAction = .store
      renderPassDescriptor.depthAttachment.storeAction = .store
    }

    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    renderPassDescriptor.colorAttachments[1].loadAction = .clear
    renderPassDescriptor.colorAttachments[1].clearColor = MTLClearColorMake(-1, 0, 0, 0)
    renderPassDescriptor.depthAttachment.loadAction = .clear
    renderPassDescriptor.depthAttachment.clearDepth = 0.0
    renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
    if layerRenderer.configuration.layout == .layered {
      renderPassDescriptor.renderTargetArrayLength = drawable.views.count
    }

    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      logger?.error("Failed to create render command encoder.")
      return false
    }

    renderEncoder.label = "BorgVR Render Encoder"
    renderEncoder.setCullMode(.front)
    renderEncoder.setFrontFacing(.counterClockwise)

    if sharedAppModel.brickVis {
      renderEncoder.setRenderPipelineState(pipelineStateBrickVis)
    } else {
      switch sharedAppModel.renderMode {
        case .isoValue:
          renderEncoder.setRenderPipelineState(pipelineStateIso)
        case .transferFunction1D:
          renderEncoder.setRenderPipelineState(pipelineStateTF)
        case .transferFunction1DLighting:
          renderEncoder.setRenderPipelineState(pipelineStateTFL)
      }
    }

    renderEncoder.setDepthStencilState(depthState)

    uniformBufferVertex.bindVertex(to: renderEncoder, index: VertexBufferIndex.uniforms.rawValue)
    uniformBufferFragment.bindFragment(to: renderEncoder, index: FragmentBufferIndex.uniforms.rawValue)
    bindRasterizationRateMap(rasterizationRateMap, to: renderEncoder)

    let viewports = drawable.views.map { $0.textureMap.viewport }
    renderEncoder.setViewports(viewports)

    if drawable.views.count > 1 {
      var viewMappings = (0..<drawable.views.count).map {
        MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                          renderTargetArrayIndexOffset: UInt32($0))
      }
      renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
    }

    renderEncoder.setVertexBuffer(cubeBuffer, offset: 0, index: VertexBufferIndex.meshPositions.rawValue)

    do {
      try sharedAppModel.transferFunction.bind(to: renderEncoder, index: TextureIndex.transferFunction.rawValue)
    } catch {
      logger?.error("Failed to bind transfer function texture: \(error)")
    }

    volumeAtlas.bind(to: renderEncoder,
                     atlasIndex: TextureIndex.volumeAtlas.rawValue,
                     metaIndex: FragmentBufferIndex.brickMeta.rawValue,
                     levelIndex: FragmentBufferIndex.levelTable.rawValue)

    hashTable.bind(to: renderEncoder, index: FragmentBufferIndex.hashTable.rawValue)
    renderEncoder.setFragmentTexture(
      opaqueGeometryTargets.depth,
      index: TextureIndex.markerDepth.rawValue
    )

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.vertexCount)

    renderEncoder.popDebugGroup()

    compositeOpaqueGeometry(
      renderEncoder,
      colorTexture: opaqueGeometryTargets.color,
      depthTexture: opaqueGeometryTargets.depth
    )
    drawMeasurementLabelsOnScreen(
      opaqueGeometryTargets.measurementLabels,
      renderEncoder: renderEncoder,
      drawable: drawable
    )

    if storedAppModel.tfMode != TransferFunctionDisplayMode.windowOnly.rawValue {
      renderTransferfunction(renderEncoder, drawable: drawable)
    } else {
      transferFunctionPanelInteractionState.updatePanel(
        matrix: matrix_identity_float4x4,
        size: .zero,
        isVisible: false
      )
      transferFunctionPanelInteractionState.setFocused(false)
    }

    renderEncoder.endEncoding()

    // The immersive space can be suspended while this frame is being encoded.
    // Dropping an uncommitted command buffer is safe; submitting it after GPU
    // access has been revoked terminates the process on visionOS.
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }

    drawable.encodePresent(commandBuffer: commandBuffer)

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error as NSError? {
      let submissionWasNotPermitted = error.domain == MTLCommandBufferErrorDomain &&
        error.code == MTLCommandBufferError.notPermitted.rawValue
      if submissionWasNotPermitted || Task.isCancelled || layerRenderer.state != .running {
        logger?.info("Render submission stopped because the immersive scene was suspended.")
        immersiveInteraction.updateVolumeInteractionDepthSnapshot(nil)
        return true
      }
      logger?.error("Render command failed: \(error.localizedDescription)")
      if let info = error.userInfo[MTLCommandBufferEncoderInfoErrorKey] {
        logger?.error("Encoder info: \(String(describing: info))")
      }
      return false
    }

    immersiveInteraction.updateVolumeInteractionDepthSnapshot(
      VolumeInteractionDepthSnapshot(
        texture: interactionDepthTexture,
        textureToClip: currentTextureToClipMatrices,
        worldToClip: currentWorldToClipMatrices,
        worldFromVolume: lastModelMatrix,
        headPosition: lastHeadPosition,
        rasterizationRateMap: rasterizationRateMap
      )
    )

    readBackHashTable(commandBuffer: commandBuffer)
    updatePerformanceCounters()

    return true
  }

  // MARK: Actual Loop

  /**
   The main render loop. Handles immersive space state transitions and repeatedly calls `renderFrame()`.
   */
  func renderLoop() async {
    while !Task.isCancelled {
      if layerRenderer.state == .invalidated {
        Task { @MainActor in
          runtimeAppModel.immersiveSpaceWasClosedBySystem()
        }
        return
      } else if layerRenderer.state == .paused {
        guard !Task.isCancelled else { return }
        Task { @MainActor in
          runtimeAppModel.immersiveSpaceState = .inTransition
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        continue
      } else {
        Task { @MainActor in
          if runtimeAppModel.immersiveSpaceState != .open {
            runtimeAppModel.markImmersiveSpaceOpened()
          }
        }
        var frameSucceeded = true
        autoreleasepool {
          frameSucceeded = self.renderFrame()
        }
        if !frameSucceeded {
          Task { @MainActor in
            runtimeAppModel.renderLoopFailed()
          }
          return
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
