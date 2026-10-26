import CompositorServices
import Metal
import RealityKit
import simd

/// Owns non-volume geometry resources. Only color/depth targets cross into the volume pass.
/// All access is serialized by the owning VisionVolumeRenderer actor.
final class VisionOpaqueGeometryRenderer {
  struct Frame {
    let snapshot: BorgVRFrameSnapshot
    let volumeScale: simd_float4x4
    let modelMatrix: simd_float4x4
    let originFromDevice: simd_float4x4
    let headPosition: SIMD3<Float>
    let physicalExtentMeters: SIMD3<Float>
    let pendingProjectionCaptureMarkerIDs: Set<UUID>
    let brushPreviewMarkers: [VolumeMarker]
    let stylusPreviewPoint: VolumeMarkerPoint?
    let stylusMeasurementPreviewMarkers: [VolumeMarker]
    let controllerModePreviewMarkers: [VolumeMarker]
    let objectPreviewInstances: [SceneMeshInstance]
    let controllerPreviewPoints: [VolumeMarkerPoint]
    let controllerSamples: [BorgSpatialInputSample]
  }

  struct Output {
    let color: MTLTexture
    let depth: MTLTexture
    let measurementLabels: [ScreenViewLabelDescriptor]
    let frame: Frame
  }

  private let device: MTLDevice
  private let layerRenderer: LayerRenderer
  /// Render pipeline state for opaque volume markers.
  var pipelineStateVolumeMarker: MTLRenderPipelineState
  /// Render pipeline state for opaque scene meshes.
  var pipelineStateSceneMesh: MTLRenderPipelineState
  /// Render pipeline state for lightweight screen-space measurement lines.
  var pipelineStateMeasurementLine: MTLRenderPipelineState
  /// Render pipeline state for compact screen-space measurement control points.
  var pipelineStateMeasurementPoint: MTLRenderPipelineState
  /// Render pipeline state for screen-view participant labels.
  var pipelineStateScreenViewLabel: MTLRenderPipelineState
  /// Screen-view and measurement labels drawn after the volume pass.
  var pipelineStateScreenViewOverlayLabel: MTLRenderPipelineState
  /// Render pipeline state for compositing marker color under the volume.
  var pipelineStateMarkerComposite: MTLRenderPipelineState
  /// Depth stencil state for marker geometry.
  var depthStateMarker: MTLDepthStencilState
  /// Marker depth test without writes, used for back-to-front transparent geometry.
  var depthStateMarkerReadOnly: MTLDepthStencilState
  /// Depth stencil state for marker compositing.
  var depthStateMarkerComposite: MTLDepthStencilState

  /// A buffer containing marker sphere vertex positions.
  let markerSphereBuffer: MTLBuffer
  /// A buffer containing marker sphere normals.
  let markerSphereNormalBuffer: MTLBuffer
  /// The number of vertices in the marker sphere buffer.
  let markerSphereVertexCount: Int
  /// A tapered pointer rendered at each tracked spatial controller's aim pose.
  let spatialControllerPointerBuffer: MTLBuffer
  let spatialControllerPointerNormalBuffer: MTLBuffer
  let spatialControllerPointerVertexCount: Int
  /// Cached tube meshes for stroke markers.
  let markerTubeMeshCache: VolumeMarkerTubeMeshCache
  /// Cached GPU resources for imported scene meshes.
  let sceneMeshGPUCache: SceneMeshGPUCache
  /// White fallback used when a scene mesh has no embedded texture.
  let sceneMeshWhiteTexture: MTLTexture
  /// Cached triangle meshes for area and volume measurements.
  let measurementSurfaceMeshCache: MeasurementSurfaceMeshCache
  /// Reusable instance buffer for lightweight measurement lines.
  var measurementLineBuffer: MTLBuffer?
  var measurementLineBufferCapacity = 0
  /// Reusable instance buffer for compact measurement-point rings.
  var measurementPointBuffer: MTLBuffer?
  var measurementPointBufferCapacity = 0
  /// Cached label textures for shared and detached screen views.
  let screenViewLabelTextureCache: ScreenViewLabelTextureCache
  /// Color texture produced by the marker prepass.
  var markerColorTexture: MTLTexture?
  /// Depth texture produced by the marker prepass.
  var markerDepthTexture: MTLTexture?

