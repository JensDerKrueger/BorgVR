import Foundation

public struct JpegLosslessImage {
  public let width: Int
  public let height: Int
  public let bitsPerSample: Int
  public let componentCount: Int
  public let bytesPerSample: Int
  public let pixels: [UInt8]

  public init(width: Int, height: Int, bitsPerSample: Int, componentCount: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    self.bitsPerSample = bitsPerSample
    self.componentCount = componentCount
    self.bytesPerSample = (bitsPerSample + 7) / 8
    self.pixels = pixels
  }

  /// Convenience for 9–16 bit data when `bytesPerSample == 2` (little-endian).
  public func pixelValuesUInt16() -> [UInt16]? {
    guard bytesPerSample == 2 else { return nil }
    let count = pixels.count / 2
    var out: [UInt16] = []
    out.reserveCapacity(count)

    var i = 0
    while i + 1 < pixels.count {
      let lo = UInt16(pixels[i])
      let hi = UInt16(pixels[i + 1]) << 8
      out.append(lo | hi)
      i += 2
    }
    return out
  }
}

public enum JpegLosslessError: Error, CustomStringConvertible {
  case invalidFormat(String)
  case unsupported(String)
  case unexpectedEof
  case missingFrameHeader
  case missingScan
  case missingHuffmanTable(tableClass: Int, tableId: Int)
  case entropyEndedEarly(marker: UInt8)
  case sampleOutOfRange(value: Int, min: Int, max: Int)

  public var description: String {
    switch self {
      case .invalidFormat(let msg): return "Invalid JPEG format: \(msg)"
      case .unsupported(let msg): return "Unsupported JPEG feature: \(msg)"
      case .unexpectedEof: return "Unexpected end of file"
      case .missingFrameHeader: return "Missing SOF3 (lossless) frame header"
      case .missingScan: return "Missing SOS (start of scan)"
      case .missingHuffmanTable(let tableClass, let tableId):
        return "Missing Huffman table (class=\(tableClass), id=\(tableId))"
      case .entropyEndedEarly(let marker):
        return String(format: "Entropy-coded data ended early at marker 0x%02X", marker)
      case .sampleOutOfRange(let value, let min, let max):
        return "Decoded sample out of range (\(value) not in \(min)...\(max))"
    }
  }
}


/// JPEG Lossless (SOF3) reader/decoder intended for DICOM-style lossless JPEG bitstreams.
/// Supports:
/// - SOF3 (lossless, Huffman-coded, non-hierarchical)
/// - Single scan (SOS)
/// - 1 or more components, but requires no subsampling (H=1,V=1 for all components)
/// - Bits per sample: 1...16 (output bytes are little-endian for 9...16 bit)
///
/// Not supported (throws):
/// - JPEG-LS (different codec), arithmetic coding, progressive, hierarchical
/// - Subsampling (H/V != 1)
/// - Restart intervals (DRI) / restart markers
public final class JpegLosslessReader {

  public init() {}

