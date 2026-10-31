import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import CoreVideo

public enum Jpeg2000Error: Error, LocalizedError {
  case invalidFormat(String)
  case unsupported(String)
  case unexpectedEof
  case imageIoDecodeFailed
  case jp2ContainerMissingCodestream
  case unsupportedCgImageFormat(String)

  public var errorDescription: String? {
    switch self {
      case .invalidFormat(let s): return "Invalid JPEG2000 format: \(s)"
      case .unsupported(let s): return "Unsupported JPEG2000 feature: \(s)"
      case .unexpectedEof: return "Unexpected end of data"
      case .imageIoDecodeFailed: return "ImageIO failed to decode JPEG2000 data"
      case .jp2ContainerMissingCodestream: return "JP2 container did not contain a jp2c codestream box"
      case .unsupportedCgImageFormat(let s): return "Unsupported CGImage format: \(s)"
    }
  }
}

public final class Jpeg2000Reader {

  public struct Jpeg2000Image {
    public let width: Int
    public let height: Int
    public let componentCount: Int
    /// Output bit depth of `pixels` (8 or 16).
    public let bitsPerComponent: Int
    public let isSigned: Bool
    /// Pixel bytes. For 16-bit output: little-endian (LSB first).
    public let pixels: [UInt8]
  }

  /// If provided (typically DICOM Bits Stored), 16-bit decoded pixels are normalized to match
  /// that reference bit depth across slices. This compensates for per-slice scaling differences
  /// introduced by platform decoders when codestream precision varies (e.g., 11 vs 12).
  private let referenceStoredBitsForNormalization: Int?

  public init(referenceStoredBitsForNormalization: Int? = nil) {
    self.referenceStoredBitsForNormalization = referenceStoredBitsForNormalization
  }

  public func read(filename: String) throws -> Jpeg2000Image {
    let url = URL(fileURLWithPath: filename)
    let data = try Data(contentsOf: url)
    return try read(data: data)
  }

  public func read(data: Data) throws -> Jpeg2000Image {
    guard data.count >= 4 else { throw Jpeg2000Error.invalidFormat("Too small") }

    let normalized = trimTrailingZeroPadding(data)

    let input = try classifyAndExtractCodestream(from: normalized)
    let info = try J2kCodestreamInfo.parse(from: input.codestream)

    guard info.componentCount == 1 else {
      throw Jpeg2000Error.unsupported("Only 1-component (grayscale) JPEG2000 is implemented for now")
    }

    // Prefer: CoreImage decode from container bytes -> OneComponent16
    // (avoids CGImage 8-bit path on some systems)
    let containerForCI: Data = {
      if input.wasRawCodestream {
        return Jp2Builder.wrapCodestreamAsJp2(
          input.codestream,
          width: info.width,
          height: info.height,
          componentCount: info.componentCount,
          bitsPerComponent: info.bitsPerComponent,
          isSigned: info.isSigned
        )
      } else {
        return input.containerData
      }
    }()

    if let px16 = decodeViaCoreImageFromDataTo16(
      containerData: containerForCI,
      width: info.width,
      height: info.height
    ) {
      let normalized16 = normalizeDecoded16LEIfNeeded(
        px16,
        codestreamBits: info.bitsPerComponent
      )

      return Jpeg2000Image(
        width: info.width,
        height: info.height,
        componentCount: info.componentCount,
        bitsPerComponent: 16,
        isSigned: info.isSigned,
        pixels: normalized16
      )
    }

    // Fallback: ImageIO -> CGImage
    let cgImage: CGImage
    if let img = createCgImageWithImageIo(from: input.containerData) {
      cgImage = img
    } else if input.wasRawCodestream {
      let jp2 = Jp2Builder.wrapCodestreamAsJp2(
        input.codestream,
        width: info.width,
        height: info.height,
        componentCount: info.componentCount,
        bitsPerComponent: info.bitsPerComponent,
        isSigned: info.isSigned
      )
      guard let img = createCgImageWithImageIo(from: jp2) else {
        throw Jpeg2000Error.imageIoDecodeFailed
      }
      cgImage = img
    } else {
      throw Jpeg2000Error.imageIoDecodeFailed
    }

    // Prefer provider bytes if already usable; otherwise force grayscale via CoreImage (from CGImage),
    // and only then fallback to CGContext.draw.
    let outIs16 = info.bitsPerComponent > 8
    var pixels: [UInt8]

    if let direct = try extractGrayscaleBytesDirectIfPossible(
      cgImage: cgImage,
      width: info.width,
      height: info.height,
      desiredBits: info.bitsPerComponent
    ) {
      pixels = direct
    } else if let viaCI = try renderViaCoreImageToGrayscaleBytes(
      cgImage: cgImage,
      width: info.width,
      height: info.height,
      desiredBits: info.bitsPerComponent
    ) {
      pixels = viaCI
    } else {
      pixels = try renderCgImageToGrayscaleBytes(
        cgImage: cgImage,
        width: info.width,
        height: info.height,
        bitsPerComponent: info.bitsPerComponent
      )
    }

    if outIs16 {
      pixels = normalizeDecoded16LEIfNeeded(pixels, codestreamBits: info.bitsPerComponent)
    }

    return Jpeg2000Image(
      width: info.width,
      height: info.height,
      componentCount: info.componentCount,
      bitsPerComponent: outIs16 ? 16 : 8,
      isSigned: info.isSigned,
      pixels: pixels
    )
  }

