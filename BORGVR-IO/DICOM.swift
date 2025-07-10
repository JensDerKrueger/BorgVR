import Foundation
import ImageIO

/**
 A parser for DICOM files that can extract image slices and decode them into volumetric data.
 */
final class DicomParser {

  /**
   A representation of a decoded 3D volume from a series of DICOM slices.

   - Parameters:
   - width: The width (number of columns) of each slice.
   - height: The height (number of rows) of each slice.
   - depth: The number of slices in the volume.
   - bytesPerVoxel: The number of bytes used to represent each voxel.
   - scale: The physical scaling factors in x, y, and z dimensions.
   - voxelData: A flat array of voxel intensities in ZYX order.
   */
  struct DicomVolume {
    /// The width (columns) of each 2D slice.
    let width: Int
    /// The height (rows) of each 2D slice.
    let height: Int
    /// The number of slices (depth) in the volume.
    let depth: Int
    /// Number of bytes per voxel (e.g., 1 or 2).
    let bytesPerVoxel: Int
    /// Physical scale factors for each axis (x, y, z).
    let scale: (x: Float, y: Float, z: Float)
    /// Flat voxel data array in Z-Y-X order.
    let voxelData: [UInt8]
  }

  /**
   Decode a series of DICOM files into a single volumetric dataset.

   - Parameter dicomFiles: An array of file URLs pointing to DICOM files.
   - Throws: `DicomParsingError` if parsing fails at any step.
   - Returns: A `DicomVolume` containing the reconstructed volume.
   */
  static func decodeVolume(from dicomFiles: [URL]) throws -> DicomVolume {
    // Parse headers and slice data for each file, ignoring those that fail
    let parsed: [(DicomFile, DicomSlice)] = dicomFiles.compactMap { url in
      do {
        let file = try parseDicomHeader(from: url)
        let slice = try decodeSlice(from: file)
        return (file, slice)
      } catch {
        return nil
      }
    }

    guard !parsed.isEmpty else {
      throw DicomParsingError.noValidFilesFound
    }

    // Use the first successfully parsed slice to determine dimensions
    let first = parsed.first!.1
    let width = Int(first.columns)
    let height = Int(first.rows)
    // Calculate bytes per voxel based on bit depth and samples per pixel
    let bytesPerVoxel = Int((first.bitsAllocated ?? 8 + 7) / 8) * Int(first.samplesPerPixel ?? 1)

    // Filter out slices that do not match the dimensions
    let filtered = parsed.filter { (_, slice) in
      Int(slice.columns) == width && Int(slice.rows) == height
    }

    // Sort slices by Z position or instance number
    let sorted = filtered.sorted { a, b in
      if let z1 = a.1.position?.2, let z2 = b.1.position?.2 {
        return z1 < z2
      } else if let i1 = a.1.instanceNumber, let i2 = b.1.instanceNumber {
        return i1 < i2
      } else {
        return false
      }
    }

    let depth = sorted.count
    // Allocate a buffer for all voxel data
    var buffer = [UInt8](repeating: 0, count: width * height * depth * bytesPerVoxel)

    // Decode each slice and copy its pixels into the buffer
    for (i, (file, slice)) in sorted.enumerated() {
      let offset = i * width * height * bytesPerVoxel
      let pixels = try slice.decodedPixels(using: file.transferSyntax.pixelDataEncoding)
      guard pixels.count == width * height * bytesPerVoxel else {
        throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
      }
      buffer.replaceSubrange(offset..<offset + pixels.count, with: pixels)
    }

    // Compute physical aspect ratio (scale) in x, y, z
    let scale: (Float, Float, Float)
    if let firstZ = sorted.first?.1.position?.2,
       let lastZ = sorted.last?.1.position?.2 {
      // Use slice position difference to estimate Z spacing
      let sliceSpacingZ = depth > 1 ? abs((lastZ - firstZ) / Float(depth - 1)) : 1
      scale = (x: 1, y: 1, z: sliceSpacingZ)
    } else if let spacingX = first.pixelSpacing?.0,
              let spacingY = first.pixelSpacing?.1,
              let sliceThickness = first.sliceThickness {
      // Fallback to pixel spacing and slice thickness tags
      scale = (x: spacingX, y: spacingY, z: sliceThickness)
    } else {
      // Default unit aspect ratio
      scale = (1, 1, 1)
    }

    return DicomVolume(
      width: width,
      height: height,
      depth: depth,
      bytesPerVoxel: bytesPerVoxel,
      scale: scale,
      voxelData: buffer
    )
  }

