import Foundation

enum BorgVRVolumeBrushMode: String, Codable, Sendable {
  case erase
  case restore
}

enum BorgVRVolumeBrushLimits {
  static let radiusFraction = 0.002...0.15
  static let maximumSampleCount = 65536
}

struct BorgVRVolumeEditStatus: Sendable {
  let datasetID: String
  let hasEdits: Bool
  let isUpdatingBricks: Bool
  let pendingBrickCount: Int
}

struct BorgVRVolumeBrushCursor: Codable, Equatable, Sendable {
  let id: UUID
  let position: SIMD3<Float>
  let radius: Float
  let mode: BorgVRVolumeBrushMode
}

struct BorgVRVolumeBrushSample: Codable, Equatable, Sendable {
  /// Coordinates are measured from the volume's minimum corner, in meters.
  let center: SIMD3<Double>
  let radius: Double

  func validate() throws {
    guard center.x.isFinite, center.y.isFinite, center.z.isFinite,
          radius.isFinite, radius > 0, radius * radius < Double.infinity else {
      throw BorgVRVolumeEditError.invalidBrush
    }
  }
}

struct BorgVRVolumeBrushBatch: Codable, Sendable {
  let id: UUID
  let revision: UInt64
  let mode: BorgVRVolumeBrushMode
  let samples: [BorgVRVolumeBrushSample]
  var affectedBrickIDs: [Int]? = nil
}

/// Optional renderer interface. No Metal types, disk access, or network waits on the render thread.
protocol BorgVRVolumeGPUBrushSource: AnyObject {
  var gpuBrushGeneration: UInt64 { get }
  func attachGPUBrushRenderer()
  func detachGPUBrushRenderer()
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch]
  /// Lower bound included in a subsequent successful CPU read; nil while that brick is dirty.
  func gpuReadableRevision(index: Int) -> UInt64?
  func cachedOriginalBrick(index: Int) -> [UInt8]?
}

extension BorgVRVolumeGPUBrushSource {
  var gpuBrushGeneration: UInt64 { 0 }
}

/// Use the same normalized Float predicate on CPU and GPU, even for microscopic datasets.
struct BorgVRVolumeBrushGeometry {
  let spacing: SIMD3<Float>
  let sphere: SIMD4<Float>

  init?(size: SIMD3<Int>, spacing: SIMD3<Double>, sample: BorgVRVolumeBrushSample) {
    let extent = SIMD3<Double>(size) * spacing
    let scale = max(extent.x, extent.y, extent.z)
    let normalizedSpacing = SIMD3<Float>(spacing / scale)
    let center = SIMD3<Float>(sample.center / scale)
    let radius = Float(sample.radius / scale)
    guard normalizedSpacing.x > 0, normalizedSpacing.y > 0, normalizedSpacing.z > 0,
          center.x.isFinite, center.y.isFinite, center.z.isFinite,
          radius > 0, (radius * radius).isFinite else { return nil }
    self.spacing = normalizedSpacing
    sphere = SIMD4(center, radius)
  }

  func squaredBounds(_ region: BorgVRVoxelRegion) -> (Float, Float) {
    let center = SIMD3(sphere.x, sphere.y, sphere.z)
    let low = (SIMD3<Float>(region.lower) + SIMD3(repeating: 0.5)) * spacing - center
    let high = (SIMD3<Float>(region.upper) - SIMD3(repeating: 0.5)) * spacing - center
    var near = SIMD3<Float>.zero, far = SIMD3<Float>.zero
    for axis in 0..<3 {
      near[axis] = max(low[axis], 0, -high[axis])
      far[axis] = max(abs(low[axis]), abs(high[axis]))
    }
    func squared(_ v: SIMD3<Float>) -> Float {
      (v.x * v.x).addingProduct(v.y, v.y).addingProduct(v.z, v.z)
    }
    return (squared(near), squared(far))
  }
}

enum BorgVRVolumeEditError: Error {
  case invalidBrush
  case invalidGeometry
  case invalidRevision
  case invalidBrick
  case invalidBufferSize
  case corruptJournal
  case incompatibleDataset
  case editingBlocked
}

struct BorgVRVoxelRegion: Codable, Equatable, Sendable {
  let lower: SIMD3<Int>
  let upper: SIMD3<Int> // exclusive

  var isEmpty: Bool {
    lower.x >= upper.x || lower.y >= upper.y || lower.z >= upper.z
  }

