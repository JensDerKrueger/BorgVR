import Metal
import MetalKit

enum VolumeRendererPipelineError: LocalizedError {
  case missingShaderFunction(String)

  var errorDescription: String? {
    switch self {
      case let .missingShaderFunction(name):
        return "Metal function \(name) was not found in RuntimeVolumeShaders.metal."
    }
  }
}

enum VolumeRendererPipeline {
  static func buildRenderPipelines(
    device: MTLDevice,
    colorFormat: MTLPixelFormat,
    depthFormat: MTLPixelFormat,
    drawableWidth: Float,
    metadata: BORGVRMetaData,
    hashTable: GPUHashtable,
    appSettings: AppSettings,
    labelPrefix: String
  ) throws -> (
    tf: MTLRenderPipelineState,
    tfl: MTLRenderPipelineState,
    iso: MTLRenderPipelineState,
    brick: MTLRenderPipelineState,
    marker: MTLRenderPipelineState,
    sceneMesh: MTLRenderPipelineState,
    markerComposite: MTLRenderPipelineState
  ) {
    let shaderSource = try RuntimeMetalShaderLoader.loadSource(named: "RuntimeVolumeShaders")

    let compileOptions = VolumeShaderCompiler.compileOptions(
      metadata: metadata,
      hashTableSize: hashTable.size,
      configuration: VolumeShaderConfiguration(
        screenSpaceError: Float(appSettings.screenSpaceError),
        atlasSizeMB: appSettings.atlasSizeMB,
        maximumProbingAttempts: appSettings.maxProbingAttempts,
        requestsLowResolutionLOD: appSettings.requestLowResLOD,
        stopsOnMissingBrick: appSettings.stopOnMiss,
        fieldOfViewRadians: 0.75,
        drawableWidth: drawableWidth
      )
    )

    let library = try device.makeLibrary(source: shaderSource, options: compileOptions)
    guard let vertexFunction = library.makeFunction(name: "volumeVertexShader") else {
      throw VolumeRendererPipelineError.missingShaderFunction("volumeVertexShader")
    }

    func descriptor(label: String, fragmentName: String) throws -> MTLRenderPipelineDescriptor {
      guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
        throw VolumeRendererPipelineError.missingShaderFunction(fragmentName)
      }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.label = label
      descriptor.vertexFunction = vertexFunction
      descriptor.fragmentFunction = fragmentFunction
      let colorAttachment = descriptor.colorAttachments[0]!
      colorAttachment.pixelFormat = colorFormat
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .one
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      descriptor.depthAttachmentPixelFormat = depthFormat
      return descriptor
    }

    guard let markerVertexFunction = library.makeFunction(name: "screenVolumeMarkerVertex"),
          let markerFragmentFunction = library.makeFunction(name: "screenVolumeMarkerFragment"),
          let sceneMeshVertexFunction = library.makeFunction(name: "screenSceneMeshVertex"),
          let sceneMeshFragmentFunction = library.makeFunction(name: "screenSceneMeshFragment"),
          let markerCompositeVertexFunction = library.makeFunction(name: "screenMarkerCompositeVertex"),
          let markerCompositeFragmentFunction = library.makeFunction(name: "screenMarkerCompositeFragment") else {
      throw VolumeRendererPipelineError.missingShaderFunction("screen marker shaders")
    }

    let markerDescriptor = MTLRenderPipelineDescriptor()
    markerDescriptor.label = "\(labelPrefix) Volume Marker"
    markerDescriptor.vertexFunction = markerVertexFunction
    markerDescriptor.fragmentFunction = markerFragmentFunction
    markerDescriptor.colorAttachments[0].pixelFormat = colorFormat
    if let colorAttachment = markerDescriptor.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .sourceAlpha
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    markerDescriptor.depthAttachmentPixelFormat = depthFormat

    let sceneMeshDescriptor = MTLRenderPipelineDescriptor()
    sceneMeshDescriptor.label = "\(labelPrefix) Scene Mesh"
    sceneMeshDescriptor.vertexFunction = sceneMeshVertexFunction
    sceneMeshDescriptor.fragmentFunction = sceneMeshFragmentFunction
    sceneMeshDescriptor.colorAttachments[0].pixelFormat = colorFormat
    sceneMeshDescriptor.depthAttachmentPixelFormat = depthFormat

