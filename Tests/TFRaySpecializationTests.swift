import Foundation
import Metal
import simd

private struct RayTestFailure: Error { let message: String }

@main
private enum TFRaySpecializationTests {
  private static func source(_ url: URL) throws -> String {
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

  private static let shader = """
    static_assert(sizeof(FragmentUniformsArray) <= 1024, "Test uniform allocation is too small");
    kernel void compareRayPaths(
      texture3d<float> atlas [[texture(0)]], texture3d<float> secondary [[texture(1)]],
      texture1d<half> tf1 [[texture(2)]], texture1d<half> tf2 [[texture(3)]],
      texture1d<half> tf3 [[texture(4)]], texture1d<half> tf4 [[texture(5)]],
      device FragmentUniformsArray *arrays [[buffer(0)]],
      device LevelData *levels [[buffer(1)]], device uint *bricks [[buffer(2)]],
      device atomic_uint *requests [[buffer(3)]], device float4 *results [[buffer(4)]],
      device const float *geometryDepths [[buffer(5)]], uint index [[thread_position_in_grid]]) {
      FragmentUniforms u = {};
      bool clipped = (index & 2) != 0;
      u.cubeBounds[0] = clipped ? float3(0.1, 0.2, 0.15) : float3(0);
      u.cubeBounds[1] = clipped ? float3(0.9, 0.85, 0.95) : float3(1);
      u.cameraPosInTextureSpace = float3(fract(float(index) * 0.37) * 1.5 - 0.25,
        fract(float(index) * 0.61) * 1.5 - 0.25, (index & 1) ? -1.0 : 2.0);
      u.cameraPosInTextureSpaceVoxelScaled = u.cameraPosInTextureSpace;
      u.transferBias = float4(1.0, 1.7, 0.8, 2.3);
      u.sampleJitter = float((index >> 2) & 1);
      u.oversampling = 0.4 + float((index >> 3) % 4) * 0.5;
      u.textureToClip = float4x4(float4(1, 0, 0.07, 0.03), float4(0, 1, 0.05, 0.02),
        float4(0, 0, 0.5, 0.1), float4(0, 0, 0.1, 1));
      arrays[index].uniforms[0] = u;
      u.cameraPosInTextureSpace.x += 0.03;
      arrays[index].uniforms[1] = u;
      LevelData level = {};
      level.bricksX = 1; level.bricksXTimesBricksY = 1;
      level.fractionalBrickLayout = float3(1);
      levels[index] = level;
      bricks[index] = BI_FLAG_COUNT;
      VertexToFragment in;
      in.position = float4(0.5, 0.5, 0, 1);
      in.exitPoint = mix(u.cubeBounds[0], u.cubeBounds[1],
        float3(fract(float(index) * 0.13), fract(float(index) * 0.29), float(index & 1)));
      uint eye = (index >> 4) & 1;
      device atomic_uint *hash = requests + index * HASHTABLE_SIZE;
      // Runtime depth keeps the original geometry-capable path unspecialized.
      VolumeFragmentOutput reference = raycastTransferFunction<true>(
        in, eye, geometryDepths[index], u.oversampling, atlas, secondary, tf1, tf2, tf3, tf4,
        arrays[index], levels + index, bricks + index, hash);
      VolumeFragmentOutput actual = raycastTransferFunction<false>(
        in, eye, 0.0, u.oversampling, atlas, secondary, tf1, tf2, tf3, tf4,
        arrays[index], levels + index, bricks + index, hash);
      results[index * 2] = abs(float4(reference.color) - float4(actual.color));
      results[index * 2 + 1] = float4(abs(reference.interactionDepth - actual.interactionDepth),
        abs(reference.depth - actual.depth), 0, 0);
    }
    """

  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw RayTestFailure(message: "Metal is required for ray specialization tests")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let production = try source(root.appendingPathComponent("AppSupport/Rendering/Shaders/VolumeRaycaster.metal"))
    let count = 1024
    let atlasDescriptor = MTLTextureDescriptor()
    atlasDescriptor.textureType = .type3D
    atlasDescriptor.pixelFormat = .rgba8Unorm
    atlasDescriptor.width = 16; atlasDescriptor.height = 16; atlasDescriptor.depth = 16
    atlasDescriptor.storageMode = .shared
    atlasDescriptor.usage = .shaderRead
    let atlas = device.makeTexture(descriptor: atlasDescriptor)!
    let voxels = (0..<16384).map { (i: Int) -> UInt8 in
      let value = i * 97 + i / 37
      return UInt8(value % 256)
    }
    voxels.withUnsafeBytes {
      atlas.replace(region: MTLRegionMake3D(0, 0, 0, 16, 16, 16), mipmapLevel: 0, slice: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 64, bytesPerImage: 1024)
    }
    var textures: [MTLTexture] = [atlas, atlas]
    for channel in 0..<4 {
      let d = MTLTextureDescriptor()
      d.textureType = .type1D; d.width = 128; d.pixelFormat = .rgba16Float
      d.storageMode = .shared; d.usage = .shaderRead
      let texture = device.makeTexture(descriptor: d)!
      let values = (0..<512).map { i -> Float16 in
        Float16(i % 4 == 3 ? Float((i / 4 + channel * 17) % 32) / 1000 : Float((i * 31 + channel * 23) % 128) / 127)
      }
      values.withUnsafeBytes {
        texture.replace(region: MTLRegionMake1D(0, 128), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 0)
      }
      textures.append(texture)
    }
    let buffers = [count * 1024, count * 32, count * 4, count * 64 * 4,
                   count * 2 * MemoryLayout<SIMD4<Float>>.stride].map {
      device.makeBuffer(length: $0, options: .storageModeShared)!
    }
    let depths = (0..<count).map { $0 % 2 == 0 ? Float(0) : Float(-1) }
    let depthBuffer = device.makeBuffer(bytes: depths, length: count * 4, options: .storageModeShared)!
    for channels in 1...4 { for bytes in [1, 2] {
      let options = MTLCompileOptions()
      options.mathMode = .fast
      let definitions: [String: String] = [
        "OVERRIDE_DUMMY": "1", "LEVEL_COUNT": "1", "BRICK_SIZE": "16", "BRICK_INNER_SIZE": "14",
        "OVERLAP_STEP": "float3(0.0625)", "LEVEL_ZERO_WORLD_SPACE_ERROR": "1",
        "VOLUME_SCALE": "float3(1)", "LOD_FACTOR": "1", "POOL_CAPACITY": "uint3(1)",
        "POOL_SIZE": "float3(16)", "VOLUME_SIZE": "float3(14)", "HASHTABLE_SIZE": "64",
        "MAX_PROBING_ATTEMPTS": "64", "MAX_ITERATIONS": "16", "REQUEST_LOWRES_LOD": "1",
        "STOP_ON_MISS": "0", "VOLUME_COMPONENT_COUNT": String(channels),
        "VOLUME_BYTES_PER_COMPONENT": String(bytes),
        "VOLUME_SHADER_USES_MARKER_TEXTURES": "1", "VOLUME_SHADER_WRITES_REPROJECTION_DEPTH": "1"
      ]
      options.preprocessorMacros = definitions.mapValues { $0 as NSString }
      let library = try device.makeLibrary(source: production + shader, options: options)
      let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "compareRayPaths")!)
      let command = queue.makeCommandBuffer()!
      let encoder = command.makeComputeCommandEncoder()!
      encoder.setComputePipelineState(pipeline)
      for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
      for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
      encoder.setBuffer(depthBuffer, offset: 0, index: 5)
      encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
      encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
      if let error = command.error { throw error }
      let result = buffers[4].contents().bindMemory(to: SIMD4<Float>.self, capacity: count * 2)
      for i in 0..<(count * 2) where result[i] != .zero {
        throw RayTestFailure(message: "Specialization changed color/picking/depth, \(channels)x\(bytes), ray \(i / 2): \(result[i])")
      }
      print("TF ray paths exactly identical: \(channels)x\(bytes)-byte components, \(count) rays (clipping, jitter, both views)")
    } }
  }
}
