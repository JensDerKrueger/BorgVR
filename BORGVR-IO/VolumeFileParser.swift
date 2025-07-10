/**
 A protocol that defines the interface for a volume file parser.

 Conforming types must provide properties describing the volume file's location, dimensions, data layout,
 and endianness. This protocol abstracts the parsing of different volume file formats
 so they can be accessed uniformly.
 */
public protocol VolumeFileParser {

  /// The absolute path to the volume file on disk.
  var absoluteFilename: String { get }

  /// The dimensions of the volume in voxels, as (width, height, depth).
  var size: Vec3<Int> { get }

  /// The physical spacing (slice thickness) along each axis (x, y, z).
  var sliceThickness: Vec3<Float> { get }

  /// The number of bytes used to represent a single data component (e.g., 1 for 8-bit, 2 for 16-bit).
  var bytesPerComponent: Int { get }

  /// The number of components per voxel (e.g., 1 for grayscale, 3 for RGB).
  var components: Int { get }

  /// `true` if the file data is stored in little-endian byte order; otherwise, big-endian.
  var isLittleEndian: Bool { get }

  /// The byte offset within the file where the raw voxel data begins.
  var offset: Int { get }

  /// `true` if the parser created a temporary copy of the data; otherwise, `false`.
  var dataIsTempCopy: Bool { get }
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
