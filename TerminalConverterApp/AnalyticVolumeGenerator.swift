import Foundation

enum AnalyticVolumeKind: String, CaseIterable {
  case quaternionJulia
  case mandelbox
  case gyroid
  case sheppLogan
  case frequencyChirp

  var displayName: String {
    switch self {
      case .quaternionJulia: "Quaternion sine Julia set"
      case .mandelbox: "Mandelbox"
      case .gyroid: "Gyroid"
      case .sheppLogan: "3D Shepp-Logan phantom"
      case .frequencyChirp: "Frequency chirp and brick-boundary test"
    }
  }
}

enum AnalyticVolumeBackend {
  case metal
  case cpu

  var displayName: String {
    switch self {
      case .metal: "Metal"
      case .cpu: "CPU"
    }
  }
}

private enum QuaternionJuliaParameters {
  // Shawn Halayka, "Some visually interesting non-standard quaternion
  // fractal sets", Chaos, Solitons & Fractals 41 (2009), Fig. 3.
  // https://doi.org/10.1016/j.chaos.2008.10.035
  // Z' = sin(Z) + C * sin(Z).
  static let coordinateScale: Float = 1.5
  static let sliceCoordinate: Float = 0
  // Published as C_xyzw = (0.3, 0.5, 0.4, 0.2). This implementation stores
  // the scalar component last, hence the reordered (y, z, w, x) components.
  static let constant = SIMD4<Float>(0.5, 0.4, 0.2, 0.3)
  static let maximumIterations = 8
  static let escapeRadiusSquared: Float = 16
}

final class GPUAnalyticVolumeGenerator {
  let sizeX: Int
  let sizeY: Int
  let sizeZ: Int

  private let sliceGenerator: MetalSliceGenerator

  init(kind: AnalyticVolumeKind,
       sizeX: Int,
       sizeY: Int,
       sizeZ: Int,
       bytesPerVoxel: Int,
       brickStride: Int) throws {
    guard sizeX > 1, sizeY > 1, sizeZ > 1 else {
      throw MetalSliceGeneratorError.invalidDimensions(width: sizeX, height: sizeY)
    }
    guard [1, 2, 4].contains(bytesPerVoxel) else {
      throw MetalSliceGeneratorError.invalidElementSize(bytesPerVoxel)
    }

    self.sizeX = sizeX
    self.sizeY = sizeY
    self.sizeZ = sizeZ
    self.sliceGenerator = try MetalSliceGenerator(
      width: sizeX,
      height: sizeY,
      bytesPerElement: bytesPerVoxel,
      shaderSource: Self.shaderSource(
        kind: kind,
        sizeZ: sizeZ,
        bytesPerVoxel: bytesPerVoxel,
        brickStride: brickStride
      )
    )
  }

  func generateSlice(zCoordinate: Int) throws -> Data {
    guard zCoordinate >= 0, zCoordinate < sizeZ else {
      throw MetalSliceGeneratorError.invalidZCoordinate(zCoordinate)
    }
    return try sliceGenerator.generateSliceData(zCoordinate: zCoordinate)
  }

