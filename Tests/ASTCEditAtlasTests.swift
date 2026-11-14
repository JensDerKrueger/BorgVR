import Foundation
import Metal

// The isolated atlas target does not include the conversion service.
final class BorgVRVolumeConversionCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.withLock { cancelled } }
  func cancel() { lock.withLock { cancelled = true } }
  func checkCancellation() throws { if isCancelled { throw CancellationError() } }
}

private struct ASTCAtlasFailure: Error { let message: String }

private final class ASTCAtlasSource: BORGVRDatasetProtocol {
  let metadata: BORGVRMetaData
  let original: [UInt8]
  let payload: [UInt8]
  init(block: Int) throws {
    metadata = BORGVRMetaData(width: 56, height: 56, depth: 56, componentCount: 4,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: 32, overlap: 2, minValue: 192, maxValue: 192, compression: true,
      datasetDescription: "ASTC atlas updates", metaDescription: "")
    try metadata.setChannelInterpretation(BORGVRChannelInterpretation.rgba.withASTC(blockSize: block))
    original = (0..<(32 * 32 * 32)).flatMap { _ in [UInt8(32), 96, 224, 192] }
    payload = original.withUnsafeBufferPointer {
      BorgVRASTCCodec.encode($0.baseAddress!, brickSize: 32, components: 4, blockSize: block)
    }
    for level in metadata.levelMetadata {
      for _ in 0..<(level.totalBricks.x * level.totalBricks.y * level.totalBricks.z) {
        metadata.append(offset: 8, size: payload.count, componentRanges: [.init(minValue: 192, maxValue: 192)])
      }
    }
  }
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: original.count) }
  func newRequest() {}
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: 0, outputBuffer: outputBuffer) }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    _ = original.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, $0.count) }
  }
  func getASTCBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>, synchronous: Bool) throws -> Bool {
    _ = payload.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, $0.count) }
    return true
  }
}

