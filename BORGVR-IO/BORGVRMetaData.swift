import Foundation

// MARK: - BrickMetadata

/**
 Holds metadata for a single brick (subvolume) in a volumetric dataset.

 The metadata includes the file offset and size for the brick’s data,
 the minimum and maximum intensity values (determined from non-zero occurrences).

 This class supports both direct initialization and binary I/O via a FileHandle.
 It conforms to `Codable` for easy serialization and `CustomStringConvertible` for debugging.
 */
final class BrickMetadata: Codable, CustomStringConvertible {

  /// The byte offset in the file where this brick’s data begins.
  let offset: Int
  /// The size in bytes of this brick’s data.
  let size: Int
  /// The minimum intensity value that appears (first histogram bin with non-zero count).
  let minValue: Int
  /// The maximum intensity value that appears (last histogram bin with non-zero count).
  let maxValue: Int

  /**
   Initializes a new `BrickMetadata` with all fields.

   - Parameter offset: The byte offset in the file where the brick’s data begins.
   - Parameter size: The size in bytes of the brick’s data.
   - Parameter minValue: The minimum intensity value.
   - Parameter maxValue: The maximum intensity value.
   */
  init(offset: Int, size: Int, minValue: Int, maxValue: Int) {
    self.offset = offset
    self.size = size
    self.minValue = minValue
    self.maxValue = maxValue
  }

  /**
   Initializes a new `BrickMetadata` by reading from a binary data blob.

   - Parameter data: The data blob containing serialized metadata.
   - Parameter offset: On input, the byte offset in `data` at which to start reading; advanced past read bytes.
   - Parameter componentCount: The number of components per voxel (unused by this class).
   - Throws: An error if the data is invalid or out of bounds.
   */
  init(fromData data: Data, offset: inout Int, componentCount: Int) throws {
    func read<T: FixedWidthInteger>() throws -> T {
      guard offset + MemoryLayout<T>.size <= data.count else {
        throw NSError(domain: "BrickMetadata", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected end of data"])
      }

      let value = data.loadLE(at: offset) as T
      offset += MemoryLayout<T>.size
      return value
    }

    self.offset   = Int(try read() as Int64)
    self.size     = Int(try read() as Int64)
    self.minValue = Int(try read() as Int64)
    self.maxValue = Int(try read() as Int64)
  }

  /**
   Serializes the `BrickMetadata` into a `Data` object.

   - Returns: A `Data` instance containing the serialized metadata as Int64 values.
   */
  func toData() -> Data {
    var data = Data()
    data.append(Data(from: Int64(offset)))
    data.append(Data(from: Int64(size)))
    data.append(Data(from: Int64(minValue)))
    data.append(Data(from: Int64(maxValue)))
    return data
  }

  /// A textual description of the brick metadata for debugging purposes.
  public var description: String {
    return "(offset: \(offset), size: \(size), minValue: \(minValue), maxValue: \(maxValue))"
  }
}

// MARK: - LevelMetadata

/**
 Holds metadata for one level in the bricked hierarchy.

 This class stores the volume size at this level and computes the number of bricks along each dimension,
 as well as a cumulative count of bricks from all lower levels (used to index into the full brick metadata array).
 */
final class LevelMetadata: Codable, CustomStringConvertible {
  /// The size dimensions (width, height, depth) of the volume at this level.
  private(set) var size: Vec3<Int>
  /// The number of bricks along each dimension at this level.
  private(set) var totalBricks: Vec3<Int>
  /// The cumulative number of bricks in all lower levels.
  private(set) var prevBricks: Int

  /**
   Initializes `LevelMetadata` for a given resolution level.

   - Parameter width: The width of the volume at this level.
   - Parameter height: The height of the volume at this level.
   - Parameter depth: The depth of the volume at this level.
   - Parameter brickSize: The size of each brick in voxels.
   - Parameter overlap: The overlap between adjacent bricks in voxels.
   - Parameter prevBricks: The cumulative count of bricks from all previous levels.
   */
  init(_ width: Int, _ height: Int, _ depth: Int, _ brickSize: Int, _ overlap: Int, _ prevBricks: Int) {
    self.size = Vec3<Int>(x: width, y: height, z: depth)
    self.prevBricks = prevBricks
    self.totalBricks = BORGVRMetaData.calculateOutputBrickCount(size: self.size, brickSize: brickSize, overlap: overlap)
  }

