import Metal

/**
 Errors related to the allocation of aligned Metal buffers.
 */
enum AlignedBufferError: Error, LocalizedError {
  /// Raised when allocation of a buffer of a given size fails.
  case allocationFailed(size: Int)

  var errorDescription: String? {
    switch self {
      case .allocationFailed(let size):
        return "Failed to allocate Metal buffer of size \(size) bytes."
    }
  }
}

/**
 A utility class for managing dynamically aligned Metal buffers.

 This class allocates a single buffer and allows you to rotate through
 a specified number of aligned regions in memory (e.g., for double/triple buffering).

 It provides typed access to the current frame’s data and convenience methods
 to bind the buffer to Metal command encoders.

 - Note: Memory is aligned to 256 bytes by default to meet GPU requirements.
 */
final class AlignedBuffer<T> {

  /// The underlying Metal buffer.
  private let buffer: MTLBuffer
  /// The aligned size of each T instance.
  private let alignedSize: Int
  /// The number of instances that fit in this buffer.
  private let capacity: Int

  /// The index of the currently active frame.
  private(set) var index : Int

  /// The offset into the buffer for the current frame.
  private var offset: Int {
    alignedSize * index
  }

  /// A typed pointer to the current frame’s region of the buffer.
  private var currentPointer: UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(buffer.contents() + offset).bindMemory(to: T.self, capacity: 1)
  }

  /// Access the current frame’s value directly (read/write).
  var current: T {
    get { currentPointer.pointee }
    set { currentPointer.pointee = newValue }
  }

  /**
   Initializes an aligned Metal buffer for type `T`.

   - Parameters:
   - device: The Metal device used to allocate the buffer.
   - capacity: The number of elements to store (usually the number of in-flight frames).
   - alignment: The byte alignment for each element (default is 256).
   - Throws: `AlignedBufferError` if buffer allocation fails.
   */
  init(device: MTLDevice, capacity: Int, alignment: Int = 256) throws {
    self.capacity = capacity
    self.alignedSize = Self.alignedSize(for: T.self, alignment: alignment)
    self.index  = 0

    let totalSize = alignedSize * capacity
    guard let buffer = device.makeBuffer(
      length: totalSize,
      options: [.storageModeShared]
    ) else {
      throw AlignedBufferError.allocationFailed(size: totalSize)
    }

    self.buffer = buffer
    self.buffer.label = "DynamicUniformBuffer<\(T.self)>"
  }

  /// Advances the buffer to the next frame (cyclic).
  func advance() {
    index = (index + 1) % capacity
  }

  /**
   Binds this buffer to the vertex function of a render command encoder.

   - Parameters:
   - encoder: The `MTLRenderCommandEncoder` to bind this buffer to.
   - index: The index in the vertex shader's buffer argument table.
   */
  func bindVertex(to encoder: MTLRenderCommandEncoder, index: Int) {
    encoder.setVertexBuffer(buffer, offset: offset, index: index)
  }

  /**
   Binds this buffer to the fragment function of a render command encoder.

   - Parameters:
   - encoder: The `MTLRenderCommandEncoder` to bind this buffer to.
   - index: The index in the fragment shader's buffer argument table.
   */
  func bindFragment(to encoder: MTLRenderCommandEncoder, index: Int) {
    encoder.setFragmentBuffer(buffer, offset: offset, index: index)
  }

  /**
   Binds this buffer to a compute function at the specified index.

   - Parameters:
   - encoder: The `MTLComputeCommandEncoder` to bind this buffer to.
   - index: The index in the compute shader's buffer argument table.

   This allows the buffer to be used as an input or output resource during GPU compute passes.
   */
  func bindCompute(to encoder: MTLComputeCommandEncoder, index: Int) {
    encoder.setBuffer(buffer, offset: offset, index: index)
  }

  /**
   Returns an aligned size in bytes for the given type.

   The size is aligned to the specified alignment (default 256 bytes).

   - Parameters:
   - type: The type to compute the size for.
   - count: The number of elements (default is 1).
   - alignment: The required alignment (default is 256).
   - Returns: The aligned size in bytes.
   */
  static func alignedSize(for type: T.Type, count: Int = 1,
                          alignment: Int = 256) -> Int {
    let perElementSize = ((MemoryLayout<T>.size + (alignment - 1)) / alignment) * alignment
    return count * perElementSize
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
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
