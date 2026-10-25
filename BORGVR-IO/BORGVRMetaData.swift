import Foundation

// MARK: - BORGVRError

/**
 Typed errors for BORGVRMetaData and BrickMetadata parsing/serialization.
 */
enum BORGVRError: Swift.Error, LocalizedError {
  // Generic I/O / bounds
  case unexpectedEndOfData(context: String)
  case fileReadFailed(String)
  case fileWriteFailed(String)

  // Header validation
  case invalidMagicBytes
  case unsupportedVersion(found: Int64, expected: Int)

  // String / UUID issues
  case invalidStringEncoding
  case invalidUUID(String)
  case invalidValue(context: String, reason: String)

  // Other
  case other(String)

  var errorDescription: String? {
    switch self {
      case .unexpectedEndOfData(let ctx):
        return "Unexpected end of data while reading \(ctx)."
      case .fileReadFailed(let msg):
        return "Failed to read file: \(msg)"
      case .fileWriteFailed(let msg):
        return "Failed to write file: \(msg)"
      case .invalidMagicBytes:
        return "Invalid magic bytes in BORGVR metadata."
      case .unsupportedVersion(let found, let expected):
        return "Unsupported metadata version \(found). Expected \(expected)."
      case .invalidStringEncoding:
        return "Invalid UTF-8 string encoding in metadata."
      case .invalidUUID(let s):
        return "Invalid UUID string: \(s)"
      case .invalidValue(let context, let reason):
        return "Invalid \(context) in BORGVR metadata: \(reason)"
      case .other(let msg):
        return msg
    }
  }
}

// MARK: - Binary metadata reader

private struct BORGVRBinaryReader {
  let data: Data
  private(set) var offset: Int

  init(data: Data, offset: Int = 0) {
    self.data = data
    self.offset = offset
  }

  var remainingCount: Int {
    data.count - offset
  }

  mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type,
                                                   context: String) throws -> T {
    let byteCount = MemoryLayout<T>.size
    try require(byteCount, context: context)

    var value: T = 0
    let end = offset + byteCount
    _ = withUnsafeMutableBytes(of: &value) { destination in
      data.copyBytes(to: destination, from: offset..<end)
    }
    offset = end
    return T(littleEndian: value)
  }

  mutating func readFloat(context: String) throws -> Float {
    let bits: UInt32 = try readInteger(UInt32.self, context: context)
    return Float(bitPattern: bits)
  }

  mutating func readBool(context: String) throws -> Bool {
    let raw: UInt8 = try readInteger(UInt8.self, context: context)
    guard raw <= 1 else {
      throw BORGVRError.invalidValue(context: context,
                                     reason: "expected 0 or 1, found \(raw)")
    }
    return raw == 1
  }

  mutating func readData(length: Int, context: String) throws -> Data {
    try require(length, context: context)
    let end = offset + length
    let value = data.subdata(in: offset..<end)
    offset = end
    return value
  }

  mutating func readString(context: String, maximumByteCount: Int) throws -> String {
    let length64: Int64 = try readInteger(Int64.self, context: "\(context).length")
    guard length64 >= 0, let length = Int(exactly: length64) else {
      throw BORGVRError.invalidValue(context: "\(context).length",
                                     reason: "negative or not representable")
    }
    guard length <= maximumByteCount else {
      throw BORGVRError.invalidValue(context: "\(context).length",
                                     reason: "exceeds \(maximumByteCount) bytes")
    }
    let stringData = try readData(length: length, context: context)
    guard let string = String(data: stringData, encoding: .utf8) else {
      throw BORGVRError.invalidStringEncoding
    }
    return string
  }

  mutating func skip(_ count: Int, context: String) throws {
    try require(count, context: context)
    offset += count
  }

  private func require(_ count: Int, context: String) throws {
    guard count >= 0, offset >= 0, offset <= data.count,
          count <= data.count - offset else {
      throw BORGVRError.unexpectedEndOfData(context: context)
    }
  }
}

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
  /// The minimum across all component ranges. TF visibility uses `componentRanges`.
  let minValue: Int
  /// The maximum across all component ranges. TF visibility uses `componentRanges`.
  let maxValue: Int
  /// One value range per volume component.
  let componentRanges: [BORGVRComponentRange]

  /**
   Initializes a new `BrickMetadata` with all fields.

   - Parameter offset: The byte offset in the file where the brick’s data begins.
   - Parameter size: The size in bytes of the brick’s data.
   - Parameter minValue: The minimum intensity value.
   - Parameter maxValue: The maximum intensity value.
   */
  init(offset: Int,
       size: Int,
       minValue: Int,
       maxValue: Int,
       componentRanges: [BORGVRComponentRange]) {
    self.offset = offset
    self.size = size
    self.minValue = minValue
    self.maxValue = maxValue
    self.componentRanges = componentRanges
  }

  /**
   Initializes a new `BrickMetadata` from the current position of a checked binary reader.

   - Parameter reader: The reader whose position is advanced past the brick record.
   - Throws: An error if the data is invalid or out of bounds.
   */
  fileprivate init(from reader: inout BORGVRBinaryReader, componentCount: Int) throws {
    func intValue(_ rawValue: Int64, context: String) throws -> Int {
      guard let value = Int(exactly: rawValue) else {
        throw BORGVRError.invalidValue(context: context, reason: "not representable")
      }
      return value
    }

    self.offset = try intValue(
      reader.readInteger(Int64.self, context: "brick offset"),
      context: "brick offset"
    )
    self.size = try intValue(
      reader.readInteger(Int64.self, context: "brick size"),
      context: "brick size"
    )
    self.minValue = try intValue(
      reader.readInteger(Int64.self, context: "brick minValue"),
      context: "brick minValue"
    )
    self.maxValue = try intValue(
      reader.readInteger(Int64.self, context: "brick maxValue"),
      context: "brick maxValue"
    )
    self.componentRanges = try (0..<componentCount).map { component in
      BORGVRComponentRange(
        minValue: try intValue(
          reader.readInteger(Int64.self, context: "brick component \(component) minValue"),
          context: "brick component \(component) minValue"
        ),
        maxValue: try intValue(
          reader.readInteger(Int64.self, context: "brick component \(component) maxValue"),
          context: "brick component \(component) maxValue"
        )
      )
    }
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
    for range in componentRanges {
      data.append(Data(from: range.minValue))
      data.append(Data(from: range.maxValue))
    }
    return data
  }

  /// A textual description of the brick metadata for debugging purposes.
  public var description: String {
    return "(offset: \(offset), size: \(size), minValue: \(minValue), maxValue: \(maxValue), componentRanges: \(componentRanges))"
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

// MARK: - Component ranges

struct BORGVRComponentRange: Codable, Equatable, Sendable {
  let minValue: Int
  let maxValue: Int
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
  private static let version: Int = 4
  private static let maximumStringByteCount = 1_048_576
  static let maximumComponentCount = 1024
  private static let maximumDimension = Int(Int32.max)

  /// The original volume width.
  private(set) var width: Int = 0
  /// The original volume height.
  private(set) var height: Int = 0
  /// The original volume depth.
  private(set) var depth: Int = 0
  /// The physical spacing of one voxel along the x-axis.
  private(set) var voxelSpacingX: Float = 0
  /// The physical spacing of one voxel along the y-axis.
  private(set) var voxelSpacingY: Float = 0
  /// The physical spacing of one voxel along the z-axis.
  private(set) var voxelSpacingZ: Float = 0
  /// The number of components per voxel.
  private(set) var componentCount: Int = 0
  /// The number of bytes per component.
  private(set) var bytesPerComponent: Int = 0

  /// The physical extent of the complete volume in meters.
  var physicalExtentMeters: SIMD3<Float> {
    SIMD3<Float>(
      Float(width) * voxelSpacingX,
      Float(height) * voxelSpacingY,
      Float(depth) * voxelSpacingZ
    )
  }

  /// The maximum component value based on the number of bytes per component.
  var rangeMax: Int {
    switch bytesPerComponent {
      case 1:
        return Int(UInt8.max)
      case 2:
        return Int(UInt16.max)
      case 4:
        return Int(UInt32.max)
      default:
        return 0
    }
  }

  /// The brick size (in voxels).
  private(set) var brickSize: Int = 0
  /// The overlap (in voxels) between adjacent bricks.
  private(set) var overlap: Int = 0
  /// The minimum across all component ranges, used by scalar modes such as ISO.
  private(set) var minValue: Int = 0
  /// The maximum across all component ranges, used by scalar modes such as ISO.
  private(set) var maxValue: Int = 0
  /// The actual value range of each component.
  private(set) var componentRanges: [BORGVRComponentRange] = []
  /// A flag indicating whether compression is enabled.
  private(set) var compression: Bool = false
  /// A unique ID generated at time of creation
  var uniqueID: String = ""
  /// A short description of the dataset.
  var datasetDescription: String = ""
  /// A long description of the dataset.
  var metaDescription: String = ""

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
    component ranges: \(componentRanges.map { "\($0.minValue)/\($0.maxValue)" }.joined(separator: ", ")), \
    levels: \(levelMetadata.count), \
    bricks: \(brickMetadata.count), \
    label: “\(datasetDescription)”, \
    desc: “\(metaDescription)”, \
    uniqueID: “\(uniqueID)”
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
    precondition(size.x > 0 && size.y > 0 && size.z > 0,
                 "Volume dimensions must be positive.")
    precondition(brickSize > 0 && overlap >= 0 && overlap <= (brickSize - 1) / 2,
                 "Brick size must be greater than twice the overlap.")
    let effectiveSize = brickSize - 2 * overlap
    return Vec3<Int>(
      x: (size.x - 1) / effectiveSize + 1,
      y: (size.y - 1) / effectiveSize + 1,
      z: (size.z - 1) / effectiveSize + 1
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
    var maximumBrickCount = max(brickCount.x, brickCount.y, brickCount.z)
    var levelCount = 1
    while maximumBrickCount > 1 {
      maximumBrickCount = (maximumBrickCount + 1) / 2
      levelCount += 1
    }
    return levelCount
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
   - Parameter voxelSpacingX: The physical spacing of one voxel along the x-axis.
   - Parameter voxelSpacingY: The physical spacing of one voxel along the y-axis.
   - Parameter voxelSpacingZ: The physical spacing of one voxel along the z-axis.
   - Parameter brickSize: The brick size (in voxels).
   - Parameter overlap: The overlap between bricks (in voxels).
   - Parameter minValue: The minimum intensity value in the volume.
   - Parameter maxValue: The maximum intensity value in the volume.
   - Parameter compression: A Boolean flag indicating compression status.
   - Parameter description: A short description of the dataset.
   - Parameter metaDescription: A long description of the dataset.
   */
  init(width: Int,
       height: Int,
       depth: Int,
       componentCount: Int,
       bytePerComponent: Int,
       voxelSpacingX: Float,
       voxelSpacingY: Float,
       voxelSpacingZ: Float,
       brickSize: Int,
       overlap: Int,
       minValue: Int,
       maxValue: Int,
       compression: Bool,
       datasetDescription: String,
       metaDescription:String) {
    self.width = width
    self.height = height
    self.depth = depth
    self.componentCount = componentCount
    self.bytesPerComponent = bytePerComponent
    self.voxelSpacingX = voxelSpacingX
    self.voxelSpacingY = voxelSpacingY
    self.voxelSpacingZ = voxelSpacingZ
    self.brickSize = brickSize
    self.overlap = overlap
    self.minValue = minValue
    self.maxValue = maxValue
    self.componentRanges = Array(
      repeating: BORGVRComponentRange(minValue: minValue, maxValue: maxValue),
      count: componentCount
    )
    self.compression = compression
    self.datasetDescription = datasetDescription
    self.metaDescription = metaDescription
    self.uniqueID = UUID().uuidString

    computeLevelMetadata()
  }

  /**
   Initializes `BORGVRMetaData` by loading from a file.

   - Parameter filename: The file path from which to load the metadata.
   - Throws: An error if reading or parsing fails.
   */
  convenience init(filename: String) throws {
    try self.init(url: URL(fileURLWithPath: filename))
  }

  /**
   Initializes `BORGVRMetaData` by loading from a file.

   - Parameter url: The url from which to load the metadata.
   - Throws: An error if reading or parsing fails.
   */
  init(url: URL) throws {
    try self.load(url: url)
  }

  /**
   Initializes `BORGVRMetaData` by parsing from binary data.

   - Parameter fromData: The data blob containing serialized metadata.
   - Throws: An error if parsing fails.
   */
  init(fromData: Data) throws {
    try self.fromData(fromData)
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

  func editExportMetadata() -> BORGVRMetaData {
    // The output builds its own brick table; do not serialize and decode the
    // potentially enormous original table merely to copy the volume properties.
    let copy = BORGVRMetaData(width: width, height: height, depth: depth,
      componentCount: componentCount, bytePerComponent: bytesPerComponent,
      voxelSpacingX: voxelSpacingX, voxelSpacingY: voxelSpacingY, voxelSpacingZ: voxelSpacingZ,
      brickSize: brickSize, overlap: overlap, minValue: minValue, maxValue: maxValue,
      compression: compression, datasetDescription: datasetDescription, metaDescription: metaDescription)
    copy.updateComponentRanges(componentRanges)
    return copy
  }

  func updateComponentRanges(_ componentRanges: [BORGVRComponentRange]) {
    precondition(componentRanges.count == componentCount)
    self.componentRanges = componentRanges
    self.minValue = componentRanges.map(\.minValue).min() ?? 0
    self.maxValue = componentRanges.map(\.maxValue).max() ?? 0
  }

  // MARK: - Private Methods

  /**
   Computes and stores the level metadata for the bricked hierarchy.

   This method uses the volume dimensions and brick parameters to compute the size of each level
   and the number of bricks per level. It also computes a cumulative count of bricks from all previous levels.
   */
  func computeLevelMetadata() {
    do {
      let result = try BORGVRMetaData.makeLevelMetadata(
        width: width,
        height: height,
        depth: depth,
        brickSize: brickSize,
        overlap: overlap
      )
      self.levelMetadata = result.levels
    } catch {
      preconditionFailure("Invalid programmatically created BORGVR metadata: \(error.localizedDescription)")
    }
  }

  private static func makeLevelMetadata(width: Int,
                                        height: Int,
                                        depth: Int,
                                        brickSize: Int,
                                        overlap: Int) throws -> (levels: [LevelMetadata], brickCount: Int) {
    guard width > 0, height > 0, depth > 0,
          width <= maximumDimension,
          height <= maximumDimension,
          depth <= maximumDimension else {
      throw BORGVRError.invalidValue(
        context: "volume dimensions",
        reason: "each dimension must be in 1...\(maximumDimension)"
      )
    }
    guard brickSize > 0, brickSize <= maximumDimension else {
      throw BORGVRError.invalidValue(
        context: "brickSize",
        reason: "must be in 1...\(maximumDimension)"
      )
    }
    guard overlap >= 0, overlap <= (brickSize - 1) / 2 else {
      throw BORGVRError.invalidValue(
        context: "overlap",
        reason: "brickSize must be greater than twice the overlap"
      )
    }

    let size = Vec3<Int>(x: width, y: height, z: depth)
    let levelCount = calculateLevelCount(size: size, brickSize: brickSize, overlap: overlap)
    var levels: [LevelMetadata] = []
    levels.reserveCapacity(levelCount)
    var levelWidth = width
    var levelHeight = height
    var levelDepth = depth
    var prevBricks = 0
    for _ in 0..<levelCount {
      let nextLevel = LevelMetadata(levelWidth, levelHeight, levelDepth, brickSize, overlap, prevBricks)
      let (xyCount, xyOverflow) = nextLevel.totalBricks.x.multipliedReportingOverflow(
        by: nextLevel.totalBricks.y
      )
      let (levelBrickCount, xyzOverflow) = xyCount.multipliedReportingOverflow(
        by: nextLevel.totalBricks.z
      )
      let (nextBrickCount, sumOverflow) = prevBricks.addingReportingOverflow(levelBrickCount)
      guard !xyOverflow, !xyzOverflow, !sumOverflow else {
        throw BORGVRError.invalidValue(
          context: "brick hierarchy",
          reason: "brick count exceeds the supported integer range"
        )
      }

      levels.append(nextLevel)
      levelWidth = max(1, (levelWidth + 1) / 2)
      levelHeight = max(1, (levelHeight + 1) / 2)
      levelDepth = max(1, (levelDepth + 1) / 2)
      prevBricks = nextBrickCount
    }
    return (levels, prevBricks)
  }

  /**
   Appends a new `BrickMetadata` record to the metadata list.

   - Parameter offset: The byte offset in the file where brick data begins.
   - Parameter size: The size in bytes of the brick.
   - Parameter minValue: The minimum intensity value in the brick.
   - Parameter maxValue: The maximum intensity value in the brick.
   */
  func append(offset: Int,
              size: Int,
              minValue: Int,
              maxValue: Int,
              componentRanges: [BORGVRComponentRange]? = nil) {
    let ranges = componentRanges ?? Array(
      repeating: BORGVRComponentRange(minValue: minValue, maxValue: maxValue),
      count: componentCount
    )
    precondition(ranges.count == componentCount)
    let brick = BrickMetadata(
      offset: offset,
      size: size,
      minValue: minValue,
      maxValue: maxValue,
      componentRanges: ranges
    )
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
    data.append(Data(from: voxelSpacingX))
    data.append(Data(from: voxelSpacingY))
    data.append(Data(from: voxelSpacingZ))
    data.append(Data(from: brickSize))
    data.append(Data(from: overlap))
    data.append(Data(from: minValue))
    data.append(Data(from: maxValue))
    data.append(Data(from: Int64(componentRanges.count)))
    for range in componentRanges {
      data.append(Data(from: range.minValue))
      data.append(Data(from: range.maxValue))
    }
    data.append(Data(from: compression))
    data.appendString(uniqueID)
    data.appendString(datasetDescription)
    data.appendString(metaDescription)
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
    do {
      let fileHandle = try FileHandle(forWritingTo: fileURL)
      defer { try? fileHandle.close() }
      fileHandle.seekToEndOfFile()
      let binaryData = toData()
      fileHandle.write(binaryData)
    } catch {
      throw BORGVRError.fileWriteFailed(error.localizedDescription)
    }
  }

  /**
   Loads metadata from a file.

   Expects the file to begin with a header (magic bytes, version, volume parameters),
   followed by the raw data file name and a sequence of `BrickMetadata` records.

   - Parameter url: The url from which to load the metadata.
   - Throws: An error if the file cannot be read or if the data is invalid.
   */
  private func load(url: URL) throws {
    do {
      let fileHandle = try FileHandle(forReadingFrom: url)
      defer { fileHandle.closeFile() }

      let offsetData = try fileHandle.read(upToCount: 8)
      guard let offsetData, offsetData.count == 8 else {
        throw BORGVRError.fileReadFailed("Unable to read metadata offset (expected 8 bytes).")
      }
      var offsetReader = BORGVRBinaryReader(data: offsetData)
      let metadataOffset = try offsetReader.readInteger(UInt64.self, context: "metadata offset")
      let fileSize = try fileHandle.seekToEnd()
      guard metadataOffset >= 8, metadataOffset < fileSize else {
        throw BORGVRError.invalidValue(
          context: "metadata offset",
          reason: "must point inside the dataset file"
        )
      }

      try fileHandle.seek(toOffset: metadataOffset)
      let fileData = fileHandle.readDataToEndOfFile()
      try fromData(fileData, brickDataUpperBound: metadataOffset)
    } catch let e as BORGVRError {
      throw e
    } catch {
      throw BORGVRError.fileReadFailed(error.localizedDescription)
    }
  }

  /**
   Parses `BORGVRMetaData` from binary data.

   - Parameter data: The data blob containing serialized metadata.
   - Throws: An error if the data is invalid or incomplete.
   */
  func fromData(_ data: Data, brickDataUpperBound: UInt64? = nil) throws {
    var reader = BORGVRBinaryReader(data: data)

    func readInt(_ context: String) throws -> Int {
      let rawValue = try reader.readInteger(Int64.self, context: context)
      guard let value = Int(exactly: rawValue) else {
        throw BORGVRError.invalidValue(context: context, reason: "not representable")
      }
      return value
    }

    let magic = try reader.readData(length: BORGVRMetaData.magicBytes.count, context: "magicBytes")
    guard magic == BORGVRMetaData.magicBytes else {
      throw BORGVRError.invalidMagicBytes
    }

    let fileVersion = try reader.readInteger(Int64.self, context: "version")
    guard fileVersion == BORGVRMetaData.version else {
      throw BORGVRError.unsupportedVersion(found: fileVersion, expected: BORGVRMetaData.version)
    }

    self.width = try readInt("width")
    self.height = try readInt("height")
    self.depth = try readInt("depth")
    self.componentCount = try readInt("componentCount")
    self.bytesPerComponent = try readInt("bytesPerComponent")
    self.voxelSpacingX = try reader.readFloat(context: "voxelSpacingX")
    self.voxelSpacingY = try reader.readFloat(context: "voxelSpacingY")
    self.voxelSpacingZ = try reader.readFloat(context: "voxelSpacingZ")
    self.brickSize = try readInt("brickSize")
    self.overlap = try readInt("overlap")
    self.minValue = try readInt("minValue")
    self.maxValue = try readInt("maxValue")
    let componentRangeCount = try readInt("componentRangeCount")
    guard componentCount > 0, componentCount <= Self.maximumComponentCount else {
      throw BORGVRError.invalidValue(context: "componentCount",
        reason: "must be in 1...\(Self.maximumComponentCount)")
    }
    guard componentRangeCount == componentCount else {
      throw BORGVRError.invalidValue(
        context: "componentRangeCount",
        reason: "expected \(componentCount), found \(componentRangeCount)"
      )
    }
    self.componentRanges = try (0..<componentRangeCount).map { component in
      BORGVRComponentRange(
        minValue: try readInt("componentRanges[\(component)].minValue"),
        maxValue: try readInt("componentRanges[\(component)].maxValue")
      )
    }
    self.compression = try reader.readBool(context: "compression")

    try validateHeaderValues()
    let fullBrickByteCount = try self.fullBrickByteCount()
    let levelResult = try BORGVRMetaData.makeLevelMetadata(
      width: width,
      height: height,
      depth: depth,
      brickSize: brickSize,
      overlap: overlap
    )

    let uniqueIDStr = try reader.readString(
      context: "uniqueID",
      maximumByteCount: BORGVRMetaData.maximumStringByteCount
    )
    if UUID(uuidString: uniqueIDStr) != nil {
      self.uniqueID = uniqueIDStr
    } else {
      throw BORGVRError.invalidUUID(uniqueIDStr)
    }

    self.datasetDescription = try reader.readString(
      context: "datasetDescription",
      maximumByteCount: BORGVRMetaData.maximumStringByteCount
    )
    self.metaDescription = try reader.readString(
      context: "metaDescription",
      maximumByteCount: BORGVRMetaData.maximumStringByteCount
    )
    let metadataCount = try readInt("brickMetadataCount")
    let dataOffset = try readInt("brickDataOffset")

    guard metadataCount >= 0 else {
      throw BORGVRError.invalidValue(context: "brickMetadataCount", reason: "must not be negative")
    }
    guard metadataCount == levelResult.brickCount else {
      throw BORGVRError.invalidValue(
        context: "brickMetadataCount",
        reason: "expected \(levelResult.brickCount), found \(metadataCount)"
      )
    }
    guard dataOffset >= 0 else {
      throw BORGVRError.invalidValue(context: "brickDataOffset", reason: "must not be negative")
    }
    try reader.skip(dataOffset, context: "brickDataOffset")

    let brickMetadataRecordSize = (4 + 2 * componentCount) * MemoryLayout<Int64>.size
    let (metadataByteCount, metadataByteCountOverflow) = metadataCount.multipliedReportingOverflow(
      by: brickMetadataRecordSize
    )
    guard !metadataByteCountOverflow, metadataByteCount <= reader.remainingCount else {
      throw BORGVRError.unexpectedEndOfData(context: "brick metadata records")
    }

    self.brickMetadata = []
    self.brickMetadata.reserveCapacity(metadataCount)
    for _ in 0..<metadataCount {
      let brickMeta = try BrickMetadata(from: &reader, componentCount: componentCount)
      try validate(brick: brickMeta, fullBrickByteCount: fullBrickByteCount, brickDataUpperBound: brickDataUpperBound)
      self.brickMetadata.append(brickMeta)
    }
    self.levelMetadata = levelResult.levels
  }

  private func validateHeaderValues() throws {
    guard componentCount > 0, componentCount <= BORGVRMetaData.maximumComponentCount else {
      throw BORGVRError.invalidValue(
        context: "componentCount",
        reason: "must be in 1...\(BORGVRMetaData.maximumComponentCount)"
      )
    }
    guard bytesPerComponent == 1 || bytesPerComponent == 2 || bytesPerComponent == 4 else {
      throw BORGVRError.invalidValue(
        context: "bytesPerComponent",
        reason: "supported values are 1, 2, and 4"
      )
    }
    guard voxelSpacingX.isFinite, voxelSpacingX > 0,
          voxelSpacingY.isFinite, voxelSpacingY > 0,
          voxelSpacingZ.isFinite, voxelSpacingZ > 0 else {
      throw BORGVRError.invalidValue(
        context: "voxel spacing",
        reason: "all values must be finite and greater than zero"
      )
    }
    guard minValue >= 0, minValue <= maxValue, maxValue <= rangeMax else {
      throw BORGVRError.invalidValue(
        context: "value range",
        reason: "must be ordered and fit the declared component type"
      )
    }
    guard componentRanges.count == componentCount else {
      throw BORGVRError.invalidValue(
        context: "component ranges",
        reason: "must contain one range per component"
      )
    }
    for (component, range) in componentRanges.enumerated() {
      guard range.minValue >= 0,
            range.minValue <= range.maxValue,
            range.maxValue <= rangeMax else {
        throw BORGVRError.invalidValue(
          context: "component range \(component)",
          reason: "must be ordered and fit the declared component type"
        )
      }
    }
    guard componentRanges.map(\.minValue).min() == minValue,
          componentRanges.map(\.maxValue).max() == maxValue else {
      throw BORGVRError.invalidValue(
        context: "value range",
        reason: "must equal the union of the component ranges"
      )
    }
  }

  func fullBrickByteCount() throws -> Int {
    var count = 1
    for factor in [brickSize, brickSize, brickSize, componentCount, bytesPerComponent] {
      let (product, overflow) = count.multipliedReportingOverflow(by: factor)
      guard factor > 0, !overflow, product > 0 else {
        throw BORGVRError.invalidValue(context: "full brick size", reason: "byte count exceeds the supported integer range")
      }
      count = product
    }
    return count
  }

  func validateStoredBrickByteCount(_ count: Int, fullBrickByteCount: Int) throws {
    guard count > 0, count <= fullBrickByteCount, compression || count == fullBrickByteCount else {
      throw BORGVRError.invalidValue(context: "brick size",
        reason: "stored bytes must fit a full brick; uncompressed bricks must have exactly the full size")
    }
  }

  private func validate(brick: BrickMetadata, fullBrickByteCount: Int, brickDataUpperBound: UInt64?) throws {
    guard brick.offset >= 8 else {
      throw BORGVRError.invalidValue(context: "brick offset", reason: "must be at least 8")
    }
    try validateStoredBrickByteCount(brick.size, fullBrickByteCount: fullBrickByteCount)
    let (brickEnd, overflow) = brick.offset.addingReportingOverflow(brick.size)
    guard !overflow else {
      throw BORGVRError.invalidValue(context: "brick range", reason: "offset plus size overflows")
    }
    guard brick.minValue >= 0,
          brick.minValue <= brick.maxValue,
          brick.maxValue <= rangeMax else {
      throw BORGVRError.invalidValue(
        context: "brick value range",
        reason: "must be ordered and fit the declared component type"
      )
    }
    guard brick.componentRanges.count == componentCount else {
      throw BORGVRError.invalidValue(
        context: "brick component ranges",
        reason: "must contain one range per component"
      )
    }
    for (component, range) in brick.componentRanges.enumerated() {
      guard range.minValue >= 0,
            range.minValue <= range.maxValue,
            range.maxValue <= rangeMax else {
        throw BORGVRError.invalidValue(
          context: "brick component range \(component)",
          reason: "must be ordered and fit the declared component type"
        )
      }
    }
    guard brick.componentRanges.map(\.minValue).min() == brick.minValue,
          brick.componentRanges.map(\.maxValue).max() == brick.maxValue else {
      throw BORGVRError.invalidValue(
        context: "brick value range",
        reason: "must equal the union of the brick component ranges"
      )
    }
    if let brickDataUpperBound {
      guard UInt64(brickEnd) <= brickDataUpperBound else {
        throw BORGVRError.invalidValue(
          context: "brick range",
          reason: "extends into or beyond the metadata section"
        )
      }
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

// MARK: - Physical size formatting

enum PhysicalSizeFormatter {
  private struct Unit {
    let meters: Double
    let symbol: String
  }

  private static let kilometer = Unit(meters: 1000, symbol: "km")
  private static let meter = Unit(meters: 1, symbol: "m")
  private static let decimeter = Unit(meters: 1e-1, symbol: "dm")
  private static let centimeter = Unit(meters: 1e-2, symbol: "cm")
  private static let millimeter = Unit(meters: 1e-3, symbol: "mm")
  private static let micrometer = Unit(meters: 1e-6, symbol: "µm")
  private static let nanometer = Unit(meters: 1e-9, symbol: "nm")
  private static let picometer = Unit(meters: 1e-12, symbol: "pm")

  static func length(meters: Double, locale: Locale = .current) -> String? {
    guard meters.isFinite, meters >= 0 else { return nil }
    let unit = meters == 0 ? meter : preferredUnit(for: meters)
    guard let value = formattedNumber(meters / unit.meters, locale: locale) else {
      return nil
    }
    return "\(value) \(unit.symbol)"
  }

  static func area(squareMeters: Double, locale: Locale = .current) -> String? {
    guard squareMeters.isFinite, squareMeters >= 0 else { return nil }
    let unit = squareMeters == 0
      ? meter
      : preferredPoweredUnit(for: squareMeters, dimension: 2)
    guard let value = formattedNumber(
      squareMeters / (unit.meters * unit.meters),
      locale: locale
    ) else {
      return nil
    }
    return "\(value) \(unit.symbol)²"
  }

  static func volume(cubicMeters: Double, locale: Locale = .current) -> String? {
    guard cubicMeters.isFinite, cubicMeters >= 0 else { return nil }
    let unit = cubicMeters == 0
      ? meter
      : preferredPoweredUnit(for: cubicMeters, dimension: 3)
    guard let value = formattedNumber(
      cubicMeters / (unit.meters * unit.meters * unit.meters),
      locale: locale
    ) else {
      return nil
    }
    return "\(value) \(unit.symbol)³"
  }

  static func dimensions(
    widthMeters: Double,
    heightMeters: Double,
    depthMeters: Double,
    locale: Locale = .current
  ) -> String? {
    let dimensions = [widthMeters, heightMeters, depthMeters]
    guard dimensions.allSatisfy({ $0.isFinite && $0 >= 0 }),
          let maximum = dimensions.max(), maximum > 0 else {
      return nil
    }

    let unit = preferredUnit(for: maximum)
    let values = dimensions.compactMap {
      formattedNumber($0 / unit.meters, locale: locale)
    }
    guard values.count == dimensions.count else { return nil }
    return "\(values.joined(separator: " × ")) \(unit.symbol)"
  }

  static func dimensions(
    width: Int,
    height: Int,
    depth: Int,
    voxelSpacingX: Float,
    voxelSpacingY: Float,
    voxelSpacingZ: Float,
    locale: Locale = .current
  ) -> String? {
    dimensions(
      widthMeters: Double(width) * Double(voxelSpacingX),
      heightMeters: Double(height) * Double(voxelSpacingY),
      depthMeters: Double(depth) * Double(voxelSpacingZ),
      locale: locale
    )
  }

  static func dimensions(for metadata: BORGVRMetaData, locale: Locale = .current) -> String? {
    dimensions(
      width: metadata.width,
      height: metadata.height,
      depth: metadata.depth,
      voxelSpacingX: metadata.voxelSpacingX,
      voxelSpacingY: metadata.voxelSpacingY,
      voxelSpacingZ: metadata.voxelSpacingZ,
      locale: locale
    )
  }

  private static func preferredUnit(for meters: Double) -> Unit {
    switch meters {
      case 1000...:
        return kilometer
      case 1...:
        return meter
      case 1e-2...:
        return centimeter
      case 1e-3...:
        return millimeter
      case 1e-6...:
        return micrometer
      case 1e-9...:
        return nanometer
      default:
        return picometer
    }
  }

  private static func preferredPoweredUnit(
    for valueInMeters: Double,
    dimension: Int
  ) -> Unit {
    let units = [kilometer, meter, decimeter, centimeter, millimeter,
                 micrometer, nanometer, picometer]
    return units.first { unit in
      valueInMeters / pow(unit.meters, Double(dimension)) >= 0.1
    } ?? picometer
  }

  private static func formattedNumber(_ value: Double, locale: Locale) -> String? {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesSignificantDigits = true
    formatter.minimumSignificantDigits = 1
    formatter.maximumSignificantDigits = 4
    return formatter.string(from: NSNumber(value: value))
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
