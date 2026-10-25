import Foundation

enum BorgVRVolumeEditBorderMode: String, Codable, Sendable {
  case zero
  case clamp
  case repeatValue
}

struct BorgVRMaterializedEditBrick {
  let index: Int
  let revision: UInt64
  let bytes: [UInt8]
  let componentRanges: [BORGVRComponentRange]
  /// A true result permits removing the override and using the original brick again.
  let matchesOriginal: Bool
}

protocol BorgVRVolumeEditExecutor {
  func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                   isCancelled: @escaping () -> Bool) throws
    -> BorgVRMaterializedEditBrick
}

extension BorgVRVolumeEditExecutor {
  func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64) throws -> BorgVRMaterializedEditBrick {
    try materialize(index: index, mask: mask, revision: revision, isCancelled: { false })
  }
}

/// CPU reference implementation. Call on a worker, with a stable mask snapshot.
/// All scratch data is owned by the call; concurrent jobs never share decoding buffers.
final class BorgVRCPUVolumeEditExecutor: BorgVRVolumeEditExecutor {
  private let source: BORGVRDatasetProtocol
  private let metadata: BORGVRMetaData
  private let border: BorgVRVolumeEditBorderMode

  init(source: BORGVRDatasetProtocol, border: BorgVRVolumeEditBorderMode) throws {
    let metadata = source.getMetadata()
    guard [1, 2, 4].contains(metadata.bytesPerComponent), metadata.componentCount > 0,
          metadata.brickSize > metadata.overlap * 2 else {
      throw BorgVRVolumeEditError.invalidGeometry
    }
    self.source = source
    self.metadata = metadata
    self.border = border
  }

  func materialize(
    index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
    isCancelled: @escaping () -> Bool
  ) throws -> BorgVRMaterializedEditBrick {
    if isCancelled() { throw CancellationError() }
    guard metadata.brickMetadata.indices.contains(index) else {
      throw BorgVRVolumeEditError.invalidBrick
    }
    guard mask.size == SIMD3(metadata.width, metadata.height, metadata.depth),
          mask.spacing == SIMD3(Double(metadata.voxelSpacingX), Double(metadata.voxelSpacingY),
                                Double(metadata.voxelSpacingZ)) else {
      throw BorgVRVolumeEditError.incompatibleDataset
    }
    let context = Context(source: source, metadata: metadata, mask: mask, border: border, isCancelled: isCancelled)
    if mask.isOriginal {
      let original = try context.originalBrick(index)
      return BorgVRMaterializedEditBrick(
        index: index, revision: revision, bytes: original,
        componentRanges: metadata.brickMetadata[index].componentRanges, matchesOriginal: true
      )
    }
    let level = metadata.levelMetadata.lastIndex { $0.prevBricks <= index }!
    let layout = metadata.levelMetadata[level]
    let localIndex = index - layout.prevBricks
    let brickCoordinate = SIMD3(
      localIndex % layout.totalBricks.x,
      (localIndex / layout.totalBricks.x) % layout.totalBricks.y,
      localIndex / (layout.totalBricks.x * layout.totalBricks.y)
    )
    let stride = metadata.brickSize - 2 * metadata.overlap
    let origin = brickCoordinate &* stride &- SIMD3(repeating: metadata.overlap)
    context.directBrick = (level, index, origin)
    let byteCount = metadata.brickSize * metadata.brickSize * metadata.brickSize *
      metadata.componentCount * metadata.bytesPerComponent
    var bytes = [UInt8](repeating: 0, count: byteCount)
    var minima = Array(repeating: UInt64.max, count: metadata.componentCount)
    var maxima = Array(repeating: UInt64(0), count: metadata.componentCount)
    for z in 0..<metadata.brickSize {
      for y in 0..<metadata.brickSize {
        try context.checkCancellation()
        for x in 0..<metadata.brickSize {
          let coordinate = origin &+ SIMD3(x, y, z)
          let voxelIndex = (z * metadata.brickSize + y) * metadata.brickSize + x
          for component in 0..<metadata.componentCount {
            let value = try context.value(level: level, coordinate: coordinate, component: component)
            let offset = (voxelIndex * metadata.componentCount + component) * metadata.bytesPerComponent
            for byte in 0..<metadata.bytesPerComponent {
              bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
            }
            minima[component] = min(minima[component], value)
            maxima[component] = max(maxima[component], value)
          }
        }
      }
    }
    // Reading the base is optional here: a fully erased remote region needs no source data.
    // A missing comparison only retains an unnecessary cache entry, never loses an edit.
    let original = context.bricks[index]
    return BorgVRMaterializedEditBrick(
      index: index, revision: revision, bytes: bytes,
      componentRanges: minima.indices.map {
        BORGVRComponentRange(minValue: Int(minima[$0]), maxValue: Int(maxima[$0]))
      }, matchesOriginal: original.map { bytes == $0 } ?? false
    )
  }