  // MARK: - Transfer and Pixel Data Encoding Types

  /// Data element encoding in the DICOM file.
  enum DataElementEncoding {
    case explicitVRLittleEndian
    case implicitVRLittleEndian
    case explicitVRBigEndian
  }

  /// Pixel data encoding, including various compression methods.
  enum PixelDataEncoding {
    case uncompressed
    case jpegBaseline
    case jpegLossless
    case jpeg2000
    case rle
    case unknown(String)
  }

  /// Information about the transfer syntax, combining element and pixel encodings.
  struct TransferSyntaxInfo {
    let elementEncoding: DataElementEncoding
    let pixelDataEncoding: PixelDataEncoding
  }

  // MARK: - DICOM Tag Definitions

  /**
   Represents a DICOM tag with group and element numbers.

   Conforms to `Equatable` and `Hashable` for use in dictionaries and sets.
   */
  struct DicomTag: Equatable, Hashable {
    let group: UInt16
    let element: UInt16

    static let transferSyntaxUID = DicomTag(group: 0x0002, element: 0x0010)
    static let rows = DicomTag(group: 0x0028, element: 0x0010)
    static let columns = DicomTag(group: 0x0028, element: 0x0011)
    static let samplesPerPixel = DicomTag(group: 0x0028, element: 0x0002)
    static let bitsAllocated = DicomTag(group: 0x0028, element: 0x0100)
    static let bitsStored = DicomTag(group: 0x0028, element: 0x0101)
    static let highBit = DicomTag(group: 0x0028, element: 0x0102)
    static let pixelRepresentation = DicomTag(group: 0x0028, element: 0x0103)
    static let sliceThickness = DicomTag(group: 0x0018, element: 0x0050)
    static let pixelSpacing = DicomTag(group: 0x0028, element: 0x0030)
    static let imagePositionPatient = DicomTag(group: 0x0020, element: 0x0032)
    static let imageOrientationPatient = DicomTag(group: 0x0020, element: 0x0037)
    static let instanceNumber = DicomTag(group: 0x0020, element: 0x0013)
    static let pixelData = DicomTag(group: 0x7FE0, element: 0x0010)
  }

  // MARK: - DICOM File and Element Representations

  /**
   Holds raw DICOM file data along with transfer syntax information.
   */
  struct DicomFile {
    /// Transfer syntax defining element and pixel encoding.
    let transferSyntax: TransferSyntaxInfo
    /// Raw file data loaded from disk.
    let rawData: Data
  }

  /**
   Represents a DICOM data element parsed from the file.

   Conforms to `CustomStringConvertible` for debug printing.
   */
  struct DicomElement: CustomStringConvertible {
    let tag: DicomTag
    let vr: String
    let length: Int
    let valueOffset: Int
    let isSequence: Bool

    /// A human-readable description of the data element.
    var description: String {
      let tagString = String(format: "(%04X,%04X)", tag.group, tag.element)
      return "\(tagString) [\(vr)] - Length: \(length)  Offset: \(valueOffset)"
    }
  }

  // MARK: - Slice Decoding Errors

  /**
   Errors specific to DICOM slice decoding operations.
   */
  enum DicomSliceDecodingError: Error, LocalizedError {
    case unsupportedPixelEncoding(String)
    case notImplemented(String)

    var errorDescription: String? {
      switch self {
        case .unsupportedPixelEncoding(let encoding):
          return "Unsupported pixel encoding: \(encoding)"
        case .notImplemented(let feature):
          return "Decoding for \(feature) is not implemented yet."
      }
    }
  }

  // MARK: - DICOM Slice Representation and Decoding