  /// Main entry point: pass the raw bytes of a JPEG Lossless (SOF3) file/bitstream.
  public func read(data: Data) throws -> JpegLosslessImage {


    let stream = ByteStream(data: data)

    var frame: FrameHeader?
    var dcHuffmanTables: [Int: HuffmanTable] = [:]
    var restartInterval: Int = 0

    // Must start with SOI
    let soi = try stream.readMarker()
    guard soi == Marker.soi else {
      throw JpegLosslessError.invalidFormat(String(format: "Expected SOI (FFD8), got marker 0x%02X", soi))
    }

    var nextMarker: UInt8? = nil
    var didDecodeScan = false

    while true {
      let marker: UInt8
      if let m = nextMarker {
        marker = m
        nextMarker = nil
      } else {
        marker = try stream.readMarker()
      }

      switch marker {
        case Marker.eoi:
          if !didDecodeScan {
            throw JpegLosslessError.missingScan
          }
          // Successfully reached end
          // The image is returned immediately after decoding scan, so this is typically not reached.
          break

        case Marker.sof3:
          let payload = try stream.readSegmentPayload()
          frame = try parseSof3(payload: payload)

        case Marker.dht:
          let payload = try stream.readSegmentPayload()
          try parseDht(payload: payload, dcTables: &dcHuffmanTables)

        case Marker.dri:
          let payload = try stream.readSegmentPayload()
          restartInterval = try parseDri(payload: payload)

        case Marker.sos:
          guard let frameHeader = frame else {
            throw JpegLosslessError.missingFrameHeader
          }
          if restartInterval != 0 {
            throw JpegLosslessError.unsupported("Restart intervals (DRI) are not implemented (restartInterval=\(restartInterval))")
          }

          let payload = try stream.readSegmentPayload()
          let scanHeader = try parseSos(payload: payload, frame: frameHeader)

          let (pixels, scanEndMarker) = try decodeLosslessScan(
            stream: stream,
            frame: frameHeader,
            scan: scanHeader,
            dcHuffmanTables: dcHuffmanTables
          )

          didDecodeScan = true

          // If scan ended with EOI, return now.
          if scanEndMarker == Marker.eoi {
            return JpegLosslessImage(
              width: frameHeader.width,
              height: frameHeader.height,
              bitsPerSample: frameHeader.precision,
              componentCount: frameHeader.componentCount,
              pixels: pixels
            )
          }

          // If scan ended with something else, continue parsing segments.
          nextMarker = scanEndMarker

        default:
          // Standalone markers without length (RSTn, TEM) are not expected here (outside entropy),
          // but ignoring them is safe.
          if Marker.isStandalone(marker: marker) {
            continue
          }
          // Skip any other segment types (APPn, COM, DQT, etc.)
          _ = try stream.readSegmentPayload()
      }

      if marker == Marker.eoi {
        break
      }
    }

    // If we got here without returning, the stream ended strangely.
    throw JpegLosslessError.invalidFormat("Unexpected end of parsing without returning decoded image")
  }

  /// Convenience: reads file bytes into a Data object and calls `read(data:)`.
  public func read(filename: String) throws -> JpegLosslessImage {
    let url = URL(fileURLWithPath: filename)
    let data = try Data(contentsOf: url)
    return try read(data: data)
  }
}

// MARK: - JPEG structures & decoding

private struct FrameHeader {
  let precision: Int
  let width: Int
  let height: Int
  let components: [FrameComponent]

  var componentCount: Int { components.count }
  var componentIndexById: [Int: Int] {
    var map: [Int: Int] = [:]
    for (idx, c) in components.enumerated() {
      map[c.id] = idx
    }
    return map
  }
}

private struct FrameComponent {
  let id: Int
  let h: Int
  let v: Int
}

private struct ScanHeader {
  let componentIdsInScan: [Int]
  let dcTableIdByScanIndex: [Int]
  let predictorSelection: Int
  let pointTransform: Int
  let scanToFrameIndex: [Int]
}

private func parseSof3(payload: [UInt8]) throws -> FrameHeader {
  let r = ByteStream(bytes: payload)

  let precision = try r.readByteInt()
  let height = try r.readUInt16BEInt()
  let width = try r.readUInt16BEInt()
  let componentCount = try r.readByteInt()

  guard precision >= 1 && precision <= 16 else {
    throw JpegLosslessError.unsupported("Sample precision \(precision) not supported (expected 1...16)")
  }
  guard width > 0 && height > 0 else {
    throw JpegLosslessError.invalidFormat("Invalid dimensions \(width)x\(height)")
  }
  guard componentCount >= 1 else {
    throw JpegLosslessError.invalidFormat("Invalid component count \(componentCount)")
  }

  var components: [FrameComponent] = []
  components.reserveCapacity(componentCount)

  for _ in 0..<componentCount {
    let id = try r.readByteInt()
    let hv = try r.readByteInt()
    let h = (hv >> 4) & 0x0F
    let v = hv & 0x0F
    _ = try r.readByteInt() // tq (quant table), not used in lossless

    guard h == 1 && v == 1 else {
      throw JpegLosslessError.unsupported("Subsampling not supported (component \(id) has H=\(h), V=\(v))")
    }

    components.append(FrameComponent(id: id, h: h, v: v))
  }

  return FrameHeader(precision: precision, width: width, height: height, components: components)
}