  init(
    device: MTLDevice, layerRenderer: LayerRenderer,
    pipelineStateVolumeMarker: MTLRenderPipelineState,
    pipelineStateSceneMesh: MTLRenderPipelineState,
    pipelineStateMeasurementLine: MTLRenderPipelineState,
    pipelineStateMeasurementPoint: MTLRenderPipelineState,
    pipelineStateScreenViewLabel: MTLRenderPipelineState,
    pipelineStateScreenViewOverlayLabel: MTLRenderPipelineState,
    pipelineStateMarkerComposite: MTLRenderPipelineState
  ) {
    self.device = device
    self.layerRenderer = layerRenderer
    self.pipelineStateVolumeMarker = pipelineStateVolumeMarker
    self.pipelineStateSceneMesh = pipelineStateSceneMesh
    self.pipelineStateMeasurementLine = pipelineStateMeasurementLine
    self.pipelineStateMeasurementPoint = pipelineStateMeasurementPoint
    self.pipelineStateScreenViewLabel = pipelineStateScreenViewLabel
    self.pipelineStateScreenViewOverlayLabel = pipelineStateScreenViewOverlayLabel
    self.pipelineStateMarkerComposite = pipelineStateMarkerComposite
    self.markerTubeMeshCache = VolumeMarkerTubeMeshCache()
    self.sceneMeshGPUCache = SceneMeshGPUCache()
    self.measurementSurfaceMeshCache = MeasurementSurfaceMeshCache()
    self.measurementLineBuffer = nil
    self.measurementPointBuffer = nil
    self.screenViewLabelTextureCache = ScreenViewLabelTextureCache()
    let whiteTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm_srgb,
      width: 1,
      height: 1,
      mipmapped: false
    )
    whiteTextureDescriptor.usage = .shaderRead
    guard let sceneMeshWhiteTexture = device.makeTexture(descriptor: whiteTextureDescriptor) else {
      fatalError("Unable to allocate the scene mesh fallback texture.")
    }
    var opaqueWhite: UInt32 = 0xFFFF_FFFF
    sceneMeshWhiteTexture.replace(
      region: MTLRegionMake2D(0, 0, 1, 1),
      mipmapLevel: 0,
      withBytes: &opaqueWhite,
      bytesPerRow: MemoryLayout<UInt32>.size
    )
    self.sceneMeshWhiteTexture = sceneMeshWhiteTexture

    let markerDepthStateDescriptor = MTLDepthStencilDescriptor()
    markerDepthStateDescriptor.depthCompareFunction = .greater
    markerDepthStateDescriptor.isDepthWriteEnabled = true
    self.depthStateMarker = device.makeDepthStencilState(descriptor: markerDepthStateDescriptor)!

    let markerReadOnlyDepthStateDescriptor = MTLDepthStencilDescriptor()
    markerReadOnlyDepthStateDescriptor.depthCompareFunction = .greater
    markerReadOnlyDepthStateDescriptor.isDepthWriteEnabled = false
    self.depthStateMarkerReadOnly = device.makeDepthStencilState(
      descriptor: markerReadOnlyDepthStateDescriptor
    )!

    let markerCompositeDepthStateDescriptor = MTLDepthStencilDescriptor()
    markerCompositeDepthStateDescriptor.depthCompareFunction = .always
    markerCompositeDepthStateDescriptor.isDepthWriteEnabled = true
    self.depthStateMarkerComposite = device.makeDepthStencilState(
      descriptor: markerCompositeDepthStateDescriptor)!

