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
    /// The supplied volume layout is empty, negative, or cannot be represented safely.
    case invalidVolumeDescription

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
        case .invalidVolumeDescription:
          return "The volume dimensions, component layout, or file offset are invalid."
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

  /// Number of voxels and bytes validated during initialization.
  private let checkedVoxelCount: Int
  private let checkedVoxelByteSize: Int
  private let checkedVolumeByteCount: Int

  /// Whether the mapped payload may be accessed through naturally aligned typed pointers.
  var supportsAlignedTypedAccess: Bool {
    Int(bitPattern: mappedMemory) % bytesPerComponent == 0
  }

  // MARK: - Initialization

  /**
   Initializes a new `RawFileAccessor` by memory-mapping the specified file.

   - Parameters:
   - filename: Path to the raw binary file.
   - size: The dimensions of the volume in voxels (Vec3<Int>).
   - bytesPerComponent: Number of bytes per data component.
   - componentCount: Number of components per voxel.
   - voxelSpacing: Physical voxel spacing of the volume (Vec3<Float>).
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
              voxelSpacing: Vec3<Float>,
              offset: Int = 0,
              readOnly: Bool = true) throws {
    let layout = try Self.checkedLayout(
      size: size,
      bytesPerComponent: bytesPerComponent,
      componentCount: componentCount,
      offset: offset
    )
    self.offset = offset
    self.checkedVoxelCount = layout.voxelCount
    self.checkedVoxelByteSize = layout.voxelByteSize
    self.checkedVolumeByteCount = layout.volumeByteCount

    self.memoryMappedFile = try MemoryMappedFile(filename: filename, readOnly: readOnly)
    guard self.memoryMappedFile.fileSize >= Int64(layout.requiredFileSize) else {
      throw Error.fileSizeMismatch
    }
    self.mappedMemory = self.memoryMappedFile.mappedMemory.advanced(by: offset)
    super.init(size: size, bytesPerComponent: bytesPerComponent,
               componentCount: componentCount, voxelSpacing: voxelSpacing, readOnly: readOnly)
  }

  private static func checkedLayout(
    size: Vec3<Int>,
    bytesPerComponent: Int,
    componentCount: Int,
    offset: Int
  ) throws -> (
    voxelCount: Int,
    voxelByteSize: Int,
    volumeByteCount: Int,
    requiredFileSize: Int
  ) {
    guard size.x > 0, size.y > 0, size.z > 0,
          bytesPerComponent > 0, componentCount > 0, offset >= 0 else {
      throw Error.invalidVolumeDescription
    }

    let xy = size.x.multipliedReportingOverflow(by: size.y)
    guard !xy.overflow else { throw Error.invalidVolumeDescription }
    let voxelCount = xy.partialValue.multipliedReportingOverflow(by: size.z)
    guard !voxelCount.overflow else { throw Error.invalidVolumeDescription }
    let voxelByteSize = bytesPerComponent.multipliedReportingOverflow(by: componentCount)
    guard !voxelByteSize.overflow else { throw Error.invalidVolumeDescription }
    let volumeByteCount = voxelCount.partialValue.multipliedReportingOverflow(
      by: voxelByteSize.partialValue
    )
    guard !volumeByteCount.overflow else { throw Error.invalidVolumeDescription }
    let requiredFileSize = offset.addingReportingOverflow(volumeByteCount.partialValue)
    guard !requiredFileSize.overflow else { throw Error.invalidVolumeDescription }

    return (
      voxelCount.partialValue,
      voxelByteSize.partialValue,
      volumeByteCount.partialValue,
      requiredFileSize.partialValue
    )
  }

  private func checkedByteRange(x: Int, y: Int, z: Int, count: Int) throws -> Range<Int> {
    guard (0..<size.x).contains(x),
          (0..<size.y).contains(y),
          (0..<size.z).contains(z),
          count >= 0 else {
      throw Error.outOfBoundsAccess
    }

    let zy = z.multipliedReportingOverflow(by: size.y)
    guard !zy.overflow else { throw Error.outOfBoundsAccess }
    let row = zy.partialValue.addingReportingOverflow(y)
    guard !row.overflow else { throw Error.outOfBoundsAccess }
    let rowStart = row.partialValue.multipliedReportingOverflow(by: size.x)
    guard !rowStart.overflow else { throw Error.outOfBoundsAccess }
    let startVoxel = rowStart.partialValue.addingReportingOverflow(x)
    guard !startVoxel.overflow else { throw Error.outOfBoundsAccess }
    let endVoxel = startVoxel.partialValue.addingReportingOverflow(count)
    guard !endVoxel.overflow, endVoxel.partialValue <= checkedVoxelCount else {
      throw Error.outOfBoundsAccess
    }

    let startByte = startVoxel.partialValue.multipliedReportingOverflow(
      by: checkedVoxelByteSize
    )
    let byteCount = count.multipliedReportingOverflow(by: checkedVoxelByteSize)
    guard !startByte.overflow, !byteCount.overflow else { throw Error.outOfBoundsAccess }
    let endByte = startByte.partialValue.addingReportingOverflow(byteCount.partialValue)
    guard !endByte.overflow, endByte.partialValue <= checkedVolumeByteCount else {
      throw Error.outOfBoundsAccess
    }
    return startByte.partialValue..<endByte.partialValue
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
    let byteRange = try checkedByteRange(x: x, y: y, z: z, count: count)
    let totalBytes = byteRange.count

    // Ensure alignment with requested type
    guard totalBytes % MemoryLayout<T>.stride == 0 else {
      throw Error.incompatibleTypeSize
    }

    var result = [T](
      repeating: 0,
      count: totalBytes / MemoryLayout<T>.stride
    )
    if totalBytes > 0 {
      _ = result.withUnsafeMutableBytes { destination in
        memcpy(
          destination.baseAddress!,
          mappedMemory.advanced(by: byteRange.lowerBound),
          totalBytes
        )
      }
    }
    return result
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
    let byteRange = try checkedByteRange(x: x, y: y, z: z, count: count)

    // Prevent writes if read-only
    guard !readOnly else {
      throw Error.readOnlyAccessViolation
    }

    let totalBytes = byteRange.count

    // Verify provided data size
    let suppliedBytes = data.count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
    guard !suppliedBytes.overflow, suppliedBytes.partialValue == totalBytes else {
      throw Error.incompatibleTypeSize
    }

    // Copy data into mapped memory
    guard totalBytes > 0 else { return }
    let destination = mappedMemory.advanced(by: byteRange.lowerBound)
    _ = data.withUnsafeBytes { srcBuffer in
      memcpy(destination, srcBuffer.baseAddress!, totalBytes)
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
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
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