  private static func shaderSource(kind: AnalyticVolumeKind,
                                   sizeZ: Int,
                                   bytesPerVoxel: Int,
                                   brickStride: Int) -> String {
    let outputType: String
    let maximumValue: String
    switch bytesPerVoxel {
      case 1:
        outputType = "uchar"
        maximumValue = "255u"
      case 2:
        outputType = "ushort"
        maximumValue = "65535u"
      case 4:
        outputType = "uint"
        maximumValue = "0xffffffffu"
      default:
        preconditionFailure("Unsupported analytical volume output size")
    }

    return """
      #include <metal_stdlib>
      using namespace metal;

      struct SliceParameters {
        uint width;
        uint height;
        uint zCoordinate;
      };

      inline float4 quaternionMultiply(float4 left, float4 right) {
        return float4(
          left.w * right.xyz +
            right.w * left.xyz +
            cross(left.xyz, right.xyz),
          left.w * right.w - dot(left.xyz, right.xyz)
        );
      }

      inline float4 quaternionSine(float4 value) {
        const float vectorLength = length(value.xyz);
        const float vectorScale = vectorLength > 1e-6f
          ? cos(value.w) * sinh(vectorLength) / vectorLength
          : cos(value.w);
        return float4(
          value.xyz * vectorScale,
          sin(value.w) * cosh(vectorLength)
        );
      }

      inline float quaternionJulia(float3 normalizedPoint) {
        const float3 point = normalizedPoint *
          \(QuaternionJuliaParameters.coordinateScale)f;
        float4 value = float4(
          point.y,
          point.z,
          \(QuaternionJuliaParameters.sliceCoordinate)f,
          point.x
        );
        constexpr float4 juliaConstant = float4(
          \(QuaternionJuliaParameters.constant.x)f,
          \(QuaternionJuliaParameters.constant.y)f,
          \(QuaternionJuliaParameters.constant.z)f,
          \(QuaternionJuliaParameters.constant.w)f
        );
        constexpr uint maximumIterations = \(QuaternionJuliaParameters.maximumIterations)u;
        uint iteration = 0u;
        for (; iteration < maximumIterations; ++iteration) {
          const float4 sineValue = quaternionSine(value);
          value = sineValue + quaternionMultiply(juliaConstant, sineValue);
          if (dot(value, value) > \(QuaternionJuliaParameters.escapeRadiusSquared)f) {
            break;
          }
        }
        return float(iteration) / float(maximumIterations);
      }

      inline float mandelbox(float3 normalizedPoint) {
        const float3 point = normalizedPoint * 1.5f;
        float3 value = point;
        constexpr uint maximumIterations = 24u;
        uint iteration = 0u;
        for (; iteration < maximumIterations; ++iteration) {
          value = clamp(value, -1.0f, 1.0f) * 2.0f - value;
          const float radiusSquared = dot(value, value);
          if (radiusSquared < 0.25f) {
            value *= 4.0f;
          } else if (radiusSquared < 1.0f) {
            value /= radiusSquared;
          }
          value = -1.75f * value + point;
          if (dot(value, value) > 256.0f) {
            break;
          }
        }
        return float(iteration) / float(maximumIterations);
      }

      inline float gyroid(float3 normalizedPoint) {
        constexpr float pi = 3.14159265358979323846f;
        const float3 point = normalizedPoint * (3.0f * pi);
        const float field =
          sin(point.x) * cos(point.y) +
          sin(point.y) * cos(point.z) +
          sin(point.z) * cos(point.x);
        return clamp(0.5f + field / 3.0f, 0.0f, 1.0f);
      }

      inline float ellipsoid(float3 point,
                             float3 center,
                             float3 radii,
                             float angle,
                             float density) {
        const float cosine = cos(angle);
        const float sine = sin(angle);
        const float3 offset = point - center;
        const float3 local = float3(
          cosine * offset.x + sine * offset.y,
          -sine * offset.x + cosine * offset.y,
          offset.z
        );
        const float3 scaled = local / radii;
        return dot(scaled, scaled) <= 1.0f ? density : 0.0f;
      }

      inline float sheppLogan(float3 point) {
        float density = 0.0f;
        density += ellipsoid(point, float3( 0.00f,  0.0000f,  0.00f), float3(0.6900f, 0.920f, 0.900f),  0.000000f,  2.00f);
        density += ellipsoid(point, float3( 0.00f, -0.0184f,  0.00f), float3(0.6624f, 0.874f, 0.880f),  0.000000f, -0.98f);
        density += ellipsoid(point, float3( 0.22f,  0.0000f,  0.00f), float3(0.1100f, 0.310f, 0.220f), -0.314159f, -0.02f);
        density += ellipsoid(point, float3(-0.22f,  0.0000f,  0.00f), float3(0.1600f, 0.410f, 0.280f),  0.314159f, -0.02f);
        density += ellipsoid(point, float3( 0.00f,  0.3500f, -0.15f), float3(0.2100f, 0.250f, 0.410f),  0.000000f,  0.01f);
        density += ellipsoid(point, float3( 0.00f,  0.1000f,  0.25f), float3(0.0460f, 0.046f, 0.050f),  0.000000f,  0.01f);
        density += ellipsoid(point, float3( 0.00f, -0.1000f,  0.25f), float3(0.0460f, 0.046f, 0.050f),  0.000000f,  0.01f);
        density += ellipsoid(point, float3(-0.08f, -0.6050f,  0.00f), float3(0.0460f, 0.023f, 0.050f),  0.000000f,  0.01f);
        density += ellipsoid(point, float3( 0.00f, -0.6060f,  0.00f), float3(0.0230f, 0.023f, 0.020f),  0.000000f,  0.01f);
        density += ellipsoid(point, float3( 0.06f, -0.6050f,  0.00f), float3(0.0230f, 0.046f, 0.020f),  0.000000f,  0.01f);
        return clamp(density * 0.5f, 0.0f, 1.0f);
      }

      inline uint distanceToBrickBoundary(uint coordinate, uint stride) {
        const uint remainder = coordinate % stride;
        return min(remainder, stride - remainder);
      }

      inline float frequencyChirp(uint3 voxel, uint3 size) {
        constexpr float twoPi = 6.28318530717958647692f;
        const float3 unitPoint = float3(voxel) / float3(size - 1u);
        const float phase = twoPi * (
          2.0f * unitPoint.x + 18.0f * unitPoint.x * unitPoint.x +
          3.0f * unitPoint.y + 5.0f * unitPoint.z
        );
        const float chirp = 0.5f + 0.5f * sin(phase);

        // The upper quarter is a calibration area aligned to actual brick cores.
        if (unitPoint.y < 0.75f) {
          return chirp;
        }
        constexpr uint stride = \(max(1, brickStride))u;
        const uint boundaryDistance = min(
          distanceToBrickBoundary(voxel.x, stride),
          min(
            distanceToBrickBoundary(voxel.y, stride),
            distanceToBrickBoundary(voxel.z, stride)
          )
        );
        const float grid = boundaryDistance == 0u ? 1.0f :
          (boundaryDistance == 1u ? 0.55f : 0.08f);
        return max(chirp * 0.65f, grid);
      }

      inline float evaluateField(uint3 voxel, uint3 size) {
        const float3 normalizedPoint =
          2.0f * float3(voxel) / float3(size - 1u) - 1.0f;
        \(fieldExpression(for: kind))
      }

      inline \(outputType) quantize(float value) {
        const float clamped = clamp(value, 0.0f, 1.0f);
        if (clamped >= 1.0f) {
          return \(outputType)(\(maximumValue));
        }
        return \(outputType)(clamped * float(\(maximumValue)) + 0.5f);
      }

      kernel void generateSlice(
        device \(outputType) *output [[buffer(0)]],
        constant SliceParameters &slice [[buffer(1)]],
        uint2 position [[thread_position_in_grid]]) {
        if (position.x >= slice.width || position.y >= slice.height) {
          return;
        }
        const uint3 voxel = uint3(position, slice.zCoordinate);
        const uint3 size = uint3(slice.width, slice.height, \(sizeZ)u);
        output[position.y * slice.width + position.x] =
          quantize(evaluateField(voxel, size));
      }
      """
  }