    let compositeDescriptor = MTLRenderPipelineDescriptor()
    compositeDescriptor.label = "\(labelPrefix) Marker Composite"
    compositeDescriptor.vertexFunction = markerCompositeVertexFunction
    compositeDescriptor.fragmentFunction = markerCompositeFragmentFunction
    compositeDescriptor.colorAttachments[0].pixelFormat = colorFormat
    compositeDescriptor.depthAttachmentPixelFormat = depthFormat
    if let colorAttachment = compositeDescriptor.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
      colorAttachment.destinationRGBBlendFactor = .one
      colorAttachment.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
      colorAttachment.destinationAlphaBlendFactor = .one
    }

    return (
      try device.makeRenderPipelineState(descriptor: descriptor(label: "\(labelPrefix) TF", fragmentName: "volumeFragmentShaderTF")),
      try device.makeRenderPipelineState(descriptor: descriptor(label: "\(labelPrefix) TF Lighting", fragmentName: "volumeFragmentShaderTFLighting")),
      try device.makeRenderPipelineState(descriptor: descriptor(label: "\(labelPrefix) Iso", fragmentName: "volumeFragmentShaderIso")),
      try device.makeRenderPipelineState(descriptor: descriptor(label: "\(labelPrefix) Brick", fragmentName: "volumeFragmentShaderBrickVis")),
      try device.makeRenderPipelineState(descriptor: markerDescriptor),
      try device.makeRenderPipelineState(descriptor: sceneMeshDescriptor),
      try device.makeRenderPipelineState(descriptor: compositeDescriptor)
    )
  }
}

@MainActor
final class ScreenVolumeMarkerRenderer {
  private var markerPipeline: MTLRenderPipelineState?
  private var sceneMeshPipeline: MTLRenderPipelineState?
  private var compositePipeline: MTLRenderPipelineState?
  private var markerDepthState: MTLDepthStencilState?
  private var measurementSurfaceDepthState: MTLDepthStencilState?
  private var compositeDepthState: MTLDepthStencilState?
  private var sphereBuffer: MTLBuffer?
  private var sphereNormalBuffer: MTLBuffer?
  private var sphereVertexCount = 0
  private let tubeMeshCache = VolumeMarkerTubeMeshCache()
  private let measurementSurfaceMeshCache = MeasurementSurfaceMeshCache()
  private let sceneMeshGPUCache = SceneMeshGPUCache()
  private var whiteTexture: MTLTexture?
  private var colorTexture: MTLTexture?
  private var depthTexture: MTLTexture?