  /// A textual description of the level metadata.
  public var description: String {
    return "Size: \(size), bricks: \(totalBricks), previous bricks: \(prevBricks)"
  }
}

// MARK: - BORGVRMetaData

/**
 Represents the overall metadata for a volumetric dataset organized in a bricked hierarchy.

 This metadata includes the original volume dimensions, component details, brick parameters,
 the raw data file name, as well as per-level and per-brick metadata.

 The class provides static methods to compute the number of bricks, the number of levels,
 and the maximum output file size required to store all brick data.
 */
final class BORGVRMetaData: CustomStringConvertible, Codable {
  /// Magic bytes used for file identification.
  private static let magicBytes = "BORGVR".data(using: .utf8)!
  /// The version of the metadata format.
  private static let version: Int = 1

  /// The original volume width.
  private(set) var width: Int = 0
  /// The original volume height.
  private(set) var height: Int = 0
  /// The original volume depth.
  private(set) var depth: Int = 0
  /// The x-axis voxel aspect ratio.
  private(set) var aspectX: Float = 0
  /// The y-axis voxel aspect ratio.
  private(set) var aspectY: Float = 0
  /// The z-axis voxel aspect ratio.
  private(set) var aspectZ: Float = 0
  /// The number of components per voxel.
  private(set) var componentCount: Int = 0
  /// The number of bytes per component.
  private(set) var bytesPerComponent: Int = 0

  /// The maximum component value based on the number of bytes per component.
  var rangeMax: Int {
    get {
      return (1 << (bytesPerComponent * 8)) - 1
    }
  }

  /// The brick size (in voxels).
  private(set) var brickSize: Int = 0
  /// The overlap (in voxels) between adjacent bricks.
  private(set) var overlap: Int = 0
  /// The minimum intensity value in the volume.
  private(set) var minValue: Int = 0
  /// The maximum intensity value in the volume.
  private(set) var maxValue: Int = 0
  /// A flag indicating whether compression is enabled.
  private(set) var compression: Bool = false
  /// A short description of the dataset.
  var datasetDescription: String = ""

  /// An array containing metadata for each level in the bricked hierarchy.
  private(set) var levelMetadata: [LevelMetadata] = []
  /// An array containing metadata for each brick across all levels.
  private(set) var brickMetadata: [BrickMetadata] = []

  /// A textual description of the  metadata for debugging purposes.
  var description: String {
    return """
    BORGVRMetaData: \(width)x\(height)x\(depth), \
    \(componentCount)×\(bytesPerComponent)-byte components, \
    brick size \(brickSize), overlap \(overlap), \
    compression: \(compression ? "yes" : "no"), \
    min/max: \(minValue)/\(maxValue), \
    levels: \(levelMetadata.count), \
    bricks: \(brickMetadata.count), \
    label: “\(datasetDescription)”
    """
  }

  // MARK: - Static Helper Methods

  /**
   Computes the number of bricks along each dimension for a given volume size.

   - Parameter size: The volume size as a `Vec3<Int>`.
   - Parameter brickSize: The brick size (in voxels).
   - Parameter overlap: The overlap (in voxels) between bricks.
   - Returns: A `Vec3<Int>` indicating the number of bricks along each dimension.
   */
  static func calculateOutputBrickCount(size: Vec3<Int>, brickSize: Int, overlap: Int) -> Vec3<Int> {
    let effectiveSize = brickSize - 2 * overlap
    return Vec3<Int>(
      x: (size.x + effectiveSize - 1) / effectiveSize,
      y: (size.y + effectiveSize - 1) / effectiveSize,
      z: (size.z + effectiveSize - 1) / effectiveSize
    )
  }

  /**
   Computes the number of levels required in the bricked hierarchy.

   - Parameter size: The volume size as a `Vec3<Int>`.
   - Parameter brickSize: The brick size (in voxels).
   - Parameter overlap: The overlap (in voxels) between bricks.
   - Returns: The total number of levels.
   */
  static func calculateLevelCount(size: Vec3<Int>, brickSize: Int, overlap: Int) -> Int {
    let brickCount = calculateOutputBrickCount(size: size, brickSize: brickSize, overlap: overlap)
    return 1 + Int(ceil(log2(Double(max(brickCount.x, brickCount.y, brickCount.z)))))
  }

