import Foundation
import Metal
import simd

private final class ColorVolumeFixture: BORGVRDatasetProtocol, BorgVRVolumeGPUBrushSource {
  let metadata: BORGVRMetaData
  var alpha: UInt8
  var contentRevision: UInt64 = 0
  var unavailable = false
  var gpuBrushAttached = false
  var history: [BorgVRVolumeBrushBatch] = []
  var gpuBrushGeneration: UInt64 { 0 }
  func attachGPUBrushRenderer() { gpuBrushAttached = true }
  func detachGPUBrushRenderer() { gpuBrushAttached = false }
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] { history }
  func gpuReadableRevision(index: Int) -> UInt64? { unavailable ? nil : contentRevision }
  func cachedOriginalBrick(index: Int) -> BorgVRVolumeOriginalBrick? { nil }
  func changedBrickIDs(since revision: UInt64) -> [Int] { revision < contentRevision ? [0] : [] }
  init(_ interpretation: BORGVRChannelInterpretation, alpha: UInt8) throws {
    self.alpha = alpha
    let channels = interpretation == .rgb ? 3 : 4
    metadata = BORGVRMetaData(width: 28, height: 28, depth: 28, componentCount: channels,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: 32, overlap: 2, minValue: 0, maxValue: 255, compression: false,
      datasetDescription: "Color test", metaDescription: "")
    try metadata.setChannelInterpretation(interpretation)
    let ranges = interpretation == .rgb ? [] : [BORGVRComponentRange(minValue: Int(alpha), maxValue: Int(alpha))]
    metadata.updateComponentRanges(ranges)
    metadata.append(offset: 8, size: 32 * 32 * 32 * channels, componentRanges: ranges)
  }
  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> {
    .allocate(capacity: 32 * 32 * 32 * metadata.componentCount)
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: 0, outputBuffer: outputBuffer) }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    if unavailable { throw BORGVRDataError.brickNotYetAvailable(index: index) }
    for i in 0..<(32 * 32 * 32) {
      let start = i * metadata.componentCount
      outputBuffer[start] = 32; outputBuffer[start + 1] = 96; outputBuffer[start + 2] = 224
      if metadata.componentCount == 4 { outputBuffer[start + 3] = alpha }
    }
  }
}

