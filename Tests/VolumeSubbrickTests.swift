import Foundation
import Metal
import simd

struct BorgVRTransferFunctionSnapshot {
  let channel: Int
  let samples: [SIMD4<UInt8>]
  let revision: UInt64
}
enum VolumeAtlasError: Error { case failedToCreateTexture }
private struct SubbrickFailure: Error { let message: String }

@main
enum VolumeSubbrickTests {
  static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SubbrickFailure(message: message) }
  }
  static func source(_ url: URL) throws -> String {
    var result = ""
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
      if (line.hasPrefix("#include") || line.hasPrefix("#import")),
         let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
        result += try source(url.deletingLastPathComponent().appendingPathComponent(
          String(line[line.index(after: first)..<last])).standardizedFileURL)
      } else { result += line + "\n" }
    }
    return result
  }
  static func main() throws {
    try require(MemoryLayout<FragmentUniforms>.offset(of: \.opacityAdaptiveSampling) == 12 &&
      MemoryLayout<FragmentUniforms>.offset(of: \.transferBias) == 16,
      "Adaptive flag must use the existing uniform padding")
    for (size, expected) in [(8,1), (16,1), (31,2), (32,2), (64,4), (128,8)] {
      try require(VolumeAtlasSubbrickCache.divisions(brickSize: size, overlap: 2) == expected,
        "Wrong fixed subdivision for brick size \(size)")
    }
    try require(VolumeAtlasSubbrickCache.divisions(brickSize: 64, overlap: 0) == 1,
      "Atlas pages without a filtering halo must not use subbrick skipping")
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw SubbrickFailure(message: "Metal is required")
    }
    for (bytes, channels) in [(1,1), (1,2), (1,3), (1,4), (2,1), (2,2), (2,3), (2,4), (4,1)] {
      for brickSize in [16, 17] { for divisions in [2, 4, 8] {
        let overlap = 2, inner = brickSize - 4
        let m = BORGVRMetaData(width: inner, height: inner, depth: inner, componentCount: channels,
          bytePerComponent: bytes, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
          brickSize: brickSize, overlap: overlap, minValue: 0, maxValue: 255,
          compression: false, datasetDescription: "Subbrick test", metaDescription: "")
        let primaryComponents = bytes == 4 ? 4 : (bytes == 2 ? min(channels, 2) * 2 : (channels == 3 ? 4 : channels))
        func texture(_ components: Int) -> MTLTexture {
          let d = MTLTextureDescriptor()
          d.textureType = .type3D
          d.width = brickSize * 3; d.height = brickSize; d.depth = brickSize
          d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
          d.pixelFormat = components == 1 ? .r8Unorm : (components == 2 ? .rg8Unorm : .rgba8Unorm)
          return device.makeTexture(descriptor: d)!
        }
        let primary = texture(primaryComponents)
        let secondary = bytes == 2 && channels > 2 ? texture((channels - 2) * 2) : primary
        var primaryBytes = [UInt8](repeating: 0, count: brickSize * brickSize * brickSize * 3 * primaryComponents)
        var secondaryBytes = [UInt8](repeating: 0, count: brickSize * brickSize * brickSize * 3 * max(1, (channels - 2) * 2))
        for z in 0..<brickSize { for y in 0..<brickSize { for x in 0..<(brickSize * 3) {
          let page = x / brickSize, localX = x % brickSize
          let voxel = x + brickSize * 3 * (y + brickSize * z)
          for c in 0..<channels {
            let high = c % 2 != 0
            let lower = high ? overlap + inner / 2 + 2 : overlap + 1
            let upper = lower + 1
            let common = (overlap + inner / 2 + 2)...(overlap + inner / 2 + 3)
            let feature = page == 0 && (((lower...upper).contains(localX) &&
              (lower...upper).contains(y) && (lower...upper).contains(z)) ||
              (common.contains(localX) && common.contains(y) && common.contains(z)))
            let value: UInt8 = page == 2 || feature ? 255 : 0
            for b in 0..<bytes {
              if bytes == 2 && c >= 2 {
                secondaryBytes[voxel * (channels - 2) * 2 + (c - 2) * 2 + b] = value
              } else { primaryBytes[voxel * primaryComponents + c * bytes + b] = value }
            }
          }
        } } }
        func upload(_ values: [UInt8], to texture: MTLTexture, components: Int) {
          values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake3D(0, 0, 0, brickSize * 3, brickSize, brickSize),
              mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
              bytesPerRow: brickSize * 3 * components, bytesPerImage: brickSize * brickSize * 3 * components)
          }
        }
        upload(primaryBytes, to: primary, components: primaryComponents)
        if secondary !== primary { upload(secondaryBytes, to: secondary, components: (channels - 2) * 2) }
        let tfs = try (0..<channels).map { c -> TransferFunction1D in
          let tf = TransferFunction1D(count: 256)
          tf.initMetal(device: device)
          let data = (0..<256).map { i in SIMD4<UInt8>(c == 0 ? 200 : 255, 120, 60, i >= 128 ? 16 : 0) }
          try tf.updateData(with: data)
          tf.updateRanges(minValue: 0, maxValue: 255, rangeMax: 255)
          return tf
        }
        let cache = try VolumeAtlasSubbrickCache(device: device, metadata: m, capacity: 3, divisions: divisions)
        let cellCount = divisions * divisions * divisions
        func expectedMasks(iso: Float? = nil) -> [UInt32] {
          var result = [UInt32](repeating: 0, count: 3 * cache.maskStride)
          for page in 0..<3 {
            var visibleCount = 0
            for cell in 0..<cellCount {
              let side = [cell % divisions, (cell / divisions) % divisions, cell / (divisions * divisions)]
              let low = side.map { overlap + $0 * inner / divisions - 1 }
              let high = side.map { overlap + ($0 + 1) * inner / divisions }
              var maxima = [UInt8](repeating: 0, count: channels)
              voxelLoop: for z in low[2]...high[2] { for y in low[1]...high[1] { for x in low[0]...high[0] {
                let voxel = page * brickSize + x + brickSize * 3 * (y + brickSize * z)
                for c in 0..<channels {
                  let value = bytes == 2 && c >= 2 ? secondaryBytes[voxel * (channels - 2) * 2 + (c - 2) * 2]
                    : primaryBytes[voxel * primaryComponents + c * bytes]
                  maxima[c] = max(maxima[c], value)
                }
                if iso.map({ threshold in maxima.allSatisfy { Float($0) / 255 >= threshold } })
                  ?? maxima.contains(where: { $0 > 127 }) { break voxelLoop }
              } } }
              let visible = iso.map { threshold in maxima.allSatisfy { Float($0) / 255 >= threshold } }
                ?? maxima.contains(where: { $0 > 127 })
              if visible {
                visibleCount += 1
                result[page * cache.maskStride + 1 + cell / 32] |= 1 << (cell & 31)
              }
            }
            result[page * cache.maskStride] = visibleCount == cellCount ? 2 : (visibleCount == 0 ? 0 : 1)
          }
          return result
        }
        func classify(abandon: Bool = false, iso: Float? = nil) throws -> [UInt32] {
          let command = queue.makeCommandBuffer()!
          try require(cache.prepare(command: command, primary: primary, secondary: secondary,
            pages: [0,1,2], transferFunctions: tfs, isoValue: iso), "Cannot prepare occupancy")
          if abandon { return [] }
          let count = 3 * cache.maskStride
          let readback = device.makeBuffer(length: count * 4, options: .storageModeShared)!
          let blit = command.makeBlitCommandEncoder()!
          blit.copy(from: cache.masks, sourceOffset: 0, to: readback, destinationOffset: 0, size: count * 4)
          blit.endEncoding(); command.commit(); command.waitUntilCompleted()
          if let error = command.error { throw error }
          return Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: UInt32.self), count: count))
        }
        _ = try classify(abandon: true)
        let originalMasks = expectedMasks()
        try require(try classify() == originalMasks, "Incorrect masks for \(channels)x\(bytes), brick \(brickSize), \(divisions)^3 cells")
        try require(try classify() == originalMasks, "Cached masks changed")
        if bytes == 2 && channels == 2 {
          try compareRays(device: device, queue: queue, primary: primary, secondary: secondary,
            cache: cache, brickSize: brickSize, transferFunctions: tfs)
        }
        let originalBytes = primaryBytes
        let middle = overlap + inner / 2
        let center = middle + brickSize * 3 * (middle + brickSize * middle)
        for b in 0..<bytes { primaryBytes[center * primaryComponents + b] = 255 }
        upload(primaryBytes, to: primary, components: primaryComponents)
        cache.invalidate(page: 0)
        try require(try classify() == expectedMasks(),
          "Interpolation halo did not retain a feature on the shared cell corner")
        primaryBytes = originalBytes
        upload(primaryBytes, to: primary, components: primaryComponents)
        cache.invalidate(page: 0)
        try require(try classify() == originalMasks, "Halo removal retained stale ranges")
        for iso: Float in [0, 0.5, 1, 1.01] {
          try require(try classify(iso: iso) == expectedMasks(iso: iso),
            "ISO min-over-channels mask is incorrect at \(iso)")
        }
        try require(try classify() == originalMasks, "Returning from ISO did not restore TF masks")
        for tf in tfs { tf.updateEmptinessThreshold(alphaEpsilon: 0.1) }
        let emptyMasks = [UInt32](repeating: 0, count: 3 * cache.maskStride)
        try require(try classify() == emptyMasks, "TF threshold did not reclassify cached ranges")
        try require(try classify(iso: 0.5) == expectedMasks(iso: 0.5), "Alpha epsilon affected ISO masks")
        for tf in tfs { tf.updateEmptinessThreshold(alphaEpsilon: 0) }
        try require(try classify() == originalMasks, "Reset did not restore masks")
        primaryBytes = [UInt8](repeating: 0, count: primaryBytes.count)
        secondaryBytes = [UInt8](repeating: 0, count: secondaryBytes.count)
        upload(primaryBytes, to: primary, components: primaryComponents)
        if secondary !== primary { upload(secondaryBytes, to: secondary, components: (channels - 2) * 2) }
        cache.invalidate(page: 0); cache.invalidate(page: 2)
        try require(try classify() == emptyMasks, "Reused/edited page retained an old mask")
        print("Subbrick masks passed: \(channels)x\(bytes)-byte, brick \(brickSize), \(divisions)^3, sparse/empty/full, TF changes, abandoned frame, invalidation")
      } }
    }
  }

  static func compareRays(device: MTLDevice, queue: MTLCommandQueue, primary: MTLTexture,
                          secondary: MTLTexture, cache: VolumeAtlasSubbrickCache, brickSize: Int,
                          transferFunctions: [TransferFunction1D]) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let shader = try source(root.appendingPathComponent("AppSupport/Rendering/Shaders/VolumeRaycaster.metal")) + """
      kernel void checkOpacitySampling(device float4 *results [[buffer(0)]],
                                       uint index [[thread_position_in_grid]]) {
        int channels = 1 + index % 4, total = 257 + index % 7;
        int cellSize = 2 + (index >> 2) % 7;
        float opacity = float((index >> 3) % 4) * 0.3;
        float baseScale = (index & 1) ? 0.5 : 1.5;
        int i = 0, reads = 0, flags = 0;
        if (opacitySamplingSpan(0.49999, 7) != 1 || opacitySamplingSpan(0.5, 7) != 2 ||
            opacitySamplingSpan(0.84999, 7) != 2 || opacitySamplingSpan(0.85, 7) != 4 ||
            opacitySamplingSpan(0.9, 3) != 3 || opacitySamplingSpan(0.9, 1) != 1) flags |= 1;
        while (i < total && reads < total) {
          int end = min((i / cellSize + 1) * cellSize, total);
          int span = opacitySamplingSpan(opacity, end - i);
          float sample = float(i) + 0.37 * float(span);
          if (span < 1 || span > 4 || i + span > end || sample < i || sample >= end) flags |= 2;
          for (int c = 0; c < channels; ++c) {
            float alpha = 1.0 - pow(1.0 - 0.0025 * float(c + 1), baseScale * float(span));
            opacity += (1.0 - opacity) * alpha;
          }
          i += span;
          ++reads;
        }
        results[index] = float4(opacity, float(reads), float(i), float(flags));
      }
      vertex VertexToFragment subbrickTestVertex(uint index [[vertex_id]]) {
        float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        VertexToFragment out;
        out.position = float4(positions[index], 0, 1);
        out.exitPoint = float3((positions[index] + 1) * 0.5, 1);
        return out;
      }
      kernel void compareSubbrickRays(texture3d<float> atlas [[texture(0)]],
        texture1d<half> tf [[texture(1)]], device FragmentUniformsArray *arrays [[buffer(0)]],
        device LevelData *levels [[buffer(1)]], device uint *metadata [[buffer(2)]],
        device atomic_uint *requests [[buffer(3)]], device const uint *masks [[buffer(4)]],
        device float4 *results [[buffer(5)]], uint index [[thread_position_in_grid]]) {
        FragmentUniforms u = {};
        u.cubeBounds[0] = (index & 128) ? float3(0.1, 0.2, 0.15) : float3(0);
        u.cubeBounds[1] = (index & 128) ? float3(0.9, 0.85, 0.95) : float3(1);
        u.cameraPosInTextureSpace = float3(fract(float(index) * 0.37), fract(float(index) * 0.61),
                                         (index & 1) ? -1.0 : 2.0);
        u.cameraPosInTextureSpaceVoxelScaled = u.cameraPosInTextureSpace;
        u.transferBias = float4(1);
        u.sampleJitter = float((index >> 2) & 1);
        u.oversampling = 0.4 + float((index >> 3) % 4) * 0.5;
        u.textureToClip = float4x4(1);
        arrays[index].uniforms[0] = u;
        LevelData level = {};
        level.bricksX = 1; level.bricksXTimesBricksY = 1; level.fractionalBrickLayout = float3(1);
        levels[index * 2] = level;
        level.prevBricks = 1;
        levels[index * 2 + 1] = level;
        metadata[index * 2] = (index & 16) ? BI_MISSING : BI_FLAG_COUNT;
        metadata[index * 2 + 1] = BI_FLAG_COUNT + ((index & 32) ? 1 : 2);
        VertexToFragment in;
        in.position = float4(0.5, 0.5, 0, 1);
        in.exitPoint = mix(u.cubeBounds[0], u.cubeBounds[1],
          float3(fract(float(index) * 0.13), fract(float(index) * 0.29), float(index & 1)));
        auto reference = raycastTransferFunction<true>(in, 0, (index & 64) ? 0.45 : 0, u.oversampling,
          atlas, atlas, tf, tf, tf, tf, arrays[index], levels + index * 2,
          metadata + index * 2, requests + index * 64, masks, 0);
        auto actual = raycastTransferFunction<true>(in, 0, (index & 64) ? 0.45 : 0, u.oversampling,
          atlas, atlas, tf, tf, tf, tf, arrays[index], levels + index * 2,
          metadata + index * 2, requests + index * 64, masks, 1);
        results[index * 2] = abs(float4(reference.color) - float4(actual.color));
        results[index * 2 + 1] = float4(abs(reference.interactionDepth - actual.interactionDepth), 0, 0, 0);
        PoolBrickInformation span;
        span.poolEntryCoords = OVERLAP_STEP;
        span.poolExitCoords = OVERLAP_STEP + float3(BRICK_INNER_SIZE, 0, 0) / POOL_SIZE;
        auto traversal = prepareSubbrickTraversal(span, 0, 65, 0.37);
        int visited = 0, i = 0;
        for (uint segment = 0; segment < 3 * VOLUME_SUBBRICK_DIVISIONS && i < 65; ++segment) {
          uint cell;
          int end = subbrickSampleEnd(traversal, i, 65, cell);
          if (cell == 0) visited += end - i;
          i = end;
        }
        results[index * 2 + 1].y = float(i != 65);
        results[index * 2 + 1].w = float(visited);
        float overlap = float((BRICK_SIZE - BRICK_INNER_SIZE) / 2);
        float3 localStart = float3(overlap), delta = float3(BRICK_INNER_SIZE, 0, 0);
        if (index & 1) { localStart += delta; delta = -delta; }
        float t = 0;
        uint cells = 0;
        for (; cells < 3 * VOLUME_SUBBRICK_DIVISIONS && t < 1; ++cells) {
          uint cell;
          float end = subbrickRayEnd(localStart, delta, t, cell);
          uint expectedCell = (index & 1) ? VOLUME_SUBBRICK_DIVISIONS - 1 - cells : cells;
          if (end <= t || cell != expectedCell) results[index * 2 + 1].z = 1;
          t = end;
        }
        if (cells != VOLUME_SUBBRICK_DIVISIONS || t != 1) results[index * 2 + 1].z = 1;
      }
      """
    let options = MTLCompileOptions()
    options.mathMode = .fast
    options.preprocessorMacros = ["OVERRIDE_DUMMY":"1", "VOLUME_SUBBRICK_SKIPPING":"1",
      "VOLUME_OPACITY_ADAPTIVE_SAMPLING":"1",
      "VOLUME_SUBBRICK_DIVISIONS":"\(cache.divisions)",
      "LEVEL_COUNT":"2", "BRICK_SIZE":"\(brickSize)", "BRICK_INNER_SIZE":"\(brickSize - 4)",
      "OVERLAP_STEP":"float3(\(2.0 / Float(brickSize * 3)),\(2.0 / Float(brickSize)),\(2.0 / Float(brickSize)))",
      "POOL_SIZE":"float3(\(brickSize * 3),\(brickSize),\(brickSize))", "POOL_CAPACITY":"uint3(3,1,1)",
      "VOLUME_SIZE":"float3(\(brickSize - 4))", "VOLUME_SCALE":"float3(1)",
      "LEVEL_ZERO_WORLD_SPACE_ERROR":"1", "LOD_FACTOR":"1", "HASHTABLE_SIZE":"64",
      "MAX_PROBING_ATTEMPTS":"64", "MAX_ITERATIONS":"8", "REQUEST_LOWRES_LOD":"1", "STOP_ON_MISS":"0",
      "VOLUME_COMPONENT_COUNT":"2", "VOLUME_BYTES_PER_COMPONENT":"2"].mapValues { $0 as NSString }
    let library = try device.makeLibrary(source: shader, options: options)
    options.preprocessorMacros?["VOLUME_OPACITY_ADAPTIVE_SAMPLING"] = NSNumber(value: 0)
    let baselineLibrary = try device.makeLibrary(source: shader, options: options)
    try verifyOpacitySampling(device: device, queue: queue, library: library)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "compareSubbrickRays")!)
    let count = 1024
    let buffers = [count * 1024, count * 2 * 32, count * 2 * 4, count * 64 * 4].map {
      device.makeBuffer(length: $0, options: .storageModeShared)!
    }
    let result = device.makeBuffer(length: count * 2 * 16, options: .storageModeShared)!
    let d = MTLTextureDescriptor()
    d.textureType = .type1D; d.pixelFormat = .rgba8Unorm; d.width = 256
    d.storageMode = .shared; d.usage = .shaderRead
    let tf = device.makeTexture(descriptor: d)!
    let values = (0..<256).map { SIMD4<UInt8>(200,120,60,$0 >= 128 ? 16 : 0) }
    values.withUnsafeBytes { tf.replace(region: MTLRegionMake1D(0,256), mipmapLevel: 0,
      withBytes: $0.baseAddress!, bytesPerRow: 0) }
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(primary, index: 0); encoder.setTexture(tf, index: 1)
    for (i,b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
    encoder.setBuffer(cache.masks, offset: 0, index: 4)
    encoder.setBuffer(result, offset: 0, index: 5)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    let data = result.contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 2)
    for i in 0..<(count * 2) {
      let visited = Float(ceil(Double((brickSize - 4) / cache.divisions) / Double(brickSize - 4) * 65 - 0.37))
      let expected = i % 2 == 0 ? SIMD4<Float>.zero : SIMD4(0,0,0,visited)
      try require(data[i] == expected, "Subbrick skipping changed color/picking or sample spans for ray \(i / 2): \(data[i])")
    }
    try verifyVisualization(device: device, queue: queue, library: library, baselineLibrary: baselineLibrary, cache: cache,
      primary: primary, secondary: secondary, transferFunctions: transferFunctions)
    print("Subbrick on/off: identical TF/lighting/ISO frames and color/picking for \(count) rays, brick \(brickSize), \(cache.divisions)^3; clipping, jitter, fallback, sample spans and diagnostic grid verified")
  }

  static func verifyVisualization(device: MTLDevice, queue: MTLCommandQueue,
                                  library: MTLLibrary, baselineLibrary: MTLLibrary, cache: VolumeAtlasSubbrickCache,
                                  primary: MTLTexture, secondary: MTLTexture,
                                  transferFunctions: [TransferFunction1D]) throws {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "subbrickTestVertex")
    d.fragmentFunction = library.makeFunction(name: "volumeFragmentShaderBrickVis")
    d.colorAttachments[0].pixelFormat = .rgba32Float
    d.colorAttachments[1].pixelFormat = .r32Float
    let pipeline = try device.makeRenderPipelineState(descriptor: d)
    let diagnosticPipeline = pipeline
    func target(_ format: MTLPixelFormat) -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 64, height: 64,
                                                              mipmapped: false)
      descriptor.storageMode = .shared; descriptor.usage = .renderTarget
      return device.makeTexture(descriptor: descriptor)!
    }
    let color = target(.rgba32Float), depth = target(.r32Float)
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = color
    pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[1].texture = depth
    pass.colorAttachments[1].loadAction = .clear; pass.colorAttachments[1].storeAction = .store
    var uniforms = FragmentUniformsArray()
    uniforms.uniforms.0.cubeBounds.1 = SIMD3(repeating: 1)
    uniforms.uniforms.0.cameraPosInTextureSpace = SIMD3(0.5,0.5,-1)
    uniforms.uniforms.0.cameraPosInTextureSpaceVoxelScaled = SIMD3(0.5,0.5,-1)
    uniforms.uniforms.0.transferBias = SIMD4(repeating: 1)
    uniforms.uniforms.0.oversampling = 1.5
    uniforms.uniforms.0.sampleJitter = 1
    uniforms.uniforms.0.modelView = matrix_identity_float4x4
    uniforms.uniforms.0.modelViewIT = matrix_identity_float4x4
    uniforms.uniforms.0.textureToClip = matrix_identity_float4x4
    uniforms.uniforms.0.lightDirection = SIMD4(0,0,-1,0)
    uniforms.uniforms.0.ambientLightColor = SIMD4(repeating: 0.15)
    uniforms.uniforms.0.diffuseLightColor = SIMD4(repeating: 0.8)
    uniforms.uniforms.0.specularLightColor = SIMD4(repeating: 1)
    var levels = [LevelData(bricksX: 1, bricksXTimesBricksY: 1, prevBricks: 0,
                           fractionalBrickLayout: SIMD3(repeating: 1)),
                  LevelData(bricksX: 1, bricksXTimesBricksY: 1, prevBricks: 1,
                            fractionalBrickLayout: SIMD3(repeating: 1))]
    let requests = device.makeBuffer(length: 64 * 4, options: .storageModeShared)!
    func render(_ pipeline: MTLRenderPipelineState, flag: UInt32 = 3, enabled: Bool = true,
                iso: Float? = nil, adaptive: Bool = false,
                states: [UInt32]? = nil) throws -> (color: [SIMD4<Float>], depth: [Float]) {
      requests.contents().bindMemory(to: UInt32.self, capacity: 64).update(repeating: .max, count: 64)
      let command = queue.makeCommandBuffer()!
      try require(cache.prepare(command: command, primary: primary, secondary: secondary,
        pages: [0,1,2], transferFunctions: transferFunctions, isoValue: iso), "Cannot prepare render mask")
      uniforms.uniforms.0.isoValue = iso ?? 0.5
      uniforms.uniforms.0.opacityAdaptiveSampling = adaptive ? 1 : 0
      let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
      encoder.setRenderPipelineState(pipeline)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FragmentUniformsArray>.stride, index: 0)
      levels.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
      (states ?? [flag,flag]).withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
      encoder.setFragmentBuffer(requests, offset: 0, index: 3)
      encoder.setFragmentBuffer(cache.masks, offset: 0, index: 5)
      var flagEnabled: UInt32 = enabled ? 1 : 0
      encoder.setFragmentBytes(&flagEnabled, length: 4, index: 6)
      encoder.setFragmentTexture(primary, index: 0)
      encoder.setFragmentTexture(secondary, index: 6)
      for (c, index) in [1,7,8,9].enumerated() {
        try transferFunctions[min(c, transferFunctions.count - 1)].bind(to: encoder, index: index)
      }
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
      if let error = command.error { throw error }
      if pipeline === diagnosticPipeline {
        let values = requests.contents().bindMemory(to: UInt32.self, capacity: 64)
        try require((0..<64).allSatisfy { values[$0] == .max }, "Diagnostic rendering requested data")
      }
      var pixels = [SIMD4<Float>](repeating: .zero, count: 64 * 64)
      pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: 64 * 16,
        from: MTLRegionMake2D(0,0,64,64), mipmapLevel: 0) }
      var picking = [Float](repeating: 0, count: 64 * 64)
      picking.withUnsafeMutableBytes { depth.getBytes($0.baseAddress!, bytesPerRow: 64 * 4,
        from: MTLRegionMake2D(0,0,64,64), mipmapLevel: 0) }
      return (pixels, picking)
    }
    let results = try [UInt32(3), 1, 0].map { try render(pipeline, flag: $0).color }
    try require(results[0].contains { $0.x > 0 } && results[0].contains { $0.y > 0 },
      "Resident subbrick visualization has no red/green regions")
    for i in results[1].indices {
      let empty = results[1][i], missing = results[2][i]
      try require(empty.x == 0 && empty.y > 0 && empty.z == 0,
        "Empty cells are not green in the fragment output")
      try require(missing.x == 0 && missing.y == 0 && missing.z == empty.y,
        "Missing cells do not use the same grid/weight as empty cells")
    }
    let full = try render(pipeline, flag: 5).color
    let emptyMask = try render(pipeline, flag: 4).color
    try require(full.indices.allSatisfy { i in
      full[i].x == results[1][i].y && full[i].y == 0 && full[i].z == 0 && emptyMask[i] == results[1][i]
    }, "Fully visible/empty masks must render one whole-brick contribution")
    try require(results[0].contains { $0.w > results[1][0].w },
      "Partial masks must display individual traversed subblocks")
    let fallback = try render(pipeline, states: [0,3]).color
    try require(fallback.contains { $0.z > 0 } && fallback.contains { $0.y > 0 } &&
      fallback.allSatisfy { $0.x == 0 }, "Resident fallback must show blue/green subblocks without requests")
    let originalLevels = levels
    levels[0].fractionalBrickLayout = SIMD3(1,1,2)
    levels[1].prevBricks = 2
    let merged = try render(pipeline, states: [1,1,1]).color
    let separate = try render(pipeline, states: [1,1,2]).color
    try require(merged.indices.allSatisfy { i in
      merged[i].x == 0 && merged[i].z == 0 && merged[i].y > 0 && separate[i].y == 2 * merged[i].y
    }, "Hierarchical leaps must contribute once instead of displaying their fine children")
    levels = originalLevels
    for name in ["volumeFragmentShaderTF", "volumeFragmentShaderTFLighting", "volumeFragmentShaderIso"] {
      d.fragmentFunction = library.makeFunction(name: name)
      let state = try device.makeRenderPipelineState(descriptor: d)
      let iso: Float? = name == "volumeFragmentShaderIso" ? 0.5 : nil
      let reference = try render(state, enabled: false, iso: iso)
      let actual = try render(state, enabled: true, iso: iso)
      try require(reference.color.contains { $0.w > 0 }, "\(name) test has no visible content")
      try require(reference.color == actual.color && reference.depth == actual.depth,
        "\(name) changed color or picking with subbrick skipping")
      d.fragmentFunction = baselineLibrary.makeFunction(name: name)
      let baseline = try render(device.makeRenderPipelineState(descriptor: d), iso: iso)
      try require(baseline.color == actual.color && baseline.depth == actual.depth,
        "Disabled opacity-adaptive mode changed \(name) compared with the original shader specialization")
      let adaptive = try render(state, iso: iso, adaptive: true)
      try require(adaptive.color.allSatisfy { pixel in
        [pixel.x, pixel.y, pixel.z, pixel.w].allSatisfy(\.isFinite) && pixel.w >= 0 && pixel.w <= 1
      } && adaptive.depth.allSatisfy(\.isFinite), "Adaptive \(name) produced invalid pixels")
      if iso != nil {
        try require(adaptive.color == actual.color && adaptive.depth == actual.depth,
          "The opacity-adaptive flag affected ISO rendering")
      }
    }
  }

  static func verifyOpacitySampling(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws {
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "checkOpacitySampling")!)
    let result = device.makeBuffer(length: 64 * 16, options: .storageModeShared)!
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(result, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 64, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    let data = result.contents().bindMemory(to: SIMD4<Float>.self, capacity: 64)
    var reduced = false
    for index in 0..<64 {
      let total = 257 + index % 7
      let scale: Double = index & 1 != 0 ? 0.5 : 1.5
      let initial = Double((index >> 3) % 4) * 0.3
      let transmission = (0..<(1 + index % 4)).reduce(1.0) { $0 * pow(1 - 0.0025 * Double($1 + 1), scale) }
      let expected = 1 - (1 - initial) * pow(transmission, Double(total))
      try require(abs(Double(data[index].x) - expected) < 2e-5 && data[index].z == Float(total) && data[index].w == 0,
        "Opacity correction/threshold/cell clipping failed: \(index), \(data[index]), expected \(expected)")
      reduced = reduced || data[index].y < Float(total)
    }
    try require(reduced, "Adaptive stepping did not reduce sample count")
    print("Opacity-adaptive sampling passed: thresholds, clipped spans, sample reduction and distance-correct alpha for 1-4 channels")
  }
}
