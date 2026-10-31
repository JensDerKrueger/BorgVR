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
import Foundation

/// Parses uncompressed and V3D/V3E-compressed PVM, PVM2, and PVM3 volumes.
public final class PVMParser: VolumeFileParser {
  public enum Error: Swift.Error, LocalizedError {
    case fileReadFailed(underlying: Swift.Error?)
    case invalidHeader(String)
    case unsupportedComponentCount(Int)
    case truncatedData(expected: Int, actual: Int)
    case decompressionError(String)
    case temporaryFileWriteFailed(underlying: Swift.Error)

    public var errorDescription: String? {
      switch self {
        case .fileReadFailed(let underlying):
          return "Failed to read the PVM file: \(underlying?.localizedDescription ?? "unknown error")."
        case .invalidHeader(let reason):
          return "Invalid PVM header: \(reason)."
        case .unsupportedComponentCount(let count):
          return "Unsupported PVM component count: \(count)."
        case .truncatedData(let expected, let actual):
          return "The PVM voxel data is truncated (expected \(expected) bytes, found \(actual))."
        case .decompressionError(let reason):
          return "Could not decompress the PVM file: \(reason)."
        case .temporaryFileWriteFailed(let underlying):
          return "Could not prepare the PVM voxel data: \(underlying.localizedDescription)."
      }
    }
  }

  public let absoluteFilename: String
  public let size: Vec3<Int>
  public let voxelSpacing: Vec3<Float>
  public let bytesPerComponent: Int
  public let components: Int
  public let isLittleEndian: Bool
  public let offset: Int
  public let dataIsTempCopy: Bool

  /// Optional descriptive fields stored after the voxel payload in PVM3 files.
  public let datasetDescription: String?
  public let courtesy: String?
  public let parameters: String?
  public let comment: String?

  private static let ddsV3DSignature = Array("DDS v3d\n".utf8)
  private static let ddsV3ESignature = Array("DDS v3e\n".utf8)
  private static let v3EInterleaveBlock = 1 << 24
  private static let maximumDecodedBytes = 16 * 1024 * 1024 * 1024

  private struct ParsedHeader {
    let version: Int
    let size: Vec3<Int>
    let relativeSpacing: Vec3<Float>
    let storedComponents: Int
    let payloadOffset: Int
    let payloadBytes: Int
    let metadata: [String?]
  }

  private enum DDSWrapper {
    case none
    case v3D
    case v3E
  }

  public init(filename: String) throws {
    let originalData: Data
    do {
      originalData = try Data(contentsOf: URL(fileURLWithPath: filename), options: .mappedIfSafe)
    } catch {
      throw Error.fileReadFailed(underlying: error)
    }

    let sourceBytes = [UInt8](originalData)
    let (decodedBytes, wrapper) = try Self.decodeDDSIfNeeded(sourceBytes)
    let header = try Self.parseHeader(in: decodedBytes)

    self.size = header.size
    self.voxelSpacing = try Self.normalizedSpacing(
      header.relativeSpacing,
      volumeSize: header.size
    )

    switch header.storedComponents {
      case 1:
        self.bytesPerComponent = 1
        self.components = 1
      case 2:
        self.bytesPerComponent = 2
        self.components = 1
      case 3, 4:
        self.bytesPerComponent = 1
        self.components = header.storedComponents
      default:
        throw Error.unsupportedComponentCount(header.storedComponents)
    }

    self.isLittleEndian = true
    self.datasetDescription = header.metadata[0]
    self.courtesy = header.metadata[1]
    self.parameters = header.metadata[2]
    self.comment = header.metadata[3]

    let needsEndianConversion = bytesPerComponent == 2
    if wrapper == .none && !needsEndianConversion {
      self.absoluteFilename = filename
      self.offset = header.payloadOffset
      self.dataIsTempCopy = false
      return
    }

    var payload = Array(
      decodedBytes[header.payloadOffset..<(header.payloadOffset + header.payloadBytes)]
    )
    if needsEndianConversion {
      for index in stride(from: 0, to: payload.count, by: 2) {
        payload.swapAt(index, index + 1)
      }
    }

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("raw")
    do {
      try Data(payload).write(to: temporaryURL, options: .atomic)
    } catch {
      throw Error.temporaryFileWriteFailed(underlying: error)
    }
    self.absoluteFilename = temporaryURL.path
    self.offset = 0
    self.dataIsTempCopy = true
  }

