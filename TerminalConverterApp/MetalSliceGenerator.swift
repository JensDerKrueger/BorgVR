import Foundation
import Metal

protocol MetalSliceElement {}

extension UInt8: MetalSliceElement {}
extension UInt16: MetalSliceElement {}
extension UInt32: MetalSliceElement {}
extension Int8: MetalSliceElement {}
extension Int16: MetalSliceElement {}
extension Int32: MetalSliceElement {}
extension Float: MetalSliceElement {}

struct MetalSlice<Element: MetalSliceElement> {
  let width: Int
  let height: Int
  let elements: [Element]

  subscript(x: Int, y: Int) -> Element {
    precondition(x >= 0 && x < width && y >= 0 && y < height)
    return elements[y * width + x]
  }
}

enum MetalSliceGeneratorError: LocalizedError {
  case metalUnavailable
  case commandQueueUnavailable
  case invalidDimensions(width: Int, height: Int)
  case invalidZCoordinate(Int)
  case invalidElementSize(Int)
  case outputTooLarge(requested: Int, maximum: Int)
  case functionNotFound(String)
  case elementTypeSizeMismatch(expected: Int, actual: Int)
  case commandBufferUnavailable
  case commandEncoderUnavailable
  case executionFailed(String)

  var errorDescription: String? {
    switch self {
      case .metalUnavailable:
        return "Metal is not available on this system."
      case .commandQueueUnavailable:
        return "Could not create a Metal command queue."
      case .invalidDimensions(let width, let height):
        return "Invalid slice dimensions: \(width) x \(height)."
      case .invalidZCoordinate(let zCoordinate):
        return "Invalid slice Z coordinate: \(zCoordinate)."
      case .invalidElementSize(let size):
        return "Invalid output element size: \(size) bytes."
      case .outputTooLarge(let requested, let maximum):
        return "The slice requires \(requested) bytes, but this Metal device supports at most \(maximum) bytes per buffer."
      case .functionNotFound(let name):
        return "The Metal shader does not contain a function named '\(name)'."
      case .elementTypeSizeMismatch(let expected, let actual):
        return "The requested Swift element occupies \(actual) bytes, but the shader output uses \(expected) bytes per element."
      case .commandBufferUnavailable:
        return "Could not create a Metal command buffer."
      case .commandEncoderUnavailable:
        return "Could not create a Metal compute command encoder."
      case .executionFailed(let message):
        return "Metal slice generation failed: \(message)"
    }
  }
}

/// Runs a two-dimensional Metal compute kernel for one integer Z coordinate.
///
/// The kernel must use this binding contract:
/// - buffer(0): one tightly packed output element per X/Y coordinate
/// - buffer(1): `uint width`, `uint height`, `uint zCoordinate`
/// - `thread_position_in_grid`: the X/Y output coordinate
final class MetalSliceGenerator {
  private struct SliceParameters {
    let width: UInt32
    let height: UInt32
    let zCoordinate: UInt32
  }

  let width: Int
  let height: Int
  let bytesPerElement: Int

  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let outputBuffer: MTLBuffer
  private let threadsPerThreadgroup: MTLSize
  private let outputByteCount: Int

  init(width: Int,
       height: Int,
       bytesPerElement: Int,
       shaderSource: String,
       functionName: String = "generateSlice",
       device requestedDevice: MTLDevice? = nil) throws {
    guard width > 0, height > 0,
          width <= Int(UInt32.max), height <= Int(UInt32.max) else {
      throw MetalSliceGeneratorError.invalidDimensions(width: width, height: height)
    }
    guard bytesPerElement > 0 else {
      throw MetalSliceGeneratorError.invalidElementSize(bytesPerElement)
    }
    let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
    let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: bytesPerElement)
    guard !pixelOverflow, !byteOverflow else {
      throw MetalSliceGeneratorError.invalidDimensions(width: width, height: height)
    }

    guard let device = requestedDevice ?? MTLCreateSystemDefaultDevice() else {
      throw MetalSliceGeneratorError.metalUnavailable
    }
    guard byteCount <= device.maxBufferLength else {
      throw MetalSliceGeneratorError.outputTooLarge(
        requested: byteCount,
        maximum: device.maxBufferLength
      )
    }
    guard let commandQueue = device.makeCommandQueue() else {
      throw MetalSliceGeneratorError.commandQueueUnavailable
    }

    let compileOptions = MTLCompileOptions()
    compileOptions.mathMode = .safe
    let library = try device.makeLibrary(source: shaderSource, options: compileOptions)
    guard let function = library.makeFunction(name: functionName) else {
      throw MetalSliceGeneratorError.functionNotFound(functionName)
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    guard let outputBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
      throw MetalSliceGeneratorError.outputTooLarge(
        requested: byteCount,
        maximum: device.maxBufferLength
      )
    }

    let threadgroupWidth = min(pipeline.threadExecutionWidth, width)
    let availableRows = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadgroupWidth)
    let threadgroupHeight = min(availableRows, height)

    self.width = width
    self.height = height
    self.bytesPerElement = bytesPerElement
    self.commandQueue = commandQueue
    self.pipeline = pipeline
    self.outputBuffer = outputBuffer
    self.threadsPerThreadgroup = MTLSize(
      width: threadgroupWidth,
      height: threadgroupHeight,
      depth: 1
    )
    self.outputByteCount = byteCount
  }

  func generateSliceData(zCoordinate: Int) throws -> Data {
    guard zCoordinate >= 0, zCoordinate <= Int(UInt32.max) else {
      throw MetalSliceGeneratorError.invalidZCoordinate(zCoordinate)
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      throw MetalSliceGeneratorError.commandBufferUnavailable
    }
    guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
      throw MetalSliceGeneratorError.commandEncoderUnavailable
    }

    var parameters = SliceParameters(
      width: UInt32(width),
      height: UInt32(height),
      zCoordinate: UInt32(zCoordinate)
    )
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(outputBuffer, offset: 0, index: 0)
    encoder.setBytes(&parameters, length: MemoryLayout<SliceParameters>.stride, index: 1)
    encoder.dispatchThreads(
      MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: threadsPerThreadgroup
    )
    encoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw MetalSliceGeneratorError.executionFailed(
        commandBuffer.error?.localizedDescription ?? "unknown command buffer error"
      )
    }

    return Data(bytes: outputBuffer.contents(), count: outputByteCount)
  }

  func generateSlice<Element: MetalSliceElement>(
    zCoordinate: Int,
    as type: Element.Type
  ) throws -> MetalSlice<Element> {
    let elementSize = MemoryLayout<Element>.stride
    guard elementSize == bytesPerElement else {
      throw MetalSliceGeneratorError.elementTypeSizeMismatch(
        expected: bytesPerElement,
        actual: elementSize
      )
    }

    let data = try generateSliceData(zCoordinate: zCoordinate)
    let elementCount = width * height
    let elements = [Element](unsafeUninitializedCapacity: elementCount) { buffer, initializedCount in
      guard let destination = buffer.baseAddress else {
        initializedCount = 0
        return
      }
      data.copyBytes(
        to: UnsafeMutableRawBufferPointer(
          start: destination,
          count: outputByteCount
        )
      )
      initializedCount = elementCount
    }
    return MetalSlice(width: width, height: height, elements: elements)
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
