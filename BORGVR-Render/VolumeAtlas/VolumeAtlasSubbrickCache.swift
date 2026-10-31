import Metal

/// Subbrick occupancy per resident atlas page. All reductions and
/// classification stay on the GPU; the volume and its sampling lattice are unchanged.
final class VolumeAtlasSubbrickCache {
  let divisions: Int
  let maskStride: Int
  private let cellCount: Int
  let masks: MTLBuffer
  private let ranges: MTLBuffer
  private let reduction: MTLComputePipelineState
  private let classification: MTLComputePipelineState
  private let device: MTLDevice
  private let channels: Int
  private struct Visibility: Equatable {
    var low: SIMD4<Float>
    var high: SIMD4<Float>
    var iso: SIMD4<Float>
  }
  private let layout: SIMD4<UInt32>
  private var dirty: [Int: UInt64]
  private var generation: UInt64 = 0
  private var lastVisibility: Visibility?
  private var pending: (command: MTLCommandBuffer, pages: [Int: UInt64], visibility: Visibility)?

  static func divisions(brickSize: Int, overlap: Int) -> Int {
    guard brickSize > 16, overlap > 0 else { return 1 }
    var value = brickSize <= 32 ? 2 : (brickSize <= 64 ? 4 : 8)
    while value > max(1, brickSize - 2 * overlap) { value /= 2 }
    return value
  }

