import Foundation

// MARK: - QVISParser

/**
 Parses a QVIS header file and extracts metadata for a volumetric dataset.

 The header file is expected to be an ASCII text file containing key-value pairs,
 one per line, where keys and values are separated by a colon (`:`). The parser extracts
 fields such as `objectFileName`, `Resolution`, `SliceThickness`, `Format`, and optional
 `Components` and `Endianess`. The parsed values are used to initialize the
 metadata properties of this class.
 */
public final class QVISParser: VolumeFileParser {

  // MARK: - Error Type

  /**
   An enumeration representing errors that can occur during header parsing.
   */
  public enum Error: Swift.Error, LocalizedError {
    /// Indicates that the header file could not be read.
    case fileReadFailed(underlying: Swift.Error?)
    /// Indicates that a required header key is missing.
    case missingKey(String)
    /// Indicates that a header key has an invalid value.
    case invalidValue(String)
    /// Indicates that a header key has an invalid value.
    case dataFileNotAccessible(String)

    /// A localized description of the error.
    public var errorDescription: String? {
      switch self {
        case .fileReadFailed(let underlying):
          if let underlying = underlying {
            return "Failed to read the header file. Underlying error: \(underlying)"
          } else {
            return "Failed to read the header file."
          }
        case .missingKey(let key):
          return "Missing key: \(key)."
        case .invalidValue(let key):
          return "Invalid value for key: \(key)."
        case .dataFileNotAccessible(let info):
          return "Data file not accessible: \(info)."
      }
    }
  }

  // MARK: - Public Properties

  /// The file name of the volume data object, resolved to an absolute path.
  public let absoluteFilename: String

  /// The resolution of the volume in voxels along x, y, and z axes.
  public let size: Vec3<Int>

  /// The physical slice thickness along x, y, and z axes.
  public let sliceThickness: Vec3<Float>

  /// Number of bytes per component (e.g., 1 for UCHAR/BYTE, 2 for USHORT, 4 for UINT).
  public let bytesPerComponent: Int

  /// Number of components per voxel (defaults to 1 if not specified in header).
  public let components: Int

  /// Indicates whether the data is stored in little-endian byte order.
  public let isLittleEndian: Bool

  /// A flag indicating whether the data is a temporary copy (always false for QVIS).
  public let dataIsTempCopy: Bool = false

  /// Byte offset within the file where the volume data begins (always 0 for QVIS).
  public let offset: Int = 0

  // MARK: - Initialization

  /**
   Initializes a new `QVISParser` by reading and parsing the header file.

   The header file is read using ASCII encoding. Each non-empty, non-comment line is
   split into a key and value using the colon (`:`) delimiter. The following keys are required:
   - `objectFileName`
   - `Resolution`
   - `SliceThickness`
   - `Format`

   The optional key `Components` specifies the number of components per voxel (defaulting to 1).
   The optional key `Endianess` determines byte order (defaulting to little-endian).

   - Parameter filename: The path to the QVIS header file.
   - Throws: `QVISParser.Error.fileReadFailed` if reading fails,
   `Error.missingKey` if a required key is not found,
   `Error.invalidValue` if a parsed value is malformed.
   */
  public init(filename: String) throws {
    // Read header file as ASCII text
    let content: String
    do {
      content = try String(contentsOfFile: filename, encoding: .ascii)
    } catch {
      throw Error.fileReadFailed(underlying: error)
    }

    // Build dictionary of header fields
    var headerDict = [String: String]()
    let lines = content.split { $0.isNewline }
    for line in lines {
      let parts = line.split(separator: ":", maxSplits: 1)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else { continue }
      headerDict[parts[0].lowercased()] = parts[1]
    }

    // Extract object file name
    guard let objectFileName = headerDict["objectfilename"], !objectFileName.isEmpty else {
      throw Error.missingKey("ObjectFileName")
    }
    // Extract resolution string
    guard let resolutionString = headerDict["resolution"], !resolutionString.isEmpty else {
      throw Error.missingKey("Resolution")
    }
    // Extract slice thickness string
    guard let sliceThicknessString = headerDict["slicethickness"], !sliceThicknessString.isEmpty else {
      throw Error.missingKey("SliceThickness")
    }
    // Extract format string
    guard let formatString = headerDict["format"], !formatString.isEmpty else {
      throw Error.missingKey("Format")
    }
    // Extract optional components, default to 1
    if let componentsString = headerDict["components"], !componentsString.isEmpty {
      self.components = Int(componentsString) ?? 1
    } else {
      self.components = 1
    }

    // Parse resolution into Vec3<Int>
    let dimensions = resolutionString
      .split { !$0.isNumber }
      .compactMap { Int($0) }
    guard dimensions.count == 3 else {
      throw Error.invalidValue("Resolution")
    }
    let size = Vec3<Int>(x: dimensions[0], y: dimensions[1], z: dimensions[2])

    // Parse slice thickness into Vec3<Float>
    let thicknessValues = sliceThicknessString.split(separator: " ")
      .compactMap { Float($0) }
    guard thicknessValues.count == 3 else {
      throw Error.invalidValue("SliceThickness")
    }
    let sliceThickness = Vec3<Float>(
      x: thicknessValues[0],
      y: thicknessValues[1],
      z: thicknessValues[2]
    )

    // Determine bytes per component based on format
    let formatUpper = formatString.uppercased()
    let bytesPerComponent: Int
    switch formatUpper {
      case "UCHAR", "BYTE":
        bytesPerComponent = 1
      case "USHORT":
        bytesPerComponent = 2
      case "UINT":
        bytesPerComponent = 4
      default:
        throw Error.invalidValue("Format")
    }

    // Determine endianness (default little)
    let isLittleEndian: Bool
    if let endianValue = headerDict["endianess"], !endianValue.isEmpty {
      isLittleEndian = endianValue.lowercased() == "little"
    } else {
      isLittleEndian = true
    }

    // Resolve absolute path of the data file
    let inputURL = URL(fileURLWithPath: filename)
    let absoluteURL = inputURL
      .deletingLastPathComponent()
      .appendingPathComponent(objectFileName)

    // Assign parsed properties
    self.absoluteFilename   = absoluteURL.path
    self.size               = size
    self.sliceThickness     = sliceThickness
    self.bytesPerComponent  = bytesPerComponent
    self.isLittleEndian     = isLittleEndian
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
