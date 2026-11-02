import Foundation
import Compression

enum BORGVRComponentType: UInt8, Codable, Sendable {
  case unsignedInteger = 0
  case signedInteger = 1
  case floatingPoint = 2

  var valueTypeName: String {
    switch self {
      case .unsignedInteger: return "uint"
      case .signedInteger: return "int"
      case .floatingPoint: return "float"
    }
  }

  func representableRange(width: Int) -> [Double] {
    if self == .floatingPoint {
      let bound = width == 4 ? Double(Float.greatestFiniteMagnitude) : Double.greatestFiniteMagnitude
      return [-bound, bound]
    }
    return [self == .signedInteger ? -pow(2, Double(width * 8 - 1)) : 0,
      pow(2, Double(width * 8 - (self == .signedInteger ? 1 : 0))) - 1]
  }

  func validate(width: Int) throws {
    let widths = self == .floatingPoint ? [4, 8] : [1, 2, 4]
    guard widths.contains(width) else {
      throw BORGVRError.invalidValue(context: "component type", reason: "unsupported type/byte-width combination")
    }
  }

  func validate(_ range: BORGVRComponentRange, width: Int) throws {
    try validate(width: width)
    let lo = range.minimum, hi = range.maximum
    if self == .floatingPoint {
      guard (lo.isNaN && hi.isNaN) || (!lo.isNaN && !hi.isNaN && lo <= hi) else {
        throw BORGVRError.invalidValue(context: "value range", reason: "NaN must affect both bounds; otherwise bounds must be ordered")
      }
      if width == 4 {
        guard [lo, hi].allSatisfy({ $0.isNaN || Double(Float($0)) == $0 }) else {
          throw BORGVRError.invalidValue(context: "value range", reason: "bounds must be representable as Float32")
        }
      }
    } else {
      let bits = width * 8
      let minimum = self == .signedInteger ? -pow(2, Double(bits - 1)) : 0
      let maximum = pow(2, Double(self == .signedInteger ? bits - 1 : bits)) - 1
      guard lo.isFinite, hi.isFinite, lo <= hi, lo >= minimum, hi <= maximum,
            lo.rounded(.towardZero) == lo, hi.rounded(.towardZero) == hi else {
        throw BORGVRError.invalidValue(context: "value range", reason: "bounds must fit the declared integer type")
      }
    }
  }
}

extension BORGVRChannelInterpretation {
  func validate(componentCount: Int, type: BORGVRComponentType, width: Int) throws {
    guard self == .independentChannels
      || (type == .unsignedInteger && width == 1 && componentCount == (colorInterpretation == .rgb ? 3 : 4)) else {
      throw BORGVRError.invalidValue(context: "channel interpretation",
        reason: "RGB requires three unsigned 8-bit channels; RGBA requires four")
    }
  }
}

public struct BORGVRProvenanceEntry: Codable, Equatable, Sendable {
  /// Milliseconds since 1970-01-01T00:00:00Z, independent of local time zone.
  public let timestampMilliseconds: Int64
  public let text: String
  public var date: Date { Date(timeIntervalSince1970: Double(timestampMilliseconds) / 1000) }

  public init(timestampMilliseconds: Int64, text: String) {
    self.timestampMilliseconds = timestampMilliseconds
    self.text = text
  }

  public init(_ text: String, date: Date = Date()) {
    timestampMilliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
    self.text = text
  }

  public static func parseDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }
}

public enum BORGVRToolIdentification {
  public static var current: String {
    let info = Bundle.main.infoDictionary
    let name = info?["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    return "\(name) \(version)"
  }
}

// Both integer types through 32 bits and all Float32/Float64 values are lossless
// in Double. On disk, bounds always use the component's declared native width.
struct BORGVRComponentRange: Codable, Equatable, Sendable {
  let minimum: Double
  let maximum: Double

  init(minValue: Int, maxValue: Int) {
    minimum = Double(minValue)
    maximum = Double(maxValue)
  }

  init(minimum: Double, maximum: Double) {
    self.minimum = minimum
    self.maximum = maximum
  }

  // Compatibility accessors for the existing unsigned-only processing pipeline.
  var minValue: Int { Int(exactly: minimum)! }
  var maxValue: Int { Int(exactly: maximum)! }

  static func == (lhs: Self, rhs: Self) -> Bool {
    (lhs.minimum == rhs.minimum || lhs.minimum.isNaN && rhs.minimum.isNaN) &&
      (lhs.maximum == rhs.maximum || lhs.maximum.isNaN && rhs.maximum.isNaN)
  }

