import Foundation
import Compression

/**
 A parser for NRRD (Nearly Raw Raster Data) volume files that conforms to the `VolumeFileParser` protocol.

 This parser reads the header information from an NRRD file, extracts dataset parameters such as volume size,
 spacing, type, and encoding, and prepares the file for volume data extraction (including decompression and
 endian conversion when necessary).
 */
public final class NRRDParser: VolumeFileParser {

  // MARK: - Error Enumeration

  /**
   Errors that can occur while parsing NRRD files.

   These errors cover issues such as file read failures, invalid headers, missing or invalid keys,
   decompression errors, unsupported encodings, and other parsing issues.
   */
  public enum Error: Swift.Error, LocalizedError {
    /// The file could not be read; includes the underlying error if available.
    case fileReadFailed(underlying: Swift.Error?)
    /// The NRRD header is invalid or unsupported.
    case invalidHeader
    /// A required header key is missing.
    case missingKey(String)
    /// A header key has an invalid value.
    case invalidValue(String)
    /// A generic parsing error with associated message.
    case otherError(String)
    /// An error occurred during decompression.
    case decompressionError(String)
    /// An encoding or feature is not yet implemented.
    case notImplemented(String)

    /// A localized description of the error.
    public var errorDescription: String? {
      switch self {
        case .fileReadFailed(let underlying):
          return "Failed to read the NRRD file: \(underlying?.localizedDescription ?? "unknown error")."
        case .invalidHeader:
          return "Invalid or unsupported NRRD header."
        case .missingKey(let key):
          return "Missing required header key: \(key)."
        case .invalidValue(let key):
          return "Invalid value for key: \(key)."
        case .otherError(let msg):
          return "Other error reading NRRD: \(msg)."
        case .decompressionError(let msg):
          return "Error decompressing the data: \(msg)."
        case .notImplemented(let enc):
          return "Unsupported encoding: \(enc)."
      }
    }
  }

  // MARK: - VolumeFileParser Conformance Properties

  /// The absolute path to the NRRD file.
  public let absoluteFilename: String
  /// The dimensions of the volume (in voxels) along x, y, z.
  public let size: Vec3<Int>
  /// The physical spacing (slice thickness) along x, y, z.
  public let sliceThickness: Vec3<Float>
  /// The number of bytes per data component (e.g., 1 for 8-bit, 2 for 16-bit).
  public let bytesPerComponent: Int
  /// The number of components per voxel.
  public let components: Int
  /// `true` if the data is stored in little-endian format.
  public let isLittleEndian: Bool
  /// Byte offset within the file where voxel data begins.
  public let offset: Int
  /// `true` if `absoluteFilename` points to a temporary copy created during parsing.
  public let dataIsTempCopy: Bool

  // MARK: - Initialization