private func parseDht(payload: [UInt8], dcTables: inout [Int: HuffmanTable]) throws {
  let r = ByteStream(bytes: payload)

  while !r.isAtEnd {
    let tcTh = try r.readByteInt()
    let tableClass = (tcTh >> 4) & 0x0F // 0=DC, 1=AC
    let tableId = tcTh & 0x0F

    var counts: [Int] = []
    counts.reserveCapacity(16)
    var symbolCount = 0
    for _ in 0..<16 {
      let c = try r.readByteInt()
      counts.append(c)
      symbolCount += c
    }

    let symbols = try r.readBytes(symbolCount)

    // Lossless uses DC tables; keep only DC.
    if tableClass == 0 {
      let table = try HuffmanTable(codeLengthCounts: counts, symbols: symbols)
      dcTables[tableId] = table
    }
  }
}

private func parseDri(payload: [UInt8]) throws -> Int {
  let r = ByteStream(bytes: payload)
  let interval = try r.readUInt16BEInt()
  return interval
}

private func parseSos(payload: [UInt8], frame: FrameHeader) throws -> ScanHeader {
  let r = ByteStream(bytes: payload)

  let ns = try r.readByteInt()
  guard ns >= 1 else {
    throw JpegLosslessError.invalidFormat("SOS has invalid component count \(ns)")
  }

  let frameIndexById = frame.componentIndexById

  var componentIds: [Int] = []
  componentIds.reserveCapacity(ns)

  var dcTableIds: [Int] = []
  dcTableIds.reserveCapacity(ns)

  var scanToFrameIndex: [Int] = []
  scanToFrameIndex.reserveCapacity(ns)

  for _ in 0..<ns {
    let cs = try r.readByteInt()
    let tdTa = try r.readByteInt()
    let td = (tdTa >> 4) & 0x0F
    let ta = tdTa & 0x0F

    // Lossless uses DC table; AC table should be 0.
    if ta != 0 {
      throw JpegLosslessError.unsupported("Lossless scan specifies AC table id \(ta) (expected 0)")
    }

    guard let frameIndex = frameIndexById[cs] else {
      throw JpegLosslessError.invalidFormat("SOS references component id \(cs) not present in SOF")
    }

    componentIds.append(cs)
    dcTableIds.append(td)
    scanToFrameIndex.append(frameIndex)
  }

  let ss = try r.readByteInt()
  let se = try r.readByteInt()
  let ahAl = try r.readByteInt()

  // Lossless JPEG: Ss = predictor selection (1..7), Se must be 0, Ah must be 0, Al is point transform.
  let predictorSelection = ss
  let pointTransform = ahAl & 0x0F
  let ah = (ahAl >> 4) & 0x0F

  guard predictorSelection >= 1 && predictorSelection <= 7 else {
    throw JpegLosslessError.unsupported("Predictor selection \(predictorSelection) not supported (expected 1...7)")
  }
  guard se == 0 else {
    throw JpegLosslessError.unsupported("Lossless scan has Se=\(se) (expected 0)")
  }
  guard ah == 0 else {
    throw JpegLosslessError.unsupported("Lossless scan has Ah=\(ah) (expected 0)")
  }
  guard pointTransform >= 0 && pointTransform < frame.precision else {
    throw JpegLosslessError.unsupported("Point transform \(pointTransform) invalid for precision \(frame.precision)")
  }

  // Typical DICOM SOF3 uses one scan with all components.
  if ns != frame.componentCount {
    throw JpegLosslessError.unsupported("Partial/multi-scan images not supported (SOS components=\(ns), SOF components=\(frame.componentCount))")
  }

  return ScanHeader(
    componentIdsInScan: componentIds,
    dcTableIdByScanIndex: dcTableIds,
    predictorSelection: predictorSelection,
    pointTransform: pointTransform,
    scanToFrameIndex: scanToFrameIndex
  )
}