  /**
   A decoded DICOM slice, containing image data and metadata.
   */
  struct DicomSlice {
    /// Number of rows in the image.
    let rows: UInt16
    /// Number of columns in the image.
    let columns: UInt16
    /// Raw pixel data as in-file bytes.
    let pixelData: Data
    /// Number of samples per pixel (e.g., 1 for grayscale, 3 for RGB).
    let samplesPerPixel: UInt16?
    /// Bits allocated per sample.
    let bitsAllocated: UInt16?
    /// Pixel representation (e.g., signed vs unsigned).
    let pixelRepresentation: UInt16?
    /// Physical slice thickness (if provided).
    let sliceThickness: Float?
    /// Pixel spacing in x and y dimensions (if provided).
    let pixelSpacing: (Float, Float)?
    /// Patient position (x, y, z) of this slice.
    let position: (Float, Float, Float)?
    /// Orientation direction cosines (six values).
    let orientation: [Float]?
    /// Instance number for ordering slices.
    let instanceNumber: Int?

    /**
     Decode the raw pixel data into an array of bytes according to the specified encoding.

     - Parameter encoding: The `PixelDataEncoding` to use (default is `.uncompressed`).
     - Throws: `DicomParsingError` or `DicomSliceDecodingError` on failure.
     - Returns: An array of decoded pixel bytes.
     */
    func decodedPixels(using encoding: PixelDataEncoding = .uncompressed) throws -> [UInt8] {
      switch encoding {
        case .uncompressed:
          // Calculate expected byte count for the uncompressed image
          let bits = Int(bitsAllocated ?? 8)
          let expectedBytesPerPixel = (bits + 7) / 8
          let totalPixels = Int(rows) * Int(columns) * Int(samplesPerPixel ?? 1)
          let expectedByteCount = totalPixels * expectedBytesPerPixel

          guard pixelData.count >= expectedByteCount else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }

          return [UInt8](pixelData.prefix(expectedByteCount))

        case .jpeg2000:
          throw DicomSliceDecodingError.notImplemented("JPEG2000")

        case .jpegBaseline:
          // Extract encapsulated JPEG fragments and reconstruct a valid JPEG stream
          let fragments = try encapsulatedFragments()
          let inData = fragments.reduce(Data(), +)
          var data = Data(inData)
          if !inData.starts(with: [0xFF, 0xD8]) {
            data.insert(contentsOf: [0xFF, 0xD8], at: 0)
          }
          if !(inData.suffix(2) == Data([0xFF, 0xD9])) {
            data.append(contentsOf: [0xFF, 0xD9])
          }
          guard let provider = CGDataProvider(data: data as CFData),
                let image = CGImage(jpegDataProviderSource: provider,
                                    decode: nil,
                                    shouldInterpolate: true,
                                    intent: .defaultIntent)
                  ?? CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
          else {
            throw DicomParsingError.jpegDecodingFailed
          }

          // Render the CGImage into RGBA8 pixel buffer
          let width = image.width
          let height = image.height
          let bytesPerPixel = 4
          let bytesPerRow = width * bytesPerPixel
          let bufferSize = bytesPerRow * height
          var buffer = [UInt8](repeating: 0, count: bufferSize)
          let colorSpace = CGColorSpaceCreateDeviceRGB()
          guard let context = CGContext(data: &buffer,
                                        width: width,
                                        height: height,
                                        bitsPerComponent: 8,
                                        bytesPerRow: bytesPerRow,
                                        space: colorSpace,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
          else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
          return buffer

        case .jpegLossless:
          throw DicomSliceDecodingError.notImplemented("JPEG Lossless")

        case .rle:
          return try decodeRLE(pixelData)

        case .unknown(let name):
          throw DicomSliceDecodingError.unsupportedPixelEncoding(name)
      }
    }

