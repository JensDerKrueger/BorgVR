import Foundation
import Metal
import simd

private struct DepthTestFailure: Error { let message: String }

private struct MarkerDepthCase {
  var textureToClip: simd_float4x4
  var entry: SIMD4<Float>
  var exit: SIMD4<Float>
  // Opaque depth, brick entry/exit parameters, sample phase within the brick.
  var parameters: SIMD4<Float>
}

@main
private enum VisionReprojectionDepthTests {
  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw DepthTestFailure(message: message) }
  }

  private static func source(_ url: URL) throws -> String {
    var result = ""
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if (trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import")),
         let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
        let name = String(line[line.index(after: first)..<last])
        result += try source(url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL)
      } else {
        result += line + "\n"
      }
    }
    return result
  }

  private static let depthComparisonShader = """
    struct MarkerDepthCase {
      float4x4 textureToClip;
      float4 entry;
      float4 exit;
      float4 parameters;
    };
    kernel void testMarkerDepth(
      device const MarkerDepthCase *cases [[buffer(0)]],
      device float4 *results [[buffer(1)]],
      uint index [[thread_position_in_grid]]) {
      MarkerDepthCase c = cases[index];
      FragmentUniforms uniforms = {};
      uniforms.textureToClip = c.textureToClip;
      float3 start = mix(c.entry.xyz, c.exit.xyz, c.parameters.y);
      float3 end = mix(c.entry.xyz, c.exit.xyz, c.parameters.z);
      float3 position = mix(start, end, c.parameters.w);
      float rayLength = length(c.exit.xyz - c.entry.xyz);
      float startT = length(start - c.entry.xyz) / rayLength;
      float endT = length(end - c.entry.xyz) / rayLength;
      float4 clip = uniforms.textureToClip * float4(position, 1.0);
      float referenceDepth = clip.z / clip.w;
      bool reference = false;
    #if VOLUME_SHADER_USES_MARKER_TEXTURES
      reference = c.parameters.x > 0 && referenceDepth <= c.parameters.x + 0.00001;
    #endif
      float4 depthTest = prepareMarkerDepthTest(
        uniforms, c.entry.xyz, c.exit.xyz, c.parameters.x
      );
      bool actual = sampleReachedMarker(depthTest, mix(startT, endT, c.parameters.w));
      results[index] = float4(float(reference), float(actual), referenceDepth, c.parameters.x);
    }
    """

  private static func testMarkerDepth(
    device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary
  ) throws {
    var cases: [MarkerDepthCase] = []
    func add(_ matrix: simd_float4x4, _ entry: SIMD3<Float>, _ exit: SIMD3<Float>,
             _ parameters: SIMD4<Float>) {
      cases.append(MarkerDepthCase(textureToClip: matrix,
        entry: SIMD4(entry, 1), exit: SIMD4(exit, 1), parameters: parameters))
    }
    let reverseZ = simd_float4x4(columns: (
      SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
      SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0.1, 0)
    ))
    for matrix in [matrix_identity_float4x4, reverseZ] {
      for (entry, exit) in [
        (SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)),
        (SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, -1)),
        (SIMD3<Float>(0, 0, -1), SIMD3<Float>(0, 0, -2)),
        (SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 2))
      ] {
        for depth: Float in [-1, 0, 0.1, 0.5, 1] {
          for sample: Float in [0, 0.01, 0.25, 0.4999, 0.5, 0.5001, 0.75, 0.99, 1] {
            add(matrix, entry, exit, SIMD4(depth, 0, 1, sample))
          }
        }
      }
    }
    // Zero clip w: +/-infinity and 0/0 must keep their original comparison result.
    for z: Float in [-0.1, 0, 0.1] {
      var matrix = matrix_identity_float4x4
      matrix.columns.2 = .zero
      matrix.columns.3 = SIMD4(0, 0, z, 0)
      add(matrix, SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD4(0.5, 0, 1, 0.5))
    }
    var seed: UInt64 = 42
    func random() -> Float {
      seed = seed &* 6364136223846793005 &+ 1
      return Float(seed >> 40) / Float(1 << 24)
    }
    for _ in 0..<32768 {
      let entry = SIMD3(random(), random(), random())
      let exit = SIMD3(random(), random(), random())
      let start = random(), end = start + (1 - start) * random()
      // Include eye offsets, skewed/rotated projections and large/small scales,
      // with positive or negative clip w throughout the ray.
      let scale = pow(Float(10), random() * 6 - 3)
      let sign: Float = random() < 0.5 ? -1 : 1
      let matrix = simd_float4x4(columns: (
        SIMD4(1, 0, (random() - 0.5) * scale, random() * 0.1 * sign),
        SIMD4(0, 1, (random() - 0.5) * scale, random() * 0.1 * sign),
        SIMD4(0, 0, (random() - 0.5) * scale, random() * 0.1 * sign),
        SIMD4(random() - 0.5, 0, random() * scale, sign)
      ))
      add(matrix, entry, exit, SIMD4(random(), start, end, random()))
    }
    let input = device.makeBuffer(bytes: cases,
      length: cases.count * MemoryLayout<MarkerDepthCase>.stride, options: .storageModeShared)!
    let output = device.makeBuffer(length: cases.count * MemoryLayout<SIMD4<Float>>.stride,
                                  options: .storageModeShared)!
    let function = library.makeFunction(name: "testMarkerDepth")!
    let pipeline = try device.makeComputePipelineState(function: function)
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setBuffer(output, offset: 0, index: 1)
    encoder.dispatchThreads(MTLSize(width: cases.count, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    let results = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: cases.count)
    var boundaryRoundoff = 0
    for index in cases.indices {
      let result = results[index]
      guard result.x != result.y else { continue }
      // Reordering affine arithmetic may move the cutoff by a few Float ulps.
      try require(result.z.isFinite && abs(result.z - (result.w + 1e-5)) < 2e-6,
        "Opaque depth comparison differs in case \(index): \(result), \(cases[index])")
      boundaryRoundoff += 1
    }
    print("Opaque ray-depth comparison passed (\(cases.count) GPU cases; \(boundaryRoundoff) within cutoff roundoff)")
  }

  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw DepthTestFailure(message: "Metal device is required for reprojection depth tests")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let options = MTLCompileOptions()
    options.preprocessorMacros = ["VOLUME_SHADER_USES_RATE_MAP": NSNumber(value: 0)]
    if #available(macOS 15.0, *) { options.mathMode = .fast }
    let shaderSource = try source(root.appendingPathComponent("VisionApp/Shaders.metal")) + """
      fragment VolumeFragmentOutput testVolumeDepth(
        ushort ampId [[amplification_id]],
        constant float4 *values [[buffer(0)]]) {
        float4 value = values[ampId];
        FragmentUniforms uniforms = {};
        uniforms.textureToClip = float4x4(1.0);
        float4 color = float4(value.z, 0, 0, value.z);
        return visibleVolumeOutput(value.w > 0, color, color, uniforms, value.x >= 0,
                                   float3(0, 0, value.x), float3(0, 0, value.y));
      }
      """ + depthComparisonShader
    let library = try device.makeLibrary(source: shaderSource, options: options)
    try testMarkerDepth(device: device, queue: queue, library: library)
    for channels in [2, 4] {
      let multichannelOptions = MTLCompileOptions()
      multichannelOptions.preprocessorMacros = [
        "VOLUME_SHADER_USES_RATE_MAP": NSNumber(value: 0),
        "VOLUME_COMPONENT_COUNT": NSNumber(value: channels),
        "VOLUME_BYTES_PER_COMPONENT": NSNumber(value: 2)
      ]
      if #available(macOS 15.0, *) { multichannelOptions.mathMode = .fast }
      let multichannelLibrary = try device.makeLibrary(source: shaderSource, options: multichannelOptions)
      try testMarkerDepth(device: device, queue: queue, library: multichannelLibrary)
      print("Shared TF/TF-lighting/ISO shaders compiled (\(channels) x 16-bit components)")
    }
    let plainSource = try source(root.appendingPathComponent(
      "AppSupport/Rendering/Shaders/VolumeRaycaster.metal")) + depthComparisonShader
    let plainLibrary = try device.makeLibrary(source: plainSource, options: options)
    try testMarkerDepth(device: device, queue: queue, library: plainLibrary)

    for samples in [1, 4] where device.supportsTextureSampleCount(samples) {
      func pipeline(_ fragment: String) -> MTLRenderPipelineDescriptor {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "vertexShaderMarkerComposite")
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = .rgba32Float
        d.colorAttachments[1].pixelFormat = .r32Float
        d.depthAttachmentPixelFormat = .depth32Float
        d.rasterSampleCount = samples
        d.maxVertexAmplificationCount = 2
        return d
      }
      let volumePipeline = try device.makeRenderPipelineState(descriptor: pipeline("testVolumeDepth"))
      let compositeDescriptor = pipeline("fragmentShaderMarkerComposite")
      compositeDescriptor.colorAttachments[1].writeMask = []
      let blend = compositeDescriptor.colorAttachments[0]!
      blend.isBlendingEnabled = true
      blend.sourceRGBBlendFactor = .oneMinusDestinationAlpha
      blend.destinationRGBBlendFactor = .one
      blend.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
      blend.destinationAlphaBlendFactor = .one
      let compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
      let depthDescriptor = compositeDescriptor.copy() as! MTLRenderPipelineDescriptor
      depthDescriptor.colorAttachments[0].writeMask = []
      depthDescriptor.colorAttachments[0].isBlendingEnabled = false
      let compositeDepthPipeline = try device.makeRenderPipelineState(descriptor: depthDescriptor)
      let boundingBoxDescriptor = pipeline("fragmentShaderBoundingBoxDepth")
      boundingBoxDescriptor.colorAttachments[0].writeMask = []
      boundingBoxDescriptor.colorAttachments[1].writeMask = []
      let boundingBoxPipeline = try device.makeRenderPipelineState(descriptor: boundingBoxDescriptor)
      func state(_ compare: MTLCompareFunction, writes: Bool) -> MTLDepthStencilState {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = compare
        d.isDepthWriteEnabled = writes
        return device.makeDepthStencilState(descriptor: d)!
      }
      let volumeDepthState = state(.always, writes: true)
      let compositeColorState = state(.always, writes: false)
      let compositeDepthState = state(.greater, writes: true)

      func texture(_ format: MTLPixelFormat, multisample: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 2, height: 2, mipmapped: false)
        d.textureType = multisample ? .type2DMultisampleArray : .type2DArray
        d.arrayLength = 2
        d.sampleCount = multisample ? samples : 1
        d.storageMode = format == .depth32Float || multisample ? .private : .shared
        d.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: d)!
      }
      let color = texture(.rgba32Float), interaction = texture(.r32Float), depth = texture(.depth32Float)
      let opaqueColor = texture(.rgba32Float), opaqueDepth = texture(.depth32Float)
      let msColor = samples > 1 ? texture(.rgba32Float, multisample: true) : color
      let msInteraction = samples > 1 ? texture(.r32Float, multisample: true) : interaction
      let msDepth = samples > 1 ? texture(.depth32Float, multisample: true) : depth

      // independent picking depth, visible TF depth, volume opacity, stopped-at-geometry
      let cases: [(SIMD4<Float>, Float)] = [
        (SIMD4(0.8, 0.8, 1, 0), 0.3),
        (SIMD4(0.8, 0.8, 0.25, 0), 0.3),
        (SIMD4(0.2, 0.8, 0.25, 1), 0.5),
        (SIMD4(0.2, 0, 0, 1), 0.9),
        (SIMD4(-1, 0, 0, 0), 0),
        (SIMD4(-1, 0, 0, 0), 0.6),
        (SIMD4(0.65, 0.65, 1, 0), 0)
      ]
      for (value, markerDepth, overrideBoundingBoxDepth) in cases.flatMap({ value, depth in
        [false, true].map { (value, depth, $0) }
      }) {
        let command = queue.makeCommandBuffer()!
        // A synthetic opaque prepass, like the production renderer's color/depth output.
        let opaquePass = MTLRenderPassDescriptor()
        opaquePass.renderTargetArrayLength = 2
        opaquePass.colorAttachments[0].texture = opaqueColor
        opaquePass.colorAttachments[0].loadAction = .clear
        opaquePass.colorAttachments[0].storeAction = .store
        opaquePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, markerDepth > 0 ? 1 : 0)
        opaquePass.depthAttachment.texture = opaqueDepth
        opaquePass.depthAttachment.loadAction = .clear
        opaquePass.depthAttachment.storeAction = .store
        opaquePass.depthAttachment.clearDepth = Double(markerDepth)
        command.makeRenderCommandEncoder(descriptor: opaquePass)!.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.renderTargetArrayLength = 2
        for (index, target, resolved) in [(0, msColor, color), (1, msInteraction, interaction)] {
          pass.colorAttachments[index].texture = target
          pass.colorAttachments[index].loadAction = .clear
          pass.colorAttachments[index].storeAction = samples > 1 ? .multisampleResolve : .store
          if samples > 1 { pass.colorAttachments[index].resolveTexture = resolved }
        }
        pass.colorAttachments[1].clearColor = MTLClearColorMake(-1, 0, 0, 0)
        pass.depthAttachment.texture = msDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = samples > 1 ? .multisampleResolve : .store
        if samples > 1 {
          pass.depthAttachment.resolveTexture = depth
          pass.depthAttachment.depthResolveFilter = .max
        }
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setViewports([MTLViewport(originX: 0, originY: 0, width: 2, height: 2, znear: 0, zfar: 1),
                              MTLViewport(originX: 0, originY: 0, width: 2, height: 2, znear: 0, zfar: 1)])
        var mappings = [MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
                        MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 1)]
        encoder.setVertexAmplificationCount(2, viewMappings: &mappings)
        var values = [value, value]
        encoder.setFragmentBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride * values.count, index: 0)
        encoder.setRenderPipelineState(volumePipeline)
        encoder.setDepthStencilState(volumeDepthState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.setFragmentTexture(opaqueColor, index: 2)
        encoder.setFragmentTexture(opaqueDepth, index: 3)
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setDepthStencilState(compositeColorState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.setRenderPipelineState(compositeDepthPipeline)
        encoder.setDepthStencilState(compositeDepthState)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if overrideBoundingBoxDepth {
          encoder.setRenderPipelineState(boundingBoxPipeline)
          encoder.setDepthStencilState(volumeDepthState)
          encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding()
        let depthReadback = device.makeBuffer(length: 1024, options: .storageModeShared)!
        let blit = command.makeBlitCommandEncoder()!
        for eye in 0..<2 {
          blit.copy(from: depth, sourceSlice: eye, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: 2, height: 2, depth: 1), to: depthReadback,
            destinationOffset: eye * 512, destinationBytesPerRow: 256, destinationBytesPerImage: 512)
        }
        blit.endEncoding()
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let visibleDepth = value.z > 0 ? (value.w > 0 ? value.y : value.x) : 0
        let expectedDepth: Float = overrideBoundingBoxDepth ? 0.5 : max(visibleDepth, markerDepth)
        for eye in 0..<2 {
          let actualDepth = depthReadback.contents().load(fromByteOffset: eye * 512, as: Float.self)
          var pixel = SIMD4<Float>.zero, pickingDepth: Float = 0
          color.getBytes(&pixel, bytesPerRow: 16, bytesPerImage: 16,
            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: eye)
          interaction.getBytes(&pickingDepth, bytesPerRow: 4, bytesPerImage: 4,
            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: eye)
          let green = markerDepth > 0 ? 1 - value.z : 0
          try require(abs(actualDepth - expectedDepth) < 1e-5,
            "Incorrect compositor depth: \(value), opaque \(markerDepth), bbox override \(overrideBoundingBoxDepth), depth \(actualDepth), eye \(eye)")
          try require(abs(pixel.x - value.z) < 1e-5 && abs(pixel.y - green) < 1e-5,
            "Depth merging changed transparent-volume compositing")
          try require(abs(pickingDepth - value.x) < 1e-5,
            "Compositor depth overwrote independent volume picking depth")
        }
      }
      print("Vision reprojection/bbox depth, unchanged color, and independent picking passed (stereo, \(samples)x MSAA)")
    }
  }
}
