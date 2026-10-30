import Foundation
import Metal

// Minimal session DTO for the isolated renderer/atlas tests.
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
  private var originals: [Int: BorgVRVolumeOriginalBrick] = [:]
  func attachGPUBrushRenderer() { enabled = true }
  func detachGPUBrushRenderer() { enabled = false }
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] { history }
  func gpuReadableRevision(index: Int) -> UInt64? { readableRevision }
  func cachedOriginalBrick(index: Int) -> BorgVRVolumeOriginalBrick? {
    originalRequests.append(index)
    guard originalAvailable else { return nil }
    if let brick = originals[index] { return brick }
    let brick = [UInt8](repeating: 128, count: 8).withUnsafeBytes { BorgVRVolumeOriginalBrick(copying: $0) }
    originals[index] = brick
    return brick
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
  var history: [BorgVRVolumeBrushBatch] = []
  var readableRevision: UInt64? = 0
  var blockCPUReads = false
  private(set) var cpuReads = 0
  private var originals: [Int: BorgVRVolumeOriginalBrick] = [:]
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
    cpuReads += 1
    guard !blockCPUReads else { throw BORGVRDataError.brickNotYetAvailable(index: index) }
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
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] { history }
  func gpuReadableRevision(index: Int) -> UInt64? { readableRevision }
  func cachedOriginalBrick(index: Int) -> BorgVRVolumeOriginalBrick? {
    guard originalAvailable else { return nil }
    if let brick = originals[index] { return brick }
    let brick = original(index).withUnsafeBytes { BorgVRVolumeOriginalBrick(copying: $0) }
    originals[index] = brick
    return brick
  }
}