  /**
   Estimates the maximum output file size required to store all brick data for the hierarchy.

   - Parameter size: The volume size as a `Vec3<Int>`.
   - Parameter brickSize: The brick size (in voxels).
   - Parameter overlap: The overlap (in voxels) between bricks.
   - Parameter elemSize: The number of bytes per voxel.
   - Returns: The estimated maximum file size in bytes.
   */
  static func calculateMaxOutputFileSize(size: Vec3<Int>,
                                         brickSize: Int,
                                         overlap: Int,
                                         elemSize: Int) -> Int {
    var brickCount = calculateOutputBrickCount(size: size, brickSize: brickSize, overlap: overlap)
    let levelCount = calculateLevelCount(size: size, brickSize: brickSize, overlap: overlap)
    let brickVolume = brickSize * brickSize * brickSize * elemSize

    var fileSize = brickCount.x * brickCount.y * brickCount.z * brickVolume
    for _ in 1...levelCount {
      brickCount.x = (brickCount.x + 1) / 2
      brickCount.y = (brickCount.y + 1) / 2
      brickCount.z = (brickCount.z + 1) / 2
      fileSize += brickCount.x * brickCount.y * brickCount.z * brickVolume
    }
    return fileSize + 8 // eight bytes for the offset to the metadata
  }

  // MARK: - Initialization

  /**
   Initializes a new `BORGVRMetaData` instance with explicit parameters.

   - Parameter width: The original volume width.
   - Parameter height: The original volume height.
   - Parameter depth: The original volume depth.
   - Parameter componentCount: The number of components per voxel.
   - Parameter bytePerComponent: The number of bytes per component.
   - Parameter aspectX: The x-axis voxel aspect ratio.
   - Parameter aspectY: The y-axis voxel aspect ratio.
   - Parameter aspectZ: The z-axis voxel aspect ratio.
   - Parameter brickSize: The brick size (in voxels).
   - Parameter overlap: The overlap between bricks (in voxels).
   - Parameter minValue: The minimum intensity value in the volume.
   - Parameter maxValue: The maximum intensity value in the volume.
   - Parameter compression: A Boolean flag indicating compression status.
   - Parameter description: A short description of the dataset.
   */
  init(width: Int,
       height: Int,
       depth: Int,
       componentCount: Int,
       bytePerComponent: Int,
       aspectX: Float,
       aspectY: Float,
       aspectZ: Float,
       brickSize: Int,
       overlap: Int,
       minValue: Int,
       maxValue: Int,
       compression: Bool,
       datasetDescription: String) {
    self.width = width
    self.height = height
    self.depth = depth
    self.componentCount = componentCount
    self.bytesPerComponent = bytePerComponent
    self.aspectX = aspectX
    self.aspectY = aspectY
    self.aspectZ = aspectZ
    self.brickSize = brickSize
    self.overlap = overlap
    self.minValue = minValue
    self.maxValue = maxValue
    self.compression = compression
    self.datasetDescription = datasetDescription

    computeLevelMetadata()
  }

  /**
   Initializes `BORGVRMetaData` by loading from a file.

   - Parameter filename: The file path from which to load the metadata.
   - Throws: An error if reading or parsing fails.
   */
  init(filename: String) throws {
    try self.load(filename: filename)
  }

  /**
   Initializes `BORGVRMetaData` by parsing from binary data.

   - Parameter fromData: The data blob containing serialized metadata.
   - Throws: An error if parsing fails.
   */
  init(fromData: Data) throws {
    try self.fromData(fromData)
    computeLevelMetadata()
  }

  /**
   Updates the stored minimum and maximum intensity values.

   - Parameter minValue: The new minimum intensity.
   - Parameter maxValue: The new maximum intensity.
   */
  func updateMinMax(minValue: Int, maxValue: Int) {
    self.minValue = minValue
    self.maxValue = maxValue
  }

  // MARK: - Private Methods