private func decodeLosslessScan(
  stream: ByteStream,
  frame: FrameHeader,
  scan: ScanHeader,
  dcHuffmanTables: [Int: HuffmanTable]
) throws -> (pixels: [UInt8], scanEndMarker: UInt8) {

  let width = frame.width
  let height = frame.height
  let componentCount = frame.componentCount
  let precision = frame.precision
  let pointTransform = scan.pointTransform

  let bytesPerSample = (precision + 7) / 8
  if bytesPerSample != 1 && bytesPerSample != 2 {
    throw JpegLosslessError.unsupported("Only 1 or 2 bytes/sample supported (precision=\(precision))")
  }

  let effectivePrecision = precision - pointTransform
  guard effectivePrecision >= 1 && effectivePrecision <= 16 else {
    throw JpegLosslessError.unsupported("Effective precision \(effectivePrecision) not supported")
  }

  // Initial prediction at beginning of first line: 2^(P - Pt - 1) == 2^(effectivePrecision - 1)
  let initialPredictor = 1 << (effectivePrecision - 1)

  // Mask for reconstructed samples in the reduced-precision domain
  let reconMask = (1 << effectivePrecision) - 1

  // Output mask (full precision)
  let outputMask = (1 << precision) - 1

  // Build per-scan-component DC Huffman table list
  var tables: [HuffmanTable] = []
  tables.reserveCapacity(componentCount)
  for i in 0..<componentCount {
    let dcId = scan.dcTableIdByScanIndex[i]
    guard let t = dcHuffmanTables[dcId] else {
      throw JpegLosslessError.missingHuffmanTable(tableClass: 0, tableId: dcId)
    }
    tables.append(t)
  }

  let totalSamples = width * height * componentCount
  var pixels = [UInt8](repeating: 0, count: totalSamples * bytesPerSample)

  // Row buffers store reconstructed samples in effectivePrecision domain
  var prevRows: [[Int]] = Array(repeating: Array(repeating: 0, count: width), count: componentCount)
  var currRows: [[Int]] = Array(repeating: Array(repeating: 0, count: width), count: componentCount)

  let bitReader = EntropyBitReader(stream: stream)

  for y in 0..<height {
    for x in 0..<width {
      for scanIndex in 0..<componentCount {

        let pred: Int
        if y == 0 {
          // First line: forced horizontal predictor (Px = Ra) except first sample
          if x == 0 {
            pred = initialPredictor
          } else {
            pred = currRows[scanIndex][x - 1] // Ra
          }
        } else {
          // Other lines: start-of-line uses above sample (Rb)
          if x == 0 {
            pred = prevRows[scanIndex][x] // Rb
          } else {
            let ra = currRows[scanIndex][x - 1]
            let rb = prevRows[scanIndex][x]
            let rc = prevRows[scanIndex][x - 1]

            switch scan.predictorSelection {
              case 1: pred = ra
              case 2: pred = rb
              case 3: pred = rc
              case 4: pred = ra + rb - rc
              case 5: pred = ra + ((rb - rc) >> 1)
              case 6: pred = rb + ((ra - rc) >> 1)
              case 7: pred = (ra + rb) >> 1
              default:
                throw JpegLosslessError.unsupported("Predictor \(scan.predictorSelection) not supported")
            }
          }
        }

        let s = try tables[scanIndex].decodeSymbol(bitReader: bitReader)

        let diff: Int
        if s == 0 {
          diff = 0
        } else if s == 16 {
          // Lossless special case: "No extra bits are appended after SSSS = 16 is encoded"
          // This corresponds to the unique 16-bit two's complement value 0x8000.
          diff = -32768
        } else {
          let v = try bitReader.readBits(s)
          diff = extend(value: v, bitCount: s)
        }

        // Spec uses modulo 2^16 arithmetic for the difference and reconstruction.
        // Wrap to 16 bits, then mask down to effectivePrecision bits.
        let recon16 = (pred + diff) & 0xFFFF
        let recon = recon16 & reconMask
        currRows[scanIndex][x] = recon

        let outValue = (recon << pointTransform) & outputMask

        // Write into output in frame component order.
        let frameIndex = scan.scanToFrameIndex[scanIndex]
        let sampleIndex = ((y * width + x) * componentCount) + frameIndex
        let byteIndex = sampleIndex * bytesPerSample

        if bytesPerSample == 1 {
          pixels[byteIndex] = UInt8(outValue & 0xFF)
        } else {
          // little-endian
          pixels[byteIndex] = UInt8(outValue & 0xFF)
          pixels[byteIndex + 1] = UInt8((outValue >> 8) & 0xFF)
        }
      }
    }

    swap(&prevRows, &currRows)
    // currRows will be overwritten next iteration; no need to clear.
  }

  let endMarker = try bitReader.scanToMarker()
  return (pixels, endMarker)
}