  func intersects(_ other: Self) -> Bool {
    lower.x < other.upper.x && upper.x > other.lower.x &&
      lower.y < other.upper.y && upper.y > other.lower.y &&
      lower.z < other.upper.z && upper.z > other.lower.z
  }

  func contains(_ other: Self) -> Bool {
    lower.x <= other.lower.x && lower.y <= other.lower.y && lower.z <= other.lower.z &&
      upper.x >= other.upper.x && upper.y >= other.upper.y && upper.z >= other.upper.z
  }

  var children: [Self] {
    func halves(_ low: Int, _ high: Int) -> [(Int, Int)] {
      guard high - low > 1 else { return [(low, high)] }
      let middle = low + (high - low) / 2
      return [(low, middle), (middle, high)]
    }
    var result: [Self] = []
    for z in halves(lower.z, upper.z) {
      for y in halves(lower.y, upper.y) {
        for x in halves(lower.x, upper.x) {
          result.append(Self(lower: SIMD3(x.0, y.0, z.0), upper: SIMD3(x.1, y.1, z.1)))
        }
      }
    }
    return result
  }
}

/// Immutable value snapshots allow a worker to finish an older revision while editing continues.
struct BorgVRVolumeEditMask: Codable, Sendable {
  indirect enum Node: Sendable {
    case original
    case erased
    case mixed([Node])
  }

  enum Coverage { case original, erased, mixed }

  let size: SIMD3<Int>
  let spacing: SIMD3<Double>
  private(set) var root: Node = .original

  init(size: SIMD3<Int>, spacing: SIMD3<Double>) throws {
    guard size.x > 0, size.y > 0, size.z > 0,
          size.x <= Int(Int32.max), size.y <= Int(Int32.max), size.z <= Int(Int32.max),
          spacing.x.isFinite, spacing.y.isFinite, spacing.z.isFinite,
          spacing.x > 0, spacing.y > 0, spacing.z > 0,
          (Double(size.x) * spacing.x).isFinite,
          (Double(size.y) * spacing.y).isFinite,
          (Double(size.z) * spacing.z).isFinite else {
      throw BorgVRVolumeEditError.invalidGeometry
    }
    self.size = size
    self.spacing = spacing
  }