func runColorVolumeRenderingTests(device: MTLDevice, queue: MTLCommandQueue) throws {
  struct Failure: Error { let message: String }
  func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
  func source(_ url: URL) throws -> String {
    var result = ""
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
      if (line.hasPrefix("#include") || line.hasPrefix("#import")),
         let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
        result += try source(url.deletingLastPathComponent().appendingPathComponent(String(line[line.index(after: first)..<last])))
      } else { result += line + "\n" }
    }
    return result
  }
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  let code = try source(root.appendingPathComponent("AppSupport/Rendering/Shaders/RuntimeVolumeShaders.metal")) + """
    vertex VertexToFragment testColorVertex(uint id [[vertex_id]]) {
      float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
      VertexToFragment out; out.position = float4(p[id], 0, 1);
      out.exitPoint = float3((p[id] + 1) * 0.5, 1); return out;
    }
    """
  for interpretation in [BORGVRChannelInterpretation.rgb, .rgba] {
    let options = MTLCompileOptions()
    options.preprocessorMacros = ["OVERRIDE_DUMMY": "1", "LEVEL_COUNT": "1", "BRICK_SIZE": "32",
      "BRICK_INNER_SIZE": "28", "VOLUME_COLOR_MODE": "\(interpretation.rawValue)",
      "VOLUME_COMPONENT_COUNT": interpretation == .rgb ? "3" : "4", "VOLUME_BYTES_PER_COMPONENT": "1",
      "OVERLAP_STEP": "float3(0.0625)", "POOL_SIZE": "float3(32)", "POOL_CAPACITY": "uint3(1)",
      "VOLUME_SIZE": "float3(28)", "VOLUME_SCALE": "float3(1)", "LEVEL_ZERO_WORLD_SPACE_ERROR": "1",
      "LOD_FACTOR": "0", "HASHTABLE_SIZE": "64", "MAX_PROBING_ATTEMPTS": "64", "MAX_ITERATIONS": "8",
      "REQUEST_LOWRES_LOD": "0", "STOP_ON_MISS": "0", "VOLUME_SUBBRICK_SKIPPING": "1",
      "VOLUME_SUBBRICK_DIVISIONS": "2", "VOLUME_OPACITY_ADAPTIVE_SAMPLING": "1"].mapValues { $0 as NSString }
    let library = try device.makeLibrary(source: code, options: options)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "testColorVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "volumeFragmentShaderColor")
    descriptor.colorAttachments[0].pixelFormat = .rgba32Float
    descriptor.colorAttachments[1].pixelFormat = .r32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    for alpha: UInt8 in [0, 16, 255] {
      let fixture = try ColorVolumeFixture(interpretation, alpha: alpha)
      let updater = AsyncEmptinessUpdater(borgData: fixture, transferFunctions: [], isoValue: 1, logger: nil)
      defer { updater.terminateBackgroundTask() }
      let brick = fixture.metadata.brickMetadata[0]
      for epsilon: Float in [0, 0.01, Float(alpha) / 255, 0.1, 1] {
        updater.updateAlphaEpsilon(epsilon)
        updater.updateIsoValue(isoValue: 1)
        updater.updateTransferFunctions([])
        let empty = interpretation == .rgba && (alpha == 0 || Float(alpha) / 255 < epsilon)
        try check(updater.brickIsEmpty(brickMetadata: brick) == empty,
          "Color emptiness depends on TF/ISO or mishandles the epsilon boundary")
      }
      for blockSize in device.supportsFamily(.apple3) ? [0, 4, 8] : [0] {
      let memory = blockSize == 0 ? 32 * 32 * 32 * 4 : (32 / blockSize) * (32 / blockSize) * 32 * 16
      let atlas = try VolumeAtlas(device: device, maxMemory: memory,
        borgData: fixture, transferFunctions: [], isoValue: 1, astcBlockSize: blockSize)
      try check(atlas.astcBlockSize == blockSize, "Requested color atlas format was not selected")
      try atlas.pageIn(IDs: [0])
      func render(skipping: Bool, epsilon: Float, adaptive: Bool = false) throws -> SIMD4<Float> {
        let command = queue.makeCommandBuffer()!
        try atlas.prepareSubbrickSkipping(commandBuffer: command, transferFunctions: [],
          enabled: skipping, isoValue: 1, alphaEpsilon: epsilon)
        func target(_ format: MTLPixelFormat) -> MTLTexture {
          let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
          d.storageMode = .shared; d.usage = .renderTarget
          return device.makeTexture(descriptor: d)!
        }
        let color = target(.rgba32Float), depth = target(.r32Float)
        let markerDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
          width: 1, height: 1, mipmapped: false)
        markerDescriptor.storageMode = .private; markerDescriptor.usage = [.renderTarget, .shaderRead]
        let markerDepth = device.makeTexture(descriptor: markerDescriptor)!
        let clearPass = MTLRenderPassDescriptor()
        clearPass.depthAttachment.texture = markerDepth
        clearPass.depthAttachment.loadAction = .clear
        clearPass.depthAttachment.storeAction = .store
        clearPass.depthAttachment.clearDepth = 0
        command.makeRenderCommandEncoder(descriptor: clearPass)!.endEncoding()
        let pass = MTLRenderPassDescriptor()
        for (index, texture) in [color, depth].enumerated() {
          pass.colorAttachments[index].texture = texture
          pass.colorAttachments[index].loadAction = .clear; pass.colorAttachments[index].storeAction = .store
        }
        var u = FragmentUniformsArray()
        u.uniforms.0.cubeBounds.1 = SIMD3(repeating: 1)
        u.uniforms.0.cameraPosInTextureSpace = SIMD3(0.5, 0.5, -1)
        u.uniforms.0.cameraPosInTextureSpaceVoxelScaled = SIMD3(0.5, 0.5, -1)
        u.uniforms.0.oversampling = 2
        u.uniforms.0.opacityAdaptiveSampling = adaptive ? 1 : 0
        u.uniforms.0.textureToClip = matrix_identity_float4x4
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<FragmentUniformsArray>.stride, index: 0)
        atlas.bind(to: encoder, atlasIndex: 0, metaIndex: 2, levelIndex: 1)
        encoder.setFragmentTexture(markerDepth, index: TextureIndex.markerDepth.rawValue)
        let requests = device.makeBuffer(length: 64 * 4, options: .storageModeShared)!
        encoder.setFragmentBuffer(requests, offset: 0, index: 3)
        // Deliberately no TF textures: the color shader must not read or require them.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        var pixel = SIMD4<Float>.zero
        color.getBytes(&pixel, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return pixel
      }
      let reference = try render(skipping: false, epsilon: 0)
      try check(try render(skipping: true, epsilon: 0) == reference, "Color subbrick skipping changed pixels")
      if interpretation == .rgba && alpha == 0 {
        try check(reference == .zero, "Zero-alpha RGBA is not transparent")
      } else {
        try check(reference.w > 0 && abs(reference.x / reference.w - 32.0 / 255) < 0.002
          && abs(reference.y / reference.w - 96.0 / 255) < 0.002
          && abs(reference.z / reference.w - 224.0 / 255) < 0.002, "Color was mapped by a TF or incorrectly composited")
        if interpretation == .rgb { try check(reference.w == 1, "RGB is not opaque") }
        let adaptive = try render(skipping: true, epsilon: 0, adaptive: true)
        try check(abs(reference.w - adaptive.w) < 0.002, "Adaptive sampling changed RGBA opacity correction")
      }
      let threshold = try render(skipping: true, epsilon: 0.1)
      if interpretation == .rgba && alpha == 16 { try check(threshold == .zero, "RGBA subblocks ignore alpha epsilon") }
      else { try check(threshold == reference, "Epsilon modified visible color samples") }
      if blockSize != 0, interpretation == .rgba, alpha == 255 {
        try check(!fixture.gpuBrushAttached && atlas.atlasTexture.usage == .shaderRead,
          "Compressed atlas must not attach a GPU writer")
        func refresh() {
          let command = queue.makeCommandBuffer()!
          atlas.prepareFrame(commandBuffer: command)
          command.commit(); command.waitUntilCompleted()
        }
        fixture.history = [BorgVRVolumeBrushBatch(id: UUID(), revision: 1, mode: .erase,
          samples: [BorgVRVolumeBrushSample(center: SIMD3(repeating: 0.5), radius: 2)])]
        fixture.contentRevision = 1; fixture.alpha = 0; fixture.unavailable = true
        refresh()
        try check(try render(skipping: false, epsilon: 0) == reference,
          "ASTC must retain the old page until CPU edits finish")
        fixture.unavailable = false
        refresh()
        try check(try render(skipping: true, epsilon: 0) == .zero, "ASTC did not upload the CPU-erased brick")
        fixture.contentRevision = 2; fixture.alpha = 255
        refresh()
        try check(try render(skipping: true, epsilon: 0) == reference, "ASTC did not upload the CPU-restored brick")
      }
      }
    }
  }
  print("RGB/RGBA GPU rendering passed: direct color, opaque RGB, straight alpha, no TF bindings, epsilon, subblocks and opacity correction")
}