  private static func fieldExpression(for kind: AnalyticVolumeKind) -> String {
    switch kind {
      case .quaternionJulia:
        "return quaternionJulia(normalizedPoint);"
      case .mandelbox:
        "return mandelbox(normalizedPoint);"
      case .gyroid:
        "return gyroid(normalizedPoint);"
      case .sheppLogan:
        "return sheppLogan(normalizedPoint);"
      case .frequencyChirp:
        "return frequencyChirp(voxel, size);"
    }
  }
}

func computeAnalyticVolume(kind: AnalyticVolumeKind,
                           filename: String,
                           sizeX: Int,
                           sizeY: Int,
                           sizeZ: Int,
                           bytesPerVoxel: Int,
                           brickStride: Int,
                           logger: LoggerBase? = nil) throws -> AnalyticVolumeBackend {
  do {
    let generator = try GPUAnalyticVolumeGenerator(
      kind: kind,
      sizeX: sizeX,
      sizeY: sizeY,
      sizeZ: sizeZ,
      bytesPerVoxel: bytesPerVoxel,
      brickStride: brickStride
    )
    logger?.info("Using Metal for \(kind.displayName) generation")
    try writeAnalyticVolumeGPU(
      generator: generator,
      kind: kind,
      filename: filename,
      sizeX: sizeX,
      sizeY: sizeY,
      sizeZ: sizeZ,
      bytesPerVoxel: bytesPerVoxel,
      logger: logger
    )
    return .metal
  } catch {
    logger?.warning(
      "Metal generation failed (\(error.localizedDescription)). " +
      "Falling back to multithreaded CPU generation."
    )
    try writeAnalyticVolumeCPU(
      kind: kind,
      filename: filename,
      sizeX: sizeX,
      sizeY: sizeY,
      sizeZ: sizeZ,
      bytesPerVoxel: bytesPerVoxel,
      brickStride: brickStride,
      logger: logger
    )
    return .cpu
  }
}