    /**
     Extract encapsulated fragments from a multi-item pixel data element.

     - Throws: `DicomParsingError.invalidElementValue` on failure.
     - Returns: An array of `Data` representing each fragment.
     */
    private func encapsulatedFragments() throws -> [Data] {
      var offset = 0
      var fragments: [Data] = []

      while offset + 8 <= pixelData.count {
        let group = UInt16(littleEndian:
                            pixelData[offset..<offset+2].withUnsafeBytes { $0.load(as: UInt16.self) })
        let element = UInt16(littleEndian:
                              pixelData[offset+2..<offset+4].withUnsafeBytes { $0.load(as: UInt16.self) })
        let tag = (group, element)
        let length = UInt32(littleEndian:
                              pixelData[offset+4..<offset+8].withUnsafeBytes { $0.load(as: UInt32.self) })
        offset += 8

        if tag == (0xFFFE, 0xE000) {
          // Item fragment
          let fragment = pixelData[offset..<min(offset + Int(length), pixelData.count)]
          fragments.append(fragment)
          offset += Int(length)
        } else if tag == (0xFFFE, 0xE0DD) {
          // Sequence Delimitation Item
          break
        } else {
          break
        }
      }

      return fragments
    }

    /**
     Decode a Run-Length Encoded (RLE) pixel data block.

     - Parameter data: The raw RLE-encoded data.
     - Throws: `DicomParsingError.invalidElementValue` on corruption.
     - Returns: A flat array of decoded pixel bytes.
     */
    private func decodeRLE(_ data: Data) throws -> [UInt8] {
      guard data.count >= 64 else {
        throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
      }

      // Read segment count and offsets
      let numberOfSegments = Int(UInt32(littleEndian:
                                          data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }))
      guard numberOfSegments > 0, numberOfSegments <= 15 else {
        throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
      }

      var segmentOffsets: [Int] = []
      for i in 0..<numberOfSegments {
        let offset = Int(UInt32(littleEndian:
                                  data[4 + i * 4..<8 + i * 4].withUnsafeBytes { $0.load(as: UInt32.self) }))
        segmentOffsets.append(offset)
      }

      // Decode each segment separately
      let totalPixels = Int(rows) * Int(columns) * Int(samplesPerPixel ?? 1)
      let bytesPerPixel = Int((bitsAllocated ?? 8 + 7) / 8)
      var decodedSegments: [[UInt8]] = Array(repeating: [], count: numberOfSegments)
      for i in 0..<numberOfSegments {
        let start = segmentOffsets[i]
        let end = (i + 1 < numberOfSegments) ? segmentOffsets[i + 1] : data.count
        let segmentData = data[start..<end]
        decodedSegments[i] = try decodeRLESegment(segmentData)
      }

      // Interleave segments into final pixel array
      var result = [UInt8](repeating: 0, count: totalPixels * bytesPerPixel)
      for pixelIndex in 0..<totalPixels {
        for bytePlane in 0..<bytesPerPixel {
          let segment = decodedSegments[bytePlane]
          guard pixelIndex < segment.count else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          result[pixelIndex * bytesPerPixel + bytePlane] = segment[pixelIndex]
        }
      }

      return result
    }

