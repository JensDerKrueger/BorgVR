import Metal
import simd

enum VolumeRenderResources {
  private static func physicalExtent(for metadata: BORGVRMetaData) -> SIMD3<Float> {
    metadata.physicalExtentMeters
  }

  static func normalizedVolumeExtent(for metadata: BORGVRMetaData) -> SIMD3<Float> {
    let physicalExtent = physicalExtent(for: metadata)
    let maximumExtent = max(physicalExtent.x, physicalExtent.y, physicalExtent.z)
    guard maximumExtent.isFinite, maximumExtent > 0 else {
      return SIMD3<Float>(repeating: 1)
    }
    return physicalExtent / maximumExtent
  }

  static func levelZeroWorldSpaceError(for metadata: BORGVRMetaData) -> Float {
    let physicalExtent = physicalExtent(for: metadata)
    let maximumExtent = max(physicalExtent.x, physicalExtent.y, physicalExtent.z)
    guard maximumExtent.isFinite, maximumExtent > 0 else {
      return 1
    }
    let error = max(metadata.voxelSpacingX, metadata.voxelSpacingY, metadata.voxelSpacingZ) / maximumExtent
    return error.isFinite && error > 0 ? error : 1
  }

  static func volumeScale(for metadata: BORGVRMetaData) -> simd_float4x4 {
    let scale = normalizedVolumeExtent(for: metadata)
    return simd_float4x4(
      SIMD4<Float>(scale.x, 0, 0, 0),
      SIMD4<Float>(0, scale.y, 0, 0),
      SIMD4<Float>(0, 0, scale.z, 0),
      SIMD4<Float>(0, 0, 0, 1)
    )
  }

  static func minimumHashTableElementCount(
    metadata: BORGVRMetaData,
    representedMemoryMB: Int,
    minimumElementCount: Int = 0
  ) -> Int {
    let bytesPerBrick = metadata.componentCount * metadata.bytesPerComponent *
      metadata.brickSize * metadata.brickSize * metadata.brickSize
    return max(
      minimumElementCount,
      Int(ceil(Double(representedMemoryMB * 1024 * 1024) / Double(bytesPerBrick)))
    )
  }

  static func pageInInitialBricks(
    atlas: VolumeAtlas,
    dataset: BORGVRDatasetProtocol,
    maximumCount: Int
  ) throws {
    let metadata = dataset.getMetadata()
    let start = metadata.brickMetadata.count - 2
    let count = min(maximumCount, metadata.brickMetadata.count - 1)
    guard start >= 0, count > 0 else { return }
    try atlas.pageIn(IDs: (0..<count).map { start - $0 })
  }
}

/// CPU-readable interaction data produced by the most recently completed volume pass.
/// The texture stores Metal clip-space depth; the matching matrices reconstruct a
/// normalized volume position without rerunning the raycaster on the CPU.
final class VolumeInteractionDepthSnapshot {
  private let texture: MTLTexture
  private let frozenDepthValues: [Float]?
  private let textureToClip: [simd_float4x4]
  private let worldToClip: [simd_float4x4]
  private let worldFromVolume: simd_float4x4?
  private let headPosition: SIMD3<Float>?
  private let rasterizationRateMap: MTLRasterizationRateMap?

  init(
    texture: MTLTexture,
    textureToClip: [simd_float4x4],
    worldToClip: [simd_float4x4] = [],
    worldFromVolume: simd_float4x4? = nil,
    headPosition: SIMD3<Float>? = nil,
    rasterizationRateMap: MTLRasterizationRateMap? = nil,
    frozenDepthValues: [Float]? = nil
  ) {
    self.texture = texture
    self.frozenDepthValues = frozenDepthValues
    self.textureToClip = textureToClip
    self.worldToClip = worldToClip
    self.worldFromVolume = worldFromVolume
    self.headPosition = headPosition
    self.rasterizationRateMap = rasterizationRateMap
  }

