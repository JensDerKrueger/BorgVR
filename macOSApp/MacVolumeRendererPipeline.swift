import Metal
import MetalKit

enum MacVolumeRendererPipelineError: LocalizedError {
  case missingShaderSource(String)
  case missingShaderFunction(String, String)

  var errorDescription: String? {
    switch self {
      case let .missingShaderSource(shaderName):
        return "\(shaderName).metal wurde nicht im App-Bundle gefunden."
      case let .missingShaderFunction(name, shaderName):
        return "Metal-Funktion \(name) wurde in \(shaderName).metal nicht gefunden."
    }
  }
}

enum RuntimeShaderVariant {
  case current
  case previous

  var resourceName: String {
    switch self {
      case .current:
        return "RuntimeVolumeShaders"
      case .previous:
        return "RuntimeVolumeShadersPrevious"
    }
  }

  var displayName: String {
    switch self {
      case .current:
        return "current"
      case .previous:
        return "previous"
    }
  }

  var toggled: RuntimeShaderVariant {
    self == .current ? .previous : .current
  }
}

extension MacVolumeRenderer {
  static func buildRenderPipelines(
    device: MTLDevice,
    colorFormat: MTLPixelFormat,
    depthFormat: MTLPixelFormat,
    drawableWidth: Float,
    metadata: BORGVRMetaData,
    hashTable: GPUHashtable,
    appSettings: AppSettings,
    shaderVariant: RuntimeShaderVariant
  ) throws -> (tf: MTLRenderPipelineState, tfl: MTLRenderPipelineState, iso: MTLRenderPipelineState, brick: MTLRenderPipelineState) {
    let shaderName = shaderVariant.resourceName
    guard let shaderPath = Bundle.main.path(forResource: shaderName, ofType: "metal") else {
      throw MacVolumeRendererPipelineError.missingShaderSource(shaderName)
    }
    let shaderSource = try String(contentsOfFile: shaderPath, encoding: .utf8)

    let screenSpaceError = Float(appSettings.screenSpaceError)
    let lodFactor = 2.0 * tan(0.75 / 2.0) * screenSpaceError / max(drawableWidth, 1)
    let levelZeroWorldSpaceError = max(
      metadata.aspectX / Float(metadata.width),
      metadata.aspectY / Float(metadata.height),
      metadata.aspectZ / Float(metadata.depth)
    )

    let (atlasWidth, atlasHeight, atlasDepth, _) = VolumeAtlas.computeAtlasSize(
      maxMemory: appSettings.atlasSizeMB * 1024 * 1024,
      maxBrickCount: metadata.brickMetadata.count,
      brickSize: metadata.brickSize,
      bytesPerComponent: metadata.bytesPerComponent,
      componentCount: metadata.componentCount
    )

    func maxCellsIntersected(in grid: Vec3<Int>) -> Int {
      grid.x - 1 + grid.y - 1 + grid.z - 1 + 1
    }

    let compileOptions = MTLCompileOptions()
    compileOptions.preprocessorMacros = [
      "OVERRIDE_DUMMY": NSNumber(value: 1),
      "LEVEL_COUNT": NSNumber(value: metadata.levelMetadata.count),
      "BRICK_SIZE": NSNumber(value: metadata.brickSize),
      "BRICK_INNER_SIZE": NSNumber(value: metadata.brickSize - metadata.overlap * 2),
      "OVERLAP_STEP": NSString(string: "float3(\(Float(metadata.overlap) / Float(atlasWidth)),\(Float(metadata.overlap) / Float(atlasHeight)),\(Float(metadata.overlap) / Float(atlasDepth)))"),
      "LEVEL_ZERO_WORLD_SPACE_ERROR": NSNumber(value: levelZeroWorldSpaceError),
      "LOD_FACTOR": NSNumber(value: lodFactor),
      "POOL_SIZE": NSString(string: "float3(\(atlasWidth),\(atlasHeight),\(atlasDepth))"),
      "VOLUME_SIZE": NSString(string: "float3(\(metadata.width),\(metadata.height),\(metadata.depth))"),
      "POOL_CAPACITY": NSString(string: "uint3(\(atlasWidth / metadata.brickSize),\(atlasHeight / metadata.brickSize),\(atlasDepth / metadata.brickSize))"),
      "HASHTABLE_SIZE": NSNumber(value: hashTable.size),
      "MAX_PROBING_ATTEMPTS": NSNumber(value: appSettings.maxProbingAttempts),
      "MAX_ITERATIONS": NSNumber(value: maxCellsIntersected(in: metadata.levelMetadata[0].totalBricks)),
      "REQUEST_LOWRES_LOD": NSNumber(value: appSettings.requestLowResLOD ? 1 : 0),
      "STOP_ON_MISS": NSNumber(value: appSettings.stopOnMiss ? 1 : 0)
    ]
    if #available(macOS 15.0, *) {
      compileOptions.mathMode = .fast
    }

    let library = try device.makeLibrary(source: shaderSource, options: compileOptions)
    guard let vertexFunction = library.makeFunction(name: "volumeVertexShader") else {
      throw MacVolumeRendererPipelineError.missingShaderFunction("volumeVertexShader", shaderName)
    }

    func descriptor(label: String, fragmentName: String) throws -> MTLRenderPipelineDescriptor {
      guard let fragmentFunction = library.makeFunction(name: fragmentName) else {
        throw MacVolumeRendererPipelineError.missingShaderFunction(fragmentName, shaderName)
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

    return (
      try device.makeRenderPipelineState(descriptor: descriptor(label: "macOS TF", fragmentName: "volumeFragmentShaderTF")),
      try device.makeRenderPipelineState(descriptor: descriptor(label: "macOS TF Lighting", fragmentName: "volumeFragmentShaderTFLighting")),
      try device.makeRenderPipelineState(descriptor: descriptor(label: "macOS Iso", fragmentName: "volumeFragmentShaderIso")),
      try device.makeRenderPipelineState(descriptor: descriptor(label: "macOS Brick", fragmentName: "volumeFragmentShaderBrickVis"))
    )
  }
}
