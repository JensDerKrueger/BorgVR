import Foundation
import Metal

private enum TestFailure: Error {
  case failed(String)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw TestFailure.failed(message) }
}

@main
enum MetalSliceGeneratorTests {
  static func main() {
    do { try run() }
    catch {
      fputs("Metal slice generator tests failed: \(error)\n", stderr)
      exit(1)
    }
  }

  private static func run() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw TestFailure.failed("A Metal device is required")
    }
    print("Metal device: \(device.name); Apple4=\(device.supportsFamily(.apple4)), Mac2=\(device.supportsFamily(.mac2))")
    let shader = """
      #include <metal_stdlib>
      using namespace metal;
      struct SliceParameters { uint width; uint height; uint zCoordinate; };
      kernel void generateSlice(device uint *output [[buffer(0)]],
        constant SliceParameters &slice [[buffer(1)]],
        uint2 position [[thread_position_in_grid]]) {
        if (position.x >= slice.width || position.y >= slice.height) { return; }
        output[position.y * slice.width + position.x] =
          1u + position.y * slice.width + position.x + slice.zCoordinate * 100000u;
      }
      """
    for (width, height) in [(1, 1), (17, 13), (37, 19), (64, 64), (512, 512)] {
      let generator = try MetalSliceGenerator(width: width, height: height,
        bytesPerElement: 4, shaderSource: shader)
      for z in [0, 3] {
        let slice = try generator.generateSlice(zCoordinate: z, as: UInt32.self)
        try require(slice.width == width && slice.height == height, "Wrong slice dimensions")
        try require(slice.elements.count == width * height, "Wrong slice element count")
        for y in 0..<height {
          for x in 0..<width {
            try require(slice[x, y] == UInt32(1 + y * width + x + z * 100000),
              "Missing/incorrect thread output at \(x),\(y),\(z) for \(width)x\(height)")
          }
        }
      }
      do {
        _ = try generator.generateSliceData(zCoordinate: -1)
        throw TestFailure.failed("Accepted a negative Z coordinate")
      } catch MetalSliceGeneratorError.invalidZCoordinate {}
    }

    let bulb = try GPUMandelbulbGenerator(sizeX: 17, sizeY: 13, sizeZ: 9, bytesPerVoxel: 1)
    for z in [0, 4, 8] {
      let slice = try bulb.generateSlice(zCoordinate: z)
      try require(slice.count == 17 * 13, "Wrong Mandelbulb slice size")
      if z == 4 {
        try require(slice[6 * 17 + 8] == 255, "Mandelbulb center is missing")
        try require(slice[0] < slice[6 * 17 + 8], "Mandelbulb is empty or inverted")
      }
    }
    let largeBulb = try GPUMandelbulbGenerator(sizeX: 512, sizeY: 512, sizeZ: 512, bytesPerVoxel: 1)
    let firstSlice = try largeBulb.generateSlice(zCoordinate: 0)
    try require(firstSlice.count == 512 * 512 && firstSlice.contains { $0 > 0 },
      "The 512-cubed Easter egg's first slice failed")
    do {
      _ = try MetalSliceGenerator(width: 1, height: 1, bytesPerElement: 1,
        shaderSource: "this is not a Metal shader")
      throw TestFailure.failed("Accepted an invalid shader")
    } catch let error as TestFailure {
      throw error
    } catch {
      // Compiler failures must remain catchable, unlike the unsupported-dispatch assert.
    }
    print("Metal slice generator passed: aligned/partial threadgroups, all pixel coordinates, buffer reuse, invalid Z and actual Mandelbulb kernels including 512x512")
  }
}
