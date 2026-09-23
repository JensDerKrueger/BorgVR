import simd

enum VolumeRenderResources {
  static func volumeScale(for metadata: BORGVRMetaData) -> simd_float4x4 {
    let maximumExtent = Float(max(metadata.width, metadata.height, metadata.depth))
    let scale = SIMD3<Float>(
      metadata.aspectX * Float(metadata.width) / maximumExtent,
      metadata.aspectY * Float(metadata.height) / maximumExtent,
      metadata.aspectZ * Float(metadata.depth) / maximumExtent
    )
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
