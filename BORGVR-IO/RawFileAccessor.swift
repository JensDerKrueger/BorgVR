import Darwin
import Foundation

// MARK: - RawFileAccessor

/**
 Provides random-access reading and writing of voxel data from a raw binary file
 via memory mapping. Conforms to `VolumeDataAccessor` and `CustomStringConvertible`.

 This class maps the entire file into memory, validates size, and allows safe
 reinterpretation of bytes as integer types. It supports read-only and read-write modes.

 - Note: Writing requires the accessor to be opened in read-write mode.
 */
public class RawFileAccessor: VolumeDataAccessor {

  // MARK: - Error Enumeration

  /**
   Errors that can occur during raw file access operations.
   */
  public enum Error: Swift.Error, LocalizedError {
    /// The file size does not match the expected volume size.
    case fileSizeMismatch
    /// Memory mapping the file failed.
    case memoryMappingFailed
    /// Attempted to read or write outside the valid voxel bounds.
    case outOfBoundsAccess
    /// Attempted to write while opened in read-only mode.
    case readOnlyAccessViolation
    /// The requested reinterpretation type size is incompatible with the data size.
    case incompatibleTypeSize

    /// A localized description for each error case.
    public var errorDescription: String? {
      switch self {
        case .fileSizeMismatch:
          return "The file size does not match the expected size."
        case .memoryMappingFailed:
          return "Memory mapping failed."
        case .outOfBoundsAccess:
          return "Attempted to access data out of bounds."
        case .readOnlyAccessViolation:
          return "Attempted to write to a file opened in read-only mode."
        case .incompatibleTypeSize:
          return "The total byte count is not compatible with the requested type size."
      }
    }
  }

  // MARK: - Properties

  /// Underlying memory-mapped file handler.
  private let memoryMappedFile: MemoryMappedFile

  /// Pointer to the start of the mapped memory region, adjusted by `offset`.
  public let mappedMemory: UnsafeMutableRawPointer

  /// Byte offset within the file where volume data begins.
  private let offset: Int

  // MARK: - Initialization

  /**
   Initializes a new `RawFileAccessor` by memory-mapping the specified file.

   - Parameters:
   - filename: Path to the raw binary file.
   - size: The dimensions of the volume in voxels (Vec3<Int>).
   - bytesPerComponent: Number of bytes per data component.
   - componentCount: Number of components per voxel.
   - aspect: Physical aspect ratios of the volume (Vec3<Float>).
   - offset: Byte offset within the file where voxel data starts (default is `0`).
   - readOnly: If `true`, open file in read-only mode; otherwise, read-write.
   - Throws:
   - `Error.memoryMappingFailed` if mapping the file fails.
   - `Error.fileSizeMismatch` if the actual file size is smaller than expected.
   */
  public init(filename: String,
              size: Vec3<Int>,
              bytesPerComponent: Int,
              componentCount: Int,
              aspect: Vec3<Float>,
              offset: Int = 0,
              readOnly: Bool = true) throws {
    self.offset = offset

    // Compute expected file size including header offset.
    let expectedFileSize = size.x * size.y * size.z
    * bytesPerComponent * componentCount
    + offset

    self.memoryMappedFile = try MemoryMappedFile(filename: filename, readOnly: readOnly)
    self.mappedMemory = self.memoryMappedFile.mappedMemory.advanced(by: offset)
    super.init(size: size, bytesPerComponent: bytesPerComponent,
               componentCount: componentCount, aspect: aspect, readOnly: readOnly)

    guard self.memoryMappedFile.fileSize >= expectedFileSize else {
      throw Error.fileSizeMismatch
    }
  }

  // MARK: - Data Access

  /**
   Reads and reinterprets voxel data at the specified coordinate.

   - Parameters:
   - x: X-coordinate of the voxel.
   - y: Y-coordinate of the voxel.
   - z: Z-coordinate of the voxel.
   - count: Number of voxels to read (default is `1`).
   - Returns: An array of type `T` containing the requested voxel data.
   - Throws:
   - `Error.outOfBoundsAccess` if the coordinates are outside the volume.
   - `Error.incompatibleTypeSize` if the byte count does not align with `T`.
   */
  public override func getData<T: FixedWidthInteger>(
    x: Int, y: Int, z: Int, count: Int = 1
  ) throws -> [T] {
    // Bounds check
    guard (0..<size.x).contains(x),
          (0..<size.y).contains(y),
          (0..<size.z).contains(z) else {
      throw Error.outOfBoundsAccess
    }

    // Compute linear byte index
    let index = calculateIndex(x: x, y: y, z: z)

    // Total bytes to read
    let totalBytes = count * componentCount * bytesPerComponent

    // Ensure alignment with requested type
    guard totalBytes % MemoryLayout<T>.size == 0 else {
      throw Error.incompatibleTypeSize
    }

    // Create buffer pointer
    let rawPointer = mappedMemory.advanced(by: index)
    let buffer = UnsafeRawBufferPointer(start: rawPointer, count: totalBytes)

    // Bind to type T and return array
    let typedBuffer = buffer.bindMemory(to: T.self)
    return Array(typedBuffer)
  }

  /**
   Writes voxel data at the specified coordinate.

   - Parameters:
   - x: X-coordinate of the voxel.
   - y: Y-coordinate of the voxel.
   - z: Z-coordinate of the voxel.
   - data: An array of type `T` containing voxel data to write.
   - count: Number of voxels to write (default is `1`).
   - Throws:
   - `Error.outOfBoundsAccess` if the coordinates are outside the volume.
   - `Error.readOnlyAccessViolation` if the accessor was opened read-only.
   - `Error.incompatibleTypeSize` if the provided data size mismatches expected byte count.
   */
  public override func setData<T: FixedWidthInteger>(
    x: Int, y: Int, z: Int, data: [T], count: Int = 1
  ) throws {
    // Bounds check
    guard (0..<size.x).contains(x),
          (0..<size.y).contains(y),
          (0..<size.z).contains(z) else {
      throw Error.outOfBoundsAccess
    }

    // Prevent writes if read-only
    guard !readOnly else {
      throw Error.readOnlyAccessViolation
    }

    // Compute byte index
    let index = calculateIndex(x: x, y: y, z: z)

    // Expected total bytes
    let totalBytes = count * componentCount * bytesPerComponent

    // Verify provided data size
    guard data.count * MemoryLayout<T>.size == totalBytes else {
      throw Error.incompatibleTypeSize
    }

    // Copy data into mapped memory
    let destination = mappedMemory.advanced(by: index)
    let _ = data.withUnsafeBytes { srcBuffer in
      memcpy(destination, srcBuffer.baseAddress, srcBuffer.count)
    }
  }

  // MARK: - Cleanup

  /**
   Closes the underlying memory-mapped file, unmapping memory and closing descriptor.

   - Throws: `MemoryMappedFile.Error` if unmapping or closing fails.
   */
  public func close() throws {
    try memoryMappedFile.close()
  }

  deinit {
    try? close()
  }

  // MARK: - CustomStringConvertible

  /// A string representation including file name and volume parameters.
  public override var description: String {
    "RawFileAccessor(file: \(memoryMappedFile.filename), " +
    "size: \(size), components: \(componentCount), " +
    "bytes/component: \(bytesPerComponent), offset: \(offset))"
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
