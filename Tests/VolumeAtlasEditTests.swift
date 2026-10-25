import Foundation
import Metal

// RenderTransferFunctionSet's session DTO is unrelated to this isolated atlas test.
struct BorgVRTransferFunctionSnapshot {
  let channel: Int
  let samples: [SIMD4<UInt8>]
  let revision: UInt64
}

private struct AtlasTestFailure: Error { let message: String }

private func expect(_ condition: Bool, _ message: String) throws {
  if !condition { throw AtlasTestFailure(message: message) }
}

private class EditableAtlasFixture: BORGVRDatasetProtocol {
  let metadata = BORGVRMetaData(width: 4, height: 2, depth: 2, componentCount: 1,
    bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
    brickSize: 2, overlap: 0, minValue: 0, maxValue: 255, compression: false,
    datasetDescription: "Atlas edit regression", metaDescription: "")
  private let lock = NSLock()
  private var revision: UInt64 = 0
  private var residents: Set<Int> = []
  var contentRevision: UInt64 { lock.withLock { revision } }
  var residentIDs: Set<Int> { lock.withLock { residents } }
  private var values: [Int: UInt8] = [:]
  private var pending: Set<Int> = []
  private var pendingBounds: [Int: BrickMetadata] = [:]

  init(maximum: Int = 255) {
    for _ in 0..<3 { metadata.append(offset: 8, size: 8, minValue: 0, maxValue: maximum) }
  }

  func edit(_ index: Int, value: UInt8, ready: Bool, bounds: BrickMetadata? = nil) {
    lock.withLock {
      values[index] = value
      if ready { pending.remove(index) } else { pending.insert(index) }
      pendingBounds[index] = bounds
      revision += 1
    }
  }

  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: 8) }
  func updateResidentBrickIDs(_ ids: Set<Int>) { lock.withLock { residents = ids } }
  func changedBrickIDs(since oldRevision: UInt64) -> [Int] {
    lock.withLock { oldRevision < revision ? Array(values.keys) : [] }
  }
  func visibilityMetadata(index: Int) -> BrickMetadata? {
    lock.withLock { pending.contains(index) ? pendingBounds[index] : metadata.brickMetadata[index] }
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try getBrick(index: 2, outputBuffer: outputBuffer)
  }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try lock.withLock {
      guard !pending.contains(index) else { throw BORGVRDataError.brickNotYetAvailable(index: index) }
      outputBuffer.update(repeating: values[index] ?? 128, count: 8)
    }
  }
}

private final class GPUAtlasFixture: EditableAtlasFixture, BorgVRVolumeGPUBrushSource {
  var gpuBrushGeneration: UInt64 = 0
  var history: [BorgVRVolumeBrushBatch] = []
  var readableRevision: UInt64? = 0
  var enabled = false
  var originalAvailable = true
  var originalRequests: [Int] = []
  func attachGPUBrushRenderer() { enabled = true }
  func detachGPUBrushRenderer() { enabled = false }
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] { history }
  func gpuReadableRevision(index: Int) -> UInt64? { readableRevision }
  func cachedOriginalBrick(index: Int) -> [UInt8]? {
    originalRequests.append(index)
    return originalAvailable ? Array(repeating: 128, count: 8) : nil
  }
  func brush(_ mode: BorgVRVolumeBrushMode) {
    history.append(BorgVRVolumeBrushBatch(id: UUID(), revision: (history.last?.revision ?? 0) + 1,
      mode: mode, samples: [BorgVRVolumeBrushSample(center: SIMD3(0.5, 0.5, 0.5), radius: 0.25)]))
    readableRevision = nil
    edit(0, value: 32, ready: false)
  }
}

