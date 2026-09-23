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
          let markerCompositeVertexFunction = library.makeFunction(name: "screenMarkerCompositeVertex"),
          let markerCompositeFragmentFunction = library.makeFunction(name: "screenMarkerCompositeFragment") else {
      throw VolumeRendererPipelineError.missingShaderFunction("screen marker shaders")
    }

    let markerDescriptor = MTLRenderPipelineDescriptor()
    markerDescriptor.label = "\(labelPrefix) Volume Marker"
    markerDescriptor.vertexFunction = markerVertexFunction
    markerDescriptor.fragmentFunction = markerFragmentFunction
    markerDescriptor.colorAttachments[0].pixelFormat = colorFormat
    markerDescriptor.depthAttachmentPixelFormat = depthFormat

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
      try device.makeRenderPipelineState(descriptor: compositeDescriptor)
    )
  }
}

@MainActor
final class ScreenVolumeMarkerRenderer {
  private var markerPipeline: MTLRenderPipelineState?
  private var compositePipeline: MTLRenderPipelineState?
  private var markerDepthState: MTLDepthStencilState?
  private var compositeDepthState: MTLDepthStencilState?
  private var sphereBuffer: MTLBuffer?
  private var sphereNormalBuffer: MTLBuffer?
  private var sphereVertexCount = 0
  private let tubeMeshCache = VolumeMarkerTubeMeshCache()
  private var colorTexture: MTLTexture?
  private var depthTexture: MTLTexture?

  func configure(
    device: MTLDevice,
    markerPipeline: MTLRenderPipelineState,
    compositePipeline: MTLRenderPipelineState
  ) {
    self.markerPipeline = markerPipeline
    self.compositePipeline = compositePipeline

    if markerDepthState == nil {
      let descriptor = MTLDepthStencilDescriptor()
      descriptor.depthCompareFunction = .greater
      descriptor.isDepthWriteEnabled = true
      markerDepthState = device.makeDepthStencilState(descriptor: descriptor)
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
  }

  func renderPrepass(
    commandBuffer: MTLCommandBuffer,
    device: MTLDevice,
    drawableSize: CGSize,
    colorFormat: MTLPixelFormat,
    depthFormat: MTLPixelFormat,
    markers: [VolumeMarker],
    spatialStylusPreviews: [SpatialStylusPreview],
    selectedMarkerID: UUID?,
    viewProjection: simd_float4x4,
    modelMatrix: simd_float4x4,
    volumeScale: simd_float4x4,
    eyePosition: SIMD3<Float>
  ) -> (color: MTLTexture, depth: MTLTexture)? {
    guard drawableSize.width >= 1,
          drawableSize.height >= 1,
          let markerPipeline,
          let markerDepthState,
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

    let coordinateScale = SIMD3<Float>(
      volumeScale.columns.0.x,
      volumeScale.columns.1.y,
      volumeScale.columns.2.z
    )
    tubeMeshCache.retainOnly(markerIDs: Set(markers.map(\.id)))

    func markerColor(_ marker: VolumeMarker) -> SIMD4<Float> {
      VolumeMarkerPresentation.color(
        for: marker,
        isSelected: marker.id == selectedMarkerID
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
    for preview in spatialStylusPreviews {
      drawSphere(preview.point, color: preview.color)
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
