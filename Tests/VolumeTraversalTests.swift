import Foundation
import Metal
import simd

private struct TraversalFailure: Error { let message: String }

private struct TraversalCase {
  var entry: SIMD4<Float>
  var exit: SIMD4<Float>
  var boundsMin: SIMD4<Float>
  var boundsMax: SIMD4<Float>
  // Metadata scenario, LOD schedule, request suppression.
  var options: SIMD4<UInt32>
}

private struct TraversalLevel {
  var bricksX: UInt32
  var bricksXTimesBricksY: UInt32
  var prevBricks: UInt32
  var fractionalBrickLayout: SIMD3<Float>
}

@main
private enum VolumeTraversalTests {
  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TraversalFailure(message: message) }
  }

  private static func source(_ url: URL) throws -> String {
    var result = ""
    for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines) {
      if (line.hasPrefix("#include") || line.hasPrefix("#import")),
         let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last {
        result += try source(url.deletingLastPathComponent().appendingPathComponent(
          String(line[line.index(after: first)..<last])).standardizedFileURL)
      } else {
        result += line + "\n"
      }
    }
    return result
  }

  private static let comparisonShader = """
    struct TraversalCase {
      float4 entry, exit, boundsMin, boundsMax;
      uint4 options;
    };
    kernel void compareTraversal(
      device const TraversalCase *cases [[buffer(0)]],
      device const LevelData *levels [[buffer(1)]],
      device const uint *metadata [[buffer(2)]],
      device atomic_uint *requests [[buffer(3)]],
      device float4 *results [[buffer(4)]],
      constant uint &brickCount [[buffer(5)]],
      uint index [[thread_position_in_grid]]) {
      TraversalCase c = cases[index];
      float3 direction = c.exit.xyz - c.entry.xyz;
      float3 inverseDirection = inverseBrickRayDirection(direction);
      float rayLength = length(direction);
      float3 bounds[2] = {c.boundsMin.xyz, c.boundsMax.xyz};
      float3 expectedPosition = c.entry.xyz, actualPosition = c.entry.xyz;
      float expectedT = 0, actualT = 0;
      float maxExitError = 0, maxPoolError = 0, maxParameterError = 0;
      device const uint *bricks = metadata + c.options.x * brickCount;
      device atomic_uint *expectedRequests = requests + index * 2 * HASHTABLE_SIZE;
      device atomic_uint *actualRequests = expectedRequests + HASHTABLE_SIZE;
      uint step = 0, failure = 0;
      for (; step < MAX_ITERATIONS; ++step) {
        bool expectedActive = expectedT < 0.9999;
        bool actualActive = actualT < 0.9999;
        if (expectedActive != actualActive) { failure = 1; break; }
        if (!expectedActive) break;
        uint expectedLOD = c.options.y == 0 ? 0 :
          (c.options.y == 1 ? (step / 3) % LEVEL_COUNT : computeLOD(mix(1.0, 8.0, expectedT)));
        uint actualLOD = c.options.y == 0 ? 0 :
          (c.options.y == 1 ? (step / 3) % LEVEL_COUNT : computeLOD(mix(1.0, 8.0, actualT)));
        auto expected = TraversalReference::getBrick(
          expectedPosition, expectedLOD, direction, bounds, bricks, levels,
          expectedRequests, c.options.z != 0);
        auto actual = getBrick(
          actualPosition, actualLOD, direction, inverseDirection, bounds, bricks, levels,
          actualRequests, c.options.z != 0);
        if (expected.brickIndex != actual.brickIndex || expected.LOD != actual.LOD ||
            expected.empty != actual.empty || expected.substitute != actual.substitute) {
          failure = 2; break;
        }
        float nextExpectedT = length(c.entry.xyz - expected.normExitCoords) / rayLength;
        float nextActualT = actualT + actual.rayExitDelta;
        if (!all(isfinite(actual.normExitCoords)) || !isfinite(nextActualT) ||
            nextActualT <= actualT || nextActualT > 1.0001) { failure = 3; break; }
        float3 exitError = abs(expected.normExitCoords - actual.normExitCoords);
        maxExitError = max(maxExitError, max(max(exitError.x, exitError.y), exitError.z));
        maxParameterError = max(maxParameterError, abs(nextExpectedT - nextActualT));
        if (!actual.empty) {
          for (uint sample = 0; sample < 5; ++sample) {
            float phase = float(sample) * 0.25;
            float3 expectedPool = mix(expected.poolBrickInfo.poolEntryCoords,
                                      expected.poolBrickInfo.poolExitCoords, phase);
            float3 actualPool = mix(actual.poolBrickInfo.poolEntryCoords,
                                    actual.poolBrickInfo.poolExitCoords, phase);
            if (!all(isfinite(actualPool))) { failure = 4; break; }
            float3 poolError = abs(expectedPool - actualPool);
            maxPoolError = max(maxPoolError, max(max(poolError.x, poolError.y), poolError.z));
          }
        }
        expectedPosition = expected.normExitCoords;
        actualPosition = actual.normExitCoords;
        expectedT = nextExpectedT;
        actualT = nextActualT;
      }
      if (step == MAX_ITERATIONS && actualT < 0.9999) failure = 5;
      for (uint slot = 0; slot < HASHTABLE_SIZE; ++slot) {
        uint requested = atomic_load_explicit(expectedRequests + slot, memory_order_relaxed);
        if (requested == 0xffffffffu) continue;
        bool found = false;
        for (uint other = 0; other < HASHTABLE_SIZE; ++other)
          found |= requested == atomic_load_explicit(actualRequests + other, memory_order_relaxed);
        if (!found) failure = 6;
      }
      for (uint slot = 0; slot < HASHTABLE_SIZE; ++slot) {
        uint requested = atomic_load_explicit(actualRequests + slot, memory_order_relaxed);
        if (requested == 0xffffffffu) continue;
        bool found = false;
        for (uint other = 0; other < HASHTABLE_SIZE; ++other)
          found |= requested == atomic_load_explicit(expectedRequests + other, memory_order_relaxed);
        if (!found) failure = 6;
      }
      results[index] = float4(maxExitError, maxPoolError, maxParameterError, float(failure));
    }
    """

  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw TraversalFailure(message: "Metal device is required for traversal tests")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let shader = try source(root.appendingPathComponent("AppSupport/Rendering/Shaders/VolumeAtlas.h")) +
      source(root.appendingPathComponent("Tests/Fixtures/VolumeAtlasTraversalReference.h")) + comparisonShader
    var seed: UInt64 = 42
    func random() -> Float {
      seed = seed &* 6364136223846793005 &+ 1
      return Float(seed >> 40) / Float(1 << 24)
    }

    for (brickSize, overlap) in [(32, 2), (64, 2), (32, 1), (32, 0)] {
      let inner = brickSize - 2 * overlap
      let poolSize = SIMD3<Float>(7, 5, 3) * Float(brickSize)
      for size in [SIMD3<Int>(1, 2, 3), SIMD3(63, 65, 127), SIMD3(512, 512, 3172),
                   SIMD3(2048, 2048, 2048), SIMD3(4097, 31, 97)] {
        var levels: [TraversalLevel] = [], counts: [SIMD3<Int>] = [], brickCount = 0
        var levelSize = size
        repeat {
          let count = (levelSize &+ SIMD3(repeating: inner - 1)) / SIMD3(repeating: inner)
          levels.append(TraversalLevel(bricksX: UInt32(count.x),
            bricksXTimesBricksY: UInt32(count.x * count.y), prevBricks: UInt32(brickCount),
            fractionalBrickLayout: SIMD3<Float>(levelSize) / Float(inner)))
          counts.append(count)
          brickCount += count.x * count.y * count.z
          if levelSize == SIMD3(repeating: 1) { break }
          levelSize = (levelSize &+ SIMD3(repeating: 1)) / SIMD3(repeating: 2)
        } while true

        // Resident, empty-space hierarchy, missing-brick fallback, and mixed cases.
        var metadata = [UInt32](repeating: 0, count: 4 * brickCount)
        for scenario in 0..<4 {
          for (lod, level) in levels.enumerated() {
            let count = counts[lod]
            for z in 0..<count.z { for y in 0..<count.y { for x in 0..<count.x {
              let index = Int(level.prevBricks) + x + y * count.x + z * count.x * count.y
              var value = UInt32(3 + index % (7 * 5 * 3))
              if scenario == 1 || scenario == 3 {
                if Float(x + 1) / level.fractionalBrickLayout.x < 0.4 { value = 1 }
                else if index % 7 == 0 { value = 2 }
              }
              if (scenario == 2 || scenario == 3) && lod + 1 < levels.count && index % 3 != 0 {
                value = 0
              }
              metadata[scenario * brickCount + index] = value
            } } }
          }
        }
        var cases: [TraversalCase] = []
        func add(_ entry: SIMD3<Float>, _ exit: SIMD3<Float>, _ low: SIMD3<Float>, _ high: SIMD3<Float>) {
          guard simd_length(exit - entry) > 1e-6 else { return }
          for scenario in 0..<4 { for schedule in 0..<3 { for dontRequest in 0..<2 {
            cases.append(TraversalCase(entry: SIMD4(entry, 1), exit: SIMD4(exit, 1),
              boundsMin: SIMD4(low, 0), boundsMax: SIMD4(high, 0),
              options: SIMD4(UInt32(scenario), UInt32(schedule), UInt32(dontRequest), 0)))
          } } }
        }
        for clipped in [false, true] {
          let low: SIMD3<Float> = clipped ? SIMD3(0.061, 0.123, 0.017) : .zero
          let high: SIMD3<Float> = clipped ? SIMD3(0.934, 0.857, 0.981) : SIMD3(repeating: 1)
          // Faces, edges, corners, axis-parallel rays, and nearly parallel axes.
          for bits in 0..<8 {
            let a = SIMD3<Float>((bits & 1) != 0 ? high.x : low.x,
              (bits & 2) != 0 ? high.y : low.y, (bits & 4) != 0 ? high.z : low.z)
            add(a, low + high - a, low, high)
            for axis in 0..<3 {
              var b = a
              b[axis] = a[axis] == low[axis] ? high[axis] : low[axis]
              add(a, b, low, high)
              b[(axis + 1) % 3] += a[(axis + 1) % 3] == low[(axis + 1) % 3] ? 1e-9 : -1e-9
              add(a, b, low, high)
            }
          }
          // Start precisely on interior brick boundaries in both directions.
          let layout = levels[0].fractionalBrickLayout
          for axis in 0..<3 where counts[0][axis] > 1 {
            for sign: Float in [-1, 1] {
              var a = (low + high) * 0.5
              a[axis] = Float(counts[0][axis] / 2) / layout[axis]
              guard a[axis] > low[axis] && a[axis] < high[axis] else { continue }
              var b = a
              b[axis] = sign < 0 ? low[axis] : high[axis]
              add(a, b, low, high)
            }
          }
          for _ in 0..<256 {
            let a = low + SIMD3(random(), random(), random()) * (high - low)
            let direction = SIMD3(random() - 0.5, random() - 0.5, random() - 0.5)
            var exitT = Float.infinity
            for axis in 0..<3 where abs(direction[axis]) > 1e-8 {
              let boundary = direction[axis] > 0 ? high[axis] : low[axis]
              exitT = min(exitT, (boundary - a[axis]) / direction[axis])
            }
            add(a, simd_clamp(a + exitT * direction, low, high), low, high)
          }
        }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        options.preprocessorMacros = [
          "OVERRIDE_DUMMY": NSNumber(value: 1), "LEVEL_COUNT": NSNumber(value: levels.count),
          "BRICK_SIZE": NSNumber(value: brickSize), "BRICK_INNER_SIZE": NSNumber(value: inner),
          "POOL_SIZE": NSString(string: "float3(\(poolSize.x),\(poolSize.y),\(poolSize.z))"),
          "POOL_CAPACITY": NSString(string: "uint3(7,5,3)"),
          "OVERLAP_STEP": NSString(string: "float3(\(Float(overlap)/poolSize.x),\(Float(overlap)/poolSize.y),\(Float(overlap)/poolSize.z))"),
          "HASHTABLE_SIZE": NSNumber(value: 64), "MAX_PROBING_ATTEMPTS": NSNumber(value: 64),
          "MAX_ITERATIONS": NSNumber(value: counts[0].x + counts[0].y + counts[0].z + levels.count),
          "REQUEST_LOWRES_LOD": NSNumber(value: 1), "LOD_FACTOR": NSNumber(value: 1),
          "LEVEL_ZERO_WORLD_SPACE_ERROR": NSNumber(value: 1),
          "VOLUME_SIZE": NSString(string: "float3(1)")
        ]
        let library = try device.makeLibrary(source: shader, options: options)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "compareTraversal")!)
        func buffer<T>(_ values: [T]) -> MTLBuffer {
          values.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
          }
        }
        let inputs = [buffer(cases), buffer(levels), buffer(metadata)]
        let requests = buffer([UInt32](repeating: .max, count: cases.count * 2 * 64))
        let output = device.makeBuffer(length: cases.count * MemoryLayout<SIMD4<Float>>.stride,
                                       options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        for (index, input) in inputs.enumerated() { encoder.setBuffer(input, offset: 0, index: index) }
        encoder.setBuffer(requests, offset: 0, index: 3)
        encoder.setBuffer(output, offset: 0, index: 4)
        var count = UInt32(brickCount)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 5)
        encoder.dispatchThreads(MTLSize(width: cases.count, height: 1, depth: 1),
          threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        let results = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: cases.count)
        var maximum = SIMD3<Float>.zero
        for index in cases.indices {
          let result = results[index]
          // The old corner-difference mapping loses precision for fine LODs.
          // Bound atlas differences to less than 0.005 of a texel on every axis.
          try require(result.w == 0 && result.x <= 2e-6 && result.y <= 1e-5 && result.z <= 3e-5,
            "Traversal differs for \(size), case \(index): \(result), \(cases[index])")
          maximum = simd_max(maximum, SIMD3(result.x, result.y, result.z))
        }
        print("Traversal passed: \(size), brick \(brickSize)/overlap \(overlap), \(cases.count) GPU rays, max errors (exit, atlas, t): \(maximum)")
      }
    }
  }
}
