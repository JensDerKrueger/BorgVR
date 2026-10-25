import Foundation
import Metal

/// UI lifecycle controls permission; background rebuilding always retains a CPU path.
enum BorgVRVolumeEditGPUAvailability {
  private static let lock = NSLock()
  #if os(iOS) || os(visionOS)
  nonisolated(unsafe) private static var active = false
  #else
  nonisolated(unsafe) private static var active = true
  #endif
  static func setApplicationActive(_ value: Bool) { lock.withLock { active = value } }
  static var isApplicationActive: Bool { lock.withLock { active } }
  static func submit(_ body: () -> Void) -> Bool {
    lock.withLock { guard active else { return false }; body(); return true }
  }
}

/// Canonical integer processing in private compute buffers, never the render atlas.
final class BorgVRMetalVolumeEditProcessor: @unchecked Sendable {
  private struct Parameters {
    var origin: SIMD4<Int32>
    var size: SIMD4<UInt32>
    var childSize: SIMD4<UInt32>
    var firstChild: SIMD4<UInt32>
    var childGrid: SIMD4<UInt32>
    var layout: SIMD4<UInt32>
  }
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let lock = NSLock()
  private var maskID: UUID?
  private var maskBuffer: MTLBuffer?
  private var processed = 0
  var processedBrickCount: Int { lock.withLock { processed } }

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw BorgVRVolumeEditError.invalidGeometry
    }
    let options = MTLCompileOptions()
    if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) { options.mathMode = .safe }
    else { options.fastMathEnabled = false }
    let library = try device.makeLibrary(source: Self.shader, options: options)
    guard let function = library.makeFunction(name: "rebuildEditBrick") else { throw BorgVRVolumeEditError.invalidGeometry }
    pipeline = try device.makeComputePipelineState(function: function)
    self.device = device; self.queue = queue
  }

  func process(_ input: BorgVRVolumeEditBrickInput, mask: BorgVRVolumeEditMask, metadata m: BORGVRMetaData,
               index: Int, revision: UInt64, isCancelled: () -> Bool) throws -> BorgVRMaterializedEditBrick? {
    try lock.withLock { () throws -> BorgVRMaterializedEditBrick? in
      if isCancelled() { throw CancellationError() }
      guard BorgVRVolumeEditGPUAvailability.isApplicationActive else { return nil }
      guard max(m.width, m.height, m.depth, m.brickSize) < Int(Int32.max),
        input.bytes.count <= device.maxBufferLength else { return nil }
      if maskID != mask.identity {
        let nodes = mask.computeNodes()
        guard nodes.count <= device.maxBufferLength / MemoryLayout<SIMD2<UInt32>>.stride else { return nil }
        maskBuffer = device.makeBuffer(bytes: nodes, length: nodes.count * MemoryLayout<SIMD2<UInt32>>.stride,
          options: .storageModeShared)
        maskID = maskBuffer == nil ? nil : mask.identity
      }
      let bytes = m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent
      guard let maskBuffer,
        let source = device.makeBuffer(bytes: input.bytes, length: input.bytes.count, options: .storageModeShared),
        let output = device.makeBuffer(length: bytes, options: .storageModeShared),
        let ranges = device.makeBuffer(length: m.componentCount * 8, options: .storageModeShared),
        let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
      let rangeWords = ranges.contents().bindMemory(to: UInt32.self, capacity: m.componentCount * 2)
      for c in 0..<m.componentCount { rangeWords[c * 2] = UInt32.max; rangeWords[c * 2 + 1] = 0 }
      var p = Parameters(origin: SIMD4(SIMD3<Int32>(truncatingIfNeeded: input.origin), Int32(input.level)),
        size: SIMD4(SIMD3<UInt32>(truncatingIfNeeded: input.size), 0), childSize: SIMD4(SIMD3<UInt32>(truncatingIfNeeded: input.childSize), 0),
        firstChild: SIMD4(SIMD3<UInt32>(truncatingIfNeeded: input.firstChild), 0), childGrid: SIMD4(SIMD3<UInt32>(truncatingIfNeeded: input.childGrid), 0),
        layout: SIMD4(UInt32(m.brickSize), UInt32(m.overlap), UInt32(m.componentCount), UInt32(m.bytesPerComponent)))
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(source, offset: 0, index: 0); encoder.setBuffer(output, offset: 0, index: 1)
      encoder.setBuffer(maskBuffer, offset: 0, index: 2); encoder.setBuffer(ranges, offset: 0, index: 3)
      encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 4)
      let count = m.brickSize * m.brickSize * m.brickSize
      encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
      encoder.endEncoding()
      guard !isCancelled(), BorgVRVolumeEditGPUAvailability.submit({ command.commit() }) else { return nil }
      command.waitUntilCompleted()
      if isCancelled() { throw CancellationError() }
      guard command.status == .completed else { return nil }
      processed += 1
      let result = Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt8.self), count: bytes))
      return .init(index: index, revision: revision, bytes: result,
        componentRanges: (0..<m.componentCount).map { .init(minValue: Int(rangeWords[$0 * 2]), maxValue: Int(rangeWords[$0 * 2 + 1])) },
        matchesOriginal: input.level == 0 && result == input.bytes)
    }
  }

  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  struct Parameters { int4 origin; uint4 size, childSize, firstChild, childGrid, layout; };
  uint readValue(device const uchar* data, uint offset, uint width) {
    uint value = 0;
    for (uint b = 0; b < width; ++b) value |= uint(data[offset + b]) << (b * 8);
    return value;
  }
  bool erased(uint3 p, uint3 size, device const uint2* nodes) {
    uint node = 0; uint3 low = 0, high = size;
    while (nodes[node].x == 2) {
      uint3 halves = (high - low) / 2;
      uint3 counts = select(uint3(1), uint3(2), high - low > 1);
      uint3 side = uint3(p >= low + halves) * (counts - 1);
      node = nodes[node].y + side.x + counts.x * (side.y + counts.y * side.z);
      high = select(low + halves, high, side > 0 || counts == 1);
      low += halves * side;
    }
    return nodes[node].x == 1;
  }
  kernel void rebuildEditBrick(device const uchar* source [[buffer(0)]],
      device uchar* output [[buffer(1)]], device const uint2* nodes [[buffer(2)]],
      device atomic_uint* ranges [[buffer(3)]], constant Parameters& p [[buffer(4)]],
      uint v [[thread_position_in_grid]]) {
    uint b = p.layout.x, overlap = p.layout.y, components = p.layout.z, width = p.layout.w;
    uint voxels = b * b * b, stride = b - 2 * overlap;
    if (v >= voxels) return;
    int3 raw = p.origin.xyz + int3(v % b, (v / b) % b, v / (b * b));
    uint3 pos = uint3(clamp(raw, int3(0), int3(p.size.xyz) - 1));
    bool isErased = p.origin.w == 0 && erased(pos, p.size.xyz, nodes);
    for (uint c = 0; c < components; ++c) {
      uint value = 0;
      if (p.origin.w == 0) {
        uint3 local = uint3(int3(pos) - p.origin.xyz);
        if (!isErased) value = readValue(source, (((local.z * b + local.y) * b + local.x) * components + c) * width, width);
      } else {
        uint low = 0, high = 0, count = 0;
        for (uint z = 0; z < 2; ++z) for (uint y = 0; y < 2; ++y) for (uint x = 0; x < 2; ++x) {
          uint3 q = pos * 2 + uint3(x, y, z);
          if (any(q >= p.childSize.xyz)) continue;
          uint3 brick = q / stride - p.firstChild.xyz;
          uint3 local = q % stride + overlap;
          uint slot = (brick.z * p.childGrid.y + brick.y) * p.childGrid.x + brick.x;
          uint next = readValue(source, ((slot * voxels + (local.z * b + local.y) * b + local.x) * components + c) * width, width);
          uint previous = low; low += next; high += uint(low < previous); ++count;
        }
        // Partial 2x2x2 cells contain 1, 2, 4 or 8 values. Carry preserves exact uint32 sums.
        uint shift = count == 8 ? 3 : count == 4 ? 2 : count == 2 ? 1 : 0;
        value = shift ? ((low >> shift) | (high << (32 - shift))) : low;
      }
      uint offset = (v * components + c) * width;
      for (uint byte = 0; byte < width; ++byte) output[offset + byte] = uchar(value >> (byte * 8));
      atomic_fetch_min_explicit(ranges + c * 2, value, memory_order_relaxed);
      atomic_fetch_max_explicit(ranges + c * 2 + 1, value, memory_order_relaxed);
    }
  }
  """
}