@main
private enum VolumeAtlasEditTests {
  static func main() throws {
    try datasetTransferFunctionFiles()
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      print("SKIP: Metal device unavailable for atlas edit regression")
      return
    }
    try rendererTransferFunctionRanges(device: device)
    try rendererAlphaEpsilon(device: device)
    try linearTransferFunctionBounds(device: device)
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
    let epsilonRenderer = RenderTransferFunctionSet(device: device)
    let weakSnapshot = BorgVRTransferFunctionSnapshot(channel: 0,
      samples: [SIMD4<UInt8>](repeating: SIMD4(255, 255, 255, 1), count: 256), revision: 1)
    let weakRanges = [BORGVRComponentRange(minValue: 0, maxValue: 255)]
    try epsilonRenderer.synchronize(with: [weakSnapshot], componentRanges: weakRanges, rangeMax: 255)
    let epsilonAtlas = try VolumeAtlas(device: device, maxMemory: 1024,
      borgData: EditableAtlasFixture(), transferFunctions: epsilonRenderer.activeTransferFunctions, isoValue: 0.5)
    try expect(!isEmpty(try render(0, using: epsilonAtlas).x), "Zero epsilon hid weakly visible data")
    func awaitEpsilonFlag(empty: Bool) throws {
      for _ in 0..<200 {
        if isEmpty(try render(0, using: epsilonAtlas).x) == empty { return }
        Thread.sleep(forTimeInterval: 0.005)
      }
      throw AtlasTestFailure(message: "Epsilon change did not update the GPU brick flags")
    }
    try epsilonRenderer.synchronize(with: [weakSnapshot], componentRanges: weakRanges,
      rangeMax: 255, alphaEpsilon: 0.004)
    epsilonAtlas.updateEmptiness(transferFunctions: epsilonRenderer.activeTransferFunctions)
    try awaitEpsilonFlag(empty: true)
    try epsilonRenderer.synchronize(with: [weakSnapshot], componentRanges: weakRanges, rangeMax: 255)
    epsilonAtlas.updateEmptiness(transferFunctions: epsilonRenderer.activeTransferFunctions)
    try awaitEpsilonFlag(empty: false)
    print("Alpha epsilon updates GPU empty/nonempty flags in both directions")
    try gpuAtlas(device: device, queue: queue, tf: tf, pipeline: pipeline, target: target)
    try channelRestoreBeforeCPU(device: device, queue: queue, tf: tf, target: target)
    try packedBrushes(device: device, queue: queue)
    print("Volume atlas edit regression tests passed")
  }

  static func rendererTransferFunctionRanges(device: MTLDevice) throws {
    for bytes in [1, 2, 4] {
      let rangeMax = bytes == 4 ? Int(UInt32.max) : (1 << (bytes * 8)) - 1
      let maxima = bytes == 1 ? [63, 255, 127, 31]
        : bytes == 2 ? [19958, 31785, 8000, 12000]
        : [Int(UInt32.max), 1_000_000, 2_000_000, 500_000]
      for channels in 1...4 {
        let renderTFs = RenderTransferFunctionSet(device: device)
        for pass in 0..<2 {
          let ranges = maxima.prefix(channels).map {
            BORGVRComponentRange(minValue: 0, maxValue: $0 / (pass + 1))
          }
          let snapshots = (0..<channels).reversed().map { channel in
            BorgVRTransferFunctionSnapshot(channel: channel,
              samples: (0..<256).map { SIMD4<UInt8>(255, 255, 255, $0 < 128 ? 0 : 255) },
              revision: 1)
          }
          try renderTFs.synchronize(with: snapshots, componentRanges: ranges, rangeMax: rangeMax)
          let active = renderTFs.activeTransferFunctions
          try expect(active.count == channels, "Renderer lost an active TF channel")
          let transparent = BrickMetadata(offset: 0, size: 0, minValue: 0,
            maxValue: ranges.map { $0.maxValue / 4 }.max()!,
            componentRanges: ranges.map { .init(minValue: 0, maxValue: $0.maxValue / 4) })
          try expect(active.indices.allSatisfy { active[$0].isBrickEmpty(brickMetadata: transparent, component: $0) },
            "Transparent channels must permit empty-space skipping")
          for channel in 0..<channels {
            let expectedBias = Float(rangeMax) / Float(ranges[channel].maxValue)
            try expect(abs(active[channel].textureBias / expectedBias - 1) < 0.000001,
              "Renderer TF \(channel) uses the global rather than channel maximum (\(bytes)-byte, \(channels) channels, pass \(pass))")
            var brickRanges = ranges.map { BORGVRComponentRange(minValue: 0, maxValue: $0.maxValue / 4) }
            let visibleValue = ranges[channel].maxValue * 3 / 4
            brickRanges[channel] = .init(minValue: visibleValue, maxValue: visibleValue)
            let visible = BrickMetadata(offset: 0, size: 0, minValue: 0,
              maxValue: brickRanges.map(\.maxValue).max()!, componentRanges: brickRanges)
            try expect(!active[channel].isBrickEmpty(brickMetadata: visible, component: channel),
              "Visible channel \(channel) was incorrectly skipped")
            try expect(!active.indices.allSatisfy { active[$0].isBrickEmpty(brickMetadata: visible, component: $0) },
              "One visible channel must keep the complete brick nonempty")
          }
        }
      }
    }
    print("Renderer TF normalization and empty-space skipping passed (1-4 channels, 8/16/32-bit, unchanged TF revisions)")
  }

  static func rendererAlphaEpsilon(device: MTLDevice) throws {
    let renderer = RenderTransferFunctionSet(device: device)
    let ranges = [BORGVRComponentRange(minValue: 0, maxValue: 255),
                  BORGVRComponentRange(minValue: 0, maxValue: 1000)]
    var samples = [SIMD4<UInt8>](repeating: SIMD4(17, 31, 63, 0), count: 256)
    samples[64].w = 1; samples[128].w = 2
    var strongSamples = samples
    strongSamples[192].w = 255
    let snapshots = [BorgVRTransferFunctionSnapshot(channel: 0, samples: samples, revision: 1),
                     BorgVRTransferFunctionSnapshot(channel: 1, samples: strongSamples, revision: 1)]
    let original = snapshots.map(\.samples)
    func sync(_ epsilon: Float) throws {
      try renderer.synchronize(with: snapshots, componentRanges: ranges, rangeMax: 65535,
        alphaEpsilon: epsilon)
    }
    try sync(0)
    try expect(renderer.activeTransferFunctions.map(\.data) == original, "Zero epsilon altered TF samples")
    let revisions = renderer.activeTransferFunctions.map(\.revision)
    try sync(0)
    try expect(renderer.activeTransferFunctions.map(\.revision) == revisions,
      "Unchanged epsilon reuploaded TF samples")
    try sync(2.0 / 255)
    for tf in renderer.activeTransferFunctions {
      try expect(tf.minIndex == 128,
        "Emptiness must ignore alpha below, but not at, the threshold")
    }
    try expect(renderer.activeTransferFunctions.map(\.data) == original &&
      renderer.activeTransferFunctions.map(\.revision) == revisions,
      "Epsilon changed the rendered TF samples or triggered a texture upload")
    let previous = TransferFunction1D(copyFrom: renderer.activeTransferFunctions[0])
    try sync(0.01)
    let active = renderer.activeTransferFunctions
    let brick = BrickMetadata(offset: 0, size: 0, minValue: 0, maxValue: 1000, componentRanges: ranges)
    try expect(active[0].isBrickEmpty(brickMetadata: brick, component: 0),
      "A channel entirely below epsilon must become empty")
    try expect(active[1].data[192].w == 255 && !active[1].isBrickEmpty(brickMetadata: brick, component: 1),
      "Ignoring weak values hid a strong feature")
    try expect(active[0].emptinessSignificantChange(previous),
      "The background emptiness updater was not notified of threshold changes")
    let copy = TransferFunction1D(copyFrom: active[0])
    copy.initMetal(device: device)
    try copy.updateData(with: samples)
    try expect(copy.isBrickEmpty(brickMetadata: brick, component: 0),
      "A background TF copy lost its emptiness threshold")
    try sync(0.01)
    try expect(active.map(\.data) == original && active.map(\.revision) == revisions,
      "Classification-only changes modified the rendered TF")
    try sync(0)
    try expect(active[0].minIndex == 64 && active.map(\.data) == original &&
      snapshots.map(\.samples) == original && active.map(\.revision) == revisions,
      "Disabling epsilon did not restore classification without changing the TFs")
    samples[80].w = 1; samples[96].w = 10
    try renderer.synchronize(with: [.init(channel: 0, samples: samples, revision: 2)],
      componentRanges: ranges, rangeMax: 65535, alphaEpsilon: 0.01)
    try expect(renderer.activeTransferFunctions[0].minIndex == 96 &&
      renderer.activeTransferFunctions[0].data == samples,
      "A changed TF bypassed the emptiness threshold or altered its rendered samples")
    for epsilon: Float in [0.02, 0] {
      try renderer.synchronize(with: [snapshots[0]], componentRanges: ranges, rangeMax: 65535,
        alphaEpsilon: epsilon)
      try sync(epsilon)
      try expect(renderer.activeTransferFunctions[1].minIndex == (epsilon == 0 ? 64 : 192),
        "A reactivated channel retained an outdated epsilon")
      try expect(renderer.activeTransferFunctions.map(\.data) == original,
        "Reactivating a channel changed its rendered TF")
    }
    print("Alpha epsilon passed: classification only, unchanged TF samples/revisions, boundary, copies, channels and reset")
  }

  static func linearTransferFunctionBounds(device: MTLDevice) throws {
    for count in [256, 4096] {
      let tf = TransferFunction1D(count: count)
      let maximum = 19958
      let index = count == 256 ? 23 : 370
      var samples = [SIMD4<UInt8>](repeating: .zero, count: count)
      samples[index].w = 255
      tf.initMetal(device: device)
      try tf.updateData(with: samples)
      tf.updateRanges(minValue: 0, maxValue: maximum, rangeMax: 65535)
      let center = Int((Double(index) + 0.5) * Double(maximum) / Double(count))
      for value in (center - 2 * maximum / count - 2)...(center + 2 * maximum / count + 2) {
        let coordinate = Float(value) / 65535 * tf.textureBias * Float(count) - 0.5
        let alpha = max(0, 1 - abs(coordinate - Float(index)))
        let brick = BrickMetadata(offset: 0, size: 0, minValue: value, maxValue: value,
          componentRanges: [.init(minValue: value, maxValue: value)])
        if alpha > 0 {
          try expect(!tf.isBrickEmpty(brickMetadata: brick, component: 0),
            "Linear TF filtering has visible support outside the old index bounds")
        } else if abs(coordinate - Float(index)) > 1.01 {
          try expect(tf.isBrickEmpty(brickMetadata: brick, component: 0),
            "Scalar values outside TF support were not skipped")
        }
      }
    }
    print("TF empty-space bounds include linear interpolation at both support edges")
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

  static func channelRestoreBeforeCPU(device: MTLDevice, queue: MTLCommandQueue,
                                     tf: TransferFunction1D, target: MTLTexture) throws {
    let dataset = PackedBrushFixture(bytes: 2, channels: 2, scale: 1)
    let atlas = try VolumeAtlas(device: device, maxMemory: 65536, borgData: dataset,
      transferFunctions: [tf, tf], isoValue: 0.5)
    try atlas.pageIn(IDs: [0])
    let readsBeforeBrush = dataset.cpuReads
    dataset.blockCPUReads = true
    dataset.readableRevision = nil
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
        uint page = meta[id] - \(BrickIDFlags.BI_FLAG_COUNT.rawValue);
        uint width = atlas.get_width() / 4, height = atlas.get_height() / 4;
        uint3 p = uint3(page % width, (page / width) % height, page / (width * height)) * 4;
        return uint4(round(atlas.read(p) * 255));
      }
      """, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "v")
    descriptor.fragmentFunction = library.makeFunction(name: "f")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Uint
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    func render(_ id: Int) throws -> SIMD4<UInt32> {
      let command = queue.makeCommandBuffer()!
      atlas.prepareFrame(commandBuffer: command)
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = target
      pass.colorAttachments[0].loadAction = .dontCare
      pass.colorAttachments[0].storeAction = .store
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
      encoder.setRenderPipelineState(pipeline)
      atlas.bind(to: encoder, atlasIndex: 0, metaIndex: 1, levelIndex: 2)
      var index = UInt32(id)
      encoder.setFragmentBytes(&index, length: 4, index: 3)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
      command.commit(); command.waitUntilCompleted()
      if let error = command.error { throw error }
      var pixel = SIMD4<UInt32>.zero
      target.getBytes(&pixel, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
      return pixel
    }
    let overview = dataset.metadata.brickMetadata.count - 1
    let original = try render(0)
    let all = BorgVRVolumeBrushSample(center: .zero, radius: 100)
    dataset.history = [.init(id: UUID(), revision: 1, mode: .erase, samples: [all])]
    try expect(try render(0) == .zero, "All-channel GPU erase waited for CPU materialization")
    dataset.originalAvailable = false
    dataset.history.append(.init(id: UUID(), revision: 2, mode: .restore, samples: [all], channels: .selected([1])))
    try expect(try render(0) == .zero, "Channel restore ran without immutable originals")
    dataset.originalAvailable = true
    let partial = SIMD4<UInt32>(0, 0, original.z, original.w)
    try expect(try render(0) == partial && render(overview) == partial,
      "Channel restore waited for pending CPU bricks or changed the other channel")
    dataset.history.append(.init(id: UUID(), revision: 3, mode: .erase, samples: [all], channels: .selected([1])))
    try expect(try render(0) == .zero, "Channel GPU erase waited for CPU materialization")
    dataset.history.append(.init(id: UUID(), revision: 4, mode: .restore, samples: [all]))
    try expect(try render(0) == original, "All-channel restore regressed after a partial restore")
    try expect(dataset.cpuReads == readsBeforeBrush, "GPU restore requested a canonical CPU brick")
    print("Channel restore updates fine/coarse atlas pages without CPU materialization")
  }

  static func datasetTransferFunctionFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-dataset-tfs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    for count in 1...4 {
      let baseURL = root.appendingPathComponent("\(count)/volume.tf1d")
      let urls = DatasetTransferFunctionStorage.fileURLs(baseURL: baseURL, componentCount: count)
      try expect(urls.count == count && Set(urls).count == count, "TF filenames collide across channels")
      try expect(count == 1 ? urls == [baseURL] : urls.last!.lastPathComponent == "volume.channel-\(count).tf1d",
        "Dataset TF naming is inconsistent")
      let originals = (0..<count).map { channel in
        let tf = TransferFunction1D(count: 256 << channel)
        tf.smoothStep(start: Float(channel + 1) * 0.1, shift: 0.2, channels: [0, 1, 2, 3], reverse: channel % 2 == 0)
        return tf
      }
      try DatasetTransferFunctionStorage.save(originals, to: urls, description: "Dataset")
      try expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Save skipped a TF channel")
      let targets = (0..<count).map { _ in TransferFunction1D(count: 128) }
      try expect(try DatasetTransferFunctionStorage.load(targets, from: urls), "Saved TFs were not found")
      for channel in 0..<count {
        try expect(targets[channel].data == originals[channel].data, "Saved TF samples/count assigned to wrong channel")
        try expect(try TransferFunction1D.fileDescription(from: Data(contentsOf: urls[channel])).contains("Dataset"),
          "Dataset TF description was lost")
      }
      if count > 1 {
        // An unrelated single preset must not be used as a fallback for a missing channel.
        try originals[0].save(to: baseURL)
        try FileManager.default.removeItem(at: urls[0])
        targets[0].reset()
        let untouched = targets[0].data
        try expect(try DatasetTransferFunctionStorage.load(targets, from: urls), "Missing TF hid other saved channels")
        try expect(targets[0].data == untouched && targets[1].data == originals[1].data,
          "Missing TF shifted channel indices or loaded a legacy fallback")
        try DatasetTransferFunctionStorage.save(originals, to: urls)
      }
      for target in targets { target.reset() }
      let before = targets.map(\.data)
      try Data([1, 2, 3]).write(to: urls[count - 1])
      var rejected = false
      do { _ = try DatasetTransferFunctionStorage.load(targets, from: urls) } catch { rejected = true }
      try expect(rejected && targets.map(\.data) == before, "Invalid later TF partially changed earlier channels")
      try DatasetTransferFunctionStorage.save(originals, to: urls)
      let saved = try urls.map { try Data(contentsOf: $0) }
      rejected = false
      do { try DatasetTransferFunctionStorage.save(originals, to: []) } catch { rejected = true }
      try expect(rejected && (try urls.map { try Data(contentsOf: $0) }) == saved,
        "Inconsistent save plan overwrote a channel")
    }
    print("Dataset TF save/load tests passed for 1-4 independent channels")
  }

  static func packedBrushes(device: MTLDevice, queue: MTLCommandQueue) throws {
    for (bytes, channels) in [(1, 1), (1, 2), (1, 3), (1, 4), (2, 1), (2, 2), (2, 3), (2, 4), (4, 1)] {
      for scale: Float in [1, 1e-12] {
        let source = PackedBrushFixture(bytes: bytes, channels: channels, scale: scale)
        let m = source.metadata
        let renderer = try VolumeAtlasBrushRenderer(device: device, metadata: m)
        let executor = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
        let spacing = SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ))
        var mask = try BorgVRVolumeEditMask(size: SIMD3(m.width, m.height, m.depth), spacing: spacing, componentCount: channels)
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
          (.restore, [.init(center: SIMD3(3, 2, 1) * spacing, radius: Double(scale) * 100)]),
          (.erase, [.init(center: SIMD3(2.5, 2.5, 1.5) * spacing, radius: Double(scale) * 2)]),
          (.erase, [.init(center: SIMD3(3, 2, 1) * spacing, radius: Double(scale) * 100)]),
          (.restore, [.init(center: SIMD3(3, 2, 1) * spacing, radius: Double(scale) * 100)]),
          (.restore, [.init(center: SIMD3(3, 2, 1) * spacing, radius: Double(scale) * 100)])
        ]
        for (step, operation) in operations.enumerated() {
          let selection: BorgVRVolumeEditChannels = step == 4 || step == 6 ? .selected([channels - 1]) : .all
          let batch = BorgVRVolumeBrushBatch(id: UUID(), revision: UInt64(step + 1),
            mode: operation.0, samples: operation.1, channels: selection)
          for sample in batch.samples { try mask.apply(sample, mode: batch.mode, channels: selection) }
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