  /**
   Computes and stores the level metadata for the bricked hierarchy.

   This method uses the volume dimensions and brick parameters to compute the size of each level
   and the number of bricks per level. It also computes a cumulative count of bricks from all previous levels.
   */
  func computeLevelMetadata() {
    self.levelMetadata.removeAll()
    let size = Vec3<Int>(x: width, y: height, z: depth)
    let levelCount = BORGVRMetaData.calculateLevelCount(size: size, brickSize: brickSize, overlap: overlap)
    var levelWidth = width
    var levelHeight = height
    var levelDepth = depth
    var prevBricks = 0
    for _ in 0..<levelCount {
      let nextLevel = LevelMetadata(levelWidth, levelHeight, levelDepth, brickSize, overlap, prevBricks)
      self.levelMetadata.append(nextLevel)
      levelWidth /= 2
      levelHeight /= 2
      levelDepth /= 2
      prevBricks += nextLevel.totalBricks.x * nextLevel.totalBricks.y * nextLevel.totalBricks.z
    }
  }

  /**
   Appends a new `BrickMetadata` record to the metadata list.

   - Parameter offset: The byte offset in the file where brick data begins.
   - Parameter size: The size in bytes of the brick.
   - Parameter minValue: The minimum intensity value in the brick.
   - Parameter maxValue: The maximum intensity value in the brick.
   */
  func append(offset: Int, size: Int, minValue: Int, maxValue: Int) {
    let brick = BrickMetadata(offset: offset, size: size, minValue: minValue, maxValue: maxValue)
    self.brickMetadata.append(brick)
  }

  /**
   Serializes the `BORGVRMetaData` into a `Data` object.

   - Returns: A `Data` object representing the serialized metadata.
   */
  func toData() -> Data {
    var data = Data()
    data.append(BORGVRMetaData.magicBytes)
    data.append(Data(from: BORGVRMetaData.version))
    data.append(Data(from: width))
    data.append(Data(from: height))
    data.append(Data(from: depth))
    data.append(Data(from: componentCount))
    data.append(Data(from: bytesPerComponent))
    data.append(Data(from: aspectX))
    data.append(Data(from: aspectY))
    data.append(Data(from: aspectZ))
    data.append(Data(from: brickSize))
    data.append(Data(from: overlap))
    data.append(Data(from: minValue))
    data.append(Data(from: maxValue))
    data.append(Data(from: compression))
    data.appendString(datasetDescription)
    data.append(Data(from: Int64(brickMetadata.count)))
    let dataOffset: Int64 = 0
    data.append(Data(from: dataOffset))

    for brick in brickMetadata {
      data.append(brick.toData())
    }
    return data
  }

  /**
   Saves the metadata to a file.

   The file format starts with a header (magic bytes, version, and volume parameters),
   followed by the raw data file name and the serialized brick metadata records.

   - Parameter filename: The file path to which the metadata is written.
   - Throws: An error if writing to the file fails.
   */
  func save(filename: String) throws {
    let fileURL = URL(fileURLWithPath: filename)
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }
    fileHandle.seekToEndOfFile()
    let binaryData = toData()
    fileHandle.write(binaryData)
  }

