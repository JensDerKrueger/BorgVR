import Foundation
import Metal

/// Exact Level-0 edits and conservative coarse previews. The CPU supplies exact
/// subsampled bricks afterwards; GPU previews never enter the persistent cache.
final class VolumeAtlasBrushRenderer {
  struct PreparedBatch {
    let revision: UInt64
    let mode: BorgVRVolumeBrushMode
    fileprivate let byteSelection: UInt32?
    fileprivate let geometry: [BorgVRVolumeBrushGeometry]
    fileprivate let spheres: MTLBuffer
    fileprivate let affectedBrickIDs: Set<Int>?
  }
  private struct Parameters {
    var origin: SIMD4<Int32>
    var page: SIMD4<UInt32>
    var size: SIMD4<Int32>
    var spacing: SIMD4<Float>
    var layout: SIMD4<UInt32>
    var selection: SIMD4<UInt32>
  }

  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  private let partialPipeline: MTLComputePipelineState?
  private let metadata: BORGVRMetaData
  private var originals: [Int: MTLBuffer] = [:]
  private var originalOrder: [Int] = []
  private var originalBytes = 0
  private let dummy: MTLBuffer

  init(device: MTLDevice, metadata: BORGVRMetaData) throws {
    self.device = device
    self.metadata = metadata
    guard max(metadata.width, metadata.height, metadata.depth) <= Int(Int32.max) - metadata.brickSize else {
      throw BorgVRVolumeEditError.invalidGeometry
    }
    let options = MTLCompileOptions()
    if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
      options.mathMode = .safe
    } else {
      options.fastMathEnabled = false
    }
    let library = try device.makeLibrary(source: Self.shader, options: options)
    guard let function = library.makeFunction(name: "volumeBrush"),
          let dummy = device.makeBuffer(length: 1, options: .storageModeShared) else {
      throw VolumeAtlasError.failedToCreateTexture
    }
    self.dummy = dummy
    pipeline = try device.makeComputePipelineState(function: function)
    if metadata.componentCount > 1, device.readWriteTextureSupport == .tier2 {
      options.preprocessorMacros = ["BORGVR_PARTIAL_CHANNELS": NSNumber(value: 1)]
      let partialLibrary = try device.makeLibrary(source: Self.shader, options: options)
      partialPipeline = try partialLibrary.makeFunction(name: "volumeBrush").map {
        try device.makeComputePipelineState(function: $0)
      }
    } else { partialPipeline = nil }
  }

  func retainOriginals(for residents: Set<Int>) {
    for id in Array(originals.keys) where !residents.contains(id) {
      originalBytes -= originals.removeValue(forKey: id)!.length
      originalOrder.removeAll { $0 == id }
    }
  }

  func prepare(_ batch: BorgVRVolumeBrushBatch) -> PreparedBatch? {
    let m = metadata
    guard let channels = try? batch.channels.validated(componentCount: m.componentCount) else { return nil }
    var byteSelection: UInt32?
    if case .selected(let selected) = channels {
      guard partialPipeline != nil, m.componentCount * m.bytesPerComponent <= 8 else { return nil }
      byteSelection = selected.reduce(UInt32(0)) { bits, channel in
        bits | (((UInt32(1) << m.bytesPerComponent) - 1) << (channel * m.bytesPerComponent))
      }
    }
    let size = SIMD3(m.width, m.height, m.depth)
    let spacing = SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ))
    let geometry = batch.samples.compactMap {
      BorgVRVolumeBrushGeometry(size: size, spacing: spacing, sample: $0)
    }
    guard geometry.count == batch.samples.count, !geometry.isEmpty,
          let spheres = device.makeBuffer(bytes: geometry.map(\.sphere),
            length: geometry.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
      return nil
    }
    return PreparedBatch(revision: batch.revision, mode: batch.mode, byteSelection: byteSelection, geometry: geometry, spheres: spheres,
                         affectedBrickIDs: batch.affectedBrickIDs.map { Set($0) })
  }

  /// False leaves the page revision unchanged: retry later or use a ready CPU brick.
  func encode(_ batch: PreparedBatch, brickID: Int, pageOrigin: SIMD3<Int>,
              primary: MTLTexture, secondary: MTLTexture?, source: BorgVRVolumeGPUBrushSource,
              encoder: MTLComputeCommandEncoder) -> Bool {
    if let ids = batch.affectedBrickIDs, !ids.contains(brickID) { return true }
    let m = metadata
    let size = SIMD3(m.width, m.height, m.depth)
    let geometry = batch.geometry
    let levelIndex = m.levelMetadata.lastIndex { $0.prevBricks <= brickID }!
    let level = m.levelMetadata[levelIndex]
    let localID = brickID - level.prevBricks
    let coordinate = SIMD3(localID % level.totalBricks.x,
      (localID / level.totalBricks.x) % level.totalBricks.y,
      localID / (level.totalBricks.x * level.totalBricks.y))
    let origin = coordinate &* (m.brickSize - 2 * m.overlap) &- SIMD3(repeating: m.overlap)
    let factor = 1 << levelIndex
    let low = origin &* factor
    let high = (origin &+ SIMD3(repeating: m.brickSize)) &* factor
    let region = BorgVRVoxelRegion(lower: SIMD3(max(0, low.x), max(0, low.y), max(0, low.z)),
      upper: SIMD3(min(size.x, high.x), min(size.y, high.y), min(size.z, high.z)))
    guard geometry.contains(where: { $0.squaredBounds(region).0 <= $0.sphere.w * $0.sphere.w }) else {
      return true
    }

    let original: MTLBuffer
    if batch.mode == .restore {
      if let cached = originals[brickID] { original = cached }
      else {
        guard let bytes = source.cachedOriginalBrick(index: brickID),
              bytes.count == m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent,
              let buffer = device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared) else {
          return false
        }
        original = buffer
        originals[brickID] = buffer
        originalOrder.append(brickID)
        originalBytes += buffer.length
        while originalBytes > 32 * 1024 * 1024, originalOrder.count > 1 {
          let evicted = originalOrder.removeFirst()
          originalBytes -= originals.removeValue(forKey: evicted)!.length
        }
      }
    } else { original = dummy }

    if batch.byteSelection != nil {
      guard let partialPipeline else { return false }
      encoder.setComputePipelineState(partialPipeline)
    } else { encoder.setComputePipelineState(pipeline) }
    encoder.setBuffer(original, offset: 0, index: 1)
    encoder.setBuffer(batch.spheres, offset: 0, index: 2)
    var parameters = Parameters(
      origin: SIMD4(SIMD3<Int32>(truncatingIfNeeded: origin), Int32(levelIndex)),
      page: SIMD4(SIMD3<UInt32>(truncatingIfNeeded: pageOrigin), UInt32(geometry.count)),
      size: SIMD4(SIMD3<Int32>(truncatingIfNeeded: size), batch.mode == .restore ? 1 : 0),
      spacing: SIMD4(geometry[0].spacing, 0),
      layout: SIMD4(UInt32(m.brickSize), UInt32(m.componentCount * m.bytesPerComponent), 0,
                    UInt32(min(4, m.componentCount * m.bytesPerComponent))),
      selection: SIMD4(batch.byteSelection ?? 0, 0, 0, 0))
    func dispatch(_ texture: MTLTexture) {
      encoder.setTexture(texture, index: 0)
      encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
      encoder.dispatchThreads(MTLSize(width: m.brickSize, height: m.brickSize, depth: m.brickSize),
                              threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 4))
    }
    dispatch(primary)
    if let secondary {
      parameters.layout.z = 4
      parameters.layout.w = UInt32(m.componentCount * m.bytesPerComponent - 4)
      dispatch(secondary)
    }
    return true
  }

  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    // Preserve CPU voxel-center rounding; only the distance sum uses explicit fma.
    #pragma clang fp contract(off)
    struct Parameters {
      int4 origin;
      uint4 page;
      int4 size;
      float4 spacing;
      uint4 layout;
      uint4 selection;
    };
    kernel void volumeBrush(constant Parameters &p [[buffer(0)]],
                            device const uchar *original [[buffer(1)]],
                            device const float4 *spheres [[buffer(2)]],
    #if BORGVR_PARTIAL_CHANNELS
                            texture3d<float, access::read_write> atlas [[texture(0)]],
    #else
                            texture3d<float, access::write> atlas [[texture(0)]],
    #endif
                            uint3 id [[thread_position_in_grid]]) {
      int factor = 1 << p.origin.w;
      int3 levelSize = (p.size.xyz - 1) / factor + 1;
      int3 voxel = clamp(p.origin.xyz + int3(id), int3(0), levelSize - 1);
      float3 firstVoxel = float3(voxel) * float(factor);
      float3 lastVoxel = min(firstVoxel + float(factor), float3(p.size.xyz)) - 1.0f;
      bool covered = false;
      for (uint i = 0; i < p.page.w; ++i) {
        float3 d;
        if (p.origin.w == 0) {
          d = abs((float3(voxel) + 0.5f) * p.spacing.xyz - spheres[i].xyz);
        } else {
          float3 nearest = clamp(round(spheres[i].xyz / p.spacing.xyz - 0.5f), firstVoxel, lastVoxel);
          d = (nearest + 0.5f) * p.spacing.xyz - spheres[i].xyz;
        }
        float distance = fma(d.z, d.z, fma(d.y, d.y, d.x * d.x));
        if (distance <= spheres[i].w * spheres[i].w) { covered = true; break; }
      }
      if (!covered) return;
    #if BORGVR_PARTIAL_CHANNELS
      float4 value = atlas.read(id + p.page.xyz);
      for (uint c = 0; c < p.layout.w; ++c) {
        if (p.selection.x & (1u << (p.layout.z + c))) value[c] = 0;
      }
    #else
      float4 value = float4(0);
    #endif
      if (p.size.w) {
        uint3 local = uint3(voxel - p.origin.xyz);
        uint offset = ((local.z * p.layout.x + local.y) * p.layout.x + local.x) * p.layout.y;
        for (uint c = 0; c < p.layout.w; ++c) {
    #if BORGVR_PARTIAL_CHANNELS
          if (!(p.selection.x & (1u << (p.layout.z + c)))) continue;
    #endif
          value[c] = float(original[offset + p.layout.z + c]) / 255.0f;
        }
      }
      atlas.write(value, id + p.page.xyz);
    }
    """
}
