import simd

enum VolumeRenderResources {
  static func volumeScale(for metadata: BORGVRMetaData) -> simd_float4x4 {
    let physicalExtent = SIMD3<Float>(
      metadata.aspectX * Float(metadata.width),
      metadata.aspectY * Float(metadata.height),
      metadata.aspectZ * Float(metadata.depth)
    )
    let maximumExtent = max(physicalExtent.x, physicalExtent.y, physicalExtent.z)
    guard maximumExtent.isFinite, maximumExtent > 0 else {
      return matrix_identity_float4x4
    }
    let scale = physicalExtent / maximumExtent
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