private func writeAnalyticVolumeGPU(generator: GPUAnalyticVolumeGenerator,
                                    kind: AnalyticVolumeKind,
                                    filename: String,
                                    sizeX: Int,
                                    sizeY: Int,
                                    sizeZ: Int,
                                    bytesPerVoxel: Int,
                                    logger: LoggerBase?) throws {
  let sliceByteCount = sizeX * sizeY * bytesPerVoxel
  let memoryMappedFile = try MemoryMappedFile(
    filename: filename,
    size: Int64(sliceByteCount * sizeZ)
  )
  defer { try? memoryMappedFile.close() }

  for z in 0..<sizeZ {
    logger?.progress("Generating \(kind.displayName) on GPU", Double(z) / Double(sizeZ - 1))
    let slice = try generator.generateSlice(zCoordinate: z)
    slice.withUnsafeBytes { source in
      guard let sourceAddress = source.baseAddress else { return }
      memcpy(
        memoryMappedFile.mappedMemory.advanced(by: z * sliceByteCount),
        sourceAddress,
        sliceByteCount
      )
    }
  }
  logger?.info("Finished writing \(kind.displayName) data to \(filename)")
}

private func writeAnalyticVolumeCPU(kind: AnalyticVolumeKind,
                                    filename: String,
                                    sizeX: Int,
                                    sizeY: Int,
                                    sizeZ: Int,
                                    bytesPerVoxel: Int,
                                    brickStride: Int,
                                    logger: LoggerBase?) throws {
  let memoryMappedFile = try MemoryMappedFile(
    filename: filename,
    size: Int64(sizeX * sizeY * sizeZ * bytesPerVoxel)
  )
  defer { try? memoryMappedFile.close() }

  for z in 0..<sizeZ {
    logger?.progress("Generating \(kind.displayName) on CPU", Double(z) / Double(sizeZ - 1))
    DispatchQueue.concurrentPerform(iterations: sizeY) { y in
      for x in 0..<sizeX {
        let value = AnalyticVolumeCPU.evaluate(
          kind: kind,
          x: x,
          y: y,
          z: z,
          sizeX: sizeX,
          sizeY: sizeY,
          sizeZ: sizeZ,
          brickStride: brickStride
        )
        let position = z * sizeY * sizeX + y * sizeX + x
        storeNormalizedValue(
          value,
          at: position,
          bytesPerVoxel: bytesPerVoxel,
          pointer: memoryMappedFile.mappedMemory
        )
      }
    }
  }
  logger?.info("Finished writing \(kind.displayName) data to \(filename)")
}

private func storeNormalizedValue(_ value: Float,
                                  at position: Int,
                                  bytesPerVoxel: Int,
                                  pointer: UnsafeMutableRawPointer) {
  let clamped = max(0, min(1, value))
  switch bytesPerVoxel {
    case 1:
      let quantized = clamped >= 1 ? UInt8.max : UInt8((clamped * Float(UInt8.max)).rounded())
      pointer.advanced(by: position).storeBytes(of: quantized, as: UInt8.self)
    case 2:
      let quantized = clamped >= 1 ? UInt16.max : UInt16((clamped * Float(UInt16.max)).rounded())
      pointer.advanced(by: position * 2).storeBytes(of: quantized, as: UInt16.self)
    case 4:
      let quantized = clamped >= 1
        ? UInt32.max
        : UInt32((Double(clamped) * Double(UInt32.max)).rounded())
      pointer.advanced(by: position * 4).storeBytes(of: quantized, as: UInt32.self)
    default:
      preconditionFailure("Unsupported analytical volume output size")
  }
}

