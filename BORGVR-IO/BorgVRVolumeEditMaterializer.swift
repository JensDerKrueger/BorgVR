import Foundation

struct BorgVRVolumeEditBrickInput {
  let origin: SIMD3<Int>
  let size: SIMD3<Int>
  let childSize: SIMD3<Int>
  let firstChild: SIMD3<Int>
  let childGrid: SIMD3<Int>
  let level: Int
  let bytes: [UInt8]
}

/// Exact bottom-up rebuilding, independent of the atlas and the render loop.
/// Child results are shared across demand, background, export and opening jobs.
final class BorgVRVolumeEditMaterializer: BorgVRVolumeEditExecutor, @unchecked Sendable {
  typealias Lookup = (Int, UInt64) throws -> BorgVRMaterializedEditBrick?
  private struct Key: Hashable { let index: Int; let revision: UInt64 }
  private let source: BORGVRDatasetProtocol
  private let metadata: BORGVRMetaData
  private let reference: BorgVRCPUVolumeEditExecutor
  private let condition = NSCondition()
  private var running: Set<Key> = []
  private var results: [Key: BorgVRMaterializedEditBrick] = [:]
  private var order: [Key] = []
  private var resultBytes = 0
  private let budget = 64 * 1024 * 1024
  private let processorLock = NSLock()
  private let usesMetal: Bool
  private var attemptedMetal = false
  private var metal: BorgVRMetalVolumeEditProcessor?
  var metalBrickCount: Int { processorLock.withLock { metal?.processedBrickCount ?? 0 } }

  private func gpuProcessor() -> BorgVRMetalVolumeEditProcessor? {
    guard usesMetal, BorgVRVolumeEditGPUAvailability.isApplicationActive else { return nil }
    return processorLock.withLock {
      if !attemptedMetal { attemptedMetal = true; metal = try? BorgVRMetalVolumeEditProcessor() }
      return metal
    }
  }

  init(source: BORGVRDatasetProtocol, usesMetal: Bool = true) throws {
    self.source = source
    metadata = source.getMetadata()
    reference = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
    self.usesMetal = usesMetal
  }