  private static func normalizedSpacing(
    _ spacing: Vec3<Float>,
    volumeSize: Vec3<Int>
  ) throws -> Vec3<Float> {
    let extentX = spacing.x * Float(volumeSize.x)
    let extentY = spacing.y * Float(volumeSize.y)
    let extentZ = spacing.z * Float(volumeSize.z)
    let longestExtent = max(extentX, extentY, extentZ)
    guard longestExtent.isFinite, longestExtent > 0 else {
      throw Error.invalidHeader("voxel spacing must be finite and positive")
    }
    return Vec3(
      x: spacing.x / longestExtent,
      y: spacing.y / longestExtent,
      z: spacing.z / longestExtent
    )
  }

  private static func parseHeader(in bytes: [UInt8]) throws -> ParsedHeader {
    let version: Int
    var cursor: Int
    if bytes.starts(with: Array("PVM\n".utf8)) {
      version = 1
      cursor = 4
    } else if bytes.starts(with: Array("PVM2\n".utf8)) {
      version = 2
      cursor = 5
    } else if bytes.starts(with: Array("PVM3\n".utf8)) {
      version = 3
      cursor = 5
    } else {
      throw Error.invalidHeader("missing PVM, PVM2, or PVM3 signature")
    }

    func nextContentLine() throws -> String {
      while true {
        let line = try readLine(from: bytes, cursor: &cursor)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty && !line.hasPrefix("#") {
          return line
        }
      }
    }

    let dimensions = try parseIntegers(try nextContentLine(), count: 3, label: "dimensions")
    guard dimensions.allSatisfy({ $0 > 0 }) else {
      throw Error.invalidHeader("dimensions must be positive")
    }
    let volumeSize = Vec3(x: dimensions[0], y: dimensions[1], z: dimensions[2])

    let relativeSpacing: Vec3<Float>
    if version >= 2 {
      let spacing = try parseFloats(try nextContentLine(), count: 3, label: "voxel spacing")
      guard spacing.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw Error.invalidHeader("voxel spacing must be finite and positive")
      }
      relativeSpacing = Vec3(x: spacing[0], y: spacing[1], z: spacing[2])
    } else {
      relativeSpacing = Vec3(x: 1, y: 1, z: 1)
    }

    let componentValues = try parseIntegers(
      try nextContentLine(),
      count: 1,
      label: "component count"
    )
    let storedComponents = componentValues[0]
    guard storedComponents > 0 else {
      throw Error.invalidHeader("component count must be positive")
    }

    let voxelCount = try checkedProduct(dimensions, label: "volume dimensions")
    let payloadBytes = try checkedProduct(
      [voxelCount, storedComponents],
      label: "voxel payload size"
    )
    let (payloadEnd, overflow) = cursor.addingReportingOverflow(payloadBytes)
    guard !overflow else {
      throw Error.invalidHeader("voxel payload size overflows the platform integer range")
    }
    guard payloadEnd <= bytes.count else {
      throw Error.truncatedData(expected: payloadBytes, actual: max(0, bytes.count - cursor))
    }

    var metadata = Array<String?>(repeating: nil, count: 4)
    var trailingCursor = payloadEnd
    if version == 3 {
      for index in metadata.indices {
        metadata[index] = try readNullTerminatedString(from: bytes, cursor: &trailingCursor)
      }
    }
    guard trailingCursor == bytes.count else {
      throw Error.invalidHeader("unexpected data follows the PVM payload")
    }

