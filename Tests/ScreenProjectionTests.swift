import Foundation
import Metal
import simd

private struct ProjectionFailure: Error { let message: String }

@main
private enum ScreenProjectionTests {
  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProjectionFailure(message: message) }
  }

  private static func project(_ point: SIMD3<Float>, using matrix: simd_float4x4) -> SIMD3<Float> {
    let clip = matrix * SIMD4<Float>(point, 1)
    return simd_make_float3(clip) / clip.w
  }

  private static func ray(_ point: SIMD2<Float>, using matrix: simd_float4x4) -> (SIMD3<Float>, SIMD3<Float>) {
    let inverse = simd_inverse(matrix)
    var near = inverse * SIMD4<Float>(point.x, point.y, 1, 1)
    var far = inverse * SIMD4<Float>(point.x, point.y, 0, 1)
    near /= near.w
    far /= far.w
    return (simd_make_float3(near), simd_normalize(simd_make_float3(far - near)))
  }

  private static func testMatrices() throws {
    for angle: Float in [10, 45, 67.5, 120] {
      for aspect: Float in [0.4, 1, 2.5] {
        let perspective = ScreenProjection(fieldOfView: angle, parallel: false)
        let parallel = ScreenProjection(fieldOfView: angle, parallel: true)
        let p = perspective.matrix(aspect: aspect)
        let o = parallel.matrix(aspect: aspect)
        for matrix in [p, o] {
          try require(abs(project(SIMD3(0, 0, -ScreenProjection.nearZ), using: matrix).z - 1) < 0.00001,
            "Near plane must have reverse-Z depth 1")
          try require(abs(project(SIMD3(0, 0, -ScreenProjection.farZ), using: matrix).z) < 0.00001,
            "Far plane must have reverse-Z depth 0")
        }
        let centerPlane = SIMD3<Float>(0.3, 0.2, -ScreenProjection.cameraDistance)
        let pp = project(centerPlane, using: p), op = project(centerPlane, using: o)
        try require(simd_length(SIMD2(pp.x - op.x, pp.y - op.y)) < 0.00001,
          "Switching projection changed the size at the volume-center plane")
        let closer = project(centerPlane + SIMD3(0, 0, 1), using: o)
        try require(abs(closer.x - op.x) < 0.00001 && abs(closer.y - op.y) < 0.00001,
          "Parallel geometry changes size with depth")
        let centerRay = ray(.zero, using: o)
        for cursor in [SIMD2<Float>(-0.9, -0.8), SIMD2(0.5, 0.6), SIMD2(0, 0)] {
          let (origin, direction) = ray(cursor, using: o)
          try require(simd_length(direction - centerRay.1) < 0.00001,
            "Picking rays are not parallel")
          let hit = origin + direction * ((centerPlane.z - origin.z) / direction.z)
          let screen = project(hit, using: o)
          try require(simd_length(SIMD2(screen.x, screen.y) - cursor) < 0.00001,
            "Picking did not match the rendered projection")
        }
        try require(simd_length(ray(SIMD2(0.7, 0.4), using: p).1 - ray(.zero, using: p).1) > 0.001,
          "Perspective picking rays became parallel")
      }
    }
    try require(ScreenProjection(fieldOfView: .nan, parallel: false).fieldOfView == 45,
      "Invalid FOV did not fall back safely")
    try require(ScreenProjection(fieldOfView: 0, parallel: false).fieldOfView == 10 &&
      ScreenProjection(fieldOfView: 180, parallel: false).fieldOfView == 120, "FOV limits failed")
  }

  private static func source(_ url: URL) throws -> String {
    var result = ""
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if (trimmed.hasPrefix("#include") || trimmed.hasPrefix("#import")),
         let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
        let name = String(line[line.index(after: first)..<last])
        result += try source(url.deletingLastPathComponent().appendingPathComponent(name).standardizedFileURL)
      } else { result += line + "\n" }
    }
    return result
  }

  private static func testShader() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw ProjectionFailure(message: "Metal device required")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let shader = try source(root.appendingPathComponent("AppSupport/Rendering/Shaders/RuntimeVolumeShaders.metal")) + """
      kernel void testProjection(device float4 *output [[buffer(0)]]) {
        FragmentUniforms uniforms = {};
        uniforms.cubeBounds[0] = float3(0);
        uniforms.cubeBounds[1] = float3(1);
        uniforms.cameraPosInTextureSpace = float3(0.5, 0.5, 2.9);
        uniforms.cameraPosInTextureSpaceVoxelScaled = float3(0.5, 0.5, 2.9);
        uniforms.parallelRayDirection = float4(0, 0, -1, 2.4);
        uniforms.projectionLODScale = 1;
        output[0] = float4(volumeRayEntryPoint(uniforms, float3(0.2, 0.8, 0)), 1);
        output[1] = float4(volumeRayEntryPoint(uniforms, float3(0.8, 0.2, 0)), 1);
        output[2] = float4(distanceFromCameraInNormalizedVolumeSpace(uniforms, float3(0)),
                           distanceFromCameraInNormalizedVolumeSpace(uniforms, float3(1)), 0, 0);
        uniforms.projectionLODScale = 2;
        output[3] = float4(distanceFromCameraInNormalizedVolumeSpace(uniforms, float3(0)), 0, 0, 0);
        uniforms.parallelRayDirection = float4(0);
        uniforms.projectionLODScale = 0;
        output[4] = float4(volumeRayEntryPoint(uniforms, float3(0.5, 0.5, 0)), 1);
        output[5] = float4(distanceFromCameraInNormalizedVolumeSpace(uniforms, float3(0.5, 0.5, 0.5)), 0, 0, 0);
      }
      """
    let library = try device.makeLibrary(source: shader, options: nil)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "testProjection")!)
    let output = device.makeBuffer(length: 6 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(output, offset: 0, index: 0)
    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    let actual = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 6)
    let expected: [SIMD4<Float>] = [SIMD4(0.2, 0.8, 1, 1), SIMD4(0.8, 0.2, 1, 1),
      SIMD4(2.4, 2.4, 0, 0), SIMD4(4.8, 0, 0, 0), SIMD4(0.5, 0.5, 1, 1), SIMD4(2.4, 0, 0, 0)]
    for i in expected.indices {
      try require(simd_length(actual[i] - expected[i]) < 0.0001,
        "GPU projection case \(i): \(actual[i]), expected \(expected[i])")
    }
  }

  static func main() throws {
    try testMatrices()
    try testShader()
    print("Screen projection tests passed: FOV, reverse-Z, picking, parallel rays, LOD and perspective fallback")
  }
}