  init(device: MTLDevice, metadata: BORGVRMetaData, capacity: Int, divisions: Int) throws {
    self.device = device
    self.divisions = divisions
    cellCount = self.divisions * self.divisions * self.divisions
    maskStride = 1 + (cellCount + 31) / 32
    channels = metadata.componentCount
    layout = SIMD4(UInt32(metadata.brickSize), UInt32(metadata.overlap),
                   UInt32(metadata.brickSize - 2 * metadata.overlap), UInt32(channels))
    dirty = Dictionary(uniqueKeysWithValues: (0..<capacity).map { ($0, 0) })
    guard let ranges = device.makeBuffer(length: capacity * cellCount * channels * 8, options: .storageModePrivate),
          let masks = device.makeBuffer(length: capacity * maskStride * 4, options: .storageModePrivate) else {
      throw VolumeAtlasError.failedToCreateTexture
    }
    self.ranges = ranges
    self.masks = masks
    ranges.label = "Subbrick min/max (\(self.divisions)^3)"
    masks.label = "Subbrick visibility (\(self.divisions)^3)"
    let options = MTLCompileOptions()
    if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
      options.mathMode = .safe
    } else {
      options.fastMathEnabled = false
    }
    options.preprocessorMacros = ["CHANNELS": NSNumber(value: channels),
      "COMPONENT_BYTES": NSNumber(value: metadata.bytesPerComponent),
      "DIVISIONS": NSNumber(value: self.divisions), "CELL_COUNT": NSNumber(value: cellCount),
      "MASK_STRIDE": NSNumber(value: maskStride)]
    let library = try device.makeLibrary(source: Self.shader, options: options)
    reduction = try device.makeComputePipelineState(function: library.makeFunction(name: "reduceSubbricks")!)
    classification = try device.makeComputePipelineState(function: library.makeFunction(name: "classifySubbricks")!)
  }

  func invalidate(page: Int) {
    generation &+= 1
    dirty[page] = generation
  }

  func prepare(command: MTLCommandBuffer, primary: MTLTexture, secondary: MTLTexture?,
               pages: [Int], transferFunctions: [TransferFunction1D], isoValue: Float? = nil) -> Bool {
    if let pending {
      if pending.command.status == .completed {
        for (page, revision) in pending.pages where dirty[page] == revision {
          dirty.removeValue(forKey: page)
        }
        lastVisibility = pending.visibility
      }
      self.pending = nil
    }
    guard isoValue != nil || transferFunctions.count == channels else { return false }
    var low = SIMD4<Float>(repeating: .infinity), high = SIMD4<Float>(repeating: -.infinity)
    for (channel, tf) in transferFunctions.enumerated() where isoValue == nil && tf.minIndex >= 0 {
      let scale = Float(tf.data.count) * tf.textureBias
      // Include the complete linear-filter footprint, with conservative roundoff.
      let margin = 8 * Float.ulpOfOne
      low[channel] = ((Float(tf.minIndex) - 0.5) / scale).nextDown - margin
      high[channel] = ((Float(tf.maxIndex) + 1.5) / scale).nextUp + margin
    }
    var visibility = Visibility(low: low, high: high,
      iso: SIMD4((isoValue ?? 0).nextDown - 8 * Float.ulpOfOne, 0, 0, isoValue == nil ? 0 : 1))
    let rebuilt = pages.filter { dirty[$0] != nil }
    let classified = lastVisibility == visibility ? rebuilt : pages
    guard !classified.isEmpty else { return true }
    guard let encoder = command.makeComputeCommandEncoder() else { return false }
    encoder.label = "Build/classify subbrick occupancy"
    var layout = layout
    encoder.setBytes(&layout, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 0)
    encoder.setBuffer(ranges, offset: 0, index: 2)
    encoder.setBuffer(masks, offset: 0, index: 3)
    encoder.setBytes(&visibility, length: MemoryLayout<Visibility>.stride, index: 4)
    func pageBuffer(_ pages: [Int]) -> MTLBuffer? {
      let ids = pages.map(UInt32.init)
      return ids.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
      }
    }
    if !rebuilt.isEmpty {
      guard let ids = pageBuffer(rebuilt) else { encoder.endEncoding(); return false }
      encoder.setBuffer(ids, offset: 0, index: 1)
      encoder.setTexture(primary, index: 0)
      encoder.setTexture(secondary ?? primary, index: 1)
      encoder.setComputePipelineState(reduction)
      encoder.dispatchThreadgroups(MTLSize(width: rebuilt.count * cellCount, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: reduction.threadExecutionWidth, height: 1, depth: 1))
      encoder.memoryBarrier(scope: .buffers)
    }
    guard let ids = pageBuffer(classified) else { encoder.endEncoding(); return false }
    encoder.setBuffer(ids, offset: 0, index: 1)
    encoder.setComputePipelineState(classification)
    encoder.dispatchThreads(MTLSize(width: classified.count, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: classification.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding()
    pending = (command, Dictionary(uniqueKeysWithValues: rebuilt.map { ($0, dirty[$0]!) }), visibility)
    return true
  }

  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Visibility { float4 low, high, iso; };
    kernel void reduceSubbricks(constant uint4 &layout [[buffer(0)]],
      device const uint *pages [[buffer(1)]], device float2 *ranges [[buffer(2)]],
      texture3d<float, access::read> primary [[texture(0)]],
      texture3d<float, access::read> secondary [[texture(1)]],
      uint group [[threadgroup_position_in_grid]], uint lane [[thread_index_in_simdgroup]],
      uint width [[threads_per_simdgroup]]) {
      uint page = pages[group / CELL_COUNT], cell = group % CELL_COUNT;
      uint3 side = uint3(cell % DIVISIONS, (cell / DIVISIONS) % DIVISIONS, cell / (DIVISIONS * DIVISIONS));
      uint3 capacity = uint3(primary.get_width(), primary.get_height(), primary.get_depth()) / layout.x;
      uint3 origin = uint3(page % capacity.x, (page / capacity.x) % capacity.y,
                           page / (capacity.x * capacity.y)) * layout.x;
      int3 lo = int3(layout.y + side * layout.z / DIVISIONS) - 1;
      int3 hi = int3(layout.y + (side + 1) * layout.z / DIVISIONS);
      int3 size = hi - lo + 1;
      float4 minimum = float4(INFINITY), maximum = float4(-INFINITY);
      for (uint i = lane; i < uint(size.x * size.y * size.z); i += width) {
        uint3 p = origin + uint3(lo + int3(i % size.x, (i / size.x) % size.y, i / (size.x * size.y)));
        float4 value = primary.read(p);
    #if COMPONENT_BYTES == 4
        value = float4(dot(value, float4(1, 256, 65536, 16777216)) / 16843009.0, 0, 0, 0);
    #elif COMPONENT_BYTES == 2
        float4 extra = secondary.read(p);
        value = float4(dot(value.xy, float2(1, 256)) / 257.0,
                       dot(value.zw, float2(1, 256)) / 257.0,
                       dot(extra.xy, float2(1, 256)) / 257.0,
                       dot(extra.zw, float2(1, 256)) / 257.0);
    #endif
        minimum = min(minimum, value);
        maximum = max(maximum, value);
      }
      minimum = simd_min(minimum);
      maximum = simd_max(maximum);
      if (lane == 0) for (uint c = 0; c < CHANNELS; ++c)
        ranges[(page * CELL_COUNT + cell) * CHANNELS + c] = float2(minimum[c], maximum[c]);
    }
    kernel void classifySubbricks(constant uint4 &layout [[buffer(0)]],
      device const uint *pages [[buffer(1)]], device const float2 *ranges [[buffer(2)]],
      device uint *masks [[buffer(3)]], constant Visibility &visibility [[buffer(4)]],
      uint index [[thread_position_in_grid]]) {
      uint page = pages[index], mask = 0, visibleCount = 0;
      for (uint cell = 0; cell < CELL_COUNT; ++cell) {
        bool iso = visibility.iso.w != 0;
        bool visible = iso;
        for (uint c = 0; c < CHANNELS; ++c) {
          float2 r = ranges[(page * CELL_COUNT + cell) * CHANNELS + c];
          // ISO uses the minimum over components: every channel must reach the threshold.
          if (iso) visible &= r.y >= visibility.iso.x;
          else visible |= r.y >= visibility.low[c] && r.x <= visibility.high[c];
        }
        if (visible) { mask |= 1u << (cell & 31); ++visibleCount; }
        if ((cell & 31) == 31 || cell + 1 == CELL_COUNT) {
          masks[page * MASK_STRIDE + 1 + cell / 32] = mask;
          mask = 0;
        }
      }
      // Header: empty, partially visible, or fully visible. Full pages need no fine traversal.
      masks[page * MASK_STRIDE] = visibleCount == CELL_COUNT ? 2 : uint(visibleCount != 0);
    }
    """
}
