import Foundation
import ImageIO

/**
 A parser for DICOM files that can extract image slices and decode them into volumetric data.
 */
final class DicomParser {

  private static let undefinedLength = Int(UInt32.max)
  private static let maximumSequenceDepth = 64
  private static let maximumDecodedSliceBytes = 512 * 1024 * 1024

  private enum Endianness {
    case little
    case big
  }

  private struct ByteReader {
    let data: Data
    let endianness: Endianness

    func checkedEnd(offset: Int, length: Int) throws -> Int {
      guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
        throw DicomParsingError.incompleteElementHeader
      }
      return offset + length
    }

    func uint16(at offset: Int) throws -> UInt16 {
      let end = try checkedEnd(offset: offset, length: 2)
      let startIndex = data.index(data.startIndex, offsetBy: offset)
      let endIndex = data.index(data.startIndex, offsetBy: end)
      let bytes = data[startIndex..<endIndex]
      let first = UInt16(bytes[bytes.startIndex])
      let second = UInt16(bytes[bytes.index(after: bytes.startIndex)])
      switch endianness {
        case .little: return first | (second << 8)
        case .big: return (first << 8) | second
      }
    }

    func uint32(at offset: Int) throws -> UInt32 {
      let end = try checkedEnd(offset: offset, length: 4)
      let startIndex = data.index(data.startIndex, offsetBy: offset)
      let endIndex = data.index(data.startIndex, offsetBy: end)
      let bytes = data[startIndex..<endIndex]
      let values = bytes.map(UInt32.init)
      switch endianness {
        case .little:
          return values[0] | (values[1] << 8) | (values[2] << 16) | (values[3] << 24)
        case .big:
          return (values[0] << 24) | (values[1] << 16) | (values[2] << 8) | values[3]
      }
    }