  /**
   Loads metadata from a file.

   Expects the file to begin with a header (magic bytes, version, volume parameters),
   followed by the raw data file name and a sequence of `BrickMetadata` records.

   - Parameter filename: The file path from which to load the metadata.
   - Throws: An error if the file cannot be read or if the data is invalid.
   */
  func load(filename: String) throws {
    let fileURL = URL(fileURLWithPath: filename)
    let fileHandle = try FileHandle(forReadingFrom: fileURL)
    defer { fileHandle.closeFile() }

    let offset = try fileHandle.read(upToCount: 8)
    guard let offset = offset, offset.count == 8 else {
      throw NSError(domain: "Load error", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to read offset"])
    }
    let offsetMetaData = offset.withUnsafeBytes { $0.load(as: UInt64.self) }
    try fileHandle.seek(toOffset: offsetMetaData)
    let fileData = fileHandle.readDataToEndOfFile()
    try fromData(fileData)
  }

  /**
   Parses `BORGVRMetaData` from binary data.

   - Parameter data: The data blob containing serialized metadata.
   - Throws: An error if the data is invalid or incomplete.
   */
  func fromData(_ data: Data) throws {
    var offset = 0

    func read<T>(_ type: T.Type) throws -> T {
      guard offset + MemoryLayout<T>.size <= data.count else {
        throw NSError(domain: "BORGVRMetaData", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected end of data"])
      }
      var value: T!
      let valueData = data.subdata(in: offset..<offset + MemoryLayout<T>.size)
      valueData.withUnsafeBytes { rawBuffer in
        value = rawBuffer.load(as: T.self)
      }
      offset += MemoryLayout<T>.size
      return value
    }

    func readData(length: Int) throws -> Data {
      guard offset + length <= data.count else {
        throw NSError(domain: "BORGVRMetaData", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Unexpected end of data"])
      }
      let value = data.subdata(in: offset..<offset + length)
      offset += length
      return value
    }

    func readString() throws -> String {
      let length: Int64 = try read(Int64.self)
      let stringData = try readData(length: Int(length))
      guard let string = String(data: stringData, encoding: .utf8) else {
        throw NSError(domain: "BORGVRMetaData", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Invalid string encoding"])
      }
      return string
    }

    let magic = try readData(length: BORGVRMetaData.magicBytes.count)
    guard magic == BORGVRMetaData.magicBytes else {
      throw NSError(domain: "BORGVRMetaData", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid magic bytes"])
    }

    let fileVersion: Int64 = try read(Int64.self)
    guard fileVersion == BORGVRMetaData.version else {
      throw NSError(domain: "BORGVRMetaData", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported version"])
    }

    self.width            = Int(try read(Int64.self))
    self.height           = Int(try read(Int64.self))
    self.depth            = Int(try read(Int64.self))
    self.componentCount   = Int(try read(Int64.self))
    self.bytesPerComponent = Int(try read(Int64.self))
    self.aspectX          = try read(Float.self)
    self.aspectY          = try read(Float.self)
    self.aspectZ          = try read(Float.self)
    self.brickSize        = Int(try read(Int64.self))
    self.overlap          = Int(try read(Int64.self))
    self.minValue         = Int(try read(Int64.self))
    self.maxValue         = Int(try read(Int64.self))
    self.compression      = try read(Bool.self)
    self.datasetDescription = try readString()
    let metadataCount     = Int(try read(Int64.self))
    let dataOffset        = Int(try read(Int64.self))

    computeLevelMetadata()

    if dataOffset > 0 {
      offset += dataOffset
    }

    self.brickMetadata = []
    for _ in 0..<metadataCount {
      let brickMeta = try BrickMetadata(fromData: data, offset: &offset, componentCount: componentCount)
      self.brickMetadata.append(brickMeta)
    }
  }

  /**
   Retrieves the `BrickMetadata` for a brick at the specified level and (x, y, z) index.

   - Parameter level: The level in the bricked hierarchy.
   - Parameter x: The x-coordinate index of the brick.
   - Parameter y: The y-coordinate index of the brick.
   - Parameter z: The z-coordinate index of the brick.
   - Returns: The corresponding `BrickMetadata`.
   */
  public func getBrickMetadata(level: Int, x: Int, y: Int, z: Int) -> BrickMetadata {
    let levelMeta = levelMetadata[level]
    let index = levelMeta.prevBricks
    + x
    + y * levelMeta.totalBricks.x
    + z * levelMeta.totalBricks.x * levelMeta.totalBricks.y
    return brickMetadata[index]
  }

  /**
   Retrieves the `BrickMetadata` for a brick at the specified linear index.

   - Parameter index: The 1D brick index.
   - Returns: The corresponding `BrickMetadata`.
   */
  public func getBrickMetadata(index: Int) -> BrickMetadata {
    return brickMetadata[index]
  }
}

extension Data {
  /**
   Appends a UTF-8 string to the `Data` instance, prefixed by its 64-bit length.

   - Parameter string: The string to append.
   */
  mutating func appendString(_ string: String) {
    let utf8Data = string.data(using: .utf8)!
    let length = Int64(utf8Data.count)
    self.append(Data(from: length))
    self.append(utf8Data)
  }

  /// Loads a value of type `T` from the given byte offset.
  func load<T>(at offset: Int, as type: T.Type = T.self) -> T {
    var value: T!
    let valueData = self.subdata(in: offset..<offset + MemoryLayout<T>.size)
    valueData.withUnsafeBytes { rawBuffer in
      value = rawBuffer.load(as: T.self)
    }
    return value
  }

  /// Loads a little-endian integer from the given offset.
  func loadLE<T: FixedWidthInteger>(at offset: Int) -> T {
    T(littleEndian: load(at: offset))
  }

  /// Loads a big-endian integer from the given offset.
  func loadBE<T: FixedWidthInteger>(at offset: Int) -> T {
    T(bigEndian: load(at: offset))
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
