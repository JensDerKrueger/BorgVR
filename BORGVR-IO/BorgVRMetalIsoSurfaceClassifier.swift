import Foundation
import Metal

/// Resolves all cells of one overlapping BorgVR brick with the corrected MC33
/// case table. Vertex generation stays on the CPU so OBJ output and numerical
/// cleanup remain identical to the fallback path.
final class BorgVRMetalIsoSurfaceClassifier: @unchecked Sendable {
  struct Classification: Sendable {
    /// The corrected table's longest continued triangle sequence contains 17 entries.
    static let maximumTrianglesPerCell = 17
    static let wordsPerCell = maximumTrianglesPerCell + 1

    let words: [UInt32]

    func triangleCount(cellIndex: Int) -> Int {
      Int(words[cellIndex * Self.wordsPerCell])
    }

    func packedTriangle(cellIndex: Int, triangleIndex: Int) -> UInt32 {
      words[cellIndex * Self.wordsPerCell + 1 + triangleIndex]
    }
  }

  enum ClassifierError: LocalizedError {
    case metalUnavailable
    case commandQueueUnavailable
    case functionUnavailable
    case bufferAllocationFailed
    case outputTooLarge
    case commandBufferUnavailable
    case commandEncoderUnavailable
    case executionFailed(String)

    var errorDescription: String? {
      switch self {
        case .metalUnavailable:
          return "Metal is unavailable."
        case .commandQueueUnavailable:
          return "A Metal command queue could not be created."
        case .functionUnavailable:
          return "The Metal MC33 classification function is unavailable."
        case .bufferAllocationFailed:
          return "A Metal MC33 buffer could not be allocated."
        case .outputTooLarge:
          return "The Metal MC33 output exceeds this device's buffer limit."
        case .commandBufferUnavailable:
          return "A Metal command buffer could not be created."
        case .commandEncoderUnavailable:
          return "A Metal compute encoder could not be created."
        case .executionFailed(let message):
          return "Metal MC33 classification failed: \(message)"
      }
    }
  }