private enum AnalyticVolumeCPU {
  private struct Ellipsoid {
    let center: SIMD3<Float>
    let radii: SIMD3<Float>
    let angle: Float
    let density: Float
  }

  private static let phantomEllipsoids = [
    Ellipsoid(center: SIMD3( 0.00,  0.0000,  0.00), radii: SIMD3(0.6900, 0.920, 0.900), angle:  0.000000, density:  2.00),
    Ellipsoid(center: SIMD3( 0.00, -0.0184,  0.00), radii: SIMD3(0.6624, 0.874, 0.880), angle:  0.000000, density: -0.98),
    Ellipsoid(center: SIMD3( 0.22,  0.0000,  0.00), radii: SIMD3(0.1100, 0.310, 0.220), angle: -0.314159, density: -0.02),
    Ellipsoid(center: SIMD3(-0.22,  0.0000,  0.00), radii: SIMD3(0.1600, 0.410, 0.280), angle:  0.314159, density: -0.02),
    Ellipsoid(center: SIMD3( 0.00,  0.3500, -0.15), radii: SIMD3(0.2100, 0.250, 0.410), angle:  0.000000, density:  0.01),
    Ellipsoid(center: SIMD3( 0.00,  0.1000,  0.25), radii: SIMD3(0.0460, 0.046, 0.050), angle:  0.000000, density:  0.01),
    Ellipsoid(center: SIMD3( 0.00, -0.1000,  0.25), radii: SIMD3(0.0460, 0.046, 0.050), angle:  0.000000, density:  0.01),
    Ellipsoid(center: SIMD3(-0.08, -0.6050,  0.00), radii: SIMD3(0.0460, 0.023, 0.050), angle:  0.000000, density:  0.01),
    Ellipsoid(center: SIMD3( 0.00, -0.6060,  0.00), radii: SIMD3(0.0230, 0.023, 0.020), angle:  0.000000, density:  0.01),
    Ellipsoid(center: SIMD3( 0.06, -0.6050,  0.00), radii: SIMD3(0.0230, 0.046, 0.020), angle:  0.000000, density:  0.01)
  ]

  static func evaluate(kind: AnalyticVolumeKind,
                       x: Int,
                       y: Int,
                       z: Int,
                       sizeX: Int,
                       sizeY: Int,
                       sizeZ: Int,
                       brickStride: Int) -> Float {
    let point = SIMD3<Float>(
      2 * Float(x) / Float(sizeX - 1) - 1,
      2 * Float(y) / Float(sizeY - 1) - 1,
      2 * Float(z) / Float(sizeZ - 1) - 1
    )
    switch kind {
      case .quaternionJulia:
        return quaternionJulia(point)
      case .mandelbox:
        return mandelbox(point)
      case .gyroid:
        return gyroid(point)
      case .sheppLogan:
        return sheppLogan(point)
      case .frequencyChirp:
        return frequencyChirp(
          x: x,
          y: y,
          z: z,
          sizeX: sizeX,
          sizeY: sizeY,
          sizeZ: sizeZ,
          brickStride: brickStride
        )
    }
  }

  private static func quaternionJulia(_ point: SIMD3<Float>) -> Float {
    let parameters = QuaternionJuliaParameters.self
    let scaledPoint = point * parameters.coordinateScale
    var value = SIMD4<Float>(
      scaledPoint.y,
      scaledPoint.z,
      parameters.sliceCoordinate,
      scaledPoint.x
    )
    var iteration = 0
    while iteration < parameters.maximumIterations {
      let sineValue = quaternionSine(value)
      value = sineValue + quaternionMultiply(parameters.constant, sineValue)
      if dot(value, value) > parameters.escapeRadiusSquared { break }
      iteration += 1
    }
    return Float(iteration) / Float(parameters.maximumIterations)
  }

