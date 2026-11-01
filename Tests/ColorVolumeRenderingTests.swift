import Foundation
import Metal
import simd

private final class ColorVolumeFixture: BORGVRDatasetProtocol {
  let metadata: BORGVRMetaData
  let alpha: UInt8
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
      let atlas = try VolumeAtlas(device: device, maxMemory: 32 * 32 * 32 * 4,
        borgData: fixture, transferFunctions: [], isoValue: 1)
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
    }
  }
  print("RGB/RGBA GPU rendering passed: direct color, opaque RGB, straight alpha, no TF bindings, epsilon, subblocks and opacity correction")
}
