import Foundation

// MARK: - QVISParser

/**
 Parses a QVIS header file and extracts metadata for a volumetric dataset.

 The header file is expected to be an ASCII text file containing key-value pairs,
 one per line, where keys and values are separated by a colon (`:`). The parser extracts
 fields such as `objectFileName`, `Resolution`, `SliceThickness`, `Format`, and optional
 `Components`, `ObjectModel` and `Endianess`. The parsed values are used to initialize the
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
  public var sourceFiles: [URL] { [URL(fileURLWithPath: absoluteFilename)] }

  /// The resolution of the volume in voxels along x, y, and z axes.
  public let size: Vec3<Int>

  /// The physical voxel spacing along x, y, and z axes.
  public let voxelSpacing: Vec3<Float>
  public let hasPhysicalVoxelSpacing: Bool

  /// Number of bytes per component (e.g., 1 for UCHAR/BYTE, 2 for USHORT, 4 for UINT).
  public let bytesPerComponent: Int

  /// Component count from UCHAR3/UCHAR4 or Components; otherwise one.
  public let components: Int
  public let channelInterpretation: BORGVRChannelInterpretation

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
   - `Format`

   Without `SliceThickness`, isotropic spacing is assumed with a longest extent of one meter.
   UCHAR3/UCHAR4 specify three/four byte components; Components must agree if also supplied.
   ObjectModel RGB/RGBA explicitly identifies color data; otherwise components remain scalars.
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
    let sliceThicknessString = headerDict["slicethickness"]
    hasPhysicalVoxelSpacing = sliceThicknessString != nil
    // Extract format string
    guard let formatString = headerDict["format"], !formatString.isEmpty else {
      throw Error.missingKey("Format")
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
    let thicknessValues = sliceThicknessString?.split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
      ?? [Float](repeating: 1 / Float(max(size.x, size.y, size.z)), count: 3)
    guard thicknessValues.count == 3, thicknessValues.allSatisfy({ $0.isFinite && $0 > 0 }) else {
      throw Error.invalidValue("SliceThickness")
    }
    let voxelSpacing = Vec3<Float>(
      x: thicknessValues[0],
      y: thicknessValues[1],
      z: thicknessValues[2]
    )

    // Determine bytes per component based on format
    let formatUpper = formatString.uppercased()
    let bytesPerComponent: Int
    let formatComponents: Int?
    switch formatUpper {
      case "UCHAR", "BYTE":
        bytesPerComponent = 1
        formatComponents = nil
      case "UCHAR3":
        bytesPerComponent = 1
        formatComponents = 3
      case "UCHAR4":
        bytesPerComponent = 1
        formatComponents = 4
      case "USHORT":
        bytesPerComponent = 2
        formatComponents = nil
      case "UINT":
        bytesPerComponent = 4
        formatComponents = nil
      default:
        throw Error.invalidValue("Format")
    }

    let components: Int
    if let explicit = headerDict["components"] {
      guard let count = Int(explicit), count > 0,
            formatComponents == nil || formatComponents == count else {
        throw Error.invalidValue("Components")
      }
      components = count
    } else {
      components = formatComponents ?? 1
    }
    let interpretation: BORGVRChannelInterpretation
    switch headerDict["objectmodel"]?.uppercased() {
      case "RGB": interpretation = .rgb
      case "RGBA": interpretation = .rgba
      default: interpretation = .independentChannels
    }
    if interpretation != .independentChannels {
      guard bytesPerComponent == 1,
            components == (interpretation == .rgb ? 3 : 4) else {
        throw Error.invalidValue("ObjectModel")
      }
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
    self.voxelSpacing       = voxelSpacing
    self.bytesPerComponent  = bytesPerComponent
    self.components         = components
    self.channelInterpretation = interpretation
    self.isLittleEndian     = isLittleEndian
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