    let paddingElement = SIMD3<Float>.zero
    let sphere = Tesselation.genSphere(
      center: SIMD3<Float>(repeating: 0),
      radius: 1,
      sectorCount: 32,
      stackCount: 16
    ).unpack()
    let alignedSphereVertexDataCount = (sphere.vertices.count + 15) & -16
    let sphereVertexDataSize = MemoryLayout<SIMD3<Float>>.stride * alignedSphereVertexDataCount
    var alignedSphereVertices = sphere.vertices
    let spherePaddingCount = alignedSphereVertexDataCount - sphere.vertices.count
    alignedSphereVertices.append(
      contentsOf: Array(
        repeating: paddingElement, count: spherePaddingCount))
    markerSphereBuffer = device.makeBuffer(
      length: sphereVertexDataSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    markerSphereBuffer.contents().copyMemory(
      from: alignedSphereVertices,
      byteCount: sphereVertexDataSize
    )
    var alignedSphereNormals = sphere.normals
    alignedSphereNormals.append(
      contentsOf: Array(
        repeating: SIMD3<Float>(0, 1, 0), count: spherePaddingCount))
    markerSphereNormalBuffer = device.makeBuffer(
      length: sphereVertexDataSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    markerSphereNormalBuffer.contents().copyMemory(
      from: alignedSphereNormals,
      byteCount: sphereVertexDataSize
    )
    markerSphereVertexCount = sphere.vertices.count

    let controllerPointer = Tesselation.genPointerCone(
      radius: 0.012,
      height: 0.055,
      sectorCount: 24
    ).unpack()
    let alignedPointerVertexCount = (controllerPointer.vertices.count + 15) & -16
    let pointerBufferSize = MemoryLayout<SIMD3<Float>>.stride * alignedPointerVertexCount
    let pointerPaddingCount = alignedPointerVertexCount - controllerPointer.vertices.count
    var alignedPointerVertices = controllerPointer.vertices
    alignedPointerVertices.append(
      contentsOf: Array(
        repeating: paddingElement,
        count: pointerPaddingCount
      ))
    spatialControllerPointerBuffer = device.makeBuffer(
      length: pointerBufferSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    spatialControllerPointerBuffer.contents().copyMemory(
      from: alignedPointerVertices,
      byteCount: pointerBufferSize
    )
    var alignedPointerNormals = controllerPointer.normals
    alignedPointerNormals.append(
      contentsOf: Array(
        repeating: SIMD3<Float>(0, 0, -1),
        count: pointerPaddingCount
      ))
    spatialControllerPointerNormalBuffer = device.makeBuffer(
      length: pointerBufferSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    spatialControllerPointerNormalBuffer.contents().copyMemory(
      from: alignedPointerNormals,
      byteCount: pointerBufferSize
    )
    spatialControllerPointerVertexCount = controllerPointer.vertices.count

  }

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

  struct ScreenViewLabelDescriptor {
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
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000D")!,
  ]
  private func measurementVisualization(
    frame: Frame,
    measurements: [VolumeMeasurement]
  ) -> MeasurementVisualization {
    var result = MeasurementVisualization()
    let coordinateScale = SIMD3<Float>(
      frame.volumeScale.columns.0.x,
      frame.volumeScale.columns.1.y,
      frame.volumeScale.columns.2.z
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
        localEnd.x.isFinite, localEnd.y.isFinite, localEnd.z.isFinite
      else { return nil }
      return MeasurementVisualization.Line(
        startAndWidth: SIMD4<Float>(localStart, width),
        end: SIMD4<Float>(localEnd, 0),
        color: color
      )
    }

    for measurement in measurements {
      let selected = frame.snapshot.annotations.selectedMeasurementID == measurement.id
      let color = VisionRenderMath.measurementColor(for: measurement.kind, selected: selected)
      let geometry = measurement.geometry

      for (pointIndex, point) in geometry.points.enumerated() {
        let pointSelected =
          selected && frame.snapshot.annotations.selectedMeasurementPointID == point.id
        let definesAreaPlane = measurement.kind == .area && pointIndex < 3
        let outerColor: SIMD4<Float>
        if pointSelected {
          outerColor = SIMD4<Float>(1, 0.22, 0.03, 1)
        } else {
          outerColor = color
        }
        let localPosition = (point.position - SIMD3<Float>(repeating: 0.5)) * coordinateScale
        result.points.append(
          MeasurementPointRenderInstance(
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
        let firstPoint = geometry.points.first
      {
        result.labels.append(
          ScreenViewLabelDescriptor(
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
        result.surfaces.append(
          .init(
            measurement: measurement,
            color: SIMD4<Float>(color.x, color.y, color.z, selected ? 0.34 : 0.22)
          ))
      }
    }
    return result
  }

  private func markerRenderTargets(drawable: LayerRenderer.Drawable) -> (
    color: MTLTexture, depth: MTLTexture
  ) {
    let source = drawable.colorTextures[0]
    let viewCount = max(drawable.views.count, 1)

    let needsNewColor =
      markerColorTexture == nil || markerColorTexture!.width != source.width
      || markerColorTexture!.height != source.height || markerColorTexture!.arrayLength != viewCount
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
      markerColorTexture?.label = "Opaque Geometry Color"
    }

    let needsNewDepth =
      markerDepthTexture == nil || markerDepthTexture!.width != source.width
      || markerDepthTexture!.height != source.height || markerDepthTexture!.arrayLength != viewCount
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
      markerDepthTexture?.label = "Opaque Geometry Depth"
    }

    return (markerColorTexture!, markerDepthTexture!)
  }

  private func drawSceneMeshes(
    frame: Frame,
    _ instances: [SceneMeshInstance],
    datasetMaximumExtentMeters: Float,
    renderEncoder: MTLRenderCommandEncoder
  ) {
    guard datasetMaximumExtentMeters.isFinite, datasetMaximumExtentMeters > 0 else { return }

    renderEncoder.pushDebugGroup("Scene Meshes")
    renderEncoder.setRenderPipelineState(pipelineStateSceneMesh)
    renderEncoder.setDepthStencilState(depthStateMarker)
    renderEncoder.setCullMode(.back)
    for instance in instances where instance.isVisible {
      guard let asset = frame.snapshot.annotations.meshAssets[instance.asset.assetID],
        let gpuAsset = sceneMeshGPUCache.asset(for: asset, device: device)
      else {
        continue
      }
      var modelMatrix =
        frame.modelMatrix * matrixScale(SIMD3<Float>(repeating: 1 / datasetMaximumExtentMeters))
        * instance.transformMeters
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

  private func drawOpaqueGeometry(
    frame: Frame,
    _ renderEncoder: MTLRenderCommandEncoder,
    drawable: LayerRenderer.Drawable
  ) -> [ScreenViewLabelDescriptor] {
    let screenViews = screenViewVisualization(frame: frame, )
    let measurementSnapshot = frame.snapshot.annotations.measurements
    let pendingProjectionCaptureMarkerIDs =
      frame.pendingProjectionCaptureMarkerIDs
    let suppressLocalToolWidgets = !pendingProjectionCaptureMarkerIDs.isEmpty
    let persistentMarkers = frame.snapshot.annotations.markers.filter {
      !pendingProjectionCaptureMarkerIDs.contains($0.id)
    }
    let screenViewMarkers =
      (screenViews.markers + (suppressLocalToolWidgets ? [] : frame.brushPreviewMarkers)).filter {
        !pendingProjectionCaptureMarkerIDs.contains($0.id)
      }
    let toolWidgetMarkers =
      suppressLocalToolWidgets
      ? []
      : frame.stylusMeasurementPreviewMarkers + frame.controllerModePreviewMarkers
    let persistentMeshInstances = frame.snapshot.annotations.meshInstances
    let previewMeshInstances = suppressLocalToolWidgets ? [] : frame.objectPreviewInstances
    let visibleMeshInstances =
      (frame.snapshot.visualization.objectsVisible ? persistentMeshInstances : [])
      + previewMeshInstances
    sceneMeshGPUCache.retainOnly(assetIDs: Set(visibleMeshInstances.map(\.asset.assetID)))
    let remoteToolPreviews = frame.snapshot.annotations.remoteToolPreviews.filter(\.isActive)
    guard
      (frame.snapshot.visualization.objectsVisible
        && (!persistentMarkers.isEmpty || !persistentMeshInstances.isEmpty))
        || (frame.snapshot.visualization.measurementsVisible && !measurementSnapshot.isEmpty)
        || !screenViewMarkers.isEmpty || !screenViews.labels.isEmpty
        || !previewMeshInstances.isEmpty
        || (!suppressLocalToolWidgets && frame.stylusPreviewPoint != nil)
        || !remoteToolPreviews.isEmpty
        || (!suppressLocalToolWidgets && !frame.controllerSamples.isEmpty)
        || (!suppressLocalToolWidgets && !frame.controllerPreviewPoints.isEmpty)
    else {
      return []
    }

    renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
    renderEncoder.setDepthStencilState(depthStateMarker)
    renderEncoder.setCullMode(.back)
    renderEncoder.setFrontFacing(.counterClockwise)

    let viewCount = drawable.views.count
    guard viewCount > 0 else { return [] }
    var mvp = [simd_float4x4](repeating: matrix_identity_float4x4, count: viewCount)
    var eyePositions = [SIMD3<Float>](repeating: .zero, count: viewCount)
    for i in 0..<viewCount {
      let view = drawable.views[i]
      let eyeMatrix = frame.originFromDevice * view.transform
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

    let physicalExtent = frame.physicalExtentMeters
    let datasetMaximumExtentMeters = max(
      physicalExtent.x,
      max(physicalExtent.y, physicalExtent.z)
    )
    renderEncoder.setVertexBuffer(
      markerSphereBuffer,
      offset: 0,
      index: VertexBufferIndex.meshPositions.rawValue
    )
    renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)

    let coordinateScale = SIMD3<Float>(
      frame.volumeScale.columns.0.x,
      frame.volumeScale.columns.1.y,
      frame.volumeScale.columns.2.z
    )
    markerTubeMeshCache.retainOnly(
      markerIDs: Set((persistentMarkers + screenViewMarkers + toolWidgetMarkers).map(\.id))
    )
    measurementSurfaceMeshCache.retainOnly(
      measurementIDs: frame.snapshot.visualization.measurementsVisible
        ? Set(measurementSnapshot.map(\.id))
        : []
    )

    func color(for marker: VolumeMarker) -> SIMD4<Float> {
      VolumeMarkerPresentation.color(
        for: marker,
        isSelected: frame.snapshot.annotations.selectedMarkerIDs.contains(marker.id)
      )
    }

    func drawSphere(_ point: VolumeMarkerPoint, color: SIMD4<Float>) {
      let markerVolumePosition = simd_make_float3(
        frame.volumeScale * SIMD4<Float>(point.position - SIMD3<Float>(repeating: 0.5), 1.0)
      )
      var modelMatrix =
        frame.modelMatrix * Transform(translation: markerVolumePosition).matrix
        * Transform(scale: SIMD3<Float>(repeating: point.radius)).matrix
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

      var bodyMatrix =
        sample.aimTransform * Transform(translation: SIMD3<Float>(0, 0, 0.055)).matrix
        * Transform(scale: SIMD3<Float>(repeating: 0.015)).matrix
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
      guard
        let tubeMesh = markerTubeMeshCache.mesh(
          for: marker,
          coordinateScale: coordinateScale,
          device: device
        )
      else { return }
      var modelMatrix = frame.modelMatrix
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

    func drawObjects() {
      guard frame.snapshot.visualization.objectsVisible else { return }

      drawSceneMeshes(
        frame: frame,
        persistentMeshInstances,
        datasetMaximumExtentMeters: datasetMaximumExtentMeters,
        renderEncoder: renderEncoder
      )
      renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
      drawMarkerGeometry(persistentMarkers, groupName: "Objects")
    }

    func drawToolWidgets() {
      renderEncoder.pushDebugGroup("Spatial Tool Widgets")
      if !suppressLocalToolWidgets {
        drawSceneMeshes(
          frame: frame,
          previewMeshInstances,
          datasetMaximumExtentMeters: datasetMaximumExtentMeters,
          renderEncoder: renderEncoder
        )
        renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
        drawMarkerGeometry(toolWidgetMarkers, groupName: "Tool Mode Glyphs")
        if frame.stylusMeasurementPreviewMarkers.isEmpty,
          let spatialStylusPreviewPoint = frame.stylusPreviewPoint
        {
          drawSphere(
            spatialStylusPreviewPoint,
            color: frame.snapshot.annotations.localToolColor
          )
        }
        for point in frame.controllerPreviewPoints {
          drawSphere(point, color: frame.snapshot.annotations.localToolColor)
        }
        for sample in frame.controllerSamples {
          drawControllerPointer(sample)
        }
      }
      for preview in remoteToolPreviews {
        drawSphere(preview.point, color: preview.color)
      }
      renderEncoder.popDebugGroup()
    }

    drawObjects()
    drawMarkerGeometry(screenViewMarkers, groupName: "Screen View Avatars")
    drawToolWidgets()

    var measurementLabels: [ScreenViewLabelDescriptor] = []
    func drawMeasurements() {
      guard frame.snapshot.visualization.measurementsVisible else { return }

      let measurements = measurementVisualization(frame: frame, measurements: measurementSnapshot)
      measurementLabels = measurements.labels
      renderEncoder.pushDebugGroup("Measurements")
      if !measurements.points.isEmpty {
        let byteCount =
          MemoryLayout<MeasurementPointRenderInstance>.stride * measurements.points.count
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
          var modelMatrix = frame.modelMatrix
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
        let byteCount =
          MemoryLayout<MeasurementVisualization.Line>.stride * measurements.lines.count
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
          var modelMatrix = frame.modelMatrix
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

      let surfaceMeshes = measurements.surfaces.compactMap {
        surface -> (
          surface: MeasurementVisualization.Surface,
          mesh: MeasurementSurfaceGPUMesh
        )? in
        guard
          let mesh = measurementSurfaceMeshCache.mesh(
            for: surface.measurement,
            coordinateScale: coordinateScale,
            device: device
          )
        else { return nil }
        return (surface, mesh)
      }

      func drawSurface(
        _ mesh: MeasurementSurfaceGPUMesh,
        color: SIMD4<Float>,
        cullMode: MTLCullMode,
        depthStencilState: MTLDepthStencilState
      ) {
        guard mesh.vertexCount >= 3, mesh.vertexCount.isMultiple(of: 3) else { return }
        var modelMatrix = frame.modelMatrix
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
      frame: frame,
      screenViews.labels,
      renderEncoder: renderEncoder,
      depthStencilState: depthStateMarker,
      pipelineState: pipelineStateScreenViewLabel
    )
    return measurementLabels
  }

  private func drawScreenViewLabels(
    frame: Frame,
    _ labels: [ScreenViewLabelDescriptor],
    renderEncoder: MTLRenderCommandEncoder,
    depthStencilState: MTLDepthStencilState,
    pipelineState: MTLRenderPipelineState
  ) {
    guard !labels.isEmpty else { return }

    for label in labels {
      drawScreenViewLabel(
        frame: frame,
        label,
        renderEncoder: renderEncoder,
        depthStencilState: depthStencilState,
        pipelineState: pipelineState
      )
    }
  }

  private func screenViewLabelWorldPosition(
    frame: Frame,
    _ label: ScreenViewLabelDescriptor
  ) -> SIMD3<Float> {
    let volumePosition = simd_make_float3(
      frame.volumeScale * SIMD4<Float>(label.position - SIMD3<Float>(repeating: 0.5), 1)
    )
    var worldPosition = simd_make_float3(
      frame.modelMatrix * SIMD4<Float>(volumePosition, 1)
    )
    guard worldPosition.x.isFinite, worldPosition.y.isFinite, worldPosition.z.isFinite else {
      return frame.headPosition
    }
    if label.depthOffsetTowardCamera > 0 {
      let cameraDirection = frame.headPosition - worldPosition
      let lengthSquared = simd_length_squared(cameraDirection)
      if lengthSquared.isFinite, lengthSquared > 0.000_000_1 {
        worldPosition += cameraDirection / sqrt(lengthSquared) * label.depthOffsetTowardCamera
      }
    }
    return worldPosition
  }

  private func drawScreenViewLabel(
    frame: Frame,
    _ label: ScreenViewLabelDescriptor,
    renderEncoder: MTLRenderCommandEncoder,
    depthStencilState: MTLDepthStencilState,
    pipelineState: MTLRenderPipelineState
  ) {

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setDepthStencilState(depthStencilState)
    renderEncoder.setCullMode(.none)

    guard
      let labelTexture = screenViewLabelTextureCache.texture(
        for: label.text,
        accentColor: label.color,
        opaqueBackground: label.opaqueBackground,
        device: device
      )
    else { return }

    let worldPosition = screenViewLabelWorldPosition(frame: frame, label)
    var modelMatrix = VisionRenderMath.billboardMatrix(
      position: worldPosition,
      camera: frame.headPosition,
      up: SIMD3<Float>(0, 1, 0),
      cylindrical: false
    ).0
    modelMatrix.columns.3 +=
      modelMatrix.columns.0 * label.billboardOffset.x + modelMatrix.columns.1
      * label.billboardOffset.y
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

  private func screenViewVisualization(frame: Frame, ) -> ScreenViewVisualization {
    let spatialViews = frame.snapshot.spatialViews
    let screenParticipants = spatialViews.participants.filter {
      $0.platform == .iOS || $0.platform == .macOS
    }
    guard !screenParticipants.isEmpty else { return ScreenViewVisualization() }

    var result = ScreenViewVisualization()
    if let state = spatialViews.sharedView {
      let sharedView = screenViewVisualizationMarkers(
        frame: frame,
        state: state,
        markerID: nil,
        name: String(localized: "Shared View"),
        color: ScreenViewPresentation.sharedColor,
        interactionActive: spatialViews.interactionActive
      )
      result.markers += sharedView.markers
      if spatialViews.namesVisible {
        result.labels.append(sharedView.label)
      }
    }

    let detachedParticipants = screenParticipants.filter {
      spatialViews.detachedViews[$0.id] != nil
    }
    for participant in detachedParticipants {
      guard let state = spatialViews.detachedViews[participant.id] else {
        continue
      }
      let detachedView = screenViewVisualizationMarkers(
        frame: frame,
        state: state,
        markerID: participant.id,
        name: participant.displayName,
        color: ScreenViewPresentation.detachedColor(for: participant.id),
        interactionActive: false
      )
      result.markers += detachedView.markers
      if spatialViews.namesVisible {
        result.labels.append(detachedView.label)
      }
    }
    return result
  }

  private func screenViewVisualizationMarkers(
    frame: Frame,
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
      Transform(translation: SIMD3<Float>(state.pan.x, state.pan.y, 0)).matrix
      * simd_float4x4(state.orientation)
      * Transform(scale: SIMD3<Float>(repeating: state.scale)).matrix * frame.volumeScale
    let volumeFromScreen = simd_inverse(screenFromVolume)

    func volumePoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
      let transformed = volumeFromScreen * SIMD4<Float>(point, 1)
      return SIMD3<Float>(transformed.x, transformed.y, transformed.z) / transformed.w
        + SIMD3<Float>(repeating: 0.5)
    }

    func planeCorners(distance: Float) -> [SIMD3<Float>] {
      let halfHeight = distance * tan(fieldOfView * 0.5)
      let halfWidth = halfHeight * aspect
      let z = cameraDistance - distance
      return [
        volumePoint(SIMD3<Float>(-halfWidth, -halfHeight, z)),
        volumePoint(SIMD3<Float>(halfWidth, -halfHeight, z)),
        volumePoint(SIMD3<Float>(halfWidth, halfHeight, z)),
        volumePoint(SIMD3<Float>(-halfWidth, halfHeight, z)),
      ]
    }

    let nearHalfHeight = nearDistance * tan(fieldOfView * 0.5)
    let labelPosition = volumePoint(
      SIMD3<Float>(
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
            VolumeMarkerPoint(position: screenCorners[(index + 1) % 4], radius: 0.004),
          ])
        )
      }

      let eyeZ = cameraDistance + 0.035
      let eyeWidth: Float = 0.085
      let eyeHeight: Float = 0.038
      let upperEye = (0...8).map { index -> VolumeMarkerPoint in
        let t = Float(index) / 8
        return VolumeMarkerPoint(
          position: volumePoint(
            SIMD3<Float>(
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
          position: volumePoint(
            SIMD3<Float>(
              (t - 0.5) * eyeWidth,
              -sin(t * .pi) * eyeHeight,
              eyeZ
            )),
          radius: 0.003
        )
      }
      result.append(
        VolumeMarker(
          id: id(4),
          name: name,
          color: color,
          geometry: .stroke(upperEye)
        ))
      result.append(
        VolumeMarker(
          id: id(5),
          name: name,
          color: color,
          geometry: .stroke(lowerEye)
        ))
      result.append(
        VolumeMarker(
          id: id(6),
          name: name,
          color: color,
          geometry: .sphere(
            VolumeMarkerPoint(
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
      (near[2], far[2]), (near[3], far[3]),
    ]
    var result = edges.enumerated().map { index, edge in
      VolumeMarker(
        id: id(index),
        name: name,
        color: color,
        geometry: .stroke([
          VolumeMarkerPoint(position: edge.0, radius: lineRadius),
          VolumeMarkerPoint(position: edge.1, radius: lineRadius),
        ])
      )
    }
    result.append(
      VolumeMarker(
        id: id(12),
        name: name,
        color: color,
        geometry: .sphere(
          VolumeMarkerPoint(
            position: volumePoint(SIMD3<Float>(0, 0, cameraDistance)),
            radius: 0.018
          ))
      ))
    return (result, label)
  }

  func render(
    frame: Frame, commandBuffer: MTLCommandBuffer,
    drawable: LayerRenderer.Drawable,
    rasterizationRateMap: MTLRasterizationRateMap?
  ) -> Output {
    let targets = markerRenderTargets(drawable: drawable)
    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = targets.color
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].storeAction = .store
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 0)
    renderPassDescriptor.depthAttachment.texture = targets.depth
    renderPassDescriptor.depthAttachment.loadAction = .clear
    renderPassDescriptor.depthAttachment.storeAction = .store
    renderPassDescriptor.depthAttachment.clearDepth = 0.0
    renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
    if layerRenderer.configuration.layout == .layered {
      renderPassDescriptor.renderTargetArrayLength = drawable.views.count
    }

    guard
      let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
    else {
      fatalError("Failed to create marker prepass encoder")
    }
    renderEncoder.label = "BorgVR Opaque Geometry Prepass"
    renderEncoder.pushDebugGroup("Opaque Geometry Prepass")

    let viewports = drawable.views.map { $0.textureMap.viewport }
    renderEncoder.setViewports(viewports)

    if drawable.views.count > 1 {
      var viewMappings = (0..<drawable.views.count).map {
        MTLVertexAmplificationViewMapping(
          viewportArrayIndexOffset: UInt32($0),
          renderTargetArrayIndexOffset: UInt32($0))
      }
      renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
    }

    let measurementLabels = drawOpaqueGeometry(frame: frame, renderEncoder, drawable: drawable)

    renderEncoder.popDebugGroup()
    renderEncoder.endEncoding()

    return Output(
      color: targets.color, depth: targets.depth, measurementLabels: measurementLabels, frame: frame
    )
  }

  func drawMeasurementLabelsOnScreen(
    frame: Frame,
    _ labels: [ScreenViewLabelDescriptor],
    renderEncoder: MTLRenderCommandEncoder,
    drawable: LayerRenderer.Drawable
  ) {
    guard !labels.isEmpty, !drawable.views.isEmpty else { return }
    let mvp = drawable.views.indices.map { index in
      let view = drawable.views[index]
      let eyeMatrix = frame.originFromDevice * view.transform
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
      simd_distance_squared(screenViewLabelWorldPosition(frame: frame, $0), frame.headPosition)
        > simd_distance_squared(screenViewLabelWorldPosition(frame: frame, $1), frame.headPosition)
    }
    drawScreenViewLabels(
      frame: frame,
      sortedLabels,
      renderEncoder: renderEncoder,
      depthStencilState: depthStateMarkerComposite,
      pipelineState: pipelineStateScreenViewOverlayLabel
    )
  }

  func composite(
    _ renderEncoder: MTLRenderCommandEncoder,
    colorTexture: MTLTexture,
    depthTexture: MTLTexture
  ) {
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

}

enum VisionRenderMath {
  static func measurementColor(
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

  static func billboardMatrix(
    position: SIMD3<Float>,
    camera: SIMD3<Float>,
    up: SIMD3<Float>,
    cylindrical: Bool
  ) -> (simd_float4x4, SIMD3<Float>) {
    var forward = camera - position

    if cylindrical {
      // remove component along up -> yaw-only billboard (stays vertical)
      forward -= up * simd_dot(forward, up)
    }

    let fLen = simd_length(forward)
    let f =
      (fLen.isFinite && fLen > 1e-5)
      ? (forward / fLen)
      : SIMD3<Float>(0, 0, 1)

    var right = simd_cross(up, f)
    var rightLength = simd_length(right)
    if !rightLength.isFinite || rightLength <= 1e-5 {
      right = simd_cross(SIMD3<Float>(1, 0, 0), f)
      rightLength = simd_length(right)
    }
    let r =
      (rightLength.isFinite && rightLength > 1e-5)
      ? right / rightLength
      : SIMD3<Float>(1, 0, 0)
    let u = simd_cross(f, r)  // already normalized if r,f are

    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(r.x, r.y, r.z, 0)
    m.columns.1 = SIMD4<Float>(u.x, u.y, u.z, 0)
    m.columns.2 = SIMD4<Float>(f.x, f.y, f.z, 0)
    m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
    return (m, f)
  }

}