func runASTCEditAtlasTests(device: MTLDevice, queue: MTLCommandQueue) throws {
  guard device.supportsFamily(.apple3) else { return }
  func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw ASTCAtlasFailure(message: message) }
  }
  func wait(_ operation: (@escaping @Sendable (Error?) -> Void) -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error?
    operation { error in failure = error; done.signal() }
    try check(done.wait(timeout: .now() + 30) == .success, "Edit operation timed out")
    if let failure { throw failure }
  }
  for block in [4, 8] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-astc-atlas-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try ASTCAtlasSource(block: block)
    let data = try BorgVREditableVolumeData(source: original, directory: directory, logger: nil)
    defer { try? wait { data.shutdown(completion: $0) } }
    let m = data.getMetadata(), count = m.brickMetadata.count
    let atlas = try VolumeAtlas(device: device, maxMemory: count * original.payload.count * 2,
      borgData: data, transferFunctions: [], isoValue: 0)
    try atlas.pageIn(IDs: Array(0..<(count - 1)))
    try check(atlas.pagingStatistics.residentBricks == count, "Test must keep every LOD resident")
    func frame() {
      let command = queue.makeCommandBuffer()!
      atlas.prepareFrame(commandBuffer: command)
      command.commit(); command.waitUntilCompleted()
    }
    frame()
    let texture = atlas.atlasTexture!
    let blocksX = texture.width / block, blocksY = texture.height / block
    func contents() -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: blocksX * blocksY * texture.depth * 16)
      bytes.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: blocksX * 16, bytesPerImage: blocksX * blocksY * 16,
          from: MTLRegionMake3D(0, 0, 0, texture.width, texture.height, texture.depth), mipmapLevel: 0, slice: 0)
      }
      return bytes
    }
    let before = contents()
    let brickBlocks = 32 / block
    let pagesX = texture.width / 32, pagesY = texture.height / 32
    func page(_ bytes: [UInt8], _ index: Int) -> [UInt8] {
      let x = index % pagesX, y = (index / pagesX) % pagesY, z = index / (pagesX * pagesY)
      var result: [UInt8] = []
      for slice in 0..<32 { for row in 0..<brickBlocks {
        let start = (((z * 32 + slice) * blocksY + y * brickBlocks + row) * blocksX + x * brickBlocks) * 16
        result.append(contentsOf: bytes[start..<(start + brickBlocks * 16)])
      } }
      return result
    }
    let residentPages = (0..<(texture.width * texture.height * texture.depth / (32 * 32 * 32)))
      .filter { page(before, $0) == original.payload }
    try check(residentPages.count == count, "Could not identify all resident test pages")
    let library = try device.makeLibrary(source: """
      #include <metal_stdlib>
      using namespace metal;
      vertex float4 v(uint id [[vertex_id]]) {
        float2 p[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        return float4(p[id], 0, 1);
      }
      fragment uint f(float4 position [[position]], constant uint *metadata [[buffer(1)]]) {
        return metadata[uint(position.x)];
      }
      """, options: nil)
    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = library.makeFunction(name: "v")
    pipelineDescriptor.fragmentFunction = library.makeFunction(name: "f")
    pipelineDescriptor.colorAttachments[0].pixelFormat = .r32Uint
    let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint,
      width: count, height: 1, mipmapped: false)
    targetDescriptor.storageMode = .shared; targetDescriptor.usage = .renderTarget
    let target = device.makeTexture(descriptor: targetDescriptor)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].storeAction = .store
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    atlas.bind(to: encoder, atlasIndex: 0, metaIndex: 1, levelIndex: 2)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    var flags = [UInt32](repeating: 0, count: count)
    flags.withUnsafeMutableBytes {
      target.getBytes($0.baseAddress!, bytesPerRow: count * 4,
        from: MTLRegionMake2D(0, 0, count, 1), mipmapLevel: 0)
    }
    let flagCount = UInt32(BrickIDFlags.BI_FLAG_COUNT.rawValue)
    try check(flags.allSatisfy { $0 >= flagCount }, "Test starts with a missing or empty page")
    let pages = flags.map { Int($0 - flagCount) }
    let erased = [UInt8](repeating: 0, count: original.original.count).withUnsafeBufferPointer {
      BorgVRASTCCodec.encode($0.baseAddress!, brickSize: 32, components: 4, blockSize: block)
    }
    for mode in [BorgVRVolumeBrushMode.erase, .restore, .erase, .restore] {
      try wait { data.brush([.init(center: .zero, radius: 1000)], mode: mode, completion: $0) }
      // Keep rendering while CPU materialization and ASTC encoding complete independently.
      let deadline = Date().addingTimeInterval(15)
      let expected = mode == .erase ? erased : original.payload
      var stale: [Int] = []
      repeat {
        frame()
        let bytes = contents()
        stale = residentPages.filter { page(bytes, $0) != expected }
        if stale.isEmpty { break }
        Thread.sleep(forTimeInterval: 0.005)
      } while Date() < deadline
      try check(stale.isEmpty, "ASTC \(block)x\(block) \(mode): stale atlas pages \(stale), pending CPU work: \(data.hasPendingBrickUpdates)")
    }
    for operation in 0..<24 {
      let center = SIMD3<Double>(Double((operation * 13) % 56), Double((operation * 17) % 56), Double((operation * 23) % 56))
      try wait { data.brush([.init(center: center, radius: 14)], mode: operation % 3 == 2 ? .restore : .erase, completion: $0) }
      frame()
    }
    try wait { data.preparePendingEdits(cancellationToken: .init(), progress: { _ in }, completion: $0) }
    let buffer = data.allocateBrickBuffer()
    defer { buffer.deallocate() }
    let workReportedComplete = !data.hasPendingBrickUpdates
    for id in 0..<count {
      do {
        _ = try data.getASTCBrick(index: id, outputBuffer: buffer, synchronous: false)
      } catch BORGVRDataError.brickNotYetAvailable {
        try check(!workReportedComplete, "Edit calculation reported complete while ASTC brick \(id) was still unavailable")
      }
    }
    let expected = try (0..<count).map { id -> [UInt8] in
      try data.getBrick(index: id, outputBuffer: buffer)
      return BorgVRASTCCodec.encode(buffer, brickSize: 32, components: 4, blockSize: block)
    }
    let deadline = Date().addingTimeInterval(15)
    var stale: [Int] = []
    repeat {
      frame()
      let bytes = contents()
      stale = (0..<count).filter { page(bytes, pages[$0]) != expected[$0] }
      if stale.isEmpty { break }
      Thread.sleep(forTimeInterval: 0.005)
    } while Date() < deadline
    try check(stale.isEmpty, "ASTC \(block)x\(block) consecutive edits left stale bricks \(stale)")
  }
  print("ASTC edit/atlas integration passed: asynchronous erase/restore updates every resident LOD")
}
