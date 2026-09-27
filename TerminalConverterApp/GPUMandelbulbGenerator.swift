import Foundation

final class GPUMandelbulbGenerator {
  let sizeX: Int
  let sizeY: Int
  let sizeZ: Int
  let bytesPerVoxel: Int

  private let sliceGenerator: MetalSliceGenerator

  init(sizeX: Int, sizeY: Int, sizeZ: Int, bytesPerVoxel: Int) throws {
    guard sizeX > 1, sizeY > 1, sizeZ > 1 else {
      throw MetalSliceGeneratorError.invalidDimensions(width: sizeX, height: sizeY)
    }
    guard [1, 2, 4].contains(bytesPerVoxel) else {
      throw MetalSliceGeneratorError.invalidElementSize(bytesPerVoxel)
    }

    self.sizeX = sizeX
    self.sizeY = sizeY
    self.sizeZ = sizeZ
    self.bytesPerVoxel = bytesPerVoxel
    self.sliceGenerator = try MetalSliceGenerator(
      width: sizeX,
      height: sizeY,
      bytesPerElement: bytesPerVoxel,
      shaderSource: Self.shaderSource(sizeZ: sizeZ, bytesPerVoxel: bytesPerVoxel)
    )
  }

  func generateSlice(zCoordinate: Int) throws -> Data {
    guard zCoordinate >= 0, zCoordinate < sizeZ else {
      throw MetalSliceGeneratorError.invalidZCoordinate(zCoordinate)
    }
    return try sliceGenerator.generateSliceData(zCoordinate: zCoordinate)
  }

  private static func shaderSource(sizeZ: Int, bytesPerVoxel: Int) -> String {
    let outputType: String
    let maximumIterations: String
    switch bytesPerVoxel {
      case 1:
        outputType = "uchar"
        maximumIterations = "255u"
      case 2:
        outputType = "ushort"
        maximumIterations = "65535u"
      case 4:
        outputType = "uint"
        maximumIterations = "0xffffffffu"
      default:
        preconditionFailure("Unsupported Mandelbulb output size")
    }

    return """
      #include <metal_stdlib>
      using namespace metal;

      struct SliceParameters {
        uint width;
        uint height;
        uint zCoordinate;
      };

      kernel void generateSlice(
        device \(outputType) *output [[buffer(0)]],
        constant SliceParameters &slice [[buffer(1)]],
        uint2 position [[thread_position_in_grid]]) {
        if (position.x >= slice.width || position.y >= slice.height) {
          return;
        }

        constexpr float bulbSize = 2.25f;
        constexpr float bailout = 100.0f;
        constexpr uint exponent = 8u;
        constexpr uint maximumIterations = \(maximumIterations);
        constexpr uint volumeDepth = \(sizeZ)u;

        const float3 point = float3(
          bulbSize * float(position.x) / float(slice.width - 1u) - bulbSize * 0.5f,
          bulbSize * float(position.y) / float(slice.height - 1u) - bulbSize * 0.5f,
          bulbSize * float(slice.zCoordinate) / float(volumeDepth - 1u) - bulbSize * 0.5f
        );

        float3 value = float3(0.0f);
        float radius = 0.0f;
        uint iteration = 0u;
        for (; iteration < maximumIterations; ++iteration) {
          const float power = pow(radius, float(exponent));
          const float azimuth = atan2(value.y, value.x);
          const float polar = atan2(length(value.xy), value.z);
          const float sinPolar = sin(polar * float(exponent));
          const float cosPolar = cos(polar * float(exponent));
          const float cosAzimuth = cos(azimuth * float(exponent));
          const float sinAzimuth = sin(azimuth * float(exponent));

          value = point + power * float3(
            sinPolar * cosAzimuth,
            sinPolar * sinAzimuth,
            cosPolar
          );
          radius = length(value);
          if (radius > bailout) {
            break;
          }
        }

        output[position.y * slice.width + position.x] = \(outputType)(iteration);
      }
      """
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