  private enum CodingKeys: String, CodingKey { case size, spacing, nodes }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(size, forKey: .size)
    try values.encode(spacing, forKey: .spacing)
    // Preorder tags: child counts follow from the voxel region, not from the file.
    var nodes = Data()
    func append(_ node: Node) {
      switch node {
        case .original: nodes.append(0)
        case .erased: nodes.append(1)
        case .mixed(let children):
          nodes.append(2)
          for child in children { append(child) }
      }
    }
    append(root)
    try values.encode(nodes, forKey: .nodes)
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(size: values.decode(SIMD3<Int>.self, forKey: .size),
                  spacing: values.decode(SIMD3<Double>.self, forKey: .spacing))
    let nodes = try values.decode(Data.self, forKey: .nodes)
    let bounds = bounds
    root = try nodes.withUnsafeBytes { buffer in
      let bytes = buffer.bindMemory(to: UInt8.self)
      var offset = 0
      func read(region: BorgVRVoxelRegion) throws -> Node {
        guard offset < bytes.count else { throw BorgVRVolumeEditError.corruptJournal }
        let tag = bytes[offset]
        offset += 1
        switch tag {
          case 0: return .original
          case 1: return .erased
          case 2:
            let regions = region.children
            guard regions.count > 1, regions.count <= bytes.count - offset else {
              throw BorgVRVolumeEditError.corruptJournal
            }
            return .mixed(try regions.map { try read(region: $0) })
          default: throw BorgVRVolumeEditError.corruptJournal
        }
      }
      let result = try read(region: bounds)
      guard offset == bytes.count else { throw BorgVRVolumeEditError.corruptJournal }
      return result
    }
  }

  var bounds: BorgVRVoxelRegion { BorgVRVoxelRegion(lower: .zero, upper: size) }
  private(set) var identity = UUID()
  var isOriginal: Bool { if case .original = root { return true }; return false }

  mutating func apply(_ sample: BorgVRVolumeBrushSample, mode: BorgVRVolumeBrushMode) throws {
    try sample.validate()
    identity = UUID()
    let geometry = BorgVRVolumeBrushGeometry(size: size, spacing: spacing, sample: sample)
    root = applying(sample, geometry: geometry, mode: mode, node: root, region: bounds)
  }

  private func applying(
    _ sample: BorgVRVolumeBrushSample, geometry: BorgVRVolumeBrushGeometry?, mode: BorgVRVolumeBrushMode,
    node: Node, region: BorgVRVoxelRegion
  ) -> Node {
    if case .original = node, mode == .restore { return node }
    if case .erased = node, mode == .erase { return node }
    let outside: Bool, inside: Bool
    if let geometry {
      let (nearest, farthest) = geometry.squaredBounds(region)
      let radiusSquared = geometry.sphere.w * geometry.sphere.w
      outside = nearest > radiusSquared
      inside = farthest <= radiusSquared
    } else {
      let low = (SIMD3<Double>(region.lower) + SIMD3(repeating: 0.5)) * spacing
      let high = (SIMD3<Double>(region.upper) - SIMD3(repeating: 0.5)) * spacing
      var nearestSquared = 0.0
      var farthestSquared = 0.0
      for axis in 0..<3 {
        let near = max(low[axis] - sample.center[axis], 0, sample.center[axis] - high[axis])
        let far = max(abs(low[axis] - sample.center[axis]), abs(high[axis] - sample.center[axis]))
        nearestSquared += near * near
        farthestSquared += far * far
      }
      let radiusSquared = sample.radius * sample.radius
      outside = nearestSquared > radiusSquared
      inside = farthestSquared <= radiusSquared
    }
    guard !outside else { return node }
    if inside { return mode == .erase ? .erased : .original }
    let regions = region.children
    var children: [Node]
    if case .mixed(let existing) = node { children = existing }
    else { children = Array(repeating: node, count: regions.count) }
    for index in regions.indices {
      children[index] = applying(sample, geometry: geometry, mode: mode, node: children[index], region: regions[index])
    }
    if children.allSatisfy({ if case .original = $0 { return true }; return false }) {
      return .original
    }
    if children.allSatisfy({ if case .erased = $0 { return true }; return false }) {
      return .erased
    }
    return .mixed(children)
  }

  func coverage(in region: BorgVRVoxelRegion) -> Coverage {
    func query(_ node: Node, _ nodeRegion: BorgVRVoxelRegion) -> Coverage? {
      guard nodeRegion.intersects(region) else { return nil }
      switch node {
        case .original: return .original
        case .erased: return .erased
        case .mixed(let children):
          if region.contains(nodeRegion) { return .mixed }
          let results = zip(children, nodeRegion.children).compactMap { query($0, $1) }
          if results.allSatisfy({ $0 == .original }) { return .original }
          if results.allSatisfy({ $0 == .erased }) { return .erased }
          return .mixed
      }
    }
    return query(root, bounds) ?? .original
  }

  /// Allocation-free point query for canonical CPU rebuilding.
  func isErased(at point: SIMD3<Int>) -> Bool {
    guard point.x >= 0, point.y >= 0, point.z >= 0, point.x < size.x, point.y < size.y, point.z < size.z else { return false }
    var node = root, low = SIMD3<Int>.zero, high = size
    while case .mixed(let children) = node {
      let half = (high &- low) / 2
      let counts = SIMD3(high.x - low.x > 1 ? 2 : 1, high.y - low.y > 1 ? 2 : 1, high.z - low.z > 1 ? 2 : 1)
      let side = SIMD3(counts.x > 1 && point.x >= low.x + half.x ? 1 : 0,
        counts.y > 1 && point.y >= low.y + half.y ? 1 : 0, counts.z > 1 && point.z >= low.z + half.z ? 1 : 0)
      node = children[side.x + counts.x * (side.y + counts.y * side.z)]
      for axis in 0..<3 {
        if side[axis] == 0, counts[axis] > 1 { high[axis] = low[axis] + half[axis] }
        low[axis] += half[axis] * side[axis]
      }
    }
    if case .erased = node { return true }
    return false
  }

  /// Compact immutable tree for compute jobs; children use the same x/y/z order as bounds.children.
  func computeNodes() -> [SIMD2<UInt32>] {
    var result = [SIMD2<UInt32>.zero]
    func encode(_ node: Node, at index: Int) {
      switch node {
        case .original: result[index] = SIMD2(0, 0)
        case .erased: result[index] = SIMD2(1, 0)
        case .mixed(let children):
          let first = result.count
          result[index] = SIMD2(2, UInt32(first))
          result.append(contentsOf: repeatElement(.zero, count: children.count))
          for (offset, child) in children.enumerated() { encode(child, at: first + offset) }
      }
    }
    encode(root, at: 0)
    return result
  }
}