  func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                   isCancelled: @escaping () -> Bool) throws -> BorgVRMaterializedEditBrick {
    try materialize(index: index, mask: mask, revision: revision, revisions: nil,
      useGPU: false, cached: { _, _ in nil }, store: { _ in }, isCancelled: isCancelled)
  }

  func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                   revisions: [Int: UInt64]?, useGPU: Bool,
                   cached: @escaping Lookup, store: @escaping (BorgVRMaterializedEditBrick) throws -> Void,
                   isCancelled: @escaping () -> Bool) throws -> BorgVRMaterializedEditBrick {
    guard metadata.brickMetadata.indices.contains(index), mask.size == SIMD3(metadata.width, metadata.height, metadata.depth),
      mask.spacing == SIMD3(Double(metadata.voxelSpacingX), Double(metadata.voxelSpacingY), Double(metadata.voxelSpacingZ)) else {
      throw BorgVRVolumeEditError.incompatibleDataset
    }
    let key = Key(index: index, revision: revision)
    func finish(_ result: BorgVRMaterializedEditBrick) throws -> BorgVRMaterializedEditBrick {
      if isCancelled() { throw CancellationError() }
      try store(result)
      return result
    }
    while true {
      if isCancelled() { throw CancellationError() }
      if let saved = try cached(index, revision) { return try finish(saved) }
      condition.lock()
      if let result = results[key] { condition.unlock(); return try finish(result) }
      if running.insert(key).inserted { condition.unlock(); break }
      _ = condition.wait(until: Date().addingTimeInterval(0.05))
      condition.unlock()
    }
    defer { condition.lock(); running.remove(key); condition.broadcast(); condition.unlock() }
    let result = try finish(rebuild(index: index, mask: mask, revision: revision, revisions: revisions,
      useGPU: useGPU, cached: cached, store: store, isCancelled: isCancelled))
    condition.lock()
    if result.bytes.count <= budget {
      while resultBytes + result.bytes.count > budget, !order.isEmpty {
        if let old = results.removeValue(forKey: order.removeFirst()) { resultBytes -= old.bytes.count }
      }
      results[key] = result; order.append(key); resultBytes += result.bytes.count
    }
    condition.unlock()
    return result
  }

  private func rebuild(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                       revisions: [Int: UInt64]?, useGPU: Bool, cached: @escaping Lookup,
                       store: @escaping (BorgVRMaterializedEditBrick) throws -> Void,
                       isCancelled: @escaping () -> Bool) throws -> BorgVRMaterializedEditBrick {
    let m = metadata
    let level = m.levelMetadata.lastIndex { $0.prevBricks <= index }!
    let layout = m.levelMetadata[level]
    let local = index - layout.prevBricks
    let stride = m.brickSize - 2 * m.overlap
    let origin = SIMD3(local % layout.totalBricks.x, (local / layout.totalBricks.x) % layout.totalBricks.y,
      local / (layout.totalBricks.x * layout.totalBricks.y)) &* stride &- SIMD3(repeating: m.overlap)
    let size = SIMD3(layout.size.x, layout.size.y, layout.size.z)
    let low = SIMD3(max(0, origin.x), max(0, origin.y), max(0, origin.z)) &* (1 << level)
    let upper = origin &+ SIMD3(repeating: m.brickSize)
    let high = SIMD3(min(m.width, upper.x * (1 << level)), min(m.height, upper.y * (1 << level)),
      min(m.depth, upper.z * (1 << level)))
    let coverage = mask.coverage(in: .init(lower: low, upper: high))
    let byteCount = m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent
    if coverage == .original {
      var bytes = [UInt8](repeating: 0, count: byteCount)
      try bytes.withUnsafeMutableBufferPointer { try source.getBrick(index: index, outputBuffer: $0.baseAddress!) }
      return .init(index: index, revision: revision, bytes: bytes,
        componentRanges: m.brickMetadata[index].componentRanges, matchesOriginal: true)
    }
    if coverage == .erased {
      return .init(index: index, revision: revision, bytes: .init(repeating: 0, count: byteCount),
        componentRanges: .init(repeating: .init(minValue: 0, maxValue: 0), count: m.componentCount), matchesOriginal: false)
    }
    var input: BorgVRVolumeEditBrickInput
    if level == 0 {
      var bytes = [UInt8](repeating: 0, count: byteCount)
      try bytes.withUnsafeMutableBufferPointer { try source.getBrick(index: index, outputBuffer: $0.baseAddress!) }
      input = .init(origin: origin, size: size, childSize: .zero, firstChild: .zero,
        childGrid: .zero, level: level, bytes: bytes)
    } else {
      let child = m.levelMetadata[level - 1]
      let childSize = SIMD3(child.size.x, child.size.y, child.size.z)
      let first = (SIMD3(max(0, origin.x), max(0, origin.y), max(0, origin.z)) &* 2) / stride
      let last = SIMD3(min(childSize.x - 1, (min(size.x, upper.x) - 1) * 2 + 1),
        min(childSize.y - 1, (min(size.y, upper.y) - 1) * 2 + 1),
        min(childSize.z - 1, (min(size.z, upper.z) - 1) * 2 + 1)) / stride
      let grid = last &- first &+ SIMD3(repeating: 1)
      let count = grid.x * grid.y * grid.z
      guard count > 0, byteCount <= budget / count else {
        return try reference.materialize(index: index, mask: mask, revision: revision, isCancelled: isCancelled)
      }
      var bytes = [UInt8](); bytes.reserveCapacity(count * byteCount)
      for z in first.z...last.z { for y in first.y...last.y { for x in first.x...last.x {
        let id = child.prevBricks + (z * child.totalBricks.y + y) * child.totalBricks.x + x
        let brick = try materialize(index: id, mask: mask, revision: revisions?[id] ?? revision,
          revisions: revisions, useGPU: useGPU, cached: cached, store: store, isCancelled: isCancelled)
        bytes.append(contentsOf: brick.bytes)
      } } }
      input = .init(origin: origin, size: size, childSize: childSize, firstChild: first,
        childGrid: grid, level: level, bytes: bytes)
    }
    if isCancelled() { throw CancellationError() }
    if useGPU, let metal = gpuProcessor(), let result = try metal.process(input, mask: mask, metadata: m, index: index,
      revision: revision, isCancelled: isCancelled) { return result }
    return try Self.processCPU(input, mask: mask, metadata: m, index: index, revision: revision, isCancelled: isCancelled)
  }

  static func processCPU(_ input: BorgVRVolumeEditBrickInput, mask: BorgVRVolumeEditMask, metadata m: BORGVRMetaData,
                         index: Int, revision: UInt64, isCancelled: () -> Bool) throws -> BorgVRMaterializedEditBrick {
    let b = m.brickSize, components = m.componentCount, width = m.bytesPerComponent
    let stride = b - 2 * m.overlap
    let voxels = b * b * b
    var output = [UInt8](repeating: 0, count: voxels * components * width)
    var minima = [UInt64](repeating: UInt64.max, count: components), maxima = [UInt64](repeating: 0, count: components)
    func read(_ offset: Int) -> UInt64 {
      var value: UInt64 = 0
      for byte in 0..<width { value |= UInt64(input.bytes[offset + byte]) << (byte * 8) }
      return value
    }
    for v in 0..<voxels {
      if v & 255 == 0, isCancelled() { throw CancellationError() }
      let raw = input.origin &+ SIMD3(v % b, (v / b) % b, v / (b * b))
      let p = SIMD3(min(max(0, raw.x), input.size.x - 1), min(max(0, raw.y), input.size.y - 1),
        min(max(0, raw.z), input.size.z - 1))
      let erased = input.level == 0 && mask.isErased(at: p)
      for component in 0..<components {
        var value: UInt64 = 0
        if input.level == 0 {
          let local = p &- input.origin
          if !erased { value = read((((local.z * b + local.y) * b + local.x) * components + component) * width) }
        } else {
          var count: UInt64 = 0
          for dz in 0..<2 { for dy in 0..<2 { for dx in 0..<2 {
            let q = p &* 2 &+ SIMD3(dx, dy, dz)
            guard q.x < input.childSize.x, q.y < input.childSize.y, q.z < input.childSize.z else { continue }
            let brick = q / stride &- input.firstChild
            let local = q % stride &+ SIMD3(repeating: m.overlap)
            let slot = (brick.z * input.childGrid.y + brick.y) * input.childGrid.x + brick.x
            value += read(((slot * voxels + (local.z * b + local.y) * b + local.x) * components + component) * width)
            count += 1
          } } }
          guard count > 0 else { throw BorgVRVolumeEditError.invalidGeometry }
          value /= count
        }
        let offset = (v * components + component) * width
        for byte in 0..<width { output[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        minima[component] = min(minima[component], value); maxima[component] = max(maxima[component], value)
      }
    }
    return .init(index: index, revision: revision, bytes: output,
      componentRanges: minima.indices.map { .init(minValue: Int(minima[$0]), maxValue: Int(maxima[$0])) },
      matchesOriginal: input.level == 0 && output == input.bytes)
  }
}