  static func union(_ ranges: [Self]) -> Self {
    if ranges.contains(where: { $0.minimum.isNaN || $0.maximum.isNaN }) {
      return Self(minimum: .nan, maximum: .nan)
    }
    return Self(minimum: ranges.map(\.minimum).min() ?? 0, maximum: ranges.map(\.maximum).max() ?? 0)
  }

  /// Include a sample, propagating NaN to both bounds and retaining infinities.
  func including(_ value: Double) -> Self {
    if value.isNaN || minimum.isNaN || maximum.isNaN { return Self(minimum: .nan, maximum: .nan) }
    return Self(minimum: min(minimum, value), maximum: max(maximum, value))
  }

  // Retain the existing JSON keys used by unsigned-only collaboration messages.
  private enum CodingKeys: String, CodingKey { case minValue, maxValue }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func read(_ key: CodingKeys) throws -> Double {
      if let n = try? c.decode(Double.self, forKey: key) { return n }
      switch try c.decode(String.self, forKey: key) {
        case "NaN": return .nan
        case "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: throw BORGVRError.invalidValue(context: "value range", reason: "invalid numeric value")
      }
    }
    minimum = try read(.minValue)
    maximum = try read(.maxValue)
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    for (key, value) in [(CodingKeys.minValue, minimum), (.maxValue, maximum)] {
      if value.isFinite { try c.encode(value, forKey: key) }
      else { try c.encode(value.isNaN ? "NaN" : value > 0 ? "+Infinity" : "-Infinity", forKey: key) }
    }
  }
}

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

  mutating func readScalar(type: BORGVRComponentType, width: Int) throws -> Double {
    let bits: UInt64
    switch width {
      case 1: bits = UInt64(try readInteger(UInt8.self, context: "scalar bound"))
      case 2: bits = UInt64(try readInteger(UInt16.self, context: "scalar bound"))
      case 4: bits = UInt64(try readInteger(UInt32.self, context: "scalar bound"))
      default: bits = try readInteger(UInt64.self, context: "scalar bound")
    }
    switch type {
      case .unsignedInteger: return Double(bits)
      case .signedInteger:
        return Double(Int64(bitPattern: bits << (64 - width * 8)) >> (64 - width * 8))
      case .floatingPoint:
        return width == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
    }
  }

  mutating func readRange(type: BORGVRComponentType, width: Int) throws -> BORGVRComponentRange {
    return BORGVRComponentRange(minimum: try readScalar(type: type, width: width),
      maximum: try readScalar(type: type, width: width))
  }

  mutating func readTextBlock() throws -> Data {
    let codec = try readInteger(UInt8.self, context: "text codec")
    let rawSize = try readInteger(UInt64.self, context: "text decoded size")
    let storedSize = try readInteger(UInt64.self, context: "text stored size")
    guard codec <= 1, rawSize <= BORGVRMetaData.maximumTextByteCount,
          storedSize <= BORGVRMetaData.maximumTextByteCount,
          codec != 0 || rawSize == storedSize, codec != 1 || rawSize > 0 && storedSize > 0 else {
      throw BORGVRError.invalidValue(context: "text block", reason: "invalid codec or length")
    }
    let stored = try readData(length: Int(storedSize), context: "text block")
    if codec == 0 { return stored }
    var decoded = Data(count: Int(rawSize))
    let count = decoded.withUnsafeMutableBytes { output in
      stored.withUnsafeBytes { input in
        compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, Int(rawSize),
          input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4_RAW)
      }
    }
    guard count == Int(rawSize) else { throw BORGVRError.other("Invalid LZ4 metadata text block.") }
    return decoded
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

private extension Data {
  mutating func appendRange(_ range: BORGVRComponentRange, type: BORGVRComponentType, width: Int) {
    for value in [range.minimum, range.maximum] {
      let bits: UInt64
      switch type {
        case .unsignedInteger: bits = UInt64(value)
        case .signedInteger: bits = UInt64(bitPattern: Int64(value))
        case .floatingPoint: bits = width == 4 ? UInt64(Float(value).bitPattern) : value.bitPattern
      }
      for byte in 0..<width { append(UInt8(truncatingIfNeeded: bits >> (byte * 8))) }
    }
  }