private final class StoredASTCFixture: BORGVRDatasetProtocol {
  let metadata: BORGVRMetaData
  let payload: [UInt8]
  init(side: Int, components: Int, block: Int) throws {
    metadata = BORGVRMetaData(width: side - 4, height: side - 4, depth: side - 4, componentCount: components,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1, brickSize: side, overlap: 2,
      minValue: 192, maxValue: 192, compression: false, datasetDescription: "Stored ASTC", metaDescription: "")
    try metadata.setChannelInterpretation((components == 3 ? BORGVRChannelInterpretation.rgb : .rgba).withASTC(blockSize: block))
    let pixel: [UInt8] = components == 3 ? [32, 96, 224] : [32, 96, 224, 192]
    let bytes = (0..<(side * side * side)).flatMap { _ in pixel }
    payload = bytes.withUnsafeBufferPointer { BorgVRASTCCodec.encode($0.baseAddress!, brickSize: side, components: components, blockSize: block) }
    metadata.append(offset: 8, size: payload.count, componentRanges: metadata.componentRanges)
  }
  func newRequest() {}
  func getMetadata() -> BORGVRMetaData { metadata }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { .allocate(capacity: metadata.brickSize * metadata.brickSize * metadata.brickSize * metadata.componentCount) }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws { throw BORGVRError.other("Stored ASTC atlas must not request decoded voxels.") }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: 0, outputBuffer: outputBuffer) }
  func getASTCBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>, synchronous: Bool) throws -> Bool {
    _ = payload.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, $0.count) }
    return true
  }
}