private final class PackedBrushFixture: BORGVRDatasetProtocol, BorgVRVolumeGPUBrushSource {
  let metadata: BORGVRMetaData
  var originalAvailable = true
  init(bytes: Int, channels: Int, scale: Float) {
    metadata = BORGVRMetaData(width: 7, height: 5, depth: 3, componentCount: channels,
      bytePerComponent: bytes, voxelSpacingX: scale, voxelSpacingY: scale * 2,
      voxelSpacingZ: scale * 0.75, brickSize: 4, overlap: 1, minValue: 0,
      maxValue: 255, compression: false, datasetDescription: "Packed brush test", metaDescription: "")
    for level in metadata.levelMetadata {
      for _ in 0..<(level.totalBricks.x * level.totalBricks.y * level.totalBricks.z) {
        metadata.append(offset: 8, size: 64 * bytes * channels, minValue: 0, maxValue: 255)
      }
    }
  }
  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> {
    .allocate(capacity: 64 * metadata.componentCount * metadata.bytesPerComponent)
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try getBrick(index: metadata.brickMetadata.count - 1, outputBuffer: outputBuffer)
  }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let bytes = original(index)
    _ = bytes.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, bytes.count) }
  }
  func original(_ id: Int) -> [UInt8] {
    let m = metadata
    let level = m.levelMetadata.last { $0.prevBricks <= id }!
    let local = id - level.prevBricks
    let origin = SIMD3(local % level.totalBricks.x,
      (local / level.totalBricks.x) % level.totalBricks.y,
      local / (level.totalBricks.x * level.totalBricks.y)) &* 2 &- SIMD3(repeating: 1)
    var bytes: [UInt8] = []
    for z in 0..<4 { for y in 0..<4 { for x in 0..<4 {
      let p = origin &+ SIMD3(x, y, z)
      let clamped = SIMD3(max(0, min(level.size.x - 1, p.x)), max(0, min(level.size.y - 1, p.y)),
                          max(0, min(level.size.z - 1, p.z)))
      for c in 0..<(m.componentCount * m.bytesPerComponent) {
        bytes.append(UInt8(truncatingIfNeeded: 31 + clamped.x + clamped.y * 7 + clamped.z * 35 + c * 53))
      }
    } } }
    return bytes
  }
  func attachGPUBrushRenderer() {}
  func detachGPUBrushRenderer() {}
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] { [] }
  func gpuReadableRevision(index: Int) -> UInt64? { 0 }
  func cachedOriginalBrick(index: Int) -> [UInt8]? { originalAvailable ? original(index) : nil }
}

