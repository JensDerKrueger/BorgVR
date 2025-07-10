import Metal

/**
 A GPU-based hashtable implemented via a Metal buffer for atomic updates in shaders.

 GPUHashtable creates a shared storage buffer initialized to all 0xFF values
 (indicating empty slots), provides methods to bind the buffer to a shader,
 retrieve and reset the hashtable contents, and query its size.
 */
class GPUHashtable {
  /// The size of the hashtable (number of buckets), always aligned to 64.
  private var tableSize: Int
  /// A Metal buffer used for atomic operations on the GPU.
  private var atomicBuffer: MTLBuffer

  /// The number of buckets in the hashtable.
  var size: Int {
    tableSize
  }

  /**
   Initializes a new GPUHashtable with a minimum table size, aligned to 64 entries.

   - Parameters:
   - minTableElementCount: The minimum desired number of buckets.
   - device: The `MTLDevice` used to create the underlying Metal buffer.
   - Note: The actual table size will be rounded up to the next multiple of 64.
   - logger: An optional logger.
   */
  init(minTableElementCount: Int, device: MTLDevice, logger: LoggerBase? = nil) {
    // Align the table size to a multiple of 64 for optimal GPU atomic operations.
    self.tableSize = (minTableElementCount + 63) & -64
    if self.tableSize != minTableElementCount {
      logger?.dev("Requested table size of \(minTableElementCount) elements rounded up to \(tableSize).")
    }

    // Compute the total buffer size in bytes.
    let bufferSize = tableSize * MemoryLayout<UInt32>.stride

    // Create a shared buffer for CPU/GPU access.
    guard let buffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
      fatalError("Failed to create Metal buffer for GPUHashtable.")
    }
    self.atomicBuffer = buffer

    // Initialize all entries to 0xFF (UInt32.max) indicating empty slots.
    memset(atomicBuffer.contents(), 0xFF, bufferSize)
  }

  /**
   Binds the hashtable buffer to the given fragment shader argument index.

   - Parameters:
   - encoder: The `MTLRenderCommandEncoder` used for encoding draw calls.
   - index: The fragment shader buffer index at which to bind the hashtable.
   */
  func bind(to encoder: MTLRenderCommandEncoder, index: Int) {
    encoder.setFragmentBuffer(atomicBuffer, offset: 0, index: index)
  }

  /**
   Retrieves the current hashtable values after GPU execution, then resets the buffer.

   This method waits for the provided command buffer to complete,
   reads back all non-empty entries (those not equal to `UInt32.max`),
   clears the buffer to `UInt32.max` for the next frame, and returns the values.

   - Parameter commandBuffer: The `MTLCommandBuffer` whose execution must complete before reading back data.
   - Returns: An array of `UInt32` containing all valid hashtable entries.
   */
  func getValues(from commandBuffer: MTLCommandBuffer) -> [UInt32] {
    // Ensure GPU work is finished before reading.
    commandBuffer.waitUntilCompleted()

    // Bind the buffer contents to a UInt32 pointer.
    let pointer = atomicBuffer.contents().bindMemory(to: UInt32.self, capacity: tableSize)

    // Copy the contents into a Swift array.
    var hashTableValues = Array(UnsafeBufferPointer(start: pointer, count: tableSize))
    // Remove sentinel values (UInt32.max) indicating empty buckets.
    hashTableValues.removeAll { $0 == UInt32.max }

    // Reset the buffer back to all 0xFF for the next use.
    let bufferSize = atomicBuffer.length
    memset(atomicBuffer.contents(), 0xFF, bufferSize)

    return hashTableValues
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