    /**
     Decode a single RLE segment using PackBits-like decoding.

     - Parameter segment: The RLE segment data.
     - Throws: `DicomParsingError.invalidElementValue` on corruption.
     - Returns: The decoded byte array for that segment.
     */
    private func decodeRLESegment(_ segment: Data) throws -> [UInt8] {
      var output: [UInt8] = []
      var i = 0
      while i < segment.count {
        let control = Int8(bitPattern: segment[i])
        i += 1
        if control >= 0 {
          let count = Int(control) + 1
          guard i + count <= segment.count else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          output.append(contentsOf: segment[i..<i+count])
          i += count
        } else if control >= -127 {
          guard i < segment.count else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          let value = segment[i]
          i += 1
          output.append(contentsOf: repeatElement(value, count: 1 - Int(control)))
        }
        // -128 is a no-op
      }
      return output
    }
  }

  // MARK: - General Parsing Errors

  /**
   Errors that can occur during DICOM parsing and header extraction.
   */
  enum DicomParsingError: Error, LocalizedError {
    case fileTooSmall
    case noValidFilesFound
    case missingDICMPrefix
    case transferSyntaxUIDNotFound
    case incompleteElementHeader
    case tagNotFound(DicomTag)
    case invalidElementValue(DicomTag)
    case jpegDecodingFailed

    var errorDescription: String? {
      switch self {
        case .fileTooSmall:
          return "The DICOM file is too small to contain a valid header."
        case .noValidFilesFound:
          return "No valid DICOM files were found in the provided list."
        case .missingDICMPrefix:
          return "The DICOM file is missing the 'DICM' prefix."
        case .transferSyntaxUIDNotFound:
          return "TransferSyntaxUID tag (0002,0010) was not found in the file."
        case .incompleteElementHeader:
          return "Encountered an incomplete element header."
        case .tagNotFound(let tag):
          return String(format: "Tag (%04X,%04X) not found in DICOM dataset.", tag.group, tag.element)
        case .invalidElementValue(let tag):
          return String(format: "Could not interpret value for tag (%04X,%04X).", tag.group, tag.element)
        case .jpegDecodingFailed:
          return "Failed to decode JPEG data."
      }
    }
  }

  // MARK: - Header Parsing and Element Extraction

  /**
   Map a Transfer Syntax UID string to its corresponding encoding info.

   - Parameter uid: The UID string from the DICOM header.
   - Returns: A `TransferSyntaxInfo` struct describing element and pixel encodings.
   */
  static func parseTransferSyntaxUID(_ uid: String) -> TransferSyntaxInfo {
    switch uid {
      case "1.2.840.10008.1.2":
        return TransferSyntaxInfo(elementEncoding: .implicitVRLittleEndian, pixelDataEncoding: .uncompressed)
      case "1.2.840.10008.1.2.1":
        return TransferSyntaxInfo(elementEncoding: .explicitVRLittleEndian, pixelDataEncoding: .uncompressed)
      case "1.2.840.10008.1.2.2":
        return TransferSyntaxInfo(elementEncoding: .explicitVRBigEndian, pixelDataEncoding: .uncompressed)
      case "1.2.840.10008.1.2.4.50":
        return TransferSyntaxInfo(elementEncoding: .explicitVRLittleEndian, pixelDataEncoding: .jpegBaseline)
      case "1.2.840.10008.1.2.4.57", "1.2.840.10008.1.2.4.70":
        return TransferSyntaxInfo(elementEncoding: .explicitVRLittleEndian, pixelDataEncoding: .jpegLossless)
      case "1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91":
        return TransferSyntaxInfo(elementEncoding: .explicitVRLittleEndian, pixelDataEncoding: .jpeg2000)
      case "1.2.840.10008.1.2.5":
        return TransferSyntaxInfo(elementEncoding: .explicitVRLittleEndian, pixelDataEncoding: .rle)
      default:
        return TransferSyntaxInfo(elementEncoding: .explicitVRLittleEndian, pixelDataEncoding: .unknown(uid))
    }
  }

  /**
   Read a single DICOM data element at the given byte offset.

   - Parameters:
   - offset: Byte offset in the data buffer where the element begins.
   - data: The full DICOM file data.
   - encoding: The `DataElementEncoding` to interpret the bytes.
   - Throws: `DicomParsingError.incompleteElementHeader` if not enough data.
   - Returns: A tuple containing the parsed `DicomElement` and the offset to the next element.
   */
  static func readElement(at offset: Int, in data: Data, using encoding: DataElementEncoding) throws -> (element: DicomElement, nextOffset: Int) {
    guard offset + 8 <= data.count else {
      throw DicomParsingError.incompleteElementHeader
    }

    let groupRange = offset..<offset+2
    let elementRange = offset+2..<offset+4

    let group = encoding == .explicitVRBigEndian
    ? UInt16(bigEndian: data.subdata(in: groupRange).withUnsafeBytes { $0.load(as: UInt16.self) })
    : UInt16(littleEndian: data.subdata(in: groupRange).withUnsafeBytes { $0.load(as: UInt16.self) })

    let element = encoding == .explicitVRBigEndian
    ? UInt16(bigEndian: data.subdata(in: elementRange).withUnsafeBytes { $0.load(as: UInt16.self) })
    : UInt16(littleEndian: data.subdata(in: elementRange).withUnsafeBytes { $0.load(as: UInt16.self) })

    let tag = DicomTag(group: group, element: element)

    let vr: String
    let length: Int
    let valueOffset: Int

    if encoding == .implicitVRLittleEndian {
      vr = "UN"
      length = Int(UInt32(littleEndian: data.subdata(in: offset+4..<offset+8).withUnsafeBytes { $0.load(as: UInt32.self) }))
      valueOffset = offset + 8
    } else {
      vr = String(data: data.subdata(in: offset+4..<offset+6), encoding: .ascii) ?? "UN"
      let isLongVR = ["OB", "OW", "OF", "SQ", "UT", "UN"].contains(vr)

      if isLongVR {
        length = Int(UInt32(littleEndian: data.subdata(in: offset+8..<offset+12).withUnsafeBytes { $0.load(as: UInt32.self) }))
        valueOffset = offset + 12
      } else {
        length = Int(UInt16(littleEndian: data.subdata(in: offset+6..<offset+8).withUnsafeBytes { $0.load(as: UInt16.self) }))
        valueOffset = offset + 8
      }
    }

    return (
      element: DicomElement(tag: tag, vr: vr, length: length, valueOffset: valueOffset, isSequence: vr == "SQ"),
      nextOffset: valueOffset + length
    )
  }

  /**
   Parse the DICOM header from a file URL and extract transfer syntax info.

   - Parameter file: URL of the DICOM file.
   - Throws: `DicomParsingError` if the file is invalid or missing required tags.
   - Returns: A `DicomFile` containing raw data and transfer syntax.
   */
  static func parseDicomHeader(from file: URL) throws -> DicomFile {
    let data = try Data(contentsOf: file)
    guard data.count > 132 else {
      throw DicomParsingError.fileTooSmall
    }

    guard String(data: data.subdata(in: 128..<132), encoding: .ascii) == "DICM" else {
      throw DicomParsingError.missingDICMPrefix
    }

    var offset = 132
    var transferSyntaxUID: String?

    // Scan file meta-information for TransferSyntaxUID tag
    while offset + 8 <= data.count {
      let group = UInt16(littleEndian: data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) })
      let element = UInt16(littleEndian: data.subdata(in: offset+2..<offset+4).withUnsafeBytes { $0.load(as: UInt16.self) })
      let tag = DicomTag(group: group, element: element)

      let vr = String(data: data.subdata(in: offset+4..<offset+6), encoding: .ascii) ?? ""
      let length: Int
      let valueOffset: Int

      if ["OB", "OW", "OF", "SQ", "UT", "UN"].contains(vr) {
        length = Int(UInt32(littleEndian: data.subdata(in: offset+8..<offset+12).withUnsafeBytes { $0.load(as: UInt32.self) }))
        valueOffset = offset + 12
      } else {
        length = Int(UInt16(littleEndian: data.subdata(in: offset+6..<offset+8).withUnsafeBytes { $0.load(as: UInt16.self) }))
        valueOffset = offset + 8
      }

      if tag == .transferSyntaxUID {
        let uidData = data.subdata(in: valueOffset..<valueOffset+length)
        transferSyntaxUID = String(data: uidData, encoding: .ascii)?
          .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        break
      }

      offset = valueOffset + length
    }

    guard let uid = transferSyntaxUID else {
      throw DicomParsingError.transferSyntaxUIDNotFound
    }

    let syntaxInfo = parseTransferSyntaxUID(uid)
    return DicomFile(transferSyntax: syntaxInfo, rawData: data)
  }

  /**
   Extract specified DICOM elements from a parsed file.

   - Parameters:
   - dicom: The parsed `DicomFile` with raw data and syntax info.
   - targetTags: A set of `DicomTag` values to extract.
   - Throws: `DicomParsingError` on read errors.
   - Returns: A dictionary mapping each found tag to its `DicomElement`.
   */
  static func extractElements(from dicom: DicomFile, targetTags: Set<DicomTag>) throws -> [DicomTag: DicomElement] {
    let offset = 132
    var result: [DicomTag: DicomElement] = [:]

    /// Recursively scan data elements, handling sequences and undefined lengths.
    func scanElements(in data: Data, startingAt offset: Int, using encoding: DataElementEncoding, depth: Int = 0) throws -> Int {
      var currentOffset = offset
      let startOffset = offset
      var visitedOffsets = Set<Int>()

      while currentOffset + 8 <= data.count, !visitedOffsets.contains(currentOffset) {
        visitedOffsets.insert(currentOffset)

        var (element, nextOffset) = try readElement(at: currentOffset, in: data, using: encoding)

        // Stop at sequence delimitation
        if element.tag.group == 0xFFFE {
          currentOffset = nextOffset
          return currentOffset - startOffset
        }

        // Handle undefined-length pixel data (encapsulated)
        if element.tag.group == 0x7FE0 && element.tag.element == 0x0010 && element.length == 0xFFFFFFFF {
          var pixelOffset = element.valueOffset
          var totalLength = 0
          while pixelOffset + 8 <= data.count {
            let itemTag = DicomTag(
              group: UInt16(littleEndian: data.subdata(in: pixelOffset..<pixelOffset+2).withUnsafeBytes { $0.load(as: UInt16.self) }),
              element: UInt16(littleEndian: data.subdata(in: pixelOffset+2..<pixelOffset+4).withUnsafeBytes { $0.load(as: UInt16.self) })
            )
            if itemTag.group == 0xFFFE && itemTag.element == 0xE000 {
              let itemLength = UInt32(littleEndian:
                                        data.subdata(in: pixelOffset+4..<pixelOffset+8).withUnsafeBytes { $0.load(as: UInt32.self) })
              pixelOffset += 8 + Int(itemLength)
              totalLength += Int(itemLength)
            } else if itemTag.group == 0xFFFE && itemTag.element == 0xE0DD {
              pixelOffset += 8
              break
            } else {
              break
            }
          }
          // Patch element with actual length
          element = DicomElement(
            tag: element.tag,
            vr: element.vr,
            length: totalLength,
            valueOffset: element.valueOffset,
            isSequence: element.isSequence
          )
        }

        // Record element if it matches one of the targets
        if targetTags.contains(element.tag) {
          result[element.tag] = element
          if result.count == targetTags.count {
            return currentOffset - startOffset
          }
        }

        // Recurse into sequences
        if element.isSequence {
          let subrangeEnd = element.length == 0xFFFFFFFF
          ? data.count
          : element.valueOffset + element.length
          var itemOffset = element.valueOffset
          var maxOffset = itemOffset

          while itemOffset + 8 <= subrangeEnd {
            let itemTag = DicomTag(
              group: UInt16(littleEndian: data.subdata(in: itemOffset..<itemOffset+2).withUnsafeBytes { $0.load(as: UInt16.self) }),
              element: UInt16(littleEndian: data.subdata(in: itemOffset+2..<itemOffset+4).withUnsafeBytes { $0.load(as: UInt16.self) })
            )
            if itemTag.group == 0xFFFE && itemTag.element == 0xE000 {
              let itemLength = UInt32(littleEndian:
                                        data.subdata(in: itemOffset+4..<itemOffset+8).withUnsafeBytes { $0.load(as: UInt32.self) })
              let itemDataStart = itemOffset + 8
              let itemDataEnd = itemLength == 0xFFFFFFFF
              ? subrangeEnd
              : itemDataStart + Int(itemLength)
              let itemData = data.subdata(in: itemDataStart..<min(itemDataEnd, data.count))
              let consumed = try scanElements(in: itemData, startingAt: 0, using: encoding, depth: depth + 1)
              itemOffset = itemLength == 0xFFFFFFFF
              ? itemDataStart + consumed
              : itemDataEnd
              maxOffset = itemOffset
            } else if itemTag.group == 0xFFFE && itemTag.element == 0xE0DD {
              maxOffset = itemOffset + 8
              break
            } else {
              break
            }
          }
          currentOffset = element.length == 0xFFFE_ffff
          ? maxOffset
          : nextOffset
        } else {
          currentOffset = nextOffset
        }
      }
      return currentOffset - startOffset
    }

    _ = try scanElements(in: dicom.rawData, startingAt: offset, using: dicom.transferSyntax.elementEncoding)

    return result
  }

  // MARK: - Slice-Level Decoding

  /**
   Decode metadata and pixel data for a single DICOM slice.

   - Parameter dicom: The `DicomFile` containing raw data and transfer syntax.
   - Throws: `DicomParsingError` if required tags are missing.
   - Returns: A `DicomSlice` with image and metadata.
   */
  static func decodeSlice(from dicom: DicomFile) throws -> DicomSlice {
    // Define required and optional tags
    let tagRequirements: [(DicomTag, Bool)] = [
      (.rows, false),
      (.columns, false),
      (.pixelData, false),
      (.samplesPerPixel, true),
      (.bitsAllocated, true),
      (.pixelRepresentation, true),
      (.sliceThickness, true),
      (.pixelSpacing, true),
      (.imagePositionPatient, true),
      (.imageOrientationPatient, true),
      (.instanceNumber, true)
    ]

    let tagSet = Set(tagRequirements.map { $0.0 })
    let elements = try extractElements(from: dicom, targetTags: tagSet)

    // Ensure all non-optional tags are present
    for (tag, isOptional) in tagRequirements where !isOptional {
      guard elements[tag] != nil else {
        throw DicomParsingError.tagNotFound(tag)
      }
    }

    // Helper to read UInt16 values
    func readUInt16(tag: DicomTag) -> UInt16? {
      guard let elem = elements[tag], elem.length >= 2 else { return nil }
      return dicom.rawData.subdata(in: elem.valueOffset..<elem.valueOffset+2)
        .withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    // Helper to read Float from ASCII value
    func readFloat(tag: DicomTag) -> Float? {
      guard let elem = elements[tag] else { return nil }
      let str = String(
        data: dicom.rawData.subdata(in: elem.valueOffset..<elem.valueOffset+elem.length),
        encoding: .ascii
      )?.trimmingCharacters(in: .whitespaces)
      return str.flatMap(Float.init)
    }

    // Helper to read tuple of floats separated by backslashes
    func readFloatTuple(tag: DicomTag, count: Int) -> [Float]? {
      guard let elem = elements[tag] else { return nil }
      let str = String(
        data: dicom.rawData.subdata(in: elem.valueOffset..<elem.valueOffset+elem.length),
        encoding: .ascii
      )
      let parts = str?
        .split(separator: "\\")
        .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
      return parts?.count == count ? parts : nil
    }

    // Helper to read instance number as Int
    func readInstanceNumber(tag: DicomTag) -> Int? {
      guard let elem = elements[tag] else { return nil }
      let str = String(
        data: dicom.rawData.subdata(in: elem.valueOffset..<elem.valueOffset+elem.length),
        encoding: .ascii
      )?.trimmingCharacters(in: .whitespaces)
      return str.flatMap(Int.init)
    }

    let rows = readUInt16(tag: .rows) ?? 0
    let columns = readUInt16(tag: .columns) ?? 0
    let pixelData = elements[.pixelData].map {
      dicom.rawData.subdata(in: $0.valueOffset..<$0.valueOffset + $0.length)
    } ?? Data()

    return DicomSlice(
      rows: rows,
      columns: columns,
      pixelData: pixelData,
      samplesPerPixel: readUInt16(tag: .samplesPerPixel),
      bitsAllocated: readUInt16(tag: .bitsAllocated),
      pixelRepresentation: readUInt16(tag: .pixelRepresentation),
      sliceThickness: readFloat(tag: .sliceThickness),
      pixelSpacing: readFloatTuple(tag: .pixelSpacing, count: 2).flatMap { ($0[0], $0[1]) },
      position: readFloatTuple(tag: .imagePositionPatient, count: 3).flatMap { ($0[0], $0[1], $0[2]) },
      orientation: readFloatTuple(tag: .imageOrientationPatient, count: 6),
      instanceNumber: readInstanceNumber(tag: .instanceNumber)
    )
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