@main
private enum VolumeAtlasEditTests {
  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      print("SKIP: Metal device unavailable for atlas edit regression")
      return
    }
    let dataset = EditableAtlasFixture()
    let tf = TransferFunction1D(count: 256)
    tf.initMetal(device: device)
    tf.updateRanges(minValue: 0, maxValue: 255, rangeMax: 255)
    try tf.updateData(with: [SIMD4<UInt8>](repeating: SIMD4(255, 255, 255, 255), count: 256))
    let atlas = try VolumeAtlas(device: device, maxMemory: 1024, borgData: dataset,
      transferFunctions: [tf], isoValue: 0.5)
    try atlas.pageIn(IDs: [0])
    try expect(dataset.residentIDs.contains(0) && dataset.residentIDs.contains(2),
               "Atlas did not advertise resident fine/fallback bricks")

    let flagCount = UInt32(BrickIDFlags.BI_FLAG_COUNT.rawValue)
    let library = try device.makeLibrary(source: """
      #include <metal_stdlib>
      using namespace metal;
      vertex float4 v(uint id [[vertex_id]]) {
        float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return float4(p[id], 0, 1);
      }
      fragment uint4 f(constant uint *meta [[buffer(1)]],
                       constant uint &id [[buffer(3)]],
                       texture3d<float, access::read> atlas [[texture(0)]]) {
        uint flag = meta[id];
        if (flag < \(flagCount)) return uint4(flag, 0, 0, 0);
        uint page = flag - \(flagCount);
        uint width = atlas.get_width() / 2, height = atlas.get_height() / 2;
        uint3 p = uint3(page % width, (page / width) % height, page / (width * height)) * 2;
        return uint4(flag, uint(round(atlas.read(p).r * 255)), 0, 0);
      }
      """, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "v")
    descriptor.fragmentFunction = library.makeFunction(name: "f")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Uint
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Uint,
      width: 1, height: 1, mipmapped: false)
    targetDescriptor.storageMode = .shared
    targetDescriptor.usage = [.renderTarget]
    let target = device.makeTexture(descriptor: targetDescriptor)!

    func render(_ index: UInt32, using alternateAtlas: VolumeAtlas? = nil) throws -> SIMD4<UInt32> {
      let currentAtlas = alternateAtlas ?? atlas
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      let command = queue.makeCommandBuffer()!
      currentAtlas.prepareFrame(commandBuffer: command)
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
      encoder.setRenderPipelineState(pipeline)
      currentAtlas.bind(to: encoder, atlasIndex: 0, metaIndex: 1, levelIndex: 2)
      var index = index
      encoder.setFragmentBytes(&index, length: MemoryLayout<UInt32>.stride, index: 3)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      if let error = command.error { throw error }
      var pixel = SIMD4<UInt32>.zero
      target.getBytes(&pixel, bytesPerRow: MemoryLayout<SIMD4<UInt32>>.stride,
        from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
      return pixel
    }

    let original = try render(0)
    try expect(original.x >= flagCount && original.y == 128, "Fine brick not resident before editing")
    dataset.edit(0, value: 32, ready: false)
    for _ in 0..<16 {
      let pending = try render(0)
      try expect(pending == original, "Pending edit dropped the resident page or its previous pixels")
    }
    dataset.edit(0, value: 32, ready: true)
    let edited = try render(0)
    try expect(edited.x == original.x && edited.y == 32, "Ready edit was not uploaded to the same page")
    dataset.edit(0, value: 128, ready: true)
    try expect(try render(0) == original, "Restore did not replace the original resident page")
    dataset.edit(2, value: 64, ready: false)
    let fallback = try render(2)
    try expect(fallback.x == flagCount && fallback.y == 128, "Pending fallback edit lost its pinned page")
    dataset.edit(2, value: 64, ready: true)
    let updatedFallback = try render(2)
    try expect(updatedFallback.x == flagCount && updatedFallback.y == 64, "Pinned fallback was not updated")
    let hidden = EditableAtlasFixture(maximum: 32)
    let thresholdTF = TransferFunction1D(copyFrom: tf)
    thresholdTF.initMetal(device: device)
    var samples = [SIMD4<UInt8>](repeating: SIMD4(255, 255, 255, 0), count: 256)
    for index in 64..<256 { samples[index].w = 255 }
    try thresholdTF.updateData(with: samples)
    let hiddenAtlas = try VolumeAtlas(device: device, maxMemory: 1024, borgData: hidden,
      transferFunctions: [thresholdTF], isoValue: 0.5)
    func isEmpty(_ flag: UInt32) -> Bool {
      flag == UInt32(BrickIDFlags.BI_EMPTY.rawValue) || flag == UInt32(BrickIDFlags.BI_CHILD_EMPTY.rawValue)
    }
    func awaitFlag(_ predicate: (UInt32) -> Bool, _ message: String, index: UInt32 = 1) throws {
      let deadline = Date().addingTimeInterval(2)
      while !predicate(try render(index, using: hiddenAtlas).x) {
        try expect(Date() < deadline, message)
        Thread.sleep(forTimeInterval: 0.001)
      }
    }
    try awaitFlag(isEmpty, "Transparent brick did not start empty")
    hidden.edit(1, value: 0, ready: false, bounds: hidden.metadata.brickMetadata[1])
    for _ in 0..<32 {
      try expect(isEmpty(try render(1, using: hiddenAtlas).x), "Pending erase activated a transparent hidden brick")
    }
    hiddenAtlas.updateEmptiness(transferFunctions: [tf])
    try awaitFlag({ !isEmpty($0) }, "Opaque zero did not reactivate a pending erased brick")
    try hiddenAtlas.pageIn(IDs: [0])
    hiddenAtlas.updateEmptiness(transferFunctions: [thresholdTF])
    try awaitFlag(isEmpty, "TF change did not restore empty pending erase")
    try awaitFlag(isEmpty, "Resident brick did not become empty", index: 0)
    hidden.edit(0, value: 0, ready: false, bounds: hidden.metadata.brickMetadata[0])
    for _ in 0..<16 {
      try expect(isEmpty(try render(0, using: hiddenAtlas).x), "Pending erase reactivated an empty resident page")
    }
    hidden.edit(1, value: 128, ready: false)
    try awaitFlag({ !isEmpty($0) }, "Pending restore incorrectly retained empty status")
    hidden.edit(1, value: 0, ready: false, bounds: hidden.metadata.brickMetadata[1])
    hiddenAtlas.updateEmptiness(isoValue: 0.5)
    try awaitFlag(isEmpty, "Pending erase bounds were not used in ISO mode")
    hiddenAtlas.updateEmptiness(isoValue: 0)
    try awaitFlag({ !isEmpty($0) }, "ISO zero incorrectly skipped pending erased data")
    try gpuAtlas(device: device, queue: queue, tf: tf, pipeline: pipeline, target: target)
    try packedBrushes(device: device, queue: queue)
    print("Volume atlas edit regression tests passed")
  }

  static func gpuAtlas(device: MTLDevice, queue: MTLCommandQueue, tf: TransferFunction1D,
                       pipeline: MTLRenderPipelineState, target: MTLTexture) throws {
    let dataset = GPUAtlasFixture()
    let atlas = try VolumeAtlas(device: device, maxMemory: 1024, borgData: dataset,
      transferFunctions: [tf], isoValue: 0.5)
    try expect(dataset.enabled, "Atlas did not enable GPU brushes")
    try atlas.pageIn(IDs: [0])
    func render(_ index: UInt32 = 0, using alternateAtlas: VolumeAtlas? = nil) throws -> SIMD4<UInt32> {
      let currentAtlas = alternateAtlas ?? atlas
      let command = queue.makeCommandBuffer()!
      currentAtlas.prepareFrame(commandBuffer: command)
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
      encoder.setRenderPipelineState(pipeline)
      currentAtlas.bind(to: encoder, atlasIndex: 0, metaIndex: 1, levelIndex: 2)
      var index = index
      encoder.setFragmentBytes(&index, length: 4, index: 3)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
      command.commit()
      command.waitUntilCompleted()
      if let error = command.error { throw error }
      var pixel = SIMD4<UInt32>.zero
      target.getBytes(&pixel, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
      return pixel
    }
    let original = try render()
    dataset.brush(.erase)
    // A renderer may fail to obtain its drawable after preparing the atlas.
    // That uncommitted frame must not acknowledge the edit.
    let abandoned = queue.makeCommandBuffer()!
    atlas.prepareFrame(commandBuffer: abandoned)
    let erased = try render()
    try expect(erased.x == original.x && erased.y == 0, "GPU erase waited for the pending CPU result")
    try expect(try render(2).y == 0, "GPU preview did not update a coarse resident LOD")
    dataset.edit(2, value: 112, ready: true)
    dataset.readableRevision = 1
    try expect(try render(2).y == 112, "Exact CPU subsampling did not replace the coarse GPU preview")
    dataset.originalAvailable = false
    dataset.brush(.restore)
    try expect(try render().y == 0, "Restore ran without original data")
    dataset.originalAvailable = true
    try expect(try render() == original, "GPU restore did not use immutable source bytes")
    dataset.edit(0, value: 32, ready: true)
    dataset.readableRevision = 1
    try expect(try render() == original, "An old CPU revision overwrote the newer GPU restore")
    dataset.edit(0, value: 128, ready: true)
    dataset.edit(2, value: 128, ready: true)
    dataset.readableRevision = 2
    try expect(try render() == original, "Canonical CPU catch-up changed the restored page")
    // If a renderer misses more than the retained history, it must wait for CPU catch-up.
    dataset.brush(.erase)
    dataset.history = [BorgVRVolumeBrushBatch(id: UUID(), revision: 300, mode: .erase,
      samples: dataset.history.last!.samples)]
    try expect(try render() == original, "Atlas replayed an incomplete operation history")
    dataset.edit(0, value: 0, ready: true)
    dataset.readableRevision = 300
    try expect(try render().y == 0, "Atlas did not recover from a GPU history gap")
    dataset.history.removeAll()
    // A later operation following an existing (reopened) edit state starts above zero.
    dataset.history = [BorgVRVolumeBrushBatch(id: UUID(), revision: 301, mode: .restore,
      samples: [BorgVRVolumeBrushSample(center: SIMD3(0.5, 0.5, 0.5), radius: 0.25)])]
    dataset.readableRevision = nil
    dataset.edit(0, value: 0, ready: false)
    try expect(try render() == original, "GPU brush failed after catching up to a persisted revision")
    dataset.brush(.erase)
    dataset.brush(.restore)
    try expect(try render() == original, "Multiple operations in one frame were reordered")
    dataset.brush(.erase)
    try expect(try render().y == 0, "GPU lost the next operation after a multi-operation frame")
    let neighbor = GPUAtlasFixture()
    let neighborAtlas = try VolumeAtlas(device: device, maxMemory: 1024, borgData: neighbor,
      transferFunctions: [tf], isoValue: 0.5)
    try neighborAtlas.pageIn(IDs: [0, 1])
    neighbor.history = [BorgVRVolumeBrushBatch(id: UUID(), revision: 1,
      mode: .erase, samples: [.init(center: SIMD3(1.75, 0.5, 0.5), radius: 1)])]
    neighbor.readableRevision = nil
    neighbor.edit(1, value: 0, ready: false)
    try expect(try render(1, using: neighborAtlas).y == 0,
               "Brush radius did not reach a neighboring brick beyond its center brick")
    neighbor.history.removeAll()
    neighbor.readableRevision = 2
    for id in 0..<3 { neighbor.edit(id, value: 128, ready: true) }
    try expect(try render(1, using: neighborAtlas).y == 128 && render(2, using: neighborAtlas).y == 128,
               "Discard did not replace both exact and preview atlas pages with original data")
    let filtered = GPUAtlasFixture()
    let filteredAtlas = try VolumeAtlas(device: device, maxMemory: 1024, borgData: filtered,
      transferFunctions: [tf], isoValue: 0.5)
    try filteredAtlas.pageIn(IDs: [0, 1])
    let all = BorgVRVolumeBrushSample(center: .zero, radius: 100)
    filtered.history = [.init(id: UUID(), revision: 1, mode: .erase, samples: [all], affectedBrickIDs: [0, 2])]
    filtered.readableRevision = nil
    filtered.edit(0, value: 0, ready: false)
    try expect(try render(0, using: filteredAtlas).y == 0 && render(1, using: filteredAtlas).y == 128,
               "GPU brush ignored the filtered brick list")
    filtered.originalAvailable = false
    filtered.history.append(.init(id: UUID(), revision: 2, mode: .restore, samples: [all], affectedBrickIDs: [0, 2]))
    filtered.edit(0, value: 128, ready: false)
    try expect(try render(1, using: filteredAtlas).y == 128, "Filtered restore changed an untouched brick")
    try expect(!filtered.originalRequests.isEmpty && !filtered.originalRequests.contains(1),
               "GPU restore requested original bytes for an untouched brick")
    filtered.originalAvailable = true
    try expect(try render(0, using: filteredAtlas).y == 128, "Filtered restore did not restore the edited brick")
    let predicted = GPUAtlasFixture()
    let predictedAtlas = try VolumeAtlas(device: device, maxMemory: 1024, borgData: predicted,
      transferFunctions: [tf], isoValue: 0.5)
    try predictedAtlas.pageIn(IDs: [0])
    predicted.history = [.init(id: UUID(), revision: 1, mode: .erase, samples: [all])]
    predicted.readableRevision = nil
    try expect(try render(0, using: predictedAtlas).y == 0, "Local brush prediction was not rendered")
    predicted.gpuBrushGeneration += 1
    predicted.history.append(.init(id: UUID(), revision: 2, mode: .restore, samples: [all]))
    predicted.edit(0, value: 0, ready: false)
    try expect(try render(0, using: predictedAtlas).y == 0,
      "Prediction replayed on stale voxels before canonical state was available")
    predicted.edit(0, value: 0, ready: true)
    predicted.readableRevision = 1
    try expect(try render(0, using: predictedAtlas).y == 128,
      "Pending prediction was not replayed after canonical state reconciliation")
  }

  static func packedBrushes(device: MTLDevice, queue: MTLCommandQueue) throws {
    for (bytes, channels) in [(1, 1), (1, 2), (1, 3), (1, 4), (2, 1), (2, 2), (2, 3), (2, 4), (4, 1)] {
      for scale: Float in [1, 1e-12] {
        let source = PackedBrushFixture(bytes: bytes, channels: channels, scale: scale)
        let m = source.metadata
        let renderer = try VolumeAtlasBrushRenderer(device: device, metadata: m)
        let executor = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
        let spacing = SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ))
        var mask = try BorgVRVolumeEditMask(size: SIMD3(m.width, m.height, m.depth), spacing: spacing)
        let formats = try VolumeAtlas.getPixelFormats(bytesPerComponent: bytes, componentCount: channels)
        let count = m.levelMetadata[1].prevBricks
        // One atlas slot per fine brick, with a spare untouched voxel column.
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
          let d = MTLTextureDescriptor()
          d.textureType = .type3D; d.pixelFormat = format
          d.width = (count + 1) * 4; d.height = 4; d.depth = 4
          d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
          return device.makeTexture(descriptor: d)!
        }
        let primary = texture(formats.primary)
        let secondary = formats.secondary.map(texture)
        let primaryWidth = min(4, bytes * channels) == 3 ? 4 : min(4, bytes * channels)
        func packed(_ raw: [UInt8], offset: Int, width: Int) -> [UInt8] {
          (0..<64).flatMap { voxel in (0..<width).map { c in
            offset + c < bytes * channels ? raw[voxel * bytes * channels + offset + c] : 0
          } }
        }
        func upload(_ raw: [UInt8], id: Int, texture: MTLTexture, offset: Int, width: Int) {
          let data = packed(raw, offset: offset, width: width)
          data.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(id * 4, 0, 0, 4, 4, 4), mipmapLevel: 0, slice: 0,
              withBytes: $0.baseAddress!, bytesPerRow: 4 * width, bytesPerImage: 16 * width)
          }
        }
        for id in 0..<count {
          let raw = source.original(id)
          upload(raw, id: id, texture: primary, offset: 0, width: primaryWidth)
          if let secondary { upload(raw, id: id, texture: secondary, offset: 4, width: bytes * channels - 4) }
        }
        let operations: [(BorgVRVolumeBrushMode, [BorgVRVolumeBrushSample])] = [
          (.erase, [.init(center: SIMD3(2.5, 2.5, 1.5) * spacing, radius: Double(scale) * 2),
                    .init(center: SIMD3(6.5, 4.5, 2.5) * spacing, radius: Double(scale) * 0.75)]),
          (.restore, [.init(center: SIMD3(1.5, 2.5, 1.5) * spacing, radius: Double(scale) * 1.4)]),
          (.erase, [.init(center: SIMD3(0.5, 0.5, 0.5) * spacing, radius: Double(scale) * 0.5)]),
          (.restore, [.init(center: SIMD3(3, 2, 1) * spacing, radius: Double(scale) * 100)])
        ]
        for (step, operation) in operations.enumerated() {
          let batch = BorgVRVolumeBrushBatch(id: UUID(), revision: UInt64(step + 1),
            mode: operation.0, samples: operation.1)
          for sample in batch.samples { try mask.apply(sample, mode: batch.mode) }
          let prepared = renderer.prepare(batch)!
          let command = queue.makeCommandBuffer()!
          let encoder = command.makeComputeCommandEncoder()!
          for id in 0..<count {
            try expect(renderer.encode(prepared, brickID: id, pageOrigin: SIMD3(id * 4, 0, 0),
              primary: primary, secondary: secondary, source: source, encoder: encoder), "Could not encode brush")
          }
          encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
          if let error = command.error { throw error }
          func compare(_ texture: MTLTexture, id: Int, expected: [UInt8], offset: Int, width: Int) throws {
            var actual = Array(repeating: UInt8(0), count: 64 * width)
            actual.withUnsafeMutableBytes {
              texture.getBytes($0.baseAddress!, bytesPerRow: 4 * width, bytesPerImage: 16 * width,
                from: MTLRegionMake3D(id * 4, 0, 0, 4, 4, 4), mipmapLevel: 0, slice: 0)
            }
            let reference = packed(expected, offset: offset, width: width)
            let firstDifference = actual.indices.first { actual[$0] != reference[$0] }
            try expect(actual == reference,
              "GPU/CPU mismatch: \(bytes)-byte x \(channels), scale \(scale), step \(step), brick \(id), byte \(firstDifference ?? -1)")
          }
          for id in 0..<count {
            let expected = try executor.materialize(index: id, mask: mask, revision: batch.revision).bytes
            try compare(primary, id: id, expected: expected, offset: 0, width: primaryWidth)
            if let secondary { try compare(secondary, id: id, expected: expected, offset: 4, width: bytes * channels - 4) }
          }
        }
      }
    }
    print("GPU brushes match CPU bricks in all supported atlas formats")
  }
}