private func extend(value: Int, bitCount: Int) -> Int {
  guard bitCount > 0 else { return 0 }
  let vt = 1 << (bitCount - 1)
  if value < vt {
    return value - ((1 << bitCount) - 1)
  }
  return value
}

// MARK: - Huffman

private final class HuffmanTable {
  private let minCode: [Int]
  private let maxCode: [Int]
  private let valPtr: [Int]
  private let symbols: [UInt8]

  init(codeLengthCounts: [Int], symbols: [UInt8]) throws {
    guard codeLengthCounts.count == 16 else {
      throw JpegLosslessError.invalidFormat("Huffman table must have 16 code length counts")
    }

    self.symbols = symbols

    // Build huffsize list
    var huffSize: [Int] = []
    huffSize.reserveCapacity(symbols.count + 1)

    for i in 0..<16 {
      let count = codeLengthCounts[i]
      if count < 0 {
        throw JpegLosslessError.invalidFormat("Negative Huffman count")
      }
      for _ in 0..<count {
        huffSize.append(i + 1) // lengths are 1...16
      }
    }
    huffSize.append(0)

    // Build huffcode list
    var huffCode: [Int] = Array(repeating: 0, count: huffSize.count)

    var code = 0
    var si = huffSize[0]
    var k = 0

    while true {
      while huffSize[k] == si {
        huffCode[k] = code
        code += 1
        k += 1
      }
      if huffSize[k] == 0 { break }
      while si < huffSize[k] {
        code <<= 1
        si += 1
      }
    }

    // Build derived tables
    var minCodeTmp: [Int] = Array(repeating: 0, count: 17) // 1...16
    var maxCodeTmp: [Int] = Array(repeating: -1, count: 17)
    var valPtrTmp: [Int] = Array(repeating: 0, count: 17)

    var p = 0
    for l in 1...16 {
      let count = codeLengthCounts[l - 1]
      if count == 0 {
        maxCodeTmp[l] = -1
      } else {
        valPtrTmp[l] = p
        minCodeTmp[l] = huffCode[p]
        p += count - 1
        maxCodeTmp[l] = huffCode[p]
        p += 1
      }
    }

    if symbols.count != (p) {
      // Defensive: symbol count mismatch usually indicates malformed table.
      // Some encoders can be odd; but for DICOM this should match.
      throw JpegLosslessError.invalidFormat("Huffman table symbol count mismatch")
    }

    self.minCode = minCodeTmp
    self.maxCode = maxCodeTmp
    self.valPtr = valPtrTmp
  }

  func decodeSymbol(bitReader: EntropyBitReader) throws -> Int {
    var code = 0
    for length in 1...16 {
      let bit = try bitReader.readBit()
      code = (code << 1) | bit

      let maxForLen = maxCode[length]
      if maxForLen >= 0 && code <= maxForLen {
        let index = valPtr[length] + (code - minCode[length])
        if index < 0 || index >= symbols.count {
          throw JpegLosslessError.invalidFormat("Huffman decode produced out-of-range symbol index")
        }
        return Int(symbols[index])
      }
    }
    throw JpegLosslessError.invalidFormat("Huffman decode failed (no matching code)")
  }
}

// MARK: - Entropy-coded bit reading (handles byte stuffing and detects markers)

private final class EntropyBitReader {
  private let stream: ByteStream
  private var bitBuffer: Int = 0
  private var bitsRemaining: Int = 0
  private var pendingMarker: UInt8? = nil

  init(stream: ByteStream) {
    self.stream = stream
  }