    func bytes(at offset: Int, count: Int) throws -> Data {
      let end = try checkedEnd(offset: offset, length: count)
      let startIndex = data.index(data.startIndex, offsetBy: offset)
      let endIndex = data.index(data.startIndex, offsetBy: end)
      return data.subdata(in: startIndex..<endIndex)
    }
  }

  private static func endianness(for encoding: DataElementEncoding) -> Endianness {
    encoding == .explicitVRBigEndian ? .big : .little
  }

  private static func checkedProduct(
    _ values: Int...,
    maximum: Int = Int.max,
    tag: DicomTag
  ) throws -> Int {
    var result = 1
    for value in values {
      guard value >= 0 else {
        throw DicomParsingError.invalidElementValue(tag)
      }
      let (product, overflow) = result.multipliedReportingOverflow(by: value)
      guard !overflow, product <= maximum else {
        throw DicomParsingError.invalidElementValue(tag)
      }
      result = product
    }
    return result
  }

  /**
   An orthonormal basis describing a DICOM volume's axes in patient coordinates.

   `xAxis` follows increasing voxel-column indices, `yAxis` follows increasing
   voxel-row indices, and `zAxis` is the right-handed slice normal.
   */
  struct DicomOrientation: Equatable, Sendable {
    let xAxis: Vec3<Float>
    let yAxis: Vec3<Float>
    let zAxis: Vec3<Float>
  }

  /**
   A representation of a decoded 3D volume from a series of DICOM slices.

   - Parameters:
   - width: The width (number of columns) of each slice.
   - height: The height (number of rows) of each slice.
   - depth: The number of slices in the volume.
   - bytesPerVoxel: The number of bytes used to represent each voxel.
   - voxelSpacing: The physical voxel spacing in meters along the x, y, and z dimensions.
   - orientation: The volume axes in DICOM patient coordinates, if available.
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
    /// Physical voxel spacing in meters for each axis (x, y, z).
    let voxelSpacing: (x: Float, y: Float, z: Float)
    /// Orthonormal volume axes in DICOM patient coordinates.
    let orientation: DicomOrientation?
    /// Flat voxel data array in Z-Y-X order.
    let voxelData: [UInt8]

    let modality: String?
    let patientName: String?
    let seriesDate: String?
  }

  private static func normalize(_ v: Vec3<Float>) -> Vec3<Float>? {
    let len = sqrt(v.dot(v))
    guard len.isFinite, len > 1e-8 else { return nil }
    return Vec3<Float>(x: v.x / len, y: v.y / len, z: v.z / len)
  }

  static func orientationBasis(
    from imageOrientationPatient: [Float]?
  ) -> DicomOrientation? {
    guard let values = imageOrientationPatient,
          values.count == 6,
          values.allSatisfy(\.isFinite) else {
      return nil
    }

    let rawXAxis = Vec3<Float>(x: values[0], y: values[1], z: values[2])
    let rawYAxis = Vec3<Float>(x: values[3], y: values[4], z: values[5])
    guard let xAxis = normalize(rawXAxis) else { return nil }

    // DICOM direction cosines should be orthogonal. Remove small acquisition
    // and serialization errors before this basis is used for registration.
    let orthogonalY = rawYAxis - xAxis * rawYAxis.dot(xAxis)
    guard let yAxis = normalize(orthogonalY),
          let zAxis = normalize(xAxis.cross(yAxis)) else {
      return nil
    }

    return DicomOrientation(xAxis: xAxis, yAxis: yAxis, zAxis: zAxis)
  }

  private static func median(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    let mid = s.count / 2
    if s.count % 2 == 0 {
      return (s[mid - 1] + s[mid]) * 0.5
    } else {
      return s[mid]
    }
  }

  

  /**
   Decode a series of DICOM files into a single volumetric dataset.

   - Parameter dicomFiles: An array of file URLs pointing to DICOM files.
   - Throws: `DicomParsingError` if parsing fails at any step.
   - Returns: A `DicomVolume` containing the reconstructed volume.
   */
  static func decodeVolume(
    from dicomFiles: [URL],
    logger: LoggerBase? = nil,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil
  ) throws -> DicomVolume {
    // Parse headers and slice data for each file, ignoring those that fail
    var parsed: [(DicomFile, DicomSlice)] = []
    parsed.reserveCapacity(dicomFiles.count)
    for (index, url) in dicomFiles.enumerated() {
      try cancellationToken?.checkCancellation()
      do {
        let file = try parseDicomHeader(from: url)
        let slice = try openSlice(from: file)
        parsed.append((file, slice))
      } catch {
        // A DICOM directory can contain unrelated files. Keep scanning.
      }
      logger?.progress(
        "Reading DICOM files",
        Double(index + 1) / Double(dicomFiles.count)
      )
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
    // In-plane spacing (PixelSpacing) should always be used when present.
    // DICOM PixelSpacing is typically "rowSpacing\colSpacing".
    // Since width == columns and height == rows, map:
    //   scale.x = colSpacing, scale.y = rowSpacing
    let inPlane: (x: Float, y: Float) = {
      if let ps = filtered.compactMap({ $0.1.pixelSpacing }).first {
        return (x: ps.1, y: ps.0)
      }
      return (x: 1, y: 1)
    }()

    // Prefer geometry-based ordering + Z spacing from positions projected onto slice normal.
    var sorted = filtered
    var sliceSpacingZ: Float? = nil
    let orientation = orientationBasis(
      from: filtered.compactMap({ $0.1.orientation }).first
    )

    if let normal = orientation?.zAxis {
      let allHavePosition = filtered.allSatisfy { $0.1.position != nil }

      if allHavePosition {
        // Sort by signed distance along the normal (robust for oblique acquisitions).
        sorted = filtered.sorted { a, b in
          let pa = a.1.position!
          let pb = b.1.position!
          let la = Vec3(x: pa.0, y: pa.1, z: pa.2).dot(normal)
          let lb = Vec3(x: pb.0, y: pb.1, z: pb.2).dot(normal)
          return la < lb
        }

        // Estimate slice spacing from adjacent projected distances (median).
        var deltas: [Float] = []
        deltas.reserveCapacity(max(0, sorted.count - 1))

        for i in 0..<(sorted.count - 1) {
          let p1 = sorted[i].1.position!
          let p2 = sorted[i + 1].1.position!
          let l1 = Vec3(x: p1.0, y: p1.1, z: p1.2).dot(normal)
          let l2 = Vec3(x: p2.0, y: p2.1, z: p2.2).dot(normal)
          let d = abs(l2 - l1)

          // Skip zero/near-zero deltas (duplicate locations).
          if d > 1e-4 {
            deltas.append(d)
          }
        }

        sliceSpacingZ = median(deltas)
      }
    }

    // Fallback Z spacing if geometry-derived spacing is unavailable.
    // Note: sliceThickness and spaceBetweenSlices are not always equal
    // to spacing (gaps can exist), but it’s a reasonable fallback if
    // positions are missing.
    let fallbackSpace = filtered.compactMap({ $0.1.spaceBetweenSlices }).first
    let fallbackThickness = filtered.compactMap({ $0.1.sliceThickness }).first
    let z = sliceSpacingZ ?? fallbackSpace ?? fallbackThickness ?? 1

    let millimetersToMeters: Float = 0.001
    let voxelSpacing = (
      x: inPlane.x * millimetersToMeters,
      y: inPlane.y * millimetersToMeters,
      z: z * millimetersToMeters
    )


    let depth = sorted.count
    // Allocate a buffer for all voxel data
    let volumeByteCount = try checkedProduct(
      width, height, depth, bytesPerVoxel,
      tag: .pixelData
    )
    var buffer = [UInt8](repeating: 0, count: volumeByteCount)

    // Decode each slice and copy its pixels into the buffer
    for (i, (file, slice)) in sorted.enumerated() {
      try cancellationToken?.checkCancellation()
      let sliceByteCount = try checkedProduct(width, height, bytesPerVoxel, tag: .pixelData)
      let offset = try checkedProduct(i, sliceByteCount, tag: .pixelData)
      let pixels = try slice.decodedPixels(using: file.transferSyntax.pixelDataEncoding)
      guard pixels.count == sliceByteCount else {
        throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
      }
      buffer.replaceSubrange(offset..<offset + pixels.count, with: pixels)
      logger?.progress(
        "Decoding DICOM volume",
        Double(i + 1) / Double(sorted.count)
      )
    }

    let metaSource = parsed.first!.1

    return DicomVolume(
      width: width,
      height: height,
      depth: depth,
      bytesPerVoxel: bytesPerVoxel,
      voxelSpacing: voxelSpacing,
      orientation: orientation,
      voxelData: buffer,
      modality: metaSource.modality,
      patientName: metaSource.patientName,
      seriesDate: metaSource.seriesDate
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
    /// Bits actally used per sample.
    let bitsStored: UInt16?
    /// Pixel representation (e.g., signed vs unsigned).
    let pixelRepresentation: UInt16?
    /// Physical slice thickness (if provided).
    let sliceThickness: Float?
    /// Physical space between slices (if provided).
    let spaceBetweenSlices: Float?
    /// Pixel spacing in x and y dimensions (if provided).
    let pixelSpacing: (Float, Float)?
    /// Patient position (x, y, z) of this slice.
    let position: (Float, Float, Float)?
    /// Orientation direction cosines (six values).
    let orientation: [Float]?
    /// Instance number for ordering slices.
    let instanceNumber: Int?

    let modality: String?
    let patientName: String?
    let seriesDate: String?

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
          let expectedByteCount = try DicomParser.checkedProduct(
            Int(rows),
            Int(columns),
            Int(samplesPerPixel ?? 1),
            expectedBytesPerPixel,
            maximum: DicomParser.maximumDecodedSliceBytes,
            tag: .pixelData
          )

          guard pixelData.count >= expectedByteCount else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }

          return [UInt8](pixelData.prefix(expectedByteCount))

        case .jpeg2000:
          let fragments = try encapsulatedFragments()
          let j2kData = fragments.reduce(Data(), +)

          let reader = Jpeg2000Reader(referenceStoredBitsForNormalization: bitsStored.map(Int.init))
          let image = try reader.read(data: j2kData)

          // Optional validation against DICOM rows/columns
          if image.width != Int(columns) || image.height != Int(rows) {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }

          return image.pixels

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
          // Extract encapsulated JPEG fragments (skip BOT) and decode the JPEG Lossless (SOF3) codestream.
          let fragments = try encapsulatedFragments()
          let jpegData = fragments.reduce(Data(), +)

          guard jpegData.starts(with: [0xFF, 0xD8]) else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }

          let reader = JpegLosslessReader()
          do {
            let image1 = try reader.read(data: jpegData)
            return image1.pixels
          } catch {
            throw DicomParsingError.jpegDecodingFailed
          }

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
      var isFirstItem = true

      let reader = ByteReader(data: pixelData, endianness: .little)
      var foundDelimiter = false

      while offset < pixelData.count {
        guard pixelData.count - offset >= 8 else {
          throw DicomParsingError.invalidElementValue(.pixelData)
        }
        let group = try reader.uint16(at: offset)
        let element = try reader.uint16(at: offset + 2)
        let length = try reader.uint32(at: offset + 4)
        offset += 8

        if (group, element) == (0xFFFE, 0xE000) {
          guard length != UInt32.max else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          let itemLength = Int(length)
          let itemData: Data
          do {
            itemData = try reader.bytes(at: offset, count: itemLength)
          } catch {
            throw DicomParsingError.invalidElementValue(.pixelData)
          }

          // Skip Basic Offset Table (first item)
          if isFirstItem {
            isFirstItem = false
          } else {
            fragments.append(itemData)
          }

          offset += itemLength

        } else if (group, element) == (0xFFFE, 0xE0DD) {
          // Sequence Delimitation Item
          guard length == 0 else {
            throw DicomParsingError.invalidElementValue(.pixelData)
          }
          foundDelimiter = true
          break
        } else {
          throw DicomParsingError.invalidElementValue(.pixelData)
        }
      }

      guard foundDelimiter, !isFirstItem else {
        throw DicomParsingError.invalidElementValue(.pixelData)
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
      let reader = ByteReader(data: data, endianness: .little)
      let numberOfSegments = Int(try reader.uint32(at: 0))
      guard numberOfSegments > 0, numberOfSegments <= 15 else {
        throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
      }

      var segmentOffsets: [Int] = []
      for i in 0..<numberOfSegments {
        let offset = Int(try reader.uint32(at: 4 + i * 4))
        segmentOffsets.append(offset)
      }

      guard segmentOffsets.first == 64,
            segmentOffsets.allSatisfy({ (64...data.count).contains($0) }),
            zip(segmentOffsets, segmentOffsets.dropFirst()).allSatisfy({ $0 <= $1 }) else {
        throw DicomParsingError.invalidElementValue(.pixelData)
      }

      // Decode each segment separately
      let pixelCount = try DicomParser.checkedProduct(
        Int(rows), Int(columns),
        maximum: DicomParser.maximumDecodedSliceBytes,
        tag: .pixelData
      )
      let sampleCount = Int(samplesPerPixel ?? 1)
      let bytesPerSample = Int(((bitsAllocated ?? 8) + 7) / 8)
      let requiredSegments = try DicomParser.checkedProduct(
        sampleCount, bytesPerSample,
        tag: .pixelData
      )
      guard numberOfSegments == requiredSegments else {
        throw DicomParsingError.invalidElementValue(.pixelData)
      }
      var decodedSegments: [[UInt8]] = Array(repeating: [], count: numberOfSegments)
      for i in 0..<numberOfSegments {
        let start = segmentOffsets[i]
        let end = (i + 1 < numberOfSegments) ? segmentOffsets[i + 1] : data.count
        guard start <= end else {
          throw DicomParsingError.invalidElementValue(.pixelData)
        }
        let segmentData = try reader.bytes(at: start, count: end - start)
        decodedSegments[i] = try decodeRLESegment(segmentData, expectedByteCount: pixelCount)
      }

      // Interleave segments into final pixel array
      let resultByteCount = try DicomParser.checkedProduct(
        pixelCount, sampleCount, bytesPerSample,
        maximum: DicomParser.maximumDecodedSliceBytes,
        tag: .pixelData
      )
      var result = [UInt8](repeating: 0, count: resultByteCount)
      for pixelIndex in 0..<pixelCount {
        for sampleIndex in 0..<sampleCount {
          for bytePlane in 0..<bytesPerSample {
            let segmentIndex = sampleIndex * bytesPerSample + bytePlane
            let outputIndex = (pixelIndex * sampleCount + sampleIndex) * bytesPerSample + bytePlane
            result[outputIndex] = decodedSegments[segmentIndex][pixelIndex]
          }
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
    private func decodeRLESegment(_ segment: Data, expectedByteCount: Int) throws -> [UInt8] {
      var output: [UInt8] = []
      output.reserveCapacity(expectedByteCount)
      var i = 0
      while i < segment.count {
        let control = Int8(bitPattern: segment[i])
        i += 1
        if control >= 0 {
          let count = Int(control) + 1
          guard i + count <= segment.count else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          guard output.count <= expectedByteCount - count else {
            throw DicomParsingError.invalidElementValue(.pixelData)
          }
          output.append(contentsOf: segment[i..<i+count])
          i += count
        } else if control >= -127 {
          guard i < segment.count else {
            throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
          }
          let value = segment[i]
          i += 1
          let count = 1 - Int(control)
          guard output.count <= expectedByteCount - count else {
            throw DicomParsingError.invalidElementValue(.pixelData)
          }
          output.append(contentsOf: repeatElement(value, count: count))
        }
        // -128 is a no-op
      }
      guard output.count == expectedByteCount else {
        throw DicomParsingError.invalidElementValue(.pixelData)
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

  // Common VR inference for frequently used DICOM tags.
  // Returns a VR string like "US", "UL", "CS", "SQ", etc., or UN if unknown.
  static func inferredVR(for tag: DicomTag) -> String {
    // Lookup in centralized map defined in DicomVRMap.swift
    let tag = DicomTag(tag.group, tag.element)
    let vr = DicomVRMap.vr(for: tag)
    return vr
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
  static func readElement(at startOffset: Int, in data: Data, using encoding: DataElementEncoding) throws -> (element: DicomElement, nextOffset: Int) {
    let requestedReader = ByteReader(data: data, endianness: endianness(for: encoding))
    let littleEndianReader = ByteReader(data: data, endianness: .little)
    _ = try requestedReader.checkedEnd(offset: startOffset, length: 8)

    // File-meta information is always Explicit VR Little Endian, even when the dataset is big endian.
    let littleEndianGroup = try littleEndianReader.uint16(at: startOffset)
    let actualEncoding: DataElementEncoding = littleEndianGroup == 0x0002
      ? .explicitVRLittleEndian
      : encoding
    let reader = ByteReader(data: data, endianness: endianness(for: actualEncoding))
    let group = try reader.uint16(at: startOffset)
    let element = try reader.uint16(at: startOffset + 2)
    let tag = DicomTag(group, element)
    var offset = startOffset + 4

    // Item and delimitation tags have no VR field and always use the 8-byte item header.
    if group == 0xFFFE {
      let rawLength = try reader.uint32(at: offset)
      offset += 4
      let length = Int(rawLength)
      let nextOffset: Int
      if rawLength == UInt32.max {
        nextOffset = offset
      } else {
        nextOffset = try reader.checkedEnd(offset: offset, length: length)
      }
      return (
        element: DicomElement(
          tag: tag,
          vr: "NA",
          length: length,
          valueOffset: offset,
          isSequence: false
        ),
        nextOffset: nextOffset
      )
    }

    let vr: String
    let rawLength: UInt32

    if actualEncoding == .implicitVRLittleEndian {
      vr = inferredVR(for: tag)
      rawLength = try reader.uint32(at: offset)
      offset += 4
    } else {
      vr = String(data: try reader.bytes(at: offset, count: 2), encoding: .ascii) ?? "UN"
      offset += 2

      let isLongVR = ["OB", "OW", "OF", "SQ", "UT", "UN"].contains(vr)

      if isLongVR {
        _ = try reader.checkedEnd(offset: offset, length: 6)
        offset += 2 // skip the 2 reserved bytes
        rawLength = try reader.uint32(at: offset)
        offset += 4
      } else {
        rawLength = UInt32(try reader.uint16(at: offset))
        offset += 2
      }
    }

    let length = Int(rawLength)
    if rawLength == UInt32.max {
      return (
        element: DicomElement(tag: tag, vr: "SQ", length: length, valueOffset: offset, isSequence: true),
        nextOffset: offset
      )
    }

    let nextOffset = try reader.checkedEnd(offset: offset, length: length)
    return (
      element: DicomElement(tag: tag, vr: vr, length: length, valueOffset: offset, isSequence: vr == "SQ"),
      nextOffset: nextOffset
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

    let reader = ByteReader(data: data, endianness: .little)
    guard String(data: try reader.bytes(at: 128, count: 4), encoding: .ascii) == "DICM" else {
      throw DicomParsingError.missingDICMPrefix
    }

    var offset = 132
    var transferSyntaxUID: String?

    // Scan file meta-information for TransferSyntaxUID tag
    while offset < data.count {
      let parsed = try readElement(at: offset, in: data, using: .explicitVRLittleEndian)
      let tag = parsed.element.tag
      guard tag.group == 0x0002 else { break }

      if tag == .transferSyntaxUID {
        let uidData = try reader.bytes(
          at: parsed.element.valueOffset,
          count: parsed.element.length
        )
        transferSyntaxUID = String(data: uidData, encoding: .ascii)?
          .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        break
      }

      guard parsed.nextOffset > offset else {
        throw DicomParsingError.incompleteElementHeader
      }
      offset = parsed.nextOffset
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
  static func extractElements(from dicom: DicomFile) throws -> [DicomTag: DicomElement] {
    let offset = 132
    var result: [DicomTag: DicomElement] = [:]

    /// Recursively scan data elements, handling sequences and undefined lengths.
    func scanElements(in data: Data, startingAt offset: Int, using encoding: DataElementEncoding, depth: Int = 0) throws -> Int {
      guard depth <= maximumSequenceDepth else {
        throw DicomParsingError.invalidElementValue(DicomTag(0xFFFE, 0xE000))
      }
      var currentOffset = offset
      let startOffset = offset
      var visitedOffsets = Set<Int>()
      let reader = ByteReader(data: data, endianness: endianness(for: encoding))

      while currentOffset < data.count, !visitedOffsets.contains(currentOffset) {
        visitedOffsets.insert(currentOffset)

        var (element, nextOffset) = try readElement(at: currentOffset, in: data, using: encoding)

        // Stop at sequence delimitation
        if element.tag.group == 0xFFFE {
          guard element.tag.element == 0xE00D || element.tag.element == 0xE0DD else {
            throw DicomParsingError.invalidElementValue(element.tag)
          }
          currentOffset = nextOffset
          return currentOffset - startOffset
        }

        // Handle undefined-length pixel data (encapsulated)
        if element.tag.group == 0x7FE0 && element.tag.element == 0x0010 && element.length == 0xFFFFFFFF {
          var pixelOffset = element.valueOffset

          // Walk Item (FFFE,E000) blocks until Sequence Delimitation Item (FFFE,E0DD).
          var foundDelimiter = false
          while pixelOffset < data.count {
            guard data.count - pixelOffset >= 8 else {
              throw DicomParsingError.invalidElementValue(.pixelData)
            }
            let itemGroup = try reader.uint16(at: pixelOffset)
            let itemElement = try reader.uint16(at: pixelOffset + 2)
            let itemTag = DicomTag(itemGroup, itemElement)
            let itemLength = try reader.uint32(at: pixelOffset + 4)

            if itemTag.group == 0xFFFE && itemTag.element == 0xE000 {
              guard itemLength != UInt32.max else {
                throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
              }
              pixelOffset = try reader.checkedEnd(
                offset: pixelOffset + 8,
                length: Int(itemLength)
              )
              continue
            }

            if itemTag.group == 0xFFFE && itemTag.element == 0xE0DD {
              guard itemLength == 0 else {
                throw DicomParsingError.invalidElementValue(.pixelData)
              }
              // Include the 8-byte delimiter header.
              pixelOffset += 8
              foundDelimiter = true
              break
            }

            throw DicomParsingError.invalidElementValue(.pixelData)
          }

          guard foundDelimiter else {
            throw DicomParsingError.invalidElementValue(.pixelData)
          }

          let encapsulatedLength = pixelOffset - element.valueOffset

          // For encapsulated Pixel Data, store the full item stream (including item headers),
          // and advance the scanner to the byte after the sequence delimiter.
          element = DicomElement(
            tag: element.tag,
            vr: element.vr,
            length: encapsulatedLength,
            valueOffset: element.valueOffset,
            isSequence: false
          )
          nextOffset = pixelOffset
        }

        // Record element
        result[element.tag] = element

        // Recurse into sequences
        if element.isSequence {
          let hasUndefinedLength = element.length == undefinedLength
          let subrangeEnd = hasUndefinedLength ? data.count : nextOffset
          var itemOffset = element.valueOffset
          var maxOffset = itemOffset
          var foundDelimiter = false

          while itemOffset < subrangeEnd {
            guard subrangeEnd - itemOffset >= 8 else {
              throw DicomParsingError.invalidElementValue(element.tag)
            }
            let itemTag = DicomTag(
              try reader.uint16(at: itemOffset),
              try reader.uint16(at: itemOffset + 2)
            )
            let itemLength = try reader.uint32(at: itemOffset + 4)
            if itemTag.group == 0xFFFE && itemTag.element == 0xE000 {
              let itemDataStart = itemOffset + 8
              if itemLength == UInt32.max {
                let consumed = try scanElements(
                  in: data,
                  startingAt: itemDataStart,
                  using: encoding,
                  depth: depth + 1
                )
                itemOffset = itemDataStart + consumed
              } else {
                let itemDataEnd = try reader.checkedEnd(
                  offset: itemDataStart,
                  length: Int(itemLength)
                )
                guard itemDataEnd <= subrangeEnd else {
                  throw DicomParsingError.invalidElementValue(element.tag)
                }
                _ = try scanElements(
                  in: try reader.bytes(at: itemDataStart, count: Int(itemLength)),
                  startingAt: 0,
                  using: encoding,
                  depth: depth + 1
                )
                itemOffset = itemDataEnd
              }
              maxOffset = itemOffset
            } else if itemTag.group == 0xFFFE && itemTag.element == 0xE0DD {
              guard itemLength == 0 else {
                throw DicomParsingError.invalidElementValue(element.tag)
              }
              maxOffset = itemOffset + 8
              foundDelimiter = true
              break
            } else {
              throw DicomParsingError.invalidElementValue(element.tag)
            }
          }
          if hasUndefinedLength, !foundDelimiter {
            throw DicomParsingError.invalidElementValue(element.tag)
          }
          currentOffset = hasUndefinedLength ? maxOffset : nextOffset
        } else {
          currentOffset = nextOffset
        }

        guard currentOffset > startOffset else {
          throw DicomParsingError.incompleteElementHeader
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
  static func openSlice(from dicom: DicomFile) throws -> DicomSlice {
    let elements = try extractElements(from: dicom)

    // Ensure all non-optional tags are present
    let tagRequirements: [(DicomTag, Bool)] = [
      (.rows, false),
      (.columns, false),
      (.pixelData, false),
      (.samplesPerPixel, true),
      (.bitsAllocated, true),
      (.bitsStored, true),
      (.pixelRepresentation, true),
      (.sliceThickness, true),
      (.spaceBetweenSlices, true),
      (.pixelSpacing, true),
      (.imagePositionPatient, true),
      (.imageOrientationPatient, true),
      (.instanceNumber, true),
      (.modality, true),
      (.patientName, true),
      (.seriesDate, true)
    ]
    for (tag, isOptional) in tagRequirements where !isOptional {
      guard elements[tag] != nil else {
        throw DicomParsingError.tagNotFound(tag)
      }
    }

    // Helper to read UInt16 values
    func readUInt16(tag: DicomTag) -> UInt16? {
      guard let elem = elements[tag], elem.length >= 2 else { return nil }
      let reader = ByteReader(
        data: dicom.rawData,
        endianness: endianness(for: dicom.transferSyntax.elementEncoding)
      )
      return try? reader.uint16(at: elem.valueOffset)
    }

    // Helper to read Float from ASCII value
    func readFloat(tag: DicomTag) -> Float? {
      guard let elem = elements[tag] else { return nil }
      let reader = ByteReader(data: dicom.rawData, endianness: .little)
      guard let bytes = try? reader.bytes(at: elem.valueOffset, count: elem.length) else { return nil }
      let str = String(data: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
      return str.flatMap(Float.init)
    }

    // Helper to read ASCII value
    func readString(tag: DicomTag) -> String? {
      guard let elem = elements[tag] else { return nil }
      let reader = ByteReader(data: dicom.rawData, endianness: .little)
      guard let bytes = try? reader.bytes(at: elem.valueOffset, count: elem.length) else { return nil }
      let str = String(data: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
      return str
    }

    // Helper to read tuple of floats separated by backslashes
    func readFloatTuple(tag: DicomTag, count: Int) -> [Float]? {
      guard let elem = elements[tag] else { return nil }
      let reader = ByteReader(data: dicom.rawData, endianness: .little)
      guard let bytes = try? reader.bytes(at: elem.valueOffset, count: elem.length) else { return nil }
      let str = String(data: bytes, encoding: .ascii)
      let parts = str?
        .split(separator: "\\")
        .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
      return parts?.count == count ? parts : nil
    }

    // Helper to read instance number as Int
    func readInstanceNumber(tag: DicomTag) -> Int? {
      guard let elem = elements[tag] else { return nil }
      let reader = ByteReader(data: dicom.rawData, endianness: .little)
      guard let bytes = try? reader.bytes(at: elem.valueOffset, count: elem.length) else { return nil }
      let str = String(data: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
      return str.flatMap(Int.init)
    }

    let rows = readUInt16(tag: .rows) ?? 0
    let columns = readUInt16(tag: .columns) ?? 0
    let pixelData: Data
    if let elem = elements[.pixelData] {
      let start = elem.valueOffset
      let reader = ByteReader(data: dicom.rawData, endianness: .little)
      guard let bytes = try? reader.bytes(at: start, count: elem.length) else {
        throw DicomParsingError.invalidElementValue(DicomTag.pixelData)
      }
      pixelData = bytes
    } else {
      pixelData = Data()
    }

    return DicomSlice(
      rows: rows,
      columns: columns,
      pixelData: pixelData,
      samplesPerPixel: readUInt16(tag: .samplesPerPixel),
      bitsAllocated: readUInt16(tag: .bitsAllocated),
      bitsStored: readUInt16(tag: .bitsStored),
      pixelRepresentation: readUInt16(tag: .pixelRepresentation),
      sliceThickness: readFloat(tag: .sliceThickness),
      spaceBetweenSlices: readFloat(tag: .spaceBetweenSlices),
      pixelSpacing: readFloatTuple(tag: .pixelSpacing, count: 2).flatMap { ($0[0], $0[1]) },
      position: readFloatTuple(tag: .imagePositionPatient, count: 3).flatMap { ($0[0], $0[1], $0[2]) },
      orientation: readFloatTuple(tag: .imageOrientationPatient, count: 6),
      instanceNumber: readInstanceNumber(tag: .instanceNumber),
      modality: readString(tag:.modality),
      patientName: readString(tag:.patientName),
      seriesDate: readString(tag:.seriesDate)
    )
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