  // MARK: - ImageIO decode

  private func createCgImageWithImageIo(from data: Data) -> CGImage? {
    let options: CFDictionary = [
      kCGImageSourceShouldCache: false
    ] as CFDictionary

    guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
      return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, options)
  }

  // MARK: - CoreImage decode from container bytes (preferred if it yields 16-bit reliably)

  private func decodeViaCoreImageFromDataTo16(
    containerData: Data,
    width: Int,
    height: Int
  ) -> [UInt8]? {

    guard let ciImage = CIImage(data: containerData) else { return nil }

    let ctx = CIContext(options: [
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull()
    ])

    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent16,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]

    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_OneComponent16,
      attrs as CFDictionary,
      &pb
    ) == kCVReturnSuccess,
          let pixelBuffer = pb else { return nil }

    ctx.render(ciImage, to: pixelBuffer)

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let size = bpr * height
    return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: size))
  }

  // MARK: - Normalization (codestream precision -> reference stored bits), 16-bit LE buffer

  private func normalizeDecoded16LEIfNeeded(_ pixels: [UInt8], codestreamBits: Int) -> [UInt8] {
    guard let refBits = referenceStoredBitsForNormalization else { return pixels }
    return normalizeDecoded16LE(pixels, codestreamBits: codestreamBits, referenceBits: refBits)
  }

  /// Normalizes a 16-bit little-endian pixel buffer so that slices with lower codestream precision
  /// (e.g. 11-bit) are scaled DOWN to match the reference bit depth (e.g. 12-bit).
  ///
  /// This direction (srcMax/refMax) matches the observed behavior where the platform decoder
  /// already expands lower-precision codestreams more aggressively, making them appear brighter.
  private func normalizeDecoded16LE(
    _ pixels: [UInt8],
    codestreamBits: Int,
    referenceBits: Int
  ) -> [UInt8] {
    guard pixels.count % 2 == 0 else { return pixels }
    guard codestreamBits > 0, referenceBits > 0 else { return pixels }
    guard codestreamBits != referenceBits else { return pixels }

    let srcMax = Double((1 << codestreamBits) - 1)
    let refMax = Double((1 << referenceBits) - 1)
    let scale = srcMax / refMax

    var out = pixels
    for i in stride(from: 0, to: out.count, by: 2) {
      let v = Double(UInt16(out[i]) | (UInt16(out[i + 1]) << 8))
      let s = Int((v * scale).rounded())
      let clamped = max(0, min(65535, s))
      out[i] = UInt8(clamped & 0xFF)
      out[i + 1] = UInt8((clamped >> 8) & 0xFF)
    }
    return out
  }

  // MARK: - Prefer raw bytes from CGImage provider (no CGContext.draw)

  private func extractGrayscaleBytesDirectIfPossible(
    cgImage: CGImage,
    width: Int,
    height: Int,
    desiredBits: Int
  ) throws -> [UInt8]? {

    guard cgImage.width == width, cgImage.height == height else { return nil }
    guard cgImage.colorSpace?.model == .monochrome else { return nil }

    let alpha = cgImage.alphaInfo
    guard alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast else { return nil }

    guard let provider = cgImage.dataProvider, let cfData = provider.data else { return nil }

    let srcBpc = cgImage.bitsPerComponent
    let srcBpp = cgImage.bitsPerPixel
    let srcBpr = cgImage.bytesPerRow

    // Tight packed 16-bit gray
    if srcBpc == 16 && srcBpp == 16 && srcBpr == width * 2 {
      let length = CFDataGetLength(cfData)
      guard let ptr = CFDataGetBytePtr(cfData) else { return nil }
      var bytes = Array(UnsafeBufferPointer(start: ptr, count: length))

      // Ensure little-endian output
      let isBigEndian = cgImage.bitmapInfo.contains(.byteOrder16Big)
      if isBigEndian {
        for i in stride(from: 0, to: bytes.count, by: 2) {
          if i + 1 < bytes.count { bytes.swapAt(i, i + 1) }
        }
      }
      return bytes
    }

    // Tight packed 8-bit gray
    if srcBpc == 8 && srcBpp == 8 && srcBpr == width {
      let length = CFDataGetLength(cfData)
      guard let ptr = CFDataGetBytePtr(cfData) else { return nil }
      let bytes8 = Array(UnsafeBufferPointer(start: ptr, count: length))

      if desiredBits > 8 {
        // Expand 8->16 by v*257 into little-endian
        var out = [UInt8](repeating: 0, count: width * height * 2)
        var j = 0
        for v in bytes8 {
          let u16 = UInt16(v) * 257
          out[j] = UInt8(u16 & 0xFF)
          out[j + 1] = UInt8((u16 >> 8) & 0xFF)
          j += 2
        }
        return out
      }
      return bytes8
    }

    return nil
  }

  // MARK: - Controlled conversion via CoreImage (from CGImage) to known pixel format

  private func renderViaCoreImageToGrayscaleBytes(
    cgImage: CGImage,
    width: Int,
    height: Int,
    desiredBits: Int
  ) throws -> [UInt8]? {

    let outBits: Int = (desiredBits > 8) ? 16 : 8
    let pixelFormat: OSType = (outBits == 16) ? kCVPixelFormatType_OneComponent16 : kCVPixelFormatType_OneComponent8

    let ciImage = CIImage(cgImage: cgImage)

    let ciContext = CIContext(options: [
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull()
    ])

    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferPixelFormatTypeKey: pixelFormat,
      kCVPixelBufferIOSurfacePropertiesKey: [:]
    ]

    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let pixelBuffer = pb else {
      return nil
    }

    ciContext.render(ciImage, to: pixelBuffer)

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let size = bpr * height
    let ptr = base.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: ptr, count: size))
  }

  // MARK: - CGContext fallback

  private func renderCgImageToGrayscaleBytes(
    cgImage: CGImage,
    width: Int,
    height: Int,
    bitsPerComponent: Int
  ) throws -> [UInt8] {

    let outBits: Int = (bitsPerComponent > 8) ? 16 : 8
    let bytesPerPixel = outBits / 8
    let bytesPerRow = width * bytesPerPixel
    let bufferSize = bytesPerRow * height

    var buffer = [UInt8](repeating: 0, count: bufferSize)

    try buffer.withUnsafeMutableBytes { raw in
      guard let baseAddress = raw.baseAddress else {
        throw Jpeg2000Error.invalidFormat("Failed to allocate output buffer")
      }

      let colorSpace = CGColorSpaceCreateDeviceGray()
      let bitmapInfo: UInt32
      if outBits == 16 {
        bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.none.rawValue
      } else {
        bitmapInfo = CGImageAlphaInfo.none.rawValue
      }

      guard let context = CGContext(
        data: baseAddress,
        width: width,
        height: height,
        bitsPerComponent: outBits,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      ) else {
        throw Jpeg2000Error.invalidFormat("Failed to create CGContext for grayscale render")
      }

      context.interpolationQuality = .none
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    return buffer
  }

  // MARK: - Input classification (JP2 vs raw J2K)

  private struct CodestreamInput {
    let codestream: Data
    let containerData: Data
    let wasRawCodestream: Bool
  }

  private func classifyAndExtractCodestream(from data: Data) throws -> CodestreamInput {
    // Raw J2K codestream must start with SOC (FF 4F) for DICOM JPEG2000 payloads.
    if data.count >= 2, data[0] == 0xFF, data[1] == 0x4F {
      // Validate EOC (FF D9) after trimming.
      guard data.count >= 2, data[data.count - 2] == 0xFF, data[data.count - 1] == 0xD9 else {
        throw Jpeg2000Error.invalidFormat("Missing EOC (FF D9) at end of codestream (likely truncated fragments)")
      }
      return CodestreamInput(codestream: data, containerData: data, wasRawCodestream: true)
    }

    if looksLikeJp2(data) {
      let codestream = try extractJp2cCodestream(from: data)
      return CodestreamInput(codestream: codestream, containerData: data, wasRawCodestream: false)
    }

    throw Jpeg2000Error.invalidFormat("Data is neither raw J2K codestream nor JP2 container")
  }

  private func looksLikeJp2(_ data: Data) -> Bool {
    guard data.count >= 12 else { return false }
    return data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x0C
    && data[4] == 0x6A && data[5] == 0x50 && data[6] == 0x20 && data[7] == 0x20
    && data[8] == 0x0D && data[9] == 0x0A && data[10] == 0x87 && data[11] == 0x0A
  }

  private func extractJp2cCodestream(from jp2: Data) throws -> Data {
    var offset = 0

    while offset + 8 <= jp2.count {
      let boxLen = Int(readUInt32BE(jp2, offset))
      let boxType = readAscii4(jp2, offset + 4)

      guard boxLen >= 8, offset + boxLen <= jp2.count else {
        throw Jpeg2000Error.invalidFormat("Invalid JP2 box length")
      }

      if boxType == "jp2c" {
        let payloadStart = offset + 8
        let payloadEnd = offset + boxLen
        return jp2.subdata(in: payloadStart..<payloadEnd)
      }

      offset += boxLen
    }

    throw Jpeg2000Error.jp2ContainerMissingCodestream
  }

  // MARK: - Padding trim (DICOM fragments are even-length and may be padded)

  private func trimTrailingZeroPadding(_ data: Data) -> Data {
    if data.isEmpty { return data }
    var end = data.count
    while end > 0 && data[end - 1] == 0x00 { end -= 1 }
    if end == data.count { return data }
    return data.prefix(end)
  }

  // MARK: - Small BE helpers

  private func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
    return (UInt32(data[offset]) << 24)
    | (UInt32(data[offset + 1]) << 16)
    | (UInt32(data[offset + 2]) << 8)
    | UInt32(data[offset + 3])
  }

  private func readAscii4(_ data: Data, _ offset: Int) -> String {
    let sub = data.subdata(in: offset..<(offset + 4))
    return String(bytes: sub, encoding: .ascii) ?? "????"
  }
}