  func readBit() throws -> Int {
    if bitsRemaining == 0 {
      try fillByte()
    }
    bitsRemaining -= 1
    return (bitBuffer >> bitsRemaining) & 1
  }

  func readBits(_ count: Int) throws -> Int {
    guard count >= 0 && count <= 16 else {
      throw JpegLosslessError.invalidFormat("Invalid bit count \(count)")
    }
    var v = 0
    for _ in 0..<count {
      v = (v << 1) | (try readBit())
    }
    return v
  }

  func scanToMarker() throws -> UInt8 {
    if let marker = pendingMarker { return marker }

    // Discard partial bits and move to next marker boundary.
    bitsRemaining = 0
    bitBuffer = 0

    while true {
      let b = try stream.readByte()
      if b == 0xFF {
        var c = try stream.readByte()
        while c == 0xFF {
          c = try stream.readByte()
        }
        if c == 0x00 {
          // Stuffed 0xFF data byte; continue searching.
          continue
        }
        pendingMarker = c
        return c
      }
    }
  }

  private func fillByte() throws {
    let b = try readEntropyByte()
    bitBuffer = Int(b)
    bitsRemaining = 8
  }

  private func readEntropyByte() throws -> UInt8 {
    if pendingMarker != nil {
      // No more entropy data expected after marker.
      throw JpegLosslessError.invalidFormat("Attempted to read entropy byte after marker")
    }

    let b = try stream.readByte()
    if b != 0xFF {
      return b
    }

    // Handle byte stuffing and marker detection.
    var c = try stream.readByte()
    while c == 0xFF {
      c = try stream.readByte()
    }

    if c == 0x00 {
      return 0xFF // stuffed data byte
    }

    // Marker encountered in entropy-coded segment.
    pendingMarker = c
    throw JpegLosslessError.entropyEndedEarly(marker: c)
  }
}

// MARK: - Byte stream and marker helpers

private final class ByteStream {
  private let bytes: [UInt8]
  private(set) var offset: Int = 0

  init(data: Data) {
    self.bytes = Array(data)
  }

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  var isAtEnd: Bool { offset >= bytes.count }

  func readByte() throws -> UInt8 {
    guard offset < bytes.count else {
      throw JpegLosslessError.unexpectedEof
    }
    let b = bytes[offset]
    offset += 1
    return b
  }

  func readByteInt() throws -> Int {
    return Int(try readByte())
  }

  func readUInt16BEInt() throws -> Int {
    let hi = Int(try readByte())
    let lo = Int(try readByte())
    return (hi << 8) | lo
  }

  func readBytes(_ count: Int) throws -> [UInt8] {
    guard count >= 0 else { throw JpegLosslessError.invalidFormat("Negative length") }
    guard offset + count <= bytes.count else { throw JpegLosslessError.unexpectedEof }
    let out = Array(bytes[offset..<(offset + count)])
    offset += count
    return out
  }

  func readSegmentPayload() throws -> [UInt8] {
    let length = try readUInt16BEInt()
    guard length >= 2 else {
      throw JpegLosslessError.invalidFormat("Segment length < 2")
    }
    return try readBytes(length - 2)
  }

  func readMarker() throws -> UInt8 {
    // Markers are 0xFF followed by a non-0xFF byte (fill bytes can occur)
    var b = try readByte()
    while b != 0xFF {
      b = try readByte()
    }

    var marker = try readByte()
    while marker == 0xFF {
      marker = try readByte()
    }

    // 0xFF00 can occur as padding; keep scanning.
    if marker == 0x00 {
      return try readMarker()
    }

    return marker
  }
}

private enum Marker {
  static let soi: UInt8 = 0xD8
  static let eoi: UInt8 = 0xD9
  static let sof3: UInt8 = 0xC3
  static let dht: UInt8 = 0xC4
  static let sos: UInt8 = 0xDA
  static let dri: UInt8 = 0xDD

  static func isStandalone(marker: UInt8) -> Bool {
    // RST0..RST7, TEM
    if marker >= 0xD0 && marker <= 0xD7 { return true }
    if marker == 0x01 { return true }
    if marker == soi || marker == eoi { return true }
    return false
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