  private static func quaternionMultiply(_ left: SIMD4<Float>,
                                         _ right: SIMD4<Float>) -> SIMD4<Float> {
    let leftVector = SIMD3<Float>(left.x, left.y, left.z)
    let rightVector = SIMD3<Float>(right.x, right.y, right.z)
    let vector = left.w * rightVector +
      right.w * leftVector +
      SIMD3<Float>(
        leftVector.y * rightVector.z - leftVector.z * rightVector.y,
        leftVector.z * rightVector.x - leftVector.x * rightVector.z,
        leftVector.x * rightVector.y - leftVector.y * rightVector.x
      )
    return SIMD4<Float>(
      vector,
      left.w * right.w - dot(leftVector, rightVector)
    )
  }

  private static func quaternionSine(_ value: SIMD4<Float>) -> SIMD4<Float> {
    let vector = SIMD3<Float>(value.x, value.y, value.z)
    let vectorLength = sqrt(dot(vector, vector))
    let vectorScale = vectorLength > 1e-6
      ? cos(value.w) * sinh(vectorLength) / vectorLength
      : cos(value.w)
    return SIMD4<Float>(
      vector * vectorScale,
      sin(value.w) * cosh(vectorLength)
    )
  }

  private static func mandelbox(_ normalizedPoint: SIMD3<Float>) -> Float {
    let point = normalizedPoint * 1.5
    var value = point
    let maximumIterations = 24
    var iteration = 0
    while iteration < maximumIterations {
      value = SIMD3(
        min(1, max(-1, value.x)) * 2 - value.x,
        min(1, max(-1, value.y)) * 2 - value.y,
        min(1, max(-1, value.z)) * 2 - value.z
      )
      let radiusSquared = dot(value, value)
      if radiusSquared < 0.25 {
        value *= 4
      } else if radiusSquared < 1 {
        value /= radiusSquared
      }
      value = -1.75 * value + point
      if dot(value, value) > 256 { break }
      iteration += 1
    }
    return Float(iteration) / Float(maximumIterations)
  }

  private static func gyroid(_ normalizedPoint: SIMD3<Float>) -> Float {
    let point = normalizedPoint * (3 * Float.pi)
    let field =
      sin(point.x) * cos(point.y) +
      sin(point.y) * cos(point.z) +
      sin(point.z) * cos(point.x)
    return min(1, max(0, 0.5 + field / 3))
  }

  private static func sheppLogan(_ point: SIMD3<Float>) -> Float {
    var density: Float = 0
    for ellipsoid in phantomEllipsoids {
      let cosine = cos(ellipsoid.angle)
      let sine = sin(ellipsoid.angle)
      let offset = point - ellipsoid.center
      let local = SIMD3<Float>(
        cosine * offset.x + sine * offset.y,
        -sine * offset.x + cosine * offset.y,
        offset.z
      )
      let scaled = local / ellipsoid.radii
      if dot(scaled, scaled) <= 1 {
        density += ellipsoid.density
      }
    }
    return min(1, max(0, density * 0.5))
  }

  private static func frequencyChirp(x: Int,
                                     y: Int,
                                     z: Int,
                                     sizeX: Int,
                                     sizeY: Int,
                                     sizeZ: Int,
                                     brickStride: Int) -> Float {
    let unit = SIMD3<Float>(
      Float(x) / Float(sizeX - 1),
      Float(y) / Float(sizeY - 1),
      Float(z) / Float(sizeZ - 1)
    )
    let phase = 2 * Float.pi * (
      2 * unit.x + 18 * unit.x * unit.x + 3 * unit.y + 5 * unit.z
    )
    let chirp = 0.5 + 0.5 * sin(phase)
    guard unit.y >= 0.75 else { return chirp }

    let stride = max(1, brickStride)
    let boundaryDistance = min(
      distanceToBrickBoundary(x, stride: stride),
      min(
        distanceToBrickBoundary(y, stride: stride),
        distanceToBrickBoundary(z, stride: stride)
      )
    )
    let grid: Float = boundaryDistance == 0 ? 1 : (boundaryDistance == 1 ? 0.55 : 0.08)
    return max(chirp * 0.65, grid)
  }

  private static func distanceToBrickBoundary(_ coordinate: Int, stride: Int) -> Int {
    let remainder = coordinate % stride
    return min(remainder, stride - remainder)
  }

  private static func dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
  }

  private static func dot(_ lhs: SIMD4<Float>, _ rhs: SIMD4<Float>) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z + lhs.w * rhs.w
  }
}
