import Metal

struct VolumeShaderConfiguration {
  let screenSpaceError: Float
  let atlasSizeMB: Int
  let maximumProbingAttempts: Int
  let requestsLowResolutionLOD: Bool
  let stopsOnMissingBrick: Bool
  let fieldOfViewRadians: Float
  let drawableWidth: Float
}

enum VolumeShaderCompiler {
  static func compileOptions(
    metadata: BORGVRMetaData,
    hashTableSize: Int,
    configuration: VolumeShaderConfiguration
  ) -> MTLCompileOptions {
    let lodFactor = 2 * tan(configuration.fieldOfViewRadians / 2) *
      configuration.screenSpaceError / max(configuration.drawableWidth, 1)
    let levelZeroWorldSpaceError = max(
      metadata.aspectX / Float(metadata.width),
      metadata.aspectY / Float(metadata.height),
      metadata.aspectZ / Float(metadata.depth)
    )
    let (atlasWidth, atlasHeight, atlasDepth, _) = VolumeAtlas.computeAtlasSize(
      maxMemory: configuration.atlasSizeMB * 1024 * 1024,
      maxBrickCount: metadata.brickMetadata.count,
      brickSize: metadata.brickSize,
      bytesPerComponent: metadata.bytesPerComponent,
      componentCount: metadata.componentCount
    )
    let maximumIterations = metadata.levelMetadata[0].totalBricks.x - 1 +
      metadata.levelMetadata[0].totalBricks.y - 1 +
      metadata.levelMetadata[0].totalBricks.z - 1 + 1

    let options = MTLCompileOptions()
    options.preprocessorMacros = [
      "OVERRIDE_DUMMY": NSNumber(value: 1),
      "LEVEL_COUNT": NSNumber(value: metadata.levelMetadata.count),
      "BRICK_SIZE": NSNumber(value: metadata.brickSize),
      "BRICK_INNER_SIZE": NSNumber(value: metadata.brickSize - metadata.overlap * 2),
      "OVERLAP_STEP": NSString(
        string: "float3(\(Float(metadata.overlap) / Float(atlasWidth)),\(Float(metadata.overlap) / Float(atlasHeight)),\(Float(metadata.overlap) / Float(atlasDepth)))"
      ),
      "LEVEL_ZERO_WORLD_SPACE_ERROR": NSNumber(value: levelZeroWorldSpaceError),
      "LOD_FACTOR": NSNumber(value: lodFactor),
      "POOL_SIZE": NSString(string: "float3(\(atlasWidth),\(atlasHeight),\(atlasDepth))"),
      "VOLUME_SIZE": NSString(
        string: "float3(\(metadata.width),\(metadata.height),\(metadata.depth))"
      ),
      "POOL_CAPACITY": NSString(
        string: "uint3(\(atlasWidth / metadata.brickSize),\(atlasHeight / metadata.brickSize),\(atlasDepth / metadata.brickSize))"
      ),
      "HASHTABLE_SIZE": NSNumber(value: hashTableSize),
      "MAX_PROBING_ATTEMPTS": NSNumber(value: configuration.maximumProbingAttempts),
      "MAX_ITERATIONS": NSNumber(value: maximumIterations),
      "REQUEST_LOWRES_LOD": NSNumber(value: configuration.requestsLowResolutionLOD ? 1 : 0),
      "STOP_ON_MISS": NSNumber(value: configuration.stopsOnMissingBrick ? 1 : 0)
    ]
    if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
      options.mathMode = .fast
    }
    return options
  }
}
