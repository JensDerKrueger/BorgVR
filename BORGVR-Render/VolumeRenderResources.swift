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