  mutating func appendTextBlock(_ raw: Data, compress: Bool) {
    var compressed = Data(count: raw.count)
    let count = compress && !raw.isEmpty ? compressed.withUnsafeMutableBytes { output in
      raw.withUnsafeBytes { input in
        compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
          input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_LZ4_RAW)
      }
    } : 0
    let useCompressed = count > 0 && count < raw.count
    append(useCompressed ? 1 : 0)
    append(Data(from: UInt64(raw.count)))
    append(Data(from: UInt64(useCompressed ? count : raw.count)))
    append(useCompressed ? compressed.prefix(count) : raw)
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
  var minValue: Int { valueRange.minValue }
  /// The maximum across all component ranges. TF visibility uses `componentRanges`.
  var maxValue: Int { valueRange.maxValue }
  let valueRange: BORGVRComponentRange
  /// Scalar component ranges, no ranges for RGB, or the alpha range for RGBA.
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
    self.valueRange = BORGVRComponentRange(minValue: minValue, maxValue: maxValue)
    self.componentRanges = componentRanges
  }

  /**
   Initializes a new `BrickMetadata` from the current position of a checked binary reader.

   - Parameter reader: The reader whose position is advanced past the brick record.
   - Throws: An error if the data is invalid or out of bounds.
   */
  init(offset: Int, size: Int, componentRanges: [BORGVRComponentRange]) {
    self.offset = offset
    self.size = size
    self.componentRanges = componentRanges
    valueRange = .union(componentRanges)
  }

  fileprivate init(from reader: inout BORGVRBinaryReader, componentCount: Int,
                   interpretation: BORGVRChannelInterpretation,
                   type: BORGVRComponentType, width: Int) throws {
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
    let aggregate = interpretation == .independentChannels
      ? try reader.readRange(type: type, width: width) : nil
    self.componentRanges = try (0..<interpretation.rangeCount(componentCount: componentCount)).map { _ in
      try reader.readRange(type: type, width: width)
    }
    self.valueRange = aggregate ?? .union(componentRanges)
  }

  /**
   Serializes the `BrickMetadata` into a `Data` object.

   - Returns: A `Data` instance with native-width component bounds and Int64 addressing.
   */
  func toData(type: BORGVRComponentType, width: Int,
              interpretation: BORGVRChannelInterpretation = .independentChannels) -> Data {
    var data = Data()
    data.append(Data(from: Int64(offset)))
    data.append(Data(from: Int64(size)))
    if interpretation == .independentChannels {
      data.appendRange(valueRange, type: type, width: width)
    }
    for range in componentRanges {
      data.appendRange(range, type: type, width: width)
    }
    return data
  }

  /// A textual description of the brick metadata for debugging purposes.
  public var description: String {
    return "(offset: \(offset), size: \(size), range: \(valueRange), componentRanges: \(componentRanges))"
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
  private static let version: Int = 5
  fileprivate static let maximumTextByteCount: UInt64 = 67_108_864
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
  private(set) var componentType: BORGVRComponentType = .unsignedInteger
  private(set) var channelInterpretation: BORGVRChannelInterpretation = .independentChannels
  var provenance: [BORGVRProvenanceEntry] = []
  var meta: String = ""
  var compressMetadataText = true

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
  var minValue: Int { valueRange.minValue }
  /// The maximum across all component ranges, used by scalar modes such as ISO.
  var maxValue: Int { valueRange.maxValue }
  private(set) var valueRange = BORGVRComponentRange(minValue: 0, maxValue: 0)
  /// Scalar component ranges, none for RGB, or the single alpha range for RGBA.
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
    let bounds = channelInterpretation.colorInterpretation == .rgb ? "not stored (RGB)"
      : "\(valueRange.minimum)/\(valueRange.maximum)\(channelInterpretation.colorInterpretation == .rgba ? " (alpha)" : "")"
    return """
    BORGVRMetaData: \(width)x\(height)x\(depth), \
    \(componentCount)×\(bytesPerComponent)-byte components, \
    brick size \(brickSize), overlap \(overlap), \
    compression: \(compression ? "yes" : "no"), \
    type: \(componentType), channels: \(channelInterpretation.name), min/max: \(bounds), \
    component ranges: \(componentRanges.map { "\($0.minimum)/\($0.maximum)" }.joined(separator: ", ")), \
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
    self.valueRange = BORGVRComponentRange(minValue: minValue, maxValue: maxValue)
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
    valueRange = BORGVRComponentRange(minValue: minValue, maxValue: maxValue)
  }

  func setComponentType(_ type: BORGVRComponentType, ranges: [BORGVRComponentRange]) throws {
    try type.validate(width: bytesPerComponent)
    try channelInterpretation.validate(componentCount: componentCount, type: type, width: bytesPerComponent)
    guard ranges.count == channelInterpretation.rangeCount(componentCount: componentCount) else {
      throw BORGVRError.other("Incorrect component range count.")
    }
    for range in ranges { try type.validate(range, width: bytesPerComponent) }
    componentType = type
    updateComponentRanges(ranges)
  }

  func setChannelInterpretation(_ interpretation: BORGVRChannelInterpretation) throws {
    try interpretation.validate(componentCount: componentCount, type: componentType, width: bytesPerComponent)
    channelInterpretation = interpretation
    if interpretation.colorInterpretation == .rgb {
      componentRanges = []
    } else if interpretation.colorInterpretation == .rgba, componentRanges.count == componentCount {
      componentRanges = [componentRanges[3]]
    }
    valueRange = .union(componentRanges)
  }

  func requireIndependentChannels() throws {
    guard channelInterpretation == .independentChannels else {
      throw BORGVRError.other("This operation requires independent scalar channels, not RGB/RGBA color data.")
    }
  }

  func requireUnsignedProcessing() throws {
    guard componentType == .unsignedInteger else {
      throw BORGVRError.other("Signed and floating-point datasets can be stored, but are not yet supported by this operation.")
    }
  }

  func editExportMetadata(editStateID: UUID? = nil, revision: UInt64? = nil) -> BORGVRMetaData {
    let copy = copyProperties()
    var operation = "Materialized volume edits into a new dataset; source dataset: \(uniqueID)"
    if let editStateID { operation += "; edit state: \(editStateID.uuidString)" }
    if let revision { operation += "; revision: \(revision)" }
    operation += "; tool: \(BORGVRToolIdentification.current)"
    copy.provenance.append(BORGVRProvenanceEntry(operation))
    return copy
  }

  // Share immutable properties without serializing or duplicating the brick payload.
  private func copyProperties() -> BORGVRMetaData {
    let copy = BORGVRMetaData(width: width, height: height, depth: depth,
      componentCount: componentCount, bytePerComponent: bytesPerComponent,
      voxelSpacingX: voxelSpacingX, voxelSpacingY: voxelSpacingY, voxelSpacingZ: voxelSpacingZ,
      brickSize: brickSize, overlap: overlap, minValue: 0, maxValue: 0,
      compression: compression, datasetDescription: datasetDescription, metaDescription: metaDescription)
    copy.componentType = componentType
    copy.channelInterpretation = channelInterpretation
    copy.updateComponentRanges(componentRanges)
    copy.provenance = provenance
    copy.meta = meta
    copy.compressMetadataText = compressMetadataText
    return copy
  }

  func cacheExportMetadata(sourceDescription: String) -> BORGVRMetaData {
    let copy = copyProperties()
    copy.uniqueID = uniqueID
    copy.brickMetadata = brickMetadata
    copy.provenance.append(BORGVRProvenanceEntry("Completed local download from \(sourceDescription)"))
    return copy
  }

  /// Provenance and descriptive text can differ between copies of the same data.
  /// Recovery requires identical voxel interpretation and stored brick addressing.
  func hasSameStoredVolume(as other: BORGVRMetaData) -> Bool {
    guard uniqueID == other.uniqueID, width == other.width, height == other.height, depth == other.depth,
      voxelSpacingX == other.voxelSpacingX, voxelSpacingY == other.voxelSpacingY, voxelSpacingZ == other.voxelSpacingZ,
      componentType == other.componentType, bytesPerComponent == other.bytesPerComponent,
      channelInterpretation == other.channelInterpretation,
      componentCount == other.componentCount, brickSize == other.brickSize, overlap == other.overlap,
      compression == other.compression, valueRange == other.valueRange, componentRanges == other.componentRanges,
      brickMetadata.count == other.brickMetadata.count else { return false }
    return zip(brickMetadata, other.brickMetadata).allSatisfy { a, b in
      a.offset == b.offset && a.size == b.size && a.valueRange == b.valueRange && a.componentRanges == b.componentRanges
    }
  }

  func updateComponentRanges(_ componentRanges: [BORGVRComponentRange]) {
    precondition(componentRanges.count == channelInterpretation.rangeCount(componentCount: componentCount))
    self.componentRanges = componentRanges
    self.valueRange = .union(componentRanges)
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
      count: channelInterpretation.rangeCount(componentCount: componentCount)
    )
    precondition(ranges.count == channelInterpretation.rangeCount(componentCount: componentCount))
    let brick = BrickMetadata(
      offset: offset,
      size: size,
      minValue: minValue,
      maxValue: maxValue,
      componentRanges: ranges
    )
    self.brickMetadata.append(brick)
  }

  func append(offset: Int, size: Int, componentRanges: [BORGVRComponentRange]) {
    precondition(componentRanges.count == channelInterpretation.rangeCount(componentCount: componentCount))
    brickMetadata.append(BrickMetadata(offset: offset, size: size, componentRanges: componentRanges))
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
    data.append(componentType.rawValue)
    data.append(channelInterpretation.rawValue)
    data.append(Data(from: voxelSpacingX))
    data.append(Data(from: voxelSpacingY))
    data.append(Data(from: voxelSpacingZ))
    data.append(Data(from: brickSize))
    data.append(Data(from: overlap))
    if channelInterpretation == .independentChannels {
      data.appendRange(valueRange, type: componentType, width: bytesPerComponent)
      data.append(Data(from: Int64(componentRanges.count)))
    }
    for range in componentRanges {
      data.appendRange(range, type: componentType, width: bytesPerComponent)
    }
    data.append(Data(from: compression))
    data.appendString(uniqueID)
    data.appendString(datasetDescription)
    data.appendString(metaDescription)
    var provenanceData = Data(from: UInt64(provenance.count))
    for entry in provenance {
      provenanceData.append(Data(from: entry.timestampMilliseconds))
      provenanceData.appendString(entry.text)
    }
    data.appendTextBlock(provenanceData, compress: compressMetadataText)
    data.appendTextBlock(Data(meta.utf8), compress: compressMetadataText)
    data.append(Data(from: Int64(brickMetadata.count)))
    let dataOffset: Int64 = 0
    data.append(Data(from: dataOffset))

    for brick in brickMetadata {
      data.append(brick.toData(type: componentType, width: bytesPerComponent,
        interpretation: channelInterpretation))
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
    try validateHeaderValues()
    guard provenance.count <= 65536,
      meta.utf8.count <= Int(Self.maximumTextByteCount),
      provenance.reduce(8, { $0 + 16 + $1.text.utf8.count }) <= Int(Self.maximumTextByteCount) else {
      throw BORGVRError.invalidValue(context: "metadata text", reason: "text block exceeds the size limit")
    }
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
    let rawType = try reader.readInteger(UInt8.self, context: "componentType")
    guard let type = BORGVRComponentType(rawValue: rawType) else {
      throw BORGVRError.invalidValue(context: "componentType", reason: "unknown component type")
    }
    componentType = type
    try componentType.validate(width: bytesPerComponent)
    let rawInterpretation = try reader.readInteger(UInt8.self, context: "channelInterpretation")
    guard let interpretation = BORGVRChannelInterpretation(rawValue: rawInterpretation) else {
      throw BORGVRError.invalidValue(context: "channelInterpretation", reason: "unknown channel interpretation")
    }
    channelInterpretation = interpretation
    try channelInterpretation.validate(componentCount: componentCount, type: componentType, width: bytesPerComponent)
    self.voxelSpacingX = try reader.readFloat(context: "voxelSpacingX")
    self.voxelSpacingY = try reader.readFloat(context: "voxelSpacingY")
    self.voxelSpacingZ = try reader.readFloat(context: "voxelSpacingZ")
    self.brickSize = try readInt("brickSize")
    self.overlap = try readInt("overlap")
    let aggregate = channelInterpretation == .independentChannels
      ? try reader.readRange(type: componentType, width: bytesPerComponent) : nil
    let expectedRanges = channelInterpretation.rangeCount(componentCount: componentCount)
    let componentRangeCount = channelInterpretation == .independentChannels
      ? try readInt("componentRangeCount") : expectedRanges
    guard componentCount > 0, componentCount <= Self.maximumComponentCount else {
      throw BORGVRError.invalidValue(context: "componentCount",
        reason: "must be in 1...\(Self.maximumComponentCount)")
    }
    guard componentRangeCount == expectedRanges else {
      throw BORGVRError.invalidValue(
        context: "componentRangeCount",
        reason: "expected \(componentCount), found \(componentRangeCount)"
      )
    }
    self.componentRanges = try (0..<componentRangeCount).map { _ in
      try reader.readRange(type: componentType, width: bytesPerComponent)
    }
    self.valueRange = aggregate ?? .union(componentRanges)
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
    provenance = []
    meta = ""
    do {
      var originReader = BORGVRBinaryReader(data: try reader.readTextBlock())
      let count = try originReader.readInteger(UInt64.self, context: "provenance count")
      guard count <= 65536, count <= UInt64(originReader.remainingCount / 16) else {
        throw BORGVRError.invalidValue(context: "provenance", reason: "invalid entry count")
      }
      for _ in 0..<count {
        let time = try originReader.readInteger(Int64.self, context: "provenance timestamp")
        let text = try originReader.readString(context: "provenance entry", maximumByteCount: Int(Self.maximumTextByteCount))
        provenance.append(BORGVRProvenanceEntry(timestampMilliseconds: time, text: text))
      }
      guard originReader.remainingCount == 0,
            let text = String(data: try reader.readTextBlock(), encoding: .utf8) else {
        throw BORGVRError.invalidValue(context: "metadata text", reason: "invalid UTF-8 or trailing provenance bytes")
      }
      meta = text
    }
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

    let rangeCount = expectedRanges + (channelInterpretation == .independentChannels ? 1 : 0)
    let brickMetadataRecordSize = 16 + 2 * rangeCount * bytesPerComponent
    let (metadataByteCount, metadataByteCountOverflow) = metadataCount.multipliedReportingOverflow(
      by: brickMetadataRecordSize
    )
    guard !metadataByteCountOverflow, metadataByteCount <= reader.remainingCount else {
      throw BORGVRError.unexpectedEndOfData(context: "brick metadata records")
    }

    self.brickMetadata = []
    self.brickMetadata.reserveCapacity(metadataCount)
    for _ in 0..<metadataCount {
      let brickMeta = try BrickMetadata(from: &reader, componentCount: componentCount,
        interpretation: channelInterpretation,
        type: componentType, width: bytesPerComponent)
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
    try componentType.validate(width: bytesPerComponent)
    try channelInterpretation.validate(componentCount: componentCount, type: componentType, width: bytesPerComponent)
    guard voxelSpacingX.isFinite, voxelSpacingX > 0,
          voxelSpacingY.isFinite, voxelSpacingY > 0,
          voxelSpacingZ.isFinite, voxelSpacingZ > 0 else {
      throw BORGVRError.invalidValue(
        context: "voxel spacing",
        reason: "all values must be finite and greater than zero"
      )
    }
    try componentType.validate(valueRange, width: bytesPerComponent)
    guard componentRanges.count == channelInterpretation.rangeCount(componentCount: componentCount) else {
      throw BORGVRError.invalidValue(
        context: "component ranges",
        reason: "must contain one range per component"
      )
    }
    for range in componentRanges {
      try componentType.validate(range, width: bytesPerComponent)
    }
    guard BORGVRComponentRange.union(componentRanges) == valueRange else {
      throw BORGVRError.invalidValue(
        context: "value range",
        reason: "must equal the union of the component ranges"
      )
    }
  }

  func fullBrickByteCount() throws -> Int {
    let block = channelInterpretation.astcBlockSize
    if block != 0 {
      _ = try voxelBrickByteCount()
      guard brickSize > 0, brickSize % block == 0 else {
        throw BORGVRError.invalidValue(context: "ASTC brick size", reason: "must be a multiple of the ASTC footprint")
      }
      return try checkedBrickByteCount([brickSize / block, brickSize / block, brickSize, 16])
    }
    return try voxelBrickByteCount()
  }

  func voxelBrickByteCount() throws -> Int {
    try checkedBrickByteCount([brickSize, brickSize, brickSize, componentCount, bytesPerComponent])
  }

  private func checkedBrickByteCount(_ factors: [Int]) throws -> Int {
    var count = 1
    for factor in factors {
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
    try componentType.validate(brick.valueRange, width: bytesPerComponent)
    guard brick.componentRanges.count == channelInterpretation.rangeCount(componentCount: componentCount) else {
      throw BORGVRError.invalidValue(
        context: "brick component ranges",
        reason: "must contain one range per component"
      )
    }
    for range in brick.componentRanges {
      try componentType.validate(range, width: bytesPerComponent)
    }
    guard BORGVRComponentRange.union(brick.componentRanges) == brick.valueRange else {
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
