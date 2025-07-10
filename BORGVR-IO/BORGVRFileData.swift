import Foundation
import Compression
import os

// MARK: - BORGVRData

/**
 A class that manages volumetric brick data including optional compression.

 It loads the dataset metadata, opens a memory‑mapped file for the data, and, if compression
 is enabled, allocates scratch buffers required for decompression. It provides methods to load
 a brick from the file (decompressing it if necessary), to allocate a buffer for brick data.

 This class conforms to the BORGVRDatasetProtocol.
 */
final class BORGVRFileData: BORGVRDatasetProtocol {
  // MARK: Properties

  /// The metadata describing the brick hierarchy and dataset parameters.
  private let metadata: BORGVRMetaData

  /// The memory‑mapped file containing the brick data.
  private let memoryMappedFile: MemoryMappedFile

  /// A scratch buffer used during decompression (allocated only if compression is enabled).
  private let compressionScratchBuffer: UnsafeMutableRawPointer?

  /// A buffer used to temporarily hold compressed brick data (allocated only if compression is enabled).
  private let compressedDataBuffer: UnsafeMutablePointer<UInt8>?

  /// The expected full brick size in bytes.
  private let fullBrickSize: Int

  // MARK: Initialization

  /**
   Initializes a new instance of BORGVRFileData by loading metadata from the specified file,
   opening the associated memory‑mapped data file, and allocating compression buffers if needed.

   - Parameter filename: The file name containing the dataset metadata.
   - Throws: An error if loading metadata or mapping the data file fails.
   */
  init(filename: String) throws {
    // Load the dataset metadata.
    metadata = try BORGVRMetaData(filename: filename)
    // Open the data file specified in the metadata.
    memoryMappedFile = try MemoryMappedFile(filename: filename)
    // Compute the expected size of a full brick.
    fullBrickSize = metadata.brickSize * metadata.brickSize * metadata.brickSize *
    metadata.componentCount * metadata.bytesPerComponent
    // If compression is enabled, allocate buffers for scratch space and temporary compressed data.
    if metadata.compression {
      let scratchBufferSize = compression_decode_scratch_buffer_size(COMPRESSION_LZ4)
      compressionScratchBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: scratchBufferSize,
        alignment: MemoryLayout<UInt8>.alignment
      )
      compressedDataBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)
    } else {
      compressionScratchBuffer = nil
      compressedDataBuffer = nil
    }
  }

  /**
   Deinitializes the BORGVRFileData instance, deallocating any allocated compression buffers.
   */
  deinit {
    // Deallocate the compression scratch buffer if allocated.
    compressionScratchBuffer?.deallocate()
    // Deallocate the compressed data buffer if allocated.
    compressedDataBuffer?.deallocate()
  }

  // MARK: Methods

  /**
   Returns the dataset metadata.

   - Returns: The BORGVRMetaData describing the dataset.
   */
  public func getMetadata() -> BORGVRMetaData {
    return metadata
  }

  /**
   Loads a brick from the dataset at a specific index, decompressing it if necessary,
   and copies the brick data into the provided output buffer.

   - Parameters:
   - index: The 1D index of the brick.
   - outputBuffer: A pointer to a memory area with capacity at least `fullBrickSize` bytes.
   - Throws: A BORGVRDataError if the memory mapping is missing, compression buffers are unavailable,
   decompression fails, or the decompressed size does not match the expected full brick size.
   */
  public func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    // Retrieve the metadata for the requested brick and load the brick.
    try getBrick(brickMeta: metadata.getBrickMetadata(index: index), outputBuffer: outputBuffer)
  }

  /**
   Loads the last brick from the dataset and copies its data into the provided output buffer.
   In contrast to getBrick, this call is always synchronous.

   - Parameter outputBuffer: A pointer to a memory area with capacity at least `fullBrickSize` bytes.
   - Throws: A BORGVRDataError if the brick cannot be loaded.
   */
  public func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let lastBrickIndex = metadata.brickMetadata.count - 1
    try getBrick(index: lastBrickIndex, outputBuffer: outputBuffer)
  }

  /**
   Loads a brick from the dataset at the specified level and coordinates, decompressing it if necessary,
   and copies the brick data into the provided output buffer.

   - Parameters:
   - level: The level in the brick hierarchy.
   - x: The x-coordinate index of the brick.
   - y: The y-coordinate index of the brick.
   - z: The z-coordinate index of the brick.
   - outputBuffer: A pointer to a memory area with capacity at least `fullBrickSize` bytes.
   - Throws: A BORGVRDataError if the memory mapping is missing, compression buffers are unavailable,
   decompression fails, or the decompressed size does not match the expected full brick size.
   */
  public func getBrick(level: Int, x: Int, y: Int, z: Int,
                       outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    // Retrieve the metadata for the requested brick and load the brick.
    try getBrick(brickMeta: metadata.getBrickMetadata(level: level, x: x, y: y, z: z),
                 outputBuffer: outputBuffer)
  }

  /**
   Loads a brick from the dataset using the provided brick metadata, decompressing it if necessary,
   and copies the brick data into the provided output buffer.

   - Parameters:
   - brickMeta: The metadata for the brick to be loaded.
   - outputBuffer: A pointer to a memory area with capacity at least `fullBrickSize` bytes.
   - Throws: A BORGVRDataError if the memory mapping is missing, compression buffers are unavailable,
   decompression fails, or the decompressed size does not match the expected full brick size.
   */
  private func getBrick(brickMeta: BrickMetadata,
                        outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    // Ensure that the memory-mapped file is available.
    let baseMemory = memoryMappedFile.mappedMemory

    // Calculate a pointer to the start of the brick data.
    let brickPointer = baseMemory.advanced(by: brickMeta.offset)
      .assumingMemoryBound(to: UInt8.self)

    // If compression is enabled and the stored brick size is less than the full brick size,
    // decompress the brick data.
    if metadata.compression && brickMeta.size < fullBrickSize {
      guard let compBuffer = compressedDataBuffer,
            let scratchBuffer = compressionScratchBuffer else {
        throw BORGVRDataError.compressionBuffersUnavailable
      }

      // Copy the compressed data from the memory-mapped file to the temporary buffer.
      memcpy(compBuffer, brickPointer, brickMeta.size)

      // Decompress the data into the output buffer.
      let decompressedSize = compression_decode_buffer(
        outputBuffer,
        fullBrickSize,
        compBuffer,
        brickMeta.size,
        scratchBuffer,
        COMPRESSION_LZ4
      )

      if decompressedSize == 0 {
        throw BORGVRDataError.decompressionFailed
      } else if decompressedSize != fullBrickSize {
        throw BORGVRDataError.decompressedSizeMismatch(
          expected: fullBrickSize, got: decompressedSize)
      }
    } else {
      // For uncompressed data, copy directly from the memory-mapped file.
      memcpy(outputBuffer, brickPointer, brickMeta.size)
    }
  }

  /**
   Loads the raw brick data from the dataset using the provided brick metadata and copies it into
   the provided output buffer.

   - Parameters:
   - brickMeta: The metadata for the brick.
   - outputBuffer: A pointer to a memory area with capacity at least `brickMeta.size` bytes.
   - Throws: A BORGVRDataError if the memory mapping is missing.
   */
  func getRawBrick(brickMeta: BrickMetadata,
                   outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    // Ensure that the memory-mapped file is available.
    let baseMemory = memoryMappedFile.mappedMemory
    
    // Calculate a pointer to the start of the brick data.
    let brickPointer = baseMemory.advanced(by: brickMeta.offset)
      .assumingMemoryBound(to: UInt8.self)
    memcpy(outputBuffer, brickPointer, brickMeta.size)
  }

  /**
   Allocates and returns a new memory buffer suitable for storing a full brick.

   - Returns: A pointer to a newly allocated memory buffer with capacity `fullBrickSize` bytes.
   - Note: The caller is responsible for deallocating the returned buffer.
   */
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> {
    return UnsafeMutablePointer<UInt8>.allocate(capacity: fullBrickSize)
  }

  func newRequest() {
  }

}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

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