func runASTCEncodingTests(device: MTLDevice, queue: MTLCommandQueue) throws {
  guard device.supportsFamily(.apple3) else { print("ASTC GPU tests skipped: Apple GPU required"); return }
  struct Failure: Error { let message: String }
  func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
  let library = try device.makeLibrary(source: """
    #include <metal_stdlib>
    using namespace metal;
    kernel void decode(texture3d<float> image [[texture(0)]], device float4 *out [[buffer(0)]],
      uint3 p [[thread_position_in_grid]]) {
      constexpr sampler s(coord::normalized, filter::nearest);
      uint3 size(image.get_width(), image.get_height(), image.get_depth());
      out[(p.z * size.y + p.y) * size.x + p.x] = image.sample(s, (float3(p) + 0.5) / float3(size), level(0));
    }
    """, options: nil)
  let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "decode")!)
  let side = 16, count = side * side * side
  for blockSize in [4, 8] {
  let descriptor = MTLTextureDescriptor()
  descriptor.textureType = .type3D; descriptor.pixelFormat = blockSize == 8 ? .astc_8x8_ldr : .astc_4x4_ldr
  descriptor.width = side; descriptor.height = side; descriptor.depth = side
  descriptor.storageMode = .shared; descriptor.usage = .shaderRead
  let texture = device.makeTexture(descriptor: descriptor)!
  let decoded = device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
  for components in [3, 4] { for pattern in 0..<5 {
    var input = [UInt8](repeating: 0, count: count * components)
    for z in 0..<side { for y in 0..<side { for x in 0..<side {
      let i = ((z * side + y) * side + x) * components
      let v = pattern == 0 ? 96 : (x % blockSize) * 255 / (blockSize - 1)
      input[i] = UInt8(v); input[i + 1] = UInt8(pattern == 4 ? 0 : v / 2); input[i + 2] = UInt8(255 - v)
      if components == 4 { input[i + 3] = UInt8(pattern < 2 ? (z % 2) * 255 : (pattern == 2 ? y % blockSize : x % blockSize) * 255 / (blockSize - 1)) }
    } } }
    let packed = input.withUnsafeBufferPointer {
      BorgVRASTCCodec.encode($0.baseAddress!, brickSize: side, components: components, blockSize: blockSize)
    }
    let blocks = side / blockSize
    try check(packed.count == blocks * blocks * side * 16, "Incorrect ASTC byte count")
    packed.withUnsafeBytes { texture.replace(region: MTLRegionMake3D(0, 0, 0, side, side, side), mipmapLevel: 0,
      slice: 0, withBytes: $0.baseAddress!, bytesPerRow: blocks * 16, bytesPerImage: blocks * blocks * 16) }
    let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline); encoder.setTexture(texture, index: 0)
    encoder.setBuffer(decoded, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: side, height: side, depth: side),
      threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    let pixels = decoded.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
    var software = [UInt8](repeating: 0, count: count * components)
    try packed.withUnsafeBufferPointer { input in
      try software.withUnsafeMutableBufferPointer { output in
        try BorgVRASTCCodec.decode(input.baseAddress!, brickSize: side, components: components,
          blockSize: blockSize, output: output.baseAddress!)
      }
    }
    for i in 0..<count { for channel in 0..<4 {
      let expected = channel < components ? Float(input[i * components + channel]) / 255 : 1
      let cpu = channel < components ? Float(software[i * components + channel]) / 255 : 1
      try check(abs(pixels[i][channel] - cpu) <= 1.01 / 255, "ASTC software and Metal decoders disagree")
      try check(pixels[i][channel].isFinite && abs(pixels[i][channel] - expected) < 0.04,
        "ASTC \(blockSize)x\(blockSize) decode mismatch: pattern \(pattern), \(components) channels, voxel \(i), channel \(channel): \(pixels[i][channel]) vs \(expected)")
    } }
    if let directory = ProcessInfo.processInfo.environment["BORGVR_ASTC_FIXTURES"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      let json: [String: Any] = ["side": side, "components": components, "block": blockSize,
        "encoded": Data(packed).base64EncodedString(), "decoded": Data(software).base64EncodedString()]
      try JSONSerialization.data(withJSONObject: json).write(to: url.appendingPathComponent("\(blockSize)-\(components)-\(pattern).json"))
    }
  } }
  let capacity = 64
  let memory = capacity * (32 / blockSize) * (32 / blockSize) * 32 * 16
  let layout = VolumeAtlas.computeAtlasSize(maxMemory: memory, maxBrickCount: capacity,
    brickSize: 32, bytesPerComponent: 1, componentCount: 4, astcBlockSize: blockSize)
  try check(layout.inCoreBrickCount == capacity, "Incorrect compressed atlas capacity")
  for components in [3, 4] {
    let source = try StoredASTCFixture(side: side, components: components, block: blockSize)
    let atlas = try VolumeAtlas(device: device, maxMemory: source.payload.count, borgData: source,
      transferFunctions: [], isoValue: 0, astcBlockSize: 0)
    try check(atlas.astcBlockSize == blockSize, "Stored ASTC must override atlas settings")
    let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline); encoder.setTexture(atlas.atlasTexture, index: 0)
    encoder.setBuffer(decoded, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: side, height: side, depth: side), threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    let pixel = decoded.contents().assumingMemoryBound(to: SIMD4<Float>.self).pointee
    let expected = SIMD4<Float>(32, 96, 224, components == 3 ? 255 : 192) / 255
    try check(simd_length(pixel - expected) < 0.001, "Direct stored ASTC upload changed colors")
  }
  }
  print("ASTC sliced 3D Metal decoding passed: RGB/RGBA, constant blocks, color gradients, independent alpha, slice pitches and compressed capacity")
}