// MARK: - J2K SIZ parser (extract dimensions/bit depth)

private struct J2kCodestreamInfo {
  let width: Int
  let height: Int
  let componentCount: Int
  let bitsPerComponent: Int
  let isSigned: Bool

  static func parse(from codestream: Data) throws -> J2kCodestreamInfo {
    var r = ByteReader(data: codestream)

    let soc = try r.readUInt16BE()
    guard soc == 0xFF4F else {
      throw Jpeg2000Error.invalidFormat("Missing SOC (FF 4F)")
    }

    while !r.isAtEnd {
      let marker = try r.readUInt16BE()

      switch marker {
        case 0xFF51: // SIZ
          let lsiz = try r.readUInt16BE()
          guard lsiz >= 2 else { throw Jpeg2000Error.invalidFormat("Invalid SIZ length") }
          let start = r.offset

          _ = try r.readUInt16BE() // Rsiz
          let xsiz = try r.readUInt32BE()
          let ysiz = try r.readUInt32BE()
          let xosiz = try r.readUInt32BE()
          let yosiz = try r.readUInt32BE()
          _ = try r.readUInt32BE() // XTsiz
          _ = try r.readUInt32BE() // YTsiz
          _ = try r.readUInt32BE() // XTOsiz
          _ = try r.readUInt32BE() // YTOsiz
          let csiz = try r.readUInt16BE()

          guard csiz > 0 else { throw Jpeg2000Error.invalidFormat("Csiz == 0") }

          var precisions: [Int] = []
          precisions.reserveCapacity(Int(csiz))
          var anySigned = false

          for _ in 0..<csiz {
            let ssiz = try r.readByte()
            let precision = Int(ssiz & 0x7F) + 1
            let signed = (ssiz & 0x80) != 0
            anySigned = anySigned || signed
            precisions.append(precision)
            _ = try r.readByte() // XRsiz
            _ = try r.readByte() // YRsiz
          }

          let w = Int(xsiz) - Int(xosiz)
          let h = Int(ysiz) - Int(yosiz)
          guard w > 0, h > 0 else {
            throw Jpeg2000Error.invalidFormat("Non-positive image size from SIZ")
          }

          let bits = precisions.max() ?? 8

          // Skip any remaining bytes in this marker segment
          let consumed = r.offset - start
          let expected = Int(lsiz) - 2
          if consumed < expected {
            try r.skip(expected - consumed)
          }

          return J2kCodestreamInfo(
            width: w,
            height: h,
            componentCount: Int(csiz),
            bitsPerComponent: bits,
            isSigned: anySigned
          )

        default:
          // Most marker segments have a 2-byte length field.
          // (SOC/SOD/EOC special markers are not expected here for our purposes.)
          let length = try r.readUInt16BE()
          guard length >= 2 else { throw Jpeg2000Error.invalidFormat("Invalid marker segment length") }
          try r.skip(Int(length) - 2)
      }
    }

    throw Jpeg2000Error.invalidFormat("SIZ marker not found in codestream")
  }
}

