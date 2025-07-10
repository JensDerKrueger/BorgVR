/// A protocol for accessing and modifying volume data as generic fixed-width integers.
///
/// Conforming types provide methods to read and write blocks of voxel data at specified coordinates.
/// - Note: `getData` and `setData` methods operate in voxel units, not raw byte offsets.
public protocol VolumeDataAccessing {

  /// Retrieves a block of volume data as an array of type `T`, starting at the specified voxel coordinate.
  ///
  /// - Parameters:
  ///   - x: The x-coordinate of the starting voxel.
  ///   - y: The y-coordinate of the starting voxel.
  ///   - z: The z-coordinate of the starting voxel.
  ///   - count: The number of voxels to read.
  /// - Returns: An array of values of type `T` containing the requested data.
  /// - Throws: An error if data retrieval fails (e.g., out-of-bounds, mapping errors, or incompatible type size).
  func getData<T: FixedWidthInteger>(x: Int, y: Int, z: Int, count: Int) throws -> [T]

  /// Writes a block of volume data from an array of type `T`, starting at the specified voxel coordinate.
  ///
  /// - Parameters:
  ///   - x: The x-coordinate of the starting voxel.
  ///   - y: The y-coordinate of the starting voxel.
  ///   - z: The z-coordinate of the starting voxel.
  ///   - data: An array of values of type `T` to be written.
  ///   - count: The number of voxels to write.
  /// - Throws: An error if data writing fails (e.g., out-of-bounds, read-only violation, or incompatible type size).
  func setData<T: FixedWidthInteger>(x: Int, y: Int, z: Int, data: [T], count: Int) throws
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