    return ParsedHeader(
      version: version,
      size: volumeSize,
      relativeSpacing: relativeSpacing,
      storedComponents: storedComponents,
      payloadOffset: cursor,
      payloadBytes: payloadBytes,
      metadata: metadata
    )
  }

  private static func readLine(from bytes: [UInt8], cursor: inout Int) throws -> String {
    guard cursor < bytes.count,
          let end = bytes[cursor...].firstIndex(of: 0x0A) else {
      throw Error.invalidHeader("incomplete ASCII header")
    }
    var lineBytes = Array(bytes[cursor..<end])
    if lineBytes.last == 0x0D {
      lineBytes.removeLast()
    }
    guard lineBytes.allSatisfy({ $0 < 0x80 }) else {
      throw Error.invalidHeader("header contains non-ASCII bytes")
    }
    cursor = end + 1
    return String(decoding: lineBytes, as: UTF8.self)
  }

  private static func parseIntegers(
    _ line: String,
    count: Int,
    label: String
  ) throws -> [Int] {
    let fields = line.split(whereSeparator: { $0.isWhitespace })
    guard fields.count == count else {
      throw Error.invalidHeader("expected \(count) \(label) values")
    }
    let values = fields.compactMap { Int($0) }
    guard values.count == count else {
      throw Error.invalidHeader("invalid \(label)")
    }
    return values
  }

  private static func parseFloats(
    _ line: String,
    count: Int,
    label: String
  ) throws -> [Float] {
    let fields = line.split(whereSeparator: { $0.isWhitespace })
    guard fields.count == count else {
      throw Error.invalidHeader("expected \(count) \(label) values")
    }
    let values = fields.compactMap { Float($0) }
    guard values.count == count else {
      throw Error.invalidHeader("invalid \(label)")
    }
    return values
  }

  private static func checkedProduct(_ factors: [Int], label: String) throws -> Int {
    var result = 1
    for factor in factors {
      let (product, overflow) = result.multipliedReportingOverflow(by: factor)
      guard !overflow else {
        throw Error.invalidHeader("\(label) overflows the platform integer range")
      }
      result = product
    }
    return result
  }

  private static func readNullTerminatedString(
    from bytes: [UInt8],
    cursor: inout Int
  ) throws -> String? {
    guard cursor <= bytes.count,
          let end = bytes[cursor...].firstIndex(of: 0) else {
      throw Error.invalidHeader("PVM3 metadata is not NUL-terminated")
    }
    guard end - cursor <= 255 else {
      throw Error.invalidHeader("a PVM3 metadata field exceeds 255 bytes")
    }
    let value = String(decoding: bytes[cursor..<end], as: UTF8.self)
    cursor = end + 1
    return value.isEmpty ? nil : value
  }

  private static func decodeDDSIfNeeded(
    _ bytes: [UInt8]
  ) throws -> ([UInt8], DDSWrapper) {
    let wrapper: DDSWrapper
    let signatureLength: Int
    let blockSize: Int
    if bytes.starts(with: ddsV3DSignature) {
      wrapper = .v3D
      signatureLength = ddsV3DSignature.count
      blockSize = 0
    } else if bytes.starts(with: ddsV3ESignature) {
      wrapper = .v3E
      signatureLength = ddsV3ESignature.count
      blockSize = v3EInterleaveBlock
    } else {
      return (bytes, .none)
    }

    var compressed = Array(bytes.dropFirst(signatureLength))
    compressed.append(contentsOf: [0, 0, 0, 0])
    var reader = BitReader(bytes: compressed)
    let skip = try reader.read(2) + 1
    let strip = try reader.read(16) + 1
    var decoded: [UInt8] = []
    decoded.reserveCapacity(min(max(bytes.count * 2, 1 << 20), 256 << 20))
    var previous = 0

    while true {
      let runLength = try reader.read(7)
      if runLength == 0 {
        break
      }
      let encodedBits = try reader.read(3)
      let bitCount = encodedBits == 0 ? 0 : encodedBits + 1
      let midpoint = bitCount == 0 ? 0 : 1 << (bitCount - 1)

      for _ in 0..<runLength {
        let index = decoded.count
        let delta = try reader.read(bitCount) - midpoint
        let predictor: Int
        if strip == 1 || index <= strip {
          predictor = previous
        } else {
          predictor = previous
            + Int(decoded[index - strip])
            - Int(decoded[index - strip - 1])
        }
        let value = (predictor + delta) & 0xFF
        decoded.append(UInt8(value))
        previous = value
        if decoded.count > maximumDecodedBytes {
          throw Error.decompressionError("decoded data exceeds the 16 GiB safety limit")
        }
      }
    }

    return (deinterleave(decoded, skip: skip, blockSize: blockSize), wrapper)
  }

  private static func deinterleave(
    _ bytes: [UInt8],
    skip: Int,
    blockSize: Int
  ) -> [UInt8] {
    guard skip > 1, !bytes.isEmpty else { return bytes }

    let bytesPerBlock = blockSize == 0 ? bytes.count : skip * blockSize
    var result = Array(repeating: UInt8(0), count: bytes.count)
    var blockStart = 0
    while blockStart < bytes.count {
      let blockEnd = min(blockStart + bytesPerBlock, bytes.count)
      var source = blockStart
      for component in 0..<skip {
        var destination = blockStart + component
        while destination < blockEnd && source < blockEnd {
          result[destination] = bytes[source]
          destination += skip
          source += 1
        }
      }
      blockStart = blockEnd
    }
    return result
  }

  private struct BitReader {
    let bytes: [UInt8]
    var bitOffset = 0

    mutating func read(_ count: Int) throws -> Int {
      guard count >= 0, count <= 24,
            bitOffset <= bytes.count * 8 - count else {
        throw Error.decompressionError("unexpected end of DDS-compressed data")
      }
      guard count > 0 else { return 0 }

      var remaining = count
      var value = 0
      while remaining > 0 {
        let byteIndex = bitOffset / 8
        let bitIndex = bitOffset % 8
        let available = 8 - bitIndex
        let take = min(remaining, available)
        let shift = available - take
        let mask = (1 << take) - 1
        value = (value << take) | ((Int(bytes[byteIndex]) >> shift) & mask)
        bitOffset += take
        remaining -= take
      }
      return value
    }
  }
}