private struct ByteReader {
  let bytes: [UInt8]
  var offset: Int

  init(data: Data) {
    self.bytes = [UInt8](data)
    self.offset = 0
  }

  var isAtEnd: Bool { offset >= bytes.count }

  mutating func readByte() throws -> UInt8 {
    guard offset < bytes.count else { throw Jpeg2000Error.unexpectedEof }
    let v = bytes[offset]
    offset += 1
    return v
  }

  mutating func readUInt16BE() throws -> UInt16 {
    let b0 = UInt16(try readByte())
    let b1 = UInt16(try readByte())
    return (b0 << 8) | b1
  }

  mutating func readUInt32BE() throws -> UInt32 {
    let b0 = UInt32(try readByte())
    let b1 = UInt32(try readByte())
    let b2 = UInt32(try readByte())
    let b3 = UInt32(try readByte())
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
  }

  mutating func skip(_ count: Int) throws {
    guard count >= 0 else { throw Jpeg2000Error.invalidFormat("Negative skip") }
    guard offset + count <= bytes.count else { throw Jpeg2000Error.unexpectedEof }
    offset += count
  }
}

// MARK: - Minimal JP2 wrapper for ImageIO / CoreImage fallback

private enum Jp2Builder {
  static func wrapCodestreamAsJp2(
    _ codestream: Data,
    width: Int,
    height: Int,
    componentCount: Int,
    bitsPerComponent: Int,
    isSigned: Bool
  ) -> Data {

    var out = Data()

    // Signature box
    out.appendBox(type: "jP  ", payload: Data([0x0D, 0x0A, 0x87, 0x0A]))

    // File Type box
    var ftyp = Data()
    ftyp.appendAscii4("jp2 ")
    ftyp.appendUInt32BE(0)
    ftyp.appendAscii4("jp2 ")
    out.appendBox(type: "ftyp", payload: ftyp)

    // JP2 header box (jp2h) with ihdr + colr (enumerated)
    var jp2h = Data()

    // Image Header (ihdr)
    var ihdr = Data()
    ihdr.appendUInt32BE(UInt32(height))
    ihdr.appendUInt32BE(UInt32(width))
    ihdr.appendUInt16BE(UInt16(componentCount))

    // BPC: bits-1, MSB indicates signedness
    var bpc = UInt8(max(1, min(255, bitsPerComponent)) - 1)
    if isSigned { bpc |= 0x80 }
    ihdr.append(bpc)

    ihdr.append(0x07) // compression type = JPEG 2000
    ihdr.append(0x00) // unknown color space = false (we provide colr)
    ihdr.append(0x00) // intellectual property = false
    jp2h.appendBox(type: "ihdr", payload: ihdr)

    // Colour Specification (colr): enumerated
    var colr = Data()
    colr.append(0x01) // METH = 1 (enumerated)
    colr.append(0x00) // precedence
    colr.append(0x00) // approximation
    let enumCs: UInt32 = (componentCount == 1) ? 17 : 16 // 17 = grayscale
    colr.appendUInt32BE(enumCs)
    jp2h.appendBox(type: "colr", payload: colr)

    out.appendBox(type: "jp2h", payload: jp2h)

    // Contiguous codestream box (jp2c)
    out.appendBox(type: "jp2c", payload: codestream)

    return out
  }
}

private extension Data {
  mutating func appendUInt32BE(_ value: UInt32) {
    append(UInt8((value >> 24) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8(value & 0xFF))
  }

  mutating func appendUInt16BE(_ value: UInt16) {
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8(value & 0xFF))
  }

  mutating func appendAscii4(_ s: String) {
    let bytes = Array(s.utf8)
    precondition(bytes.count == 4, "Expected 4 ASCII bytes")
    append(contentsOf: bytes)
  }

  mutating func appendBox(type: String, payload: Data) {
    let boxLen = UInt32(payload.count + 8)
    appendUInt32BE(boxLen)
    appendAscii4(type)
    append(payload)
  }
}