  private final class Context {
    let source: BORGVRDatasetProtocol
    let metadata: BORGVRMetaData
    let mask: BorgVRVolumeEditMask
    let border: BorgVRVolumeEditBorderMode
    let isCancelled: () -> Bool
    private var visitedValues = 0
    // Bound memory even when rebuilding a very coarse brick of a remote dataset.
    var bricks: [Int: [UInt8]] = [:]
    var brickOrder: [Int] = []
    var directBrick: (level: Int, index: Int, origin: SIMD3<Int>)?
    struct Key: Hashable { let level: Int; let coordinate: SIMD3<Int>; let component: Int }
    var values: [Key: UInt64] = [:]

    init(source: BORGVRDatasetProtocol, metadata: BORGVRMetaData,
         mask: BorgVRVolumeEditMask, border: BorgVRVolumeEditBorderMode,
         isCancelled: @escaping () -> Bool) {
      self.source = source
      self.metadata = metadata
      self.mask = mask
      self.border = border
      self.isCancelled = isCancelled
    }

    func checkCancellation() throws {
      if isCancelled() { throw CancellationError() }
    }

    func originalBrick(_ index: Int) throws -> [UInt8] {
      if let bytes = bricks[index] { return bytes }
      try checkCancellation()
      let count = metadata.brickSize * metadata.brickSize * metadata.brickSize *
        metadata.componentCount * metadata.bytesPerComponent
      var bytes = [UInt8](repeating: 0, count: count)
      try bytes.withUnsafeMutableBufferPointer {
        try source.getBrick(index: index, outputBuffer: $0.baseAddress!)
      }
      try checkCancellation()
      if bricks.count >= 64 { bricks.removeValue(forKey: brickOrder.removeFirst()) }
      bricks[index] = bytes
      brickOrder.append(index)
      return bytes
    }

    func value(level: Int, coordinate input: SIMD3<Int>, component: Int) throws -> UInt64 {
      visitedValues &+= 1
      if visitedValues & 1023 == 0 { try checkCancellation() }
      let layout = metadata.levelMetadata[level]
      let size = SIMD3(layout.size.x, layout.size.y, layout.size.z)
      var coordinate = input
      for axis in 0..<3 where coordinate[axis] < 0 || coordinate[axis] >= size[axis] {
        switch border {
          case .zero: return 0
          case .clamp: coordinate[axis] = min(max(coordinate[axis], 0), size[axis] - 1)
          case .repeatValue:
            coordinate[axis] = (coordinate[axis] % size[axis] + size[axis]) % size[axis]
        }
      }
      let key = Key(level: level, coordinate: coordinate, component: component)
      if let value = values[key] { return value }
      let factor = 1 << level
      let low = coordinate &* factor
      let high = SIMD3(min(low.x + factor, mask.size.x), min(low.y + factor, mask.size.y),
                       min(low.z + factor, mask.size.z))
      let coverage = mask.coverage(in: BorgVRVoxelRegion(lower: low, upper: high))
      let result: UInt64
      switch coverage {
        case .erased: result = 0
        case .original: result = try originalValue(level: level, coordinate: coordinate, component: component)
        case .mixed:
          // Preserve the converter's integer rounding at every hierarchy level,
          // including partial 2x2x2 blocks at odd volume dimensions.
          guard level > 0 else { throw BorgVRVolumeEditError.invalidGeometry }
          let child = metadata.levelMetadata[level - 1].size
          var sum: UInt64 = 0
          var count: UInt64 = 0
          for z in 0..<2 {
            for y in 0..<2 {
              for x in 0..<2 {
                let p = coordinate &* 2 &+ SIMD3(x, y, z)
                guard p.x < child.x, p.y < child.y, p.z < child.z else { continue }
                sum += try value(level: level - 1, coordinate: p, component: component)
                count += 1
              }
            }
          }
          result = sum / count
      }
      if values.count >= 65536 { values.removeAll(keepingCapacity: true) }
      values[key] = result
      return result
    }

    func originalValue(level: Int, coordinate: SIMD3<Int>, component: Int) throws -> UInt64 {
      if let directBrick, directBrick.level == level {
        let local = coordinate &- directBrick.origin
        if local.x >= 0, local.y >= 0, local.z >= 0,
           local.x < metadata.brickSize, local.y < metadata.brickSize, local.z < metadata.brickSize {
          let bytes = try originalBrick(directBrick.index)
          return decode(bytes, local: local, component: component)
        }
      }
      let stride = metadata.brickSize - 2 * metadata.overlap
      let brick = coordinate / stride
      let layout = metadata.levelMetadata[level]
      let index = layout.prevBricks + (brick.z * layout.totalBricks.y + brick.y) *
        layout.totalBricks.x + brick.x
      let bytes = try originalBrick(index)
      let local = coordinate &- brick &* stride &+ SIMD3(repeating: metadata.overlap)
      return decode(bytes, local: local, component: component)
    }

    private func decode(_ bytes: [UInt8], local: SIMD3<Int>, component: Int) -> UInt64 {
      let offset = (((local.z * metadata.brickSize + local.y) * metadata.brickSize + local.x) *
        metadata.componentCount + component) * metadata.bytesPerComponent
      var value: UInt64 = 0
      for byte in 0..<metadata.bytesPerComponent { value |= UInt64(bytes[offset + byte]) << (byte * 8) }
      return value
    }
  }
}
