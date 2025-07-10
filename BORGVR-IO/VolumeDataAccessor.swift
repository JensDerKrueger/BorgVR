import Foundation

// MARK: - VolumeDataAccessor

/**
 A base class for accessing volume data, conforming to the `VolumeDataAccessing` protocol.

 Provides common properties and utilities (such as index calculation) that subclasses
 can use when implementing specific volume data access (e.g., memory-mapped file access).
 */
public class VolumeDataAccessor: VolumeDataAccessing, CustomStringConvertible {

  // MARK: - Error Type

  /**
   Errors related to volume data access operations.

   - outOfBoundsAccess: Thrown when attempting to read/write outside the valid voxel coordinates.
   - readOnlyAccessViolation: Thrown when attempting to write while in read-only mode.
   */
  public enum Error: Swift.Error, LocalizedError {
    case outOfBoundsAccess
    case readOnlyAccessViolation

    /// Human-readable error description.
    public var errorDescription: String? {
      switch self {
        case .outOfBoundsAccess:
          return "Attempted to access data out of bounds."
        case .readOnlyAccessViolation:
          return "Attempted to write to a file opened in read-only mode."
      }
    }
  }

  // MARK: - Properties

  /// The dimensions of the volume in voxels (x, y, z).
  public let size: Vec3<Int>

  /// The number of bytes used to represent a single data component.
  public let bytesPerComponent: Int

  /// The number of components in each voxel.
  public let componentCount: Int

  /// The aspect-ratio (physical spacing) of the volume along each axis.
  public let aspect: Vec3<Float>

  /// Indicates whether the volume is opened in read-only mode.
  public let readOnly: Bool

  /// The total number of voxels in the volume.
  public var totalVoxels: Int {
    return size.x * size.y * size.z
  }

  /// The number of bytes used to represent a single voxel.
  public var voxelByteSize: Int {
    return bytesPerComponent * componentCount
  }

  /// The total number of bytes used to store the entire volume.
  public var totalBytes: Int {
    return totalVoxels * voxelByteSize
  }

  // MARK: - Initialization

  /**
   Initializes a new volume data accessor.

   - Parameters:
   - size: The dimensions of the volume in voxels.
   - bytesPerComponent: The number of bytes for each data component.
   - componentCount: The number of components per voxel.
   - aspect: The aspect-ratio (spacing) of the volume along each axis.
   - readOnly: A Boolean indicating whether the volume is read-only.
   */
  public init(
    size: Vec3<Int>,
    bytesPerComponent: Int,
    componentCount: Int,
    aspect: Vec3<Float>,
    readOnly: Bool
  ) {
    self.size = size
    self.bytesPerComponent = bytesPerComponent
    self.componentCount = componentCount

    // Normalize the aspect-ratio to prevent zero or extreme values.
    let maxAspect = max(aspect.x, aspect.y, aspect.z)
    if maxAspect == 0 {
      self.aspect = Vec3<Float>(x: 1, y: 1, z: 1)
    } else {
      self.aspect = Vec3<Float>(
        x: aspect.x / maxAspect,
        y: aspect.y / maxAspect,
        z: aspect.z / maxAspect
      )
    }

    self.readOnly = readOnly
  }

  // MARK: - Index Calculation

  /**
   Computes the linear byte offset for a voxel at the given (x, y, z) coordinate.

   Uses row-major order: z * (height * width) + y * width + x, then multiplied by bytes per voxel.

   - Parameters:
   - x: The x-coordinate (column).
   - y: The y-coordinate (row).
   - z: The z-coordinate (slice index).
   - Returns: The byte offset within the volume data.
   */
  @inlinable
  public func calculateIndex(x: Int, y: Int, z: Int) -> Int {
    return ((z * size.y * size.x) + (y * size.x) + x) * voxelByteSize
  }

  // MARK: - Data Access (Abstract)

  /**
   Retrieves a block of volume data as an array of type `T`, starting at the specified voxel coordinate.

   - Parameters:
   - x: The x-coordinate of the starting voxel.
   - y: The y-coordinate of the starting voxel.
   - z: The z-coordinate of the starting voxel.
   - count: The number of voxels to read (default is `1`).
   - Returns: An array of `T` containing the requested data.
   - Throws: An error if data retrieval fails.
   - Note: Subclasses **must** override this method to provide actual data access.
   */
  public func getData<T: FixedWidthInteger>(
    x: Int, y: Int, z: Int, count: Int = 1
  ) throws -> [T] {
    fatalError("getData(x:y:z:count:) must be overridden by subclass")
  }

  /**
   Writes a block of volume data from an array of type `T`, starting at the specified voxel coordinate.

   - Parameters:
   - x: The x-coordinate of the starting voxel.
   - y: The y-coordinate of the starting voxel.
   - z: The z-coordinate of the starting voxel.
   - data: An array of `T` representing the data to write.
   - count: The number of voxels to write (default is `1`).
   - Throws: An error if data writing fails.
   - Note: Subclasses **must** override this method to provide actual data writing.
   */
  public func setData<T: FixedWidthInteger>(
    x: Int, y: Int, z: Int, data: [T], count: Int = 1
  ) throws {
    fatalError("setData(x:y:z:data:count:) must be overridden by subclass")
  }

  // MARK: - CustomStringConvertible

  /// A textual description of the volume data accessor.
  public var description: String {
    return "Volume(size: \(size), bytesPerComponent: \(bytesPerComponent), components: \(componentCount))"
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