  func configure(
    device: MTLDevice,
    markerPipeline: MTLRenderPipelineState,
    sceneMeshPipeline: MTLRenderPipelineState,
    compositePipeline: MTLRenderPipelineState
  ) {
    self.markerPipeline = markerPipeline
    self.sceneMeshPipeline = sceneMeshPipeline
    self.compositePipeline = compositePipeline

    if markerDepthState == nil {
      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .greater
      descriptor.isDepthWriteEnabled = true
      markerDepthState = device.makeDepthStencilState(descriptor: descriptor)
    }
    if measurementSurfaceDepthState == nil {
      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .greater
      descriptor.isDepthWriteEnabled = false
      measurementSurfaceDepthState = device.makeDepthStencilState(descriptor: descriptor)
    }
    if compositeDepthState == nil {
      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .always
      descriptor.isDepthWriteEnabled = true
      compositeDepthState = device.makeDepthStencilState(descriptor: descriptor)
    }
    if sphereBuffer == nil || sphereNormalBuffer == nil {
      let sphere = Tesselation.genSphere(
        center: .zero,
        radius: 1,
        sectorCount: 32,
        stackCount: 20
      ).unpack()
      sphereVertexCount = sphere.vertices.count
      sphereBuffer = device.makeBuffer(
        bytes: sphere.vertices,
        length: MemoryLayout<SIMD3<Float>>.stride * sphere.vertices.count,
        options: .storageModeShared
      )
      sphereNormalBuffer = device.makeBuffer(
        bytes: sphere.normals,
        length: MemoryLayout<SIMD3<Float>>.stride * sphere.normals.count,
        options: .storageModeShared
      )
      sphereBuffer?.label = "Screen Volume Marker Sphere"
      sphereNormalBuffer?.label = "Screen Volume Marker Sphere Normals"
    }
    if whiteTexture == nil {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm_srgb,
        width: 1,
        height: 1,
        mipmapped: false
      )
      descriptor.usage = .shaderRead
      whiteTexture = device.makeTexture(descriptor: descriptor)
      var white: UInt32 = 0xFFFF_FFFF
      whiteTexture?.replace(
        region: MTLRegionMake2D(0, 0, 1, 1),
        mipmapLevel: 0,
        withBytes: &white,
        bytesPerRow: MemoryLayout<UInt32>.size
      )
    }
  }

  func renderPrepass(
    commandBuffer: MTLCommandBuffer,
    device: MTLDevice,
    drawableSize: CGSize,
    colorFormat: MTLPixelFormat,
    depthFormat: MTLPixelFormat,
    markers: [VolumeMarker],
    sceneMeshAssets: [UUID: SceneMeshAsset],
    sceneMeshInstances: [SceneMeshInstance],
    spatialToolPreviews: [SpatialToolPreview],
    selectedMarkerIDs: Set<UUID>,
    measurements: [VolumeMeasurement],
    selectedMeasurementID: UUID?,
    selectedMeasurementPointID: UUID?,
    viewProjection: simd_float4x4,
    modelMatrix: simd_float4x4,
    volumeScale: simd_float4x4,
    datasetMaximumExtentMeters: Float,
    eyePosition: SIMD3<Float>
  ) -> (color: MTLTexture, depth: MTLTexture)? {
    guard drawableSize.width >= 1,
          drawableSize.height >= 1,
          let markerPipeline,
          let sceneMeshPipeline,
          let markerDepthState,
          let measurementSurfaceDepthState,
          let sphereBuffer,
          let sphereNormalBuffer else {
      return nil
    }
    guard let targets = targets(
      device: device,
      drawableSize: drawableSize,
      colorFormat: colorFormat,
      depthFormat: depthFormat
    ) else {
      return nil
    }

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = targets.color
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    descriptor.depthAttachment.texture = targets.depth
    descriptor.depthAttachment.loadAction = .clear
    descriptor.depthAttachment.storeAction = .store
    descriptor.depthAttachment.clearDepth = 0

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      return nil
    }
    encoder.label = "Screen Volume Marker Prepass"
    encoder.setRenderPipelineState(markerPipeline)
    encoder.setDepthStencilState(markerDepthState)
    encoder.setCullMode(.back)
    encoder.setFrontFacing(.counterClockwise)
    encoder.setVertexBuffer(
      sphereBuffer,
      offset: 0,
      index: VertexBufferIndex.meshPositions.rawValue
    )
    encoder.setVertexBuffer(sphereNormalBuffer, offset: 0, index: 24)

    var viewProjection = viewProjection
    var eyePosition = eyePosition
    encoder.setVertexBytes(&viewProjection, length: MemoryLayout<simd_float4x4>.stride, index: 20)
    encoder.setVertexBytes(&eyePosition, length: MemoryLayout<SIMD3<Float>>.stride, index: 22)

    sceneMeshGPUCache.retainOnly(assetIDs: Set(sceneMeshInstances.map(\.asset.assetID)))
    if datasetMaximumExtentMeters.isFinite, datasetMaximumExtentMeters > 0 {
      encoder.setRenderPipelineState(sceneMeshPipeline)
      for instance in sceneMeshInstances where instance.isVisible {
        guard let asset = sceneMeshAssets[instance.asset.assetID],
              let gpuAsset = sceneMeshGPUCache.asset(for: asset, device: device) else { continue }
        var meshModel = modelMatrix *
          matrixScale(SIMD3<Float>(repeating: 1 / datasetMaximumExtentMeters)) *
          instance.transformMeters
        var normalMatrix = simd_transpose(simd_inverse(meshModel))
        var baseColor = asset.baseColor
        encoder.setVertexBuffer(
          gpuAsset.vertexBuffer,
          offset: 0,
          index: VertexBufferIndex.meshPositions.rawValue
        )
        encoder.setVertexBytes(
          &meshModel,
          length: MemoryLayout<simd_float4x4>.stride,
          index: 21
        )
        encoder.setVertexBytes(
          &normalMatrix,
          length: MemoryLayout<simd_float4x4>.stride,
          index: 24
        )
        encoder.setFragmentBytes(
          &baseColor,
          length: MemoryLayout<SIMD3<Float>>.stride,
          index: 23
        )
        encoder.setFragmentTexture(
          gpuAsset.texture ?? whiteTexture,
          index: TextureIndex.sceneMeshColor.rawValue
        )
        encoder.drawIndexedPrimitives(
          type: .triangle,
          indexCount: gpuAsset.indexCount,
          indexType: .uint32,
          indexBuffer: gpuAsset.indexBuffer,
          indexBufferOffset: 0
        )
      }
      encoder.setRenderPipelineState(markerPipeline)
    }

    let coordinateScale = SIMD3<Float>(
      volumeScale.columns.0.x,
      volumeScale.columns.1.y,
      volumeScale.columns.2.z
    )
    var measurementLineMarkers: [VolumeMarker] = []
    for measurement in measurements {
      let selected = selectedMeasurementID == measurement.id
      let color = VolumeMeasurementPresentation.color(for: measurement.kind, selected: selected)
      for (edgeIndex, edge) in measurement.geometry.edges.enumerated() {
        measurementLineMarkers.append(VolumeMarker(
          id: VolumeMeasurementPresentation.visualizationID(
            measurement.id,
            index: 0x1000 + edgeIndex
          ),
          name: measurement.name,
          color: color,
          geometry: .stroke([
            VolumeMarkerPoint(position: edge.start, radius: 0.0015),
            VolumeMarkerPoint(position: edge.end, radius: 0.0015)
          ])
        ))
      }
    }
    tubeMeshCache.retainOnly(markerIDs: Set((markers + measurementLineMarkers).map(\.id)))
    measurementSurfaceMeshCache.retainOnly(measurementIDs: Set(measurements.map(\.id)))

    func markerColor(_ marker: VolumeMarker) -> SIMD4<Float> {
      VolumeMarkerPresentation.color(
        for: marker,
        isSelected: selectedMarkerIDs.contains(marker.id)
      )
    }

    func drawSphere(_ point: VolumeMarkerPoint, color: SIMD4<Float>) {
      var color = color
      let volumePosition = simd_make_float3(
        volumeScale * SIMD4<Float>(point.position - SIMD3<Float>(repeating: 0.5), 1)
      )
      var markerModel = modelMatrix *
        matrixTranslation(volumePosition) *
        matrixScale(SIMD3<Float>(repeating: point.radius))
      encoder.setVertexBuffer(sphereBuffer, offset: 0, index: VertexBufferIndex.meshPositions.rawValue)
      encoder.setVertexBuffer(sphereNormalBuffer, offset: 0, index: 24)
      encoder.setVertexBytes(&markerModel, length: MemoryLayout<simd_float4x4>.stride, index: 21)
      encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 23)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: sphereVertexCount)
    }

    func drawTube(for marker: VolumeMarker, color: SIMD4<Float>) {
      guard let mesh = tubeMeshCache.mesh(
        for: marker,
        coordinateScale: coordinateScale,
        device: device
      ) else { return }
      var markerModel = modelMatrix
      var color = color
      encoder.setVertexBuffer(
        mesh.positionBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      encoder.setVertexBuffer(mesh.normalBuffer, offset: 0, index: 24)
      encoder.setVertexBytes(
        &markerModel,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      encoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: mesh.vertexCount
      )
    }

    func drawMeasurementSurface(
      _ measurement: VolumeMeasurement,
      color: SIMD4<Float>,
      writesDepth: Bool
    ) {
      guard let mesh = measurementSurfaceMeshCache.mesh(
        for: measurement,
        coordinateScale: coordinateScale,
        device: device
      ) else { return }
      var markerModel = modelMatrix
      var color = color
      encoder.setDepthStencilState(writesDepth ? markerDepthState : measurementSurfaceDepthState)
      encoder.setCullMode(.none)
      encoder.setVertexBuffer(mesh.positionBuffer, offset: 0, index: VertexBufferIndex.meshPositions.rawValue)
      encoder.setVertexBuffer(mesh.normalBuffer, offset: 0, index: 24)
      encoder.setVertexBytes(&markerModel, length: MemoryLayout<simd_float4x4>.stride, index: 21)
      encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 23)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
    }

    for measurement in measurements where !measurement.geometry.triangleVertices.isEmpty {
      let selected = selectedMeasurementID == measurement.id
      var color = VolumeMeasurementPresentation.color(for: measurement.kind, selected: selected)
      color.w = measurement.kind == .area ? 0.34 : 0.24
      drawMeasurementSurface(measurement, color: color, writesDepth: false)
    }

    encoder.setDepthStencilState(markerDepthState)
    encoder.setCullMode(.back)

    for marker in markers {
      let color = markerColor(marker)
      switch marker.geometry {
        case .sphere(let point):
          drawTube(for: marker, color: color)
          drawSphere(point, color: color)
        case .stroke(let points):
          drawTube(for: marker, color: color)
          if let first = points.first {
            drawSphere(first, color: color)
          }
          if points.count > 1, let last = points.last {
            drawSphere(last, color: color)
          }
      }
    }
    for preview in spatialToolPreviews {
      drawSphere(preview.point, color: preview.color)
    }
    for marker in measurementLineMarkers {
      drawTube(for: marker, color: marker.color)
    }
    for measurement in measurements {
      let selected = selectedMeasurementID == measurement.id
      let color = VolumeMeasurementPresentation.color(for: measurement.kind, selected: selected)
      for (pointIndex, point) in measurement.geometry.points.enumerated() {
        let isSelected = selected && selectedMeasurementPointID == point.id
        let isPlaneAnchor = measurement.kind == .area && pointIndex < 3
        let pointColor = isSelected
          ? SIMD4<Float>(1, 0.22, 0.03, 1)
          : (isPlaneAnchor ? SIMD4<Float>(1, 1, 1, 1) : color)
        drawSphere(
          VolumeMarkerPoint(
            position: point.position,
            radius: isSelected ? 0.014 : (isPlaneAnchor ? 0.012 : 0.010)
          ),
          color: pointColor
        )
      }
    }
    for measurement in measurements where !measurement.geometry.triangleVertices.isEmpty {
      drawMeasurementSurface(measurement, color: .zero, writesDepth: true)
    }
    encoder.endEncoding()
    return targets
  }

  func bindDepth(_ texture: MTLTexture, to encoder: MTLRenderCommandEncoder) {
    encoder.setFragmentTexture(texture, index: TextureIndex.markerDepth.rawValue)
  }

  func composite(
    colorTexture: MTLTexture,
    depthTexture: MTLTexture,
    to encoder: MTLRenderCommandEncoder
  ) {
    guard let compositePipeline, let compositeDepthState else { return }
    encoder.pushDebugGroup("Composite Volume Markers")
    encoder.setRenderPipelineState(compositePipeline)
    encoder.setDepthStencilState(compositeDepthState)
    encoder.setCullMode(.none)
    encoder.setFragmentTexture(colorTexture, index: TextureIndex.markerColor.rawValue)
    encoder.setFragmentTexture(depthTexture, index: TextureIndex.markerDepth.rawValue)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.popDebugGroup()
  }

  func resetTargets() {
    colorTexture = nil
    depthTexture = nil
  }

  private func targets(
    device: MTLDevice,
    drawableSize: CGSize,
    colorFormat: MTLPixelFormat,
    depthFormat: MTLPixelFormat
  ) -> (color: MTLTexture, depth: MTLTexture)? {
    let width = max(1, Int(drawableSize.width))
    let height = max(1, Int(drawableSize.height))
    if colorTexture?.width != width ||
       colorTexture?.height != height ||
       colorTexture?.pixelFormat != colorFormat {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: colorFormat,
        width: width,
        height: height,
        mipmapped: false
      )
      descriptor.storageMode = .private
      descriptor.usage = [.renderTarget, .shaderRead]
      colorTexture = device.makeTexture(descriptor: descriptor)
      colorTexture?.label = "Screen Volume Marker Color"
    }
    if depthTexture?.width != width ||
       depthTexture?.height != height ||
       depthTexture?.pixelFormat != depthFormat {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: depthFormat,
        width: width,
        height: height,
        mipmapped: false
      )
      descriptor.storageMode = .private
      descriptor.usage = [.renderTarget, .shaderRead]
      depthTexture = device.makeTexture(descriptor: descriptor)
      depthTexture?.label = "Screen Volume Marker Depth"
    }
    guard let colorTexture, let depthTexture else { return nil }
    return (colorTexture, depthTexture)
  }
}