  private struct Parameters {
    let brickSize: UInt32
    let componentCount: UInt32
    let bytesPerComponent: UInt32
    let cellCountX: UInt32
    let cellCountY: UInt32
    let cellCountZ: UInt32
    let overlap: UInt32
    let thresholdInteger: UInt32
    let thresholdFraction: Float
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let lookupTableBuffer: MTLBuffer
  private let threadsPerThreadgroup: MTLSize

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw ClassifierError.metalUnavailable
    }
    guard let commandQueue = device.makeCommandQueue() else {
      throw ClassifierError.commandQueueUnavailable
    }
    let options = MTLCompileOptions()
    if #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) {
      options.mathMode = .safe
    }
    let library = try device.makeLibrary(source: Self.shaderSource, options: options)
    guard let function = library.makeFunction(name: "classifyMC33Cells") else {
      throw ClassifierError.functionUnavailable
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    let table = BorgVRMarchingCubes33.metalLookupTable
    guard let lookupTableBuffer = device.makeBuffer(
      bytes: table,
      length: table.count * MemoryLayout<UInt16>.stride,
      options: .storageModeShared
    ) else {
      throw ClassifierError.bufferAllocationFailed
    }

    let width = min(8, pipeline.threadExecutionWidth)
    let height = min(4, max(1, pipeline.maxTotalThreadsPerThreadgroup / width))
    let depth = min(4, max(1, pipeline.maxTotalThreadsPerThreadgroup / (width * height)))
    self.device = device
    self.commandQueue = commandQueue
    self.pipeline = pipeline
    self.lookupTableBuffer = lookupTableBuffer
    self.threadsPerThreadgroup = MTLSize(width: width, height: height, depth: depth)
  }

  func classify(
    brickBytes: UnsafeRawPointer,
    brickSize: Int,
    componentCount: Int,
    bytesPerComponent: Int,
    overlap: Int,
    cellDimensions: SIMD3<Int>,
    threshold: Double
  ) throws -> Classification {
    let cellCount = try checkedProduct(
      cellDimensions.x,
      cellDimensions.y,
      cellDimensions.z
    )
    let voxelCount = try checkedProduct(brickSize, brickSize, brickSize)
    let (componentValueCount, componentOverflow) = voxelCount.multipliedReportingOverflow(
      by: componentCount
    )
    let (inputByteCount, byteOverflow) = componentValueCount.multipliedReportingOverflow(
      by: bytesPerComponent
    )
    let (outputWordCount, wordOverflow) = cellCount.multipliedReportingOverflow(
      by: Classification.wordsPerCell
    )
    let (outputByteCount, outputOverflow) = outputWordCount.multipliedReportingOverflow(
      by: MemoryLayout<UInt32>.stride
    )
    guard !componentOverflow, !byteOverflow, !wordOverflow, !outputOverflow,
          inputByteCount > 0, outputByteCount > 0 else {
      throw ClassifierError.outputTooLarge
    }
    guard inputByteCount <= device.maxBufferLength,
          outputByteCount <= device.maxBufferLength else {
      throw ClassifierError.outputTooLarge
    }
    guard let inputBuffer = device.makeBuffer(
      bytes: brickBytes,
      length: inputByteCount,
      options: .storageModeShared
    ), let outputBuffer = device.makeBuffer(
      length: outputByteCount,
      options: .storageModeShared
    ) else {
      throw ClassifierError.bufferAllocationFailed
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      throw ClassifierError.commandBufferUnavailable
    }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw ClassifierError.commandEncoderUnavailable
    }

    let boundedThreshold = min(Double(UInt32.max), max(0, threshold))
    let thresholdInteger = UInt32(boundedThreshold.rounded(.down))
    var parameters = Parameters(
      brickSize: UInt32(brickSize),
      componentCount: UInt32(componentCount),
      bytesPerComponent: UInt32(bytesPerComponent),
      cellCountX: UInt32(cellDimensions.x),
      cellCountY: UInt32(cellDimensions.y),
      cellCountZ: UInt32(cellDimensions.z),
      overlap: UInt32(overlap),
      thresholdInteger: thresholdInteger,
      thresholdFraction: Float(boundedThreshold - Double(thresholdInteger))
    )
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setBuffer(lookupTableBuffer, offset: 0, index: 1)
    encoder.setBuffer(outputBuffer, offset: 0, index: 2)
    encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
    encoder.dispatchThreads(
      MTLSize(
        width: cellDimensions.x,
        height: cellDimensions.y,
        depth: cellDimensions.z
      ),
      threadsPerThreadgroup: threadsPerThreadgroup
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw ClassifierError.executionFailed(
        commandBuffer.error?.localizedDescription ?? "unknown command-buffer error"
      )
    }

    let words = [UInt32](unsafeUninitializedCapacity: outputWordCount) {
      buffer, initializedCount in
      guard let destination = buffer.baseAddress else {
        initializedCount = 0
        return
      }
      destination.update(
        from: outputBuffer.contents().assumingMemoryBound(to: UInt32.self),
        count: outputWordCount
      )
      initializedCount = outputWordCount
    }
    return Classification(words: words)
  }

  private func checkedProduct(_ a: Int, _ b: Int, _ c: Int) throws -> Int {
    let (ab, firstOverflow) = a.multipliedReportingOverflow(by: b)
    let (abc, secondOverflow) = ab.multipliedReportingOverflow(by: c)
    guard !firstOverflow, !secondOverflow, abc > 0 else {
      throw ClassifierError.outputTooLarge
    }
    return abc
  }

  private static let shaderSource = #"""
  #include <metal_stdlib>
  using namespace metal;

  constant uint wordsPerCell = 18;
  constant ushort referenceEdgeToBorgVR[13] = {
    3, 11, 7, 8, 1, 10, 5, 9, 0, 2, 6, 4, 12
  };

  struct Parameters {
    uint brickSize;
    uint componentCount;
    uint bytesPerComponent;
    uint cellCountX;
    uint cellCountY;
    uint cellCountZ;
    uint overlap;
    uint thresholdInteger;
    float thresholdFraction;
  };

  struct FaceTests {
    int values[6];
    int sum;
  };

  inline uint readComponent(
    device const uchar *input,
    ulong byteOffset,
    uint bytesPerComponent
  ) {
    uint value = uint(input[byteOffset]);
    if (bytesPerComponent > 1) {
      value |= uint(input[byteOffset + 1]) << 8;
    }
    if (bytesPerComponent > 2) {
      value |= uint(input[byteOffset + 2]) << 16;
      value |= uint(input[byteOffset + 3]) << 24;
    }
    return value;
  }

  inline uint scalarAt(
    device const uchar *input,
    constant Parameters &parameters,
    uint x,
    uint y,
    uint z
  ) {
    ulong voxel = ulong(z) * ulong(parameters.brickSize) * ulong(parameters.brickSize) +
      ulong(y) * ulong(parameters.brickSize) + ulong(x);
    ulong componentBase = voxel * ulong(parameters.componentCount);
    uint minimum = 0xFFFFFFFFu;
    for (uint component = 0; component < parameters.componentCount; ++component) {
      ulong byteOffset = (componentBase + ulong(component)) *
        ulong(parameters.bytesPerComponent);
      minimum = min(
        minimum,
        readComponent(input, byteOffset, parameters.bytesPerComponent)
      );
    }
    return minimum;
  }

  inline float thresholdDifference(
    uint value,
    uint thresholdInteger,
    float thresholdFraction
  ) {
    if (value <= thresholdInteger) {
      return float(thresholdInteger - value) + thresholdFraction;
    }
    return thresholdFraction - float(value - thresholdInteger);
  }

  inline int faceTest(int face, thread const float *values) {
    switch (face) {
      case 0: return values[0] * values[5] < values[1] * values[4] ? 0x48 : 0x84;
      case 1: return values[1] * values[6] < values[2] * values[5] ? 0x24 : 0x42;
      case 2: return values[3] * values[6] < values[2] * values[7] ? 0x21 : 0x12;
      case 3: return values[0] * values[7] < values[3] * values[4] ? 0x18 : 0x81;
      case 4: return values[0] * values[2] < values[1] * values[3] ? 0x50 : 0xA0;
      default: return values[4] * values[6] < values[5] * values[7] ? 0x05 : 0x0A;
    }
  }

  inline FaceTests faceTests(int index, thread const float *values) {
    FaceTests result;
    for (uint i = 0; i < 6; ++i) {
      result.values[i] = 0;
    }
    if ((index & 0x80) != 0) {
      result.values[0] = (index & 0xCC) == 0x84
        ? (values[0] * values[5] < values[1] * values[4] ? -1 : 1) : 0;
      result.values[3] = (index & 0x99) == 0x81
        ? (values[0] * values[7] < values[3] * values[4] ? -1 : 1) : 0;
      result.values[4] = (index & 0xF0) == 0xA0
        ? (values[0] * values[2] < values[1] * values[3] ? -1 : 1) : 0;
    } else {
      result.values[0] = (index & 0xCC) == 0x48
        ? (values[0] * values[5] < values[1] * values[4] ? 1 : -1) : 0;
      result.values[3] = (index & 0x99) == 0x18
        ? (values[0] * values[7] < values[3] * values[4] ? 1 : -1) : 0;
      result.values[4] = (index & 0xF0) == 0x50
        ? (values[0] * values[2] < values[1] * values[3] ? 1 : -1) : 0;
    }
    if ((index & 0x02) != 0) {
      result.values[1] = (index & 0x66) == 0x42
        ? (values[1] * values[6] < values[2] * values[5] ? -1 : 1) : 0;
      result.values[2] = (index & 0x33) == 0x12
        ? (values[3] * values[6] < values[2] * values[7] ? -1 : 1) : 0;
      result.values[5] = (index & 0x0F) == 0x0A
        ? (values[4] * values[6] < values[5] * values[7] ? -1 : 1) : 0;
    } else {
      result.values[1] = (index & 0x66) == 0x24
        ? (values[1] * values[6] < values[2] * values[5] ? 1 : -1) : 0;
      result.values[2] = (index & 0x33) == 0x21
        ? (values[3] * values[6] < values[2] * values[7] ? 1 : -1) : 0;
      result.values[5] = (index & 0x0F) == 0x05
        ? (values[4] * values[6] < values[5] * values[7] ? 1 : -1) : 0;
    }
    result.sum = 0;
    for (uint i = 0; i < 6; ++i) {
      result.sum += result.values[i];
    }
    return result;
  }

  inline int interiorTest(
    int diagonal,
    bool case13,
    thread const float *values
  ) {
    float a = values[4] - values[0];
    float b = values[5] - values[1];
    float c = values[6] - values[2];
    float d = values[7] - values[3];
    float quadratic = a * c - b * d;
    if (quadratic < 0.0f) {
      if ((diagonal & 1) != 0) { return 0; }
    } else if ((diagonal & 1) == 0 || quadratic == 0.0f) {
      return 0;
    }

    float t = 0.5f * (
      values[3] * b - values[2] * a + values[1] * d - values[0] * c
    ) / quadratic;
    if (!(t > 0.0f && t < 1.0f) || !isfinite(t)) { return 0; }

    a = values[0] + a * t;
    b = values[1] + b * t;
    c = values[2] + c * t;
    d = values[3] + d * t;
    float ac = a * c;
    float bd = b * d;
    if ((diagonal & 1) != 0) {
      if (!(ac < bd) || bd < 0.0f) { return 0; }
      return (signbit(b) == signbit(values[diagonal]) ? 1 : 0) + (case13 ? 1 : 0);
    }
    if (!(ac > bd) || ac < 0.0f) { return 0; }
    return (signbit(a) == signbit(values[diagonal]) ? 1 : 0) + (case13 ? 1 : 0);
  }

  inline uint resolveMC33(
    thread const uint *inputValues,
    uint thresholdInteger,
    float thresholdFraction,
    device const ushort *table,
    thread uint *triangles
  ) {
    const uchar referenceCornerOrder[8] = { 0, 3, 7, 4, 1, 2, 6, 5 };
    float values[8];
    int cubeIndex = 0;
    for (uint i = 0; i < 8; ++i) {
      values[i] = thresholdDifference(
        inputValues[referenceCornerOrder[i]],
        thresholdInteger,
        thresholdFraction
      );
      if (values[i] < 0.0f) {
        cubeIndex |= 1 << (7 - i);
      }
    }
    if (cubeIndex == 0 || cubeIndex == 0xFF) { return 0; }

    int descriptor;
    int firstWindingIndex;
    int secondWindingIndex;
    if ((cubeIndex & 0x80) != 0) {
      descriptor = int(table[cubeIndex ^ 0xFF]);
      firstWindingIndex = (descriptor & 0x800) == 0 ? 1 : 0;
      secondWindingIndex = 1 - firstWindingIndex;
    } else {
      descriptor = int(table[cubeIndex]);
      secondWindingIndex = (descriptor & 0x800) == 0 ? 1 : 0;
      firstWindingIndex = 1 - secondWindingIndex;
    }

    int patternOffset = descriptor & 0x7FF;
    int configuration = patternOffset;
    int canonicalIndex = firstWindingIndex != 0 ? cubeIndex : cubeIndex ^ 0xFF;
    switch (descriptor >> 12) {
      case 0:
        break;
      case 1: {
        int face = configuration >> 2;
        patternOffset = (canonicalIndex & faceTest(face, values)) != 0
          ? 183 + (configuration << 1) : 159 + configuration;
        break;
      }
      case 2:
        patternOffset = interiorTest(configuration, false, values) != 0
          ? 239 + 6 * configuration : 231 + (configuration << 1);
        break;
      case 3:
        if ((canonicalIndex & faceTest(configuration % 6, values)) != 0) {
          patternOffset = 575 + 5 * configuration;
        } else {
          patternOffset = interiorTest(configuration / 6, false, values) != 0
            ? 407 + 7 * configuration : 335 + 3 * configuration;
        }
        break;
      case 4: {
        FaceTests tests = faceTests(canonicalIndex, values);
        switch (tests.sum) {
          case -3:
            patternOffset = 695 + 3 * configuration;
            break;
          case -1: {
            int base = tests.values[4] + tests.values[5] < 0
              ? (tests.values[0] + tests.values[2] < 0 ? 759 : 799) : 719;
            patternOffset = base + 5 * configuration;
            break;
          }
          case 1: {
            int base = tests.values[4] + tests.values[5] < 0
              ? 983 : (tests.values[0] + tests.values[2] < 0 ? 839 : 911);
            patternOffset = base + 9 * configuration;
            break;
          }
          default:
            patternOffset = interiorTest(configuration >> 1, false, values) != 0
              ? 1095 + 9 * configuration : 1055 + 5 * configuration;
            break;
        }
        break;
      }
      case 5: {
        FaceTests tests = faceTests(canonicalIndex, values);
        switch (tests.sum) {
          case -2: {
            bool connected = configuration == 2
              ? interiorTest(0, false, values) != 0
              : interiorTest(0, false, values) != 0 ||
                interiorTest(configuration != 0 ? 1 : 3, false, values) != 0;
            patternOffset = connected
              ? 1213 + (configuration << 3) : 1189 + (configuration << 2);
            break;
          }
          case 0:
            patternOffset = (tests.values[2 + configuration] < 0 ? 1261 : 1285) +
              (configuration << 3);
            break;
          default: {
            bool connected = configuration == 2
              ? interiorTest(1, false, values) != 0
              : interiorTest(2, false, values) != 0 ||
                interiorTest(configuration != 0 ? 3 : 1, false, values) != 0;
            patternOffset = connected
              ? 1237 + (configuration << 3) : 1201 + (configuration << 2);
            break;
          }
        }
        break;
      }
      case 6: {
        FaceTests tests = faceTests(canonicalIndex, values);
        switch (tests.sum) {
          case -2: {
            int diagonal = (0xDA010C >> (configuration << 1)) & 3;
            patternOffset = interiorTest(diagonal, false, values) != 0
              ? 1453 + (configuration << 3) : 1357 + (configuration << 2);
            break;
          }
          case 0:
            patternOffset = (tests.values[configuration >> 1] < 0 ? 1645 : 1741) +
              (configuration << 3);
            break;
          default: {
            int diagonal = (0xA7B7E5 >> (configuration << 1)) & 3;
            patternOffset = interiorTest(diagonal, false, values) != 0
              ? 1549 + (configuration << 3) : 1405 + (configuration << 2);
            break;
          }
        }
        break;
      }
      default: {
        FaceTests tests = faceTests(165, values);
        switch (abs(tests.sum)) {
          case 0: {
            configuration = (tests.values[1] < 0 ? 2 : 0) |
              (tests.values[5] < 0 ? 1 : 0);
            if (tests.values[0] * tests.values[1] == tests.values[5]) {
              patternOffset = 2157 + 12 * configuration;
            } else {
              int result = interiorTest(configuration, true, values);
              patternOffset = 2285 + (result != 0
                ? 10 * configuration - 40 * result : 6 * configuration);
            }
            break;
          }
          case 2: {
            int first = tests.values[0] < 0
              ? (tests.values[2] > 0 ? 1 : 0)
              : 12 + (tests.values[2] < 0 ? 1 : 0);
            int second = tests.values[1] < 0
              ? (tests.values[3] < 0 ? 1 : 0)
              : 6 + (tests.values[3] > 0 ? 1 : 0);
            patternOffset = 1917 + 10 * (first + second);
            if (tests.values[4] > 0) { patternOffset += 30; }
            break;
          }
          case 4:
            configuration = 21 + 11 * tests.values[0] + 4 * tests.values[1] +
              3 * tests.values[2] + 2 * tests.values[3] + tests.values[4];
            if ((configuration >> 4) != 0) {
              configuration -= (configuration & 32) != 0 ? 20 : 10;
            }
            patternOffset = 1845 + 3 * configuration;
            break;
          default:
            patternOffset = 1839 + 2 * tests.values[0];
            break;
        }
        break;
      }
    }

    uint triangleCount = 0;
    int cursor = patternOffset;
    while (triangleCount < 17) {
      ++cursor;
      uint word = uint(table[cursor]);
      uint first = word & 0x0F;
      uint second = (word >> 4) & 0x0F;
      uint third = (word >> 8) & 0x0F;
      uint ordered[3] = { third, second, first };
      uint firstEdge = uint(referenceEdgeToBorgVR[ordered[secondWindingIndex]]);
      uint secondEdge = uint(referenceEdgeToBorgVR[ordered[firstWindingIndex]]);
      uint thirdEdge = uint(referenceEdgeToBorgVR[ordered[2]]);
      triangles[triangleCount] = firstEdge | (secondEdge << 4) | (thirdEdge << 8);
      ++triangleCount;
      if ((word >> 12) == 0) { break; }
    }
    return triangleCount;
  }

  kernel void classifyMC33Cells(
    device const uchar *input [[buffer(0)]],
    device const ushort *table [[buffer(1)]],
    device uint *output [[buffer(2)]],
    constant Parameters &parameters [[buffer(3)]],
    uint3 cell [[thread_position_in_grid]]
  ) {
    if (cell.x >= parameters.cellCountX ||
        cell.y >= parameters.cellCountY ||
        cell.z >= parameters.cellCountZ) {
      return;
    }
    uint x = cell.x + parameters.overlap;
    uint y = cell.y + parameters.overlap;
    uint z = cell.z + parameters.overlap;
    uint values[8] = {
      scalarAt(input, parameters, x, y, z),
      scalarAt(input, parameters, x + 1, y, z),
      scalarAt(input, parameters, x + 1, y + 1, z),
      scalarAt(input, parameters, x, y + 1, z),
      scalarAt(input, parameters, x, y, z + 1),
      scalarAt(input, parameters, x + 1, y, z + 1),
      scalarAt(input, parameters, x + 1, y + 1, z + 1),
      scalarAt(input, parameters, x, y + 1, z + 1)
    };
    uint cellIndex = cell.x + cell.y * parameters.cellCountX +
      cell.z * parameters.cellCountX * parameters.cellCountY;
    device uint *cellOutput = output + cellIndex * wordsPerCell;
    uint triangles[17];
    uint count = resolveMC33(
      values,
      parameters.thresholdInteger,
      parameters.thresholdFraction,
      table,
      triangles
    );
    cellOutput[0] = count;
    for (uint index = 0; index < count; ++index) {
      cellOutput[1 + index] = triangles[index];
    }
  }
  """#
}