  /**
   Initializes a new `NRRDParser` by reading and parsing the specified NRRD file header.

   This initializer loads the entire file into memory, parses header lines,
   validates required keys (such as dimension, sizes, spacings, type, encoding,
   and endianness), and prepares for data extraction. If the encoding is
   compressed, ASCII, or requires endian swapping, a temporary converted copy
   is created.

   - Parameter filename: The path to the NRRD file.
   - Throws: `NRRDParser.Error` if file cannot be read, header is invalid,
   required keys are missing or invalid, decompression fails, or
   an unsupported encoding is encountered.
   */
  public init(filename: String) throws {
    let fileURL = URL(fileURLWithPath: filename)
    let fileData: Data
    do {
      fileData = try Data(contentsOf: fileURL)
    } catch {
      throw Error.fileReadFailed(underlying: error)
    }

    // Verify the file starts with "NRRD"
    guard let contentString = String(data: fileData, encoding: .ascii),
          contentString.starts(with: "NRRD") else {
      throw Error.invalidHeader
    }

    // Split header into lines
    let lines = contentString.split(omittingEmptySubsequences: false) { $0.isNewline }

    var headerDict = [String: String]()
    var headerByteLength = 0
    var encounteredEmptyLine = false

    // Parse header lines until blank line
    for line in lines {
      let lineStr = String(line)
      headerByteLength += lineStr.utf8.count + 1
      if lineStr.trimmingCharacters(in: .whitespaces).isEmpty {
        encounteredEmptyLine = true
        break
      }
      if lineStr.starts(with: "#") { continue } // Skip comments
      let parts = lineStr.split(separator: ":", maxSplits: 1)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      if parts.count == 2 {
        headerDict[parts[0].lowercased()] = parts[1]
      }
    }

    // Ensure header ended properly or external data file specified
    guard encounteredEmptyLine || headerDict["data file"] != nil else {
      throw Error.invalidHeader
    }

    // Parse and validate dimension
    guard let dimensionStr = headerDict["dimension"],
          let dimension = Int(dimensionStr), dimension == 3 else {
      throw Error.invalidValue("dimension")
    }

    // Parse sizes
    guard let sizesStr = headerDict["sizes"] else {
      throw Error.missingKey("sizes")
    }
    let sizes = sizesStr.split(separator: " ").compactMap { Int($0) }
    guard sizes.count == 3 else {
      throw Error.invalidValue("sizes")
    }
    self.size = Vec3(x: sizes[0], y: sizes[1], z: sizes[2])

    // Parse spacings or space directions
    guard let spacingsStr = headerDict["spacings"] ?? headerDict["space directions"] else {
      throw Error.missingKey("spacings or space directions")
    }
    let spacingValues: [Float]
    if spacingsStr.contains("(") {
      spacingValues = spacingsStr
        .split(separator: ")")
        .compactMap { part in
          part.split(separator: "(").last?
            .split(separator: ",")
            .map { Float($0.trimmingCharacters(in: .whitespaces)) ?? 0.0 }
            .max()
        }
    } else {
      spacingValues = spacingsStr.split(separator: " ").compactMap { Float($0) }
    }
    guard spacingValues.count == 3 else {
      throw Error.invalidValue("spacings/space directions")
    }
    self.sliceThickness = Vec3(x: spacingValues[0], y: spacingValues[1], z: spacingValues[2])

    // Parse data type and components
    guard let typeStr = headerDict["type"] else {
      throw Error.missingKey("type")
    }
    self.bytesPerComponent = try Self.bytesPerComponent(for: typeStr)
    self.components = Int(headerDict["component"] ?? "1") ?? 1

    // Determine endianness
    let declaredEndian = headerDict["endian"]?.lowercased() ?? "little"
    self.isLittleEndian = (declaredEndian == "little")

    // Determine encoding and compression
    let encoding = headerDict["encoding"]?.lowercased() ?? "raw"
    let isCompressed = encoding != "raw"
    let needsEndianSwap = (declaredEndian == "big")

    // Determine data source (detached or inline)
    let isDetached = headerDict["data file"] != nil
    let dataFilePath: String
    let nrrdOffset: Int
    if isDetached {
      let relative = headerDict["data file"]!
      let headerDir = fileURL.deletingLastPathComponent()
      let dataURL = headerDir.appendingPathComponent(relative)
      dataFilePath = dataURL.path
      nrrdOffset = 0
    } else {
      nrrdOffset = headerByteLength
      dataFilePath = filename
    }

    // Compute expected data size
    let voxelCount = size.x * size.y * size.z * components
    let expectedBytes = voxelCount * bytesPerComponent
    let dataNeedsConversion = isCompressed || encoding == "ascii" || needsEndianSwap

    if !dataNeedsConversion {
      // No conversion needed: use file directly
      self.absoluteFilename = dataFilePath
      self.dataIsTempCopy = false
      self.offset = nrrdOffset
    } else {
      // Conversion required: decompress, parse ASCII, or swap endian
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      var fullData: Data
      if isDetached {
        fullData = try Data(contentsOf: URL(fileURLWithPath: dataFilePath))
      } else {
        fullData = fileData.subdata(in: nrrdOffset..<fileData.count)
      }

      // Handle compression
      if isCompressed {
        guard encoding == "gzip" || encoding == "gz" else {
          throw Error.notImplemented(encoding)
        }
        fullData = try NRRDParser.decompressGzip(data: fullData)
        guard fullData.count == expectedBytes else {
          throw Error.otherError("Data length \(fullData.count) does not match expected \(expectedBytes) bytes")
        }
      }

      // Handle ASCII encoding
      if encoding == "ascii" {
        let asciiString = String(data: fullData, encoding: .ascii) ?? ""
        let values = asciiString
          .split { $0.isWhitespace || $0 == "," }
          .compactMap { UInt32(Double($0) ?? -1) }
        var buffer = Data(capacity: expectedBytes)
        for value in values {
          switch bytesPerComponent {
            case 1:
              buffer.append(UInt8(value & 0xFF))
            case 2:
              var v = UInt16(value)
              if needsEndianSwap { v = v.byteSwapped }
              buffer.append(contentsOf: withUnsafeBytes(of: v) { Array($0) })
            case 4:
              var v = UInt32(value)
              if needsEndianSwap { v = v.byteSwapped }
              buffer.append(contentsOf: withUnsafeBytes(of: v) { Array($0) })
            default:
              throw Error.invalidValue("Unsupported bytes per component for ASCII: \(bytesPerComponent)")
          }
        }
        fullData = buffer
      } else if needsEndianSwap {
        // Swap endianness in-place
        var buffer = Data(capacity: expectedBytes)
        for i in stride(from: 0, to: expectedBytes, by: bytesPerComponent) {
          let chunk = fullData[i..<i+bytesPerComponent]
          buffer.append(contentsOf: chunk.reversed())
        }
        fullData = buffer
      }

      try fullData.write(to: tempURL)
      self.absoluteFilename = tempURL.path
      self.dataIsTempCopy = true
      self.offset = 0
    }
  }