  /// Makes the depth samples immutable so geometry created during an interaction
  /// cannot feed back into the following samples of that same interaction.
  func frozenCopy() -> VolumeInteractionDepthSnapshot {
    let sliceCount = max(texture.arrayLength, 1)
    let valuesPerSlice = texture.width * texture.height
    var values = [Float](repeating: -1, count: valuesPerSlice * sliceCount)
    values.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      for slice in 0..<sliceCount {
        texture.getBytes(
          baseAddress.advanced(by: slice * valuesPerSlice * MemoryLayout<Float>.stride),
          bytesPerRow: texture.width * MemoryLayout<Float>.stride,
          bytesPerImage: valuesPerSlice * MemoryLayout<Float>.stride,
          from: MTLRegionMake2D(0, 0, texture.width, texture.height),
          mipmapLevel: 0,
          slice: slice
        )
      }
    }
    return VolumeInteractionDepthSnapshot(
      texture: texture,
      textureToClip: textureToClip,
      worldToClip: worldToClip,
      worldFromVolume: worldFromVolume,
      headPosition: headPosition,
      rasterizationRateMap: rasterizationRateMap,
      frozenDepthValues: values
    )
  }

  func normalizedVolumePosition(
    at normalizedScreenPosition: SIMD2<Float>,
    smoothingDepthFrom previousPosition: SIMD3<Float>? = nil,
    depthSmoothingNewSampleWeight: Float = 0.35
  ) -> SIMD3<Float>? {
    guard let matrix = textureToClip.first else { return nil }
    let clamped = simd_clamp(
      normalizedScreenPosition,
      SIMD2<Float>(repeating: 0),
      SIMD2<Float>(repeating: 1)
    )
    let pixel = SIMD2<Int>(
      min(texture.width - 1, max(0, Int(clamped.x * Float(texture.width)))),
      min(texture.height - 1, max(0, Int((1 - clamped.y) * Float(texture.height))))
    )
    guard let depth = depth(at: pixel, slice: 0) else { return nil }
    return position(
      atNDC: SIMD2<Float>(clamped.x * 2 - 1, clamped.y * 2 - 1),
      depth: depth,
      textureToClip: matrix,
      smoothingDepthFrom: previousPosition,
      depthSmoothingNewSampleWeight: depthSmoothingNewSampleWeight
    )
  }

  func normalizedVolumePosition(
    projectingToward worldTarget: SIMD3<Float>,
    smoothingDepthFrom previousPosition: SIMD3<Float>? = nil,
    maximumWorldDepthDifference: Float? = nil,
    depthSmoothingNewSampleWeight: Float = 0.35
  ) -> SIMD3<Float>? {
    guard let headPosition,
          let worldFromVolume,
          worldToClip.count == textureToClip.count,
          !worldToClip.isEmpty else { return nil }
    let rayVector = worldTarget - headPosition
    let rayLengthSquared = simd_length_squared(rayVector)
    guard rayLengthSquared > 0.000_001 else { return nil }
    let rayDirection = rayVector / sqrt(rayLengthSquared)

    var best: (
      position: SIMD3<Float>,
      distanceSquared: Float,
      ndc: SIMD2<Float>,
      depth: Float,
      layer: Int
    )?
    for layer in worldToClip.indices {
      let projected = worldToClip[layer] * SIMD4<Float>(worldTarget, 1)
      guard projected.w > 0.000_001 else { continue }
      let ndc = SIMD3<Float>(projected.x, projected.y, projected.z) / projected.w
      guard abs(ndc.x) <= 1, abs(ndc.y) <= 1 else { continue }

      let pixel = physicalPixel(forNDC: SIMD2<Float>(ndc.x, ndc.y), layer: layer)
      guard let depth = depth(at: pixel, slice: layer),
            let normalizedPosition = unproject(
              clip: SIMD4<Float>(ndc.x, ndc.y, depth, 1),
              textureToClip: textureToClip[layer]
            ) else { continue }

      let centered = normalizedPosition - SIMD3<Float>(repeating: 0.5)
      let world4 = worldFromVolume * SIMD4<Float>(centered, 1)
      guard abs(world4.w) > 0.000_001 else { continue }
      let worldPosition = SIMD3<Float>(world4.x, world4.y, world4.z) / world4.w
      let alongRay = simd_dot(worldPosition - headPosition, rayDirection)
      guard alongRay >= 0 else { continue }
      if let maximumWorldDepthDifference,
         abs(alongRay - sqrt(rayLengthSquared)) > maximumWorldDepthDifference {
        continue
      }
      let closestPoint = headPosition + rayDirection * alongRay
      let distanceSquared = simd_distance_squared(worldPosition, closestPoint)
      if best == nil || distanceSquared < best!.distanceSquared {
        best = (
          normalizedPosition,
          distanceSquared,
          SIMD2<Float>(ndc.x, ndc.y),
          depth,
          layer
        )
      }
    }
    guard let best else { return nil }
    return position(
      atNDC: best.ndc,
      depth: best.depth,
      textureToClip: textureToClip[best.layer],
      smoothingDepthFrom: previousPosition,
      depthSmoothingNewSampleWeight: depthSmoothingNewSampleWeight
    ) ?? best.position
  }

  private func position(
    atNDC ndc: SIMD2<Float>,
    depth: Float,
    textureToClip: simd_float4x4,
    smoothingDepthFrom previousPosition: SIMD3<Float>?,
    depthSmoothingNewSampleWeight: Float
  ) -> SIMD3<Float>? {
    guard let rawPosition = unproject(
      clip: SIMD4<Float>(ndc.x, ndc.y, depth, 1),
      textureToClip: textureToClip
    ) else { return nil }
    guard let previousPosition else { return rawPosition }
    guard let nearPosition = unproject(
      clip: SIMD4<Float>(ndc.x, ndc.y, 1, 1),
      textureToClip: textureToClip
    ), let farPosition = unproject(
      clip: SIMD4<Float>(ndc.x, ndc.y, 0, 1),
      textureToClip: textureToClip
    ) else { return rawPosition }
    let ray = farPosition - nearPosition
    let rayLengthSquared = simd_length_squared(ray)
    guard rayLengthSquared.isFinite, rayLengthSquared > 0.000_001 else {
      return rawPosition
    }
    let direction = ray / sqrt(rayLengthSquared)
    let rawDistance = simd_dot(rawPosition - nearPosition, direction)
    let previousDistance = simd_dot(previousPosition - nearPosition, direction)
    let depthDelta = rawDistance - previousDistance
    guard depthDelta.isFinite, abs(depthDelta) <= 0.05 else { return rawPosition }
    let newSampleWeight = simd_clamp(depthSmoothingNewSampleWeight, 0, 1)
    return nearPosition + direction * (previousDistance + depthDelta * newSampleWeight)
  }

  private func physicalPixel(forNDC ndc: SIMD2<Float>, layer: Int) -> SIMD2<Int> {
    let screenWidth = Float(rasterizationRateMap?.screenSize.width ?? texture.width)
    let screenHeight = Float(rasterizationRateMap?.screenSize.height ?? texture.height)
    let screen = MTLCoordinate2D(
      x: (ndc.x + 1) * 0.5 * screenWidth,
      y: (1 - ndc.y) * 0.5 * screenHeight
    )
    let physical = rasterizationRateMap?.physicalCoordinates(
      screenCoordinates: screen,
      layer: layer
    ) ?? screen
    return SIMD2<Int>(
      min(texture.width - 1, max(0, Int(physical.x))),
      min(texture.height - 1, max(0, Int(physical.y)))
    )
  }

  private func depth(at pixel: SIMD2<Int>, slice: Int) -> Float? {
    guard pixel.x >= 0, pixel.x < texture.width,
          pixel.y >= 0, pixel.y < texture.height,
          slice >= 0, slice < max(texture.arrayLength, 1) else { return nil }
    let value: Float
    if let frozenDepthValues {
      let index = slice * texture.width * texture.height + pixel.y * texture.width + pixel.x
      guard frozenDepthValues.indices.contains(index) else { return nil }
      value = frozenDepthValues[index]
    } else {
      var currentValue: Float = -1
      texture.getBytes(
        &currentValue,
        bytesPerRow: MemoryLayout<Float>.stride,
        bytesPerImage: MemoryLayout<Float>.stride,
        from: MTLRegionMake2D(pixel.x, pixel.y, 1, 1),
        mipmapLevel: 0,
        slice: slice
      )
      value = currentValue
    }
    guard value.isFinite, value >= 0, value <= 1 else { return nil }
    return value
  }

  private func unproject(
    clip: SIMD4<Float>,
    textureToClip: simd_float4x4
  ) -> SIMD3<Float>? {
    let local = simd_inverse(textureToClip) * clip
    guard abs(local.w) > 0.000_001 else { return nil }
    let position = SIMD3<Float>(local.x, local.y, local.z) / local.w
    guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
    return position
  }
}