  // MARK: - Helper Methods

  /**
   Returns the number of bytes per component for a given NRRD data type string.

   - Parameter nrrdType: The string representation of the NRRD data type.
   - Throws: `Error.invalidValue` if the type is unrecognized.
   */
  private static func bytesPerComponent(for nrrdType: String) throws -> Int {
    switch nrrdType.lowercased() {
      case "signed char", "int8", "int8_t", "uchar", "unsigned char", "uint8", "uint8_t":
        return 1
      case "short", "short int", "signed short", "signed short int", "int16", "int16_t",
        "ushort", "unsigned short", "unsigned short int", "uint16", "uint16_t":
        return 2
      case "int", "signed int", "int32", "int32_t", "uint", "unsigned int", "uint32", "uint32_t":
        return 4
      case "long long", "long long int", "signed long long", "signed long long int", "int64", "int64_t",
        "ulonglong", "unsigned long long", "unsigned long long int", "uint64", "uint64_t":
        return 8
      default:
        throw Error.invalidValue("type")
    }
  }

  /**
   Decompresses GZIP-compressed data using the Compression framework.

   - Parameter data: The compressed input data.
   - Returns: The decompressed output data.
   - Throws: `Error.decompressionError` if decompression fails.
   */
  static func decompressGzip(data: Data) throws -> Data {
    let bufferSize = 64 * 1024

    return try data.withUnsafeBytes { (sourcePointer: UnsafeRawBufferPointer) throws -> Data in
      guard let src = sourcePointer.baseAddress else {
        throw Error.decompressionError("source pointer is nil")
      }

      var stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1).pointee
      var status = compression_stream_init(
        &stream,
        COMPRESSION_STREAM_DECODE,
        COMPRESSION_ZLIB
      )
      guard status != COMPRESSION_STATUS_ERROR else {
        throw Error.decompressionError("compression_stream_init failed")
      }
      defer { compression_stream_destroy(&stream) }

      let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
      defer { dstBuffer.deallocate() }

      stream.src_ptr  = src.assumingMemoryBound(to: UInt8.self)
      stream.src_size = data.count
      stream.dst_ptr  = dstBuffer
      stream.dst_size = bufferSize

      var output = Data()

      while status == COMPRESSION_STATUS_OK {
        status = compression_stream_process(&stream, 0)
        switch status {
          case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
            let count = bufferSize - stream.dst_size
            output.append(dstBuffer, count: count)
            stream.dst_ptr  = dstBuffer
            stream.dst_size = bufferSize
          default:
            throw Error.decompressionError("unexpected compression status \(status)")
        }
      }

      return output
    }
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
