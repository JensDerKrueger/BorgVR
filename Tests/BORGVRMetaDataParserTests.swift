import Foundation

private enum TestFailure: Error {
  case expectedRejection(String)
}

private func writeInt64(_ value: Int64, to data: inout Data, at offset: Int) {
  var bytes = [UInt8](repeating: 0, count: 8)
  let raw = UInt64(bitPattern: value)
  for index in 0..<8 {
    bytes[index] = UInt8((raw >> UInt64(index * 8)) & 0xff)
  }
  data.replaceSubrange(offset..<(offset + 8), with: bytes)
}

private func readInt64(from data: Data, at offset: Int) -> Int64 {
  var raw: UInt64 = 0
  for index in 0..<8 {
    raw |= UInt64(data[offset + index]) << UInt64(index * 8)
  }
  return Int64(bitPattern: raw)
}

private func brickCountOffset(in data: Data) -> Int {
  let componentCount = Int(readInt64(from: data, at: 38))
  let width = Int(readInt64(from: data, at: 46))
  var offset = 93 + (2 + 2 * componentCount) * width
  for _ in 0..<3 {
    let length = Int(readInt64(from: data, at: offset))
    offset += 8 + length
  }
  for _ in 0..<2 { offset += 17 + Int(readInt64(from: data, at: offset + 9)) }
  return offset
}

private func makeValidMetadata() -> Data {
  let metadata = BORGVRMetaData(
    width: 8,
    height: 8,
    depth: 8,
    componentCount: 1,
    bytePerComponent: 1,
    voxelSpacingX: 0.001,
    voxelSpacingY: 0.001,
    voxelSpacingZ: 0.001,
    brickSize: 4,
    overlap: 1,
    minValue: 0,
    maxValue: 255,
    compression: true,
    datasetDescription: "Parser test",
    metaDescription: "Valid synthetic metadata"
  )

  let expectedBrickCount = metadata.levelMetadata.reduce(0) { result, level in
    result + level.totalBricks.x * level.totalBricks.y * level.totalBricks.z
  }
  var brickOffset = 8
  for _ in 0..<expectedBrickCount {
    metadata.append(offset: brickOffset, size: 8, minValue: 0, maxValue: 255)
    brickOffset += 8
  }
  return metadata.toData()
}

private func expectRejection(_ name: String, data: Data) throws {
  do {
    _ = try BORGVRMetaData(fromData: data)
    throw TestFailure.expectedRejection(name)
  } catch is BORGVRError {
    return
  }
}

@main
private enum BORGVRMetaDataParserTests {
  static func main() throws {
    if CommandLine.arguments.contains("--verify-cpp") {
      try verifyCPPFixtures(in: URL(fileURLWithPath: CommandLine.arguments.last!))
      return
    }
    let valid = makeValidMetadata()
    if CommandLine.arguments.count > 1 {
      try valid.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    let parsed = try BORGVRMetaData(fromData: valid)
    var obsolete = valid
    writeInt64(4, to: &obsolete, at: 6)
    try expectRejection("v4 must be converted externally", data: obsolete)
    guard parsed.componentRanges == [BORGVRComponentRange(minValue: 0, maxValue: 255)] else {
      throw TestFailure.expectedRejection("component range round trip")
    }

    try expectRejection("truncated metadata", data: Data(valid.dropLast()))

    var negativeWidth = valid
    writeInt64(-1, to: &negativeWidth, at: 14)
    try expectRejection("negative width", data: negativeWidth)

    var oversizedWidth = valid
    writeInt64(Int64.max, to: &oversizedWidth, at: 14)
    try expectRejection("oversized width", data: oversizedWidth)

    var invalidComponentSize = valid
    writeInt64(3, to: &invalidComponentSize, at: 46)
    try expectRejection("unsupported component size", data: invalidComponentSize)

    for count in [Int64(-1), 0, 1025, Int64.max] {
      var invalidComponentCount = valid
      writeInt64(count, to: &invalidComponentCount, at: 38)
      writeInt64(count, to: &invalidComponentCount, at: 86)
      try expectRejection("invalid component count before range allocation", data: invalidComponentCount)
    }

    var invalidSpacing = valid
    invalidSpacing.replaceSubrange(56..<60, with: [0x00, 0x00, 0xc0, 0x7f])
    try expectRejection("non-finite voxel spacing", data: invalidSpacing)

    var invalidOverlap = valid
    writeInt64(2, to: &invalidOverlap, at: 76)
    try expectRejection("invalid brick stride", data: invalidOverlap)

    var invalidBoolean = valid
    let componentCount = Int(readInt64(from: valid, at: 38))
    let compressionOffset = 92 + (2 + 2 * componentCount)
    invalidBoolean[compressionOffset] = 2
    try expectRejection("invalid Boolean", data: invalidBoolean)

    var negativeStringLength = valid
    let firstStringOffset = compressionOffset + 1
    writeInt64(-1, to: &negativeStringLength, at: firstStringOffset)
    try expectRejection("negative string length", data: negativeStringLength)

    var oversizedStringLength = valid
    writeInt64(1_048_577, to: &oversizedStringLength, at: firstStringOffset)
    try expectRejection("oversized string length", data: oversizedStringLength)

    let uniqueIDLength = Int(readInt64(from: valid, at: firstStringOffset))
    let datasetDescriptionStart = firstStringOffset + 8 + uniqueIDLength + 8
    var invalidUTF8 = valid
    invalidUTF8[datasetDescriptionStart] = 0xff
    try expectRejection("invalid UTF-8", data: invalidUTF8)

    let metadataCountOffset = brickCountOffset(in: valid)
    var negativeBrickCount = valid
    writeInt64(-1, to: &negativeBrickCount, at: metadataCountOffset)
    try expectRejection("negative brick count", data: negativeBrickCount)

    var inconsistentBrickCount = valid
    writeInt64(1, to: &inconsistentBrickCount, at: metadataCountOffset)
    try expectRejection("inconsistent brick count", data: inconsistentBrickCount)

    var oversizedDataOffset = valid
    writeInt64(Int64.max, to: &oversizedDataOffset, at: metadataCountOffset + 8)
    try expectRejection("oversized brick metadata offset", data: oversizedDataOffset)

    var overflowingBrickRange = valid
    let firstBrickOffset = metadataCountOffset + 16
    writeInt64(Int64.max, to: &overflowingBrickRange, at: firstBrickOffset)
    try expectRejection("overflowing brick range", data: overflowingBrickRange)

    for size in [Int64(-1), 0, 65] {
      var invalidBrickSize = valid
      writeInt64(size, to: &invalidBrickSize, at: firstBrickOffset + 8)
      try expectRejection("invalid stored brick size \(size)", data: invalidBrickSize)
    }

    var shortUncompressed = valid
    shortUncompressed[compressionOffset] = 0
    try expectRejection("short uncompressed brick", data: shortUncompressed)

    var fullStoredBrick = valid
    writeInt64(64, to: &fullStoredBrick, at: firstBrickOffset + 8)
    _ = try BORGVRMetaData(fromData: fullStoredBrick)

    var overflowingFullBrickSize = valid
    writeInt64(Int64(Int32.max), to: &overflowingFullBrickSize, at: 68)
    try expectRejection("overflowing full brick byte count", data: overflowingFullBrickSize)

    try testFileReaderBounds()
    try testVersion5(in: URL(fileURLWithPath: CommandLine.arguments.last!).deletingLastPathComponent())
    try testChannelInterpretations(in: URL(fileURLWithPath: CommandLine.arguments.last!).deletingLastPathComponent())

    print("Swift BORGVR metadata parser tests passed.")
  }
}

private func testVersion5(in directory: URL) throws {
  let types: [(BORGVRComponentType, Int, BORGVRComponentRange)] = [
    (.unsignedInteger, 1, .init(minimum: 0, maximum: 255)),
    (.unsignedInteger, 2, .init(minimum: 0, maximum: 65535)),
    (.unsignedInteger, 4, .init(minimum: 0, maximum: Double(UInt32.max))),
    (.signedInteger, 1, .init(minimum: -128, maximum: 127)),
    (.signedInteger, 2, .init(minimum: -32768, maximum: 32767)),
    (.signedInteger, 4, .init(minimum: Double(Int32.min), maximum: Double(Int32.max))),
    (.floatingPoint, 4, .init(minimum: -0.25, maximum: 1.5)),
    (.floatingPoint, 8, .init(minimum: -Double.greatestFiniteMagnitude, maximum: Double.leastNonzeroMagnitude)),
    (.floatingPoint, 4, .init(minimum: -.infinity, maximum: .infinity)),
    (.floatingPoint, 8, .init(minimum: .nan, maximum: .nan))
  ]
  for (index, entry) in types.enumerated() {
    let (type, width, range) = entry
    for compress in [false, true] {
      let m = BORGVRMetaData(width: 2, height: 2, depth: 2, componentCount: 2,
        bytePerComponent: width, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
        brickSize: 2, overlap: 0, minValue: 0, maxValue: 0, compression: false,
        datasetDescription: "v5 test", metaDescription: "")
      try m.setComponentType(type, ranges: [range, range])
      m.append(offset: 8, size: 16 * width, componentRanges: [range, range])
      m.provenance = ["https://example.org/scan", "Import: DICOM", "Fusion: reference + registered volume"].enumerated().map {
        BORGVRProvenanceEntry(timestampMilliseconds: 1_793_491_234_567 + Int64($0.offset), text: $0.element)
      }
      m.meta = String(repeating: "DICOM metadata: äöü\n", count: 5000)
      m.compressMetadataText = compress
      let bytes = m.toData()
      let parsed = try BORGVRMetaData(fromData: bytes)
      guard parsed.componentType == type, parsed.valueRange == range,
            parsed.brickMetadata[0].valueRange == range, parsed.componentRanges == [range, range],
            parsed.provenance == m.provenance, parsed.meta == m.meta else {
        throw TestFailure.expectedRejection("v5 round trip \(index)")
      }
      let name = "v5-\(index)-\(compress ? "lz4" : "raw").bin"
      try bytes.write(to: directory.appendingPathComponent(name))
      var invalidType = bytes; invalidType[54] = 99
      try expectRejection("unknown component type", data: invalidType)
      try expectRejection("v5 truncated", data: bytes.dropLast())
      let firstBlock = 84 + (2 + 2 * m.componentCount) * width + 8 + 1
        + [m.uniqueID, m.datasetDescription, m.metaDescription].reduce(0) { $0 + 8 + $1.utf8.count }
      var invalidCodec = bytes; invalidCodec[firstBlock] = 9
      try expectRejection("invalid text codec", data: invalidCodec)
      var oversized = bytes
      writeInt64(Int64.max, to: &oversized, at: firstBlock + 1)
      try expectRejection("metadata decompression bomb", data: oversized)
      if compress {
        let stored = Int(readInt64(from: bytes, at: firstBlock + 9))
        let secondBlock = firstBlock + 17 + stored
        guard bytes[secondBlock] == 1 else { throw TestFailure.expectedRejection("meta should compress") }
        var corrupt = bytes; corrupt[secondBlock + 17] = 0
        try expectRejection("corrupt compressed meta", data: corrupt)
      }
      if type != .unsignedInteger {
        do { try parsed.requireUnsignedProcessing(); throw TestFailure.expectedRejection("renderer accepted new type") }
        catch is BORGVRError {}
      }
    }
  }
  let nan = BORGVRComponentRange(minimum: 1, maximum: 2).including(.nan)
  guard nan.minimum.isNaN, nan.maximum.isNaN,
        BORGVRComponentRange.union([nan, .init(minValue: 0, maxValue: 1)]) == nan,
        BORGVRComponentRange(minimum: 0, maximum: 1).including(.infinity).maximum == .infinity else {
    throw TestFailure.expectedRejection("NaN/Inf propagation")
  }
  for range in [BORGVRComponentRange(minimum: .nan, maximum: 1), .init(minimum: 1, maximum: .nan),
                .init(minimum: .infinity, maximum: -.infinity)] {
    do {
      try BORGVRComponentType.floatingPoint.validate(range, width: 8)
      throw TestFailure.expectedRejection("invalid floating-point range accepted")
    } catch is BORGVRError {}
  }
  guard let date = BORGVRProvenanceEntry.parseDate("2026-11-01T12:30:45.123+02:00"),
        BORGVRProvenanceEntry("source", date: date).timestampMilliseconds == 1_793_529_045_123,
        BORGVRProvenanceEntry.parseDate("not a date") == nil else {
    throw TestFailure.expectedRejection("UTC provenance timestamp conversion")
  }
  let m = try BORGVRMetaData(fromData: makeValidMetadata())
  m.provenance = [BORGVRProvenanceEntry("original source")]
  m.meta = "custom metadata"
  let cached = m.cacheExportMetadata(sourceDescription: "example.org:12345")
  guard m.provenance.count == 1, cached.provenance.count == 2,
        cached.uniqueID == m.uniqueID, cached.meta == m.meta, cached.hasSameStoredVolume(as: m) else {
    throw TestFailure.expectedRejection("cache provenance must not alter original metadata or recovery compatibility")
  }
  let edited = m.editExportMetadata()
  guard edited.provenance.count == 2, edited.meta == m.meta, edited.uniqueID != m.uniqueID,
        edited.brickMetadata.isEmpty else {
    throw TestFailure.expectedRejection("edit export lost provenance or metadata")
  }
  print("Swift v5 typed ranges and compressed text tests passed.")
}

private func testChannelInterpretations(in directory: URL) throws {
  for color in [BORGVRChannelInterpretation.rgb, .rgba] { for block in [4, 8] { for lz4 in [false, true] {
    let channels = color == .rgb ? 3 : 4
    let m = BORGVRMetaData(width: 2, height: 2, depth: 2, componentCount: channels, bytePerComponent: 1,
      voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1, brickSize: 8, overlap: 0,
      minValue: 0, maxValue: 255, compression: lz4, datasetDescription: "ASTC fixture", metaDescription: "")
    try m.setChannelInterpretation(color.withASTC(blockSize: block))
    let count = try m.fullBrickByteCount()
    m.append(offset: 8, size: count, componentRanges: m.componentRanges)
    let bytes = m.toData(), parsed = try BORGVRMetaData(fromData: bytes)
    guard parsed.channelInterpretation == m.channelInterpretation, try parsed.fullBrickByteCount() == count,
          parsed.compression == lz4 else { throw TestFailure.expectedRejection("ASTC metadata round trip") }
    try bytes.write(to: directory.appendingPathComponent("astc-\(color.name)-\(block)-\(lz4).bin"))
    var invalid = bytes
    writeInt64(3, to: &invalid, at: 68)
    try expectRejection("ASTC footprint alignment", data: invalid)
  } } }
  for (interpretation, channels) in [(BORGVRChannelInterpretation.rgb, 3), (.rgba, 4)] {
    let metadata = BORGVRMetaData(width: 2, height: 2, depth: 2, componentCount: channels,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: 2, overlap: 0, minValue: 0, maxValue: 255, compression: false,
      datasetDescription: "Color fixture", metaDescription: "")
    try metadata.setChannelInterpretation(interpretation)
    metadata.append(offset: 8, size: 8 * channels, componentRanges: metadata.componentRanges)
    let bytes = metadata.toData()
    try bytes.write(to: directory.appendingPathComponent("color-\(interpretation.name).bin"))
    let parsed = try BORGVRMetaData(fromData: bytes)
    guard bytes[55] == interpretation.rawValue, parsed.channelInterpretation == interpretation,
          parsed.cacheExportMetadata(sourceDescription: "test").channelInterpretation == interpretation,
          parsed.editExportMetadata().channelInterpretation == interpretation else {
      throw TestFailure.expectedRejection("color interpretation round trip/copy")
    }
    let encoded = try JSONEncoder().encode(parsed)
    guard try JSONDecoder().decode(BORGVRMetaData.self, from: encoded).channelInterpretation == interpretation else {
      throw TestFailure.expectedRejection("color interpretation JSON round trip")
    }
    do { try parsed.requireIndependentChannels(); throw TestFailure.expectedRejection("renderer accepted color") }
    catch is BORGVRError {}
    try parsed.setChannelInterpretation(.independentChannels)
    guard !parsed.hasSameStoredVolume(as: metadata) else {
      throw TestFailure.expectedRejection("recovery ignored channel interpretation")
    }
    for raw: UInt8 in [99, interpretation == .rgb ? 2 : 1] {
      var invalid = bytes; invalid[55] = raw
      try expectRejection("invalid interpretation or channel count", data: invalid)
    }
    for type: UInt8 in [1, 2] {
      var invalid = bytes; invalid[54] = type
      try expectRejection("color component type must be uint8", data: invalid)
    }
    for width: Int64 in [2, 4, 8] {
      var invalid = bytes; writeInt64(width, to: &invalid, at: 46)
      try expectRejection("color component width must be one byte", data: invalid)
    }
    var independent = bytes; independent[55] = 0
    try expectRejection("color payload cannot be reinterpreted as scalar range records", data: independent)
    var unknown = bytes; unknown[55] = 255
    try expectRejection("unknown channel interpretation", data: unknown)
  }
  print("Swift RGB/RGBA channel interpretation validation and copies passed.")
}

private func verifyCPPFixtures(in directory: URL) throws {
  for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      where (url.lastPathComponent.hasPrefix("v5-") || url.lastPathComponent.hasPrefix("color-")) && !url.lastPathComponent.hasSuffix(".cpp") {
    let swift = try BORGVRMetaData(fromData: Data(contentsOf: url))
    let cpp = try BORGVRMetaData(fromData: Data(contentsOf: url.appendingPathExtension("cpp")))
    guard cpp.componentType == swift.componentType, cpp.channelInterpretation == swift.channelInterpretation,
          cpp.bytesPerComponent == swift.bytesPerComponent,
          cpp.valueRange == swift.valueRange, cpp.componentRanges == swift.componentRanges,
          cpp.brickMetadata[0].valueRange == swift.brickMetadata[0].valueRange,
          cpp.provenance == swift.provenance, cpp.meta == swift.meta else {
      throw TestFailure.expectedRejection("C++/Swift typed metadata interoperability")
    }
  }
  print("C++ -> Swift typed metadata and raw LZ4 interoperability passed.")
}

private func testFileReaderBounds() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-brick-bounds-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  func writeDataset(storedSize: Int, name: String) throws -> URL {
    let metadata = BORGVRMetaData(width: 2, height: 2, depth: 2, componentCount: 1,
      bytePerComponent: 1, voxelSpacingX: 1, voxelSpacingY: 1, voxelSpacingZ: 1,
      brickSize: 2, overlap: 0, minValue: 0, maxValue: 255, compression: false,
      datasetDescription: "Bounds test", metaDescription: "")
    metadata.append(offset: 8, size: storedSize, minValue: 0, maxValue: 255)
    var data = Data(from: UInt64(8 + storedSize))
    data.append(contentsOf: repeatElement(UInt8(42), count: storedSize))
    data.append(metadata.toData())
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }
  for size in [7, 9] {
    let url = try writeDataset(storedSize: size, name: "invalid-\(size).data")
    do {
      _ = try BORGVRFileData(filename: url.path)
      throw TestFailure.expectedRejection("invalid brick file opened")
    } catch is BORGVRError {}
  }
  let url = try writeDataset(storedSize: 8, name: "valid.data")
  let reader = try BORGVRFileData(filename: url.path)
  let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
  defer { buffer.deallocate() }
  buffer.initialize(repeating: 77, count: 16)
  try reader.getBrick(index: 0, outputBuffer: buffer)
  guard Array(UnsafeBufferPointer(start: buffer, count: 8)) == Array(repeating: 42, count: 8), buffer[8] == 77 else {
    throw TestFailure.expectedRejection("valid decoded brick changed its buffer boundary")
  }
  _ = try reader.getRawBrick(index: 0, outputBuffer: buffer)
  let ranges = [BORGVRComponentRange(minValue: 0, maxValue: 255)]
  for brick in [BrickMetadata(offset: 8, size: 9, minValue: 0, maxValue: 255, componentRanges: ranges),
                BrickMetadata(offset: 8, size: 7, minValue: 0, maxValue: 255, componentRanges: ranges),
                BrickMetadata(offset: Int.max, size: 8, minValue: 0, maxValue: 255, componentRanges: ranges)] {
    do {
      try reader.getRawBrick(brickMeta: brick, outputBuffer: buffer)
      throw TestFailure.expectedRejection("raw copy accepted invalid brick bounds")
    } catch is BORGVRError {}
  }
  for index in [-1, 1] {
    do {
      try reader.getBrick(index: index, outputBuffer: buffer)
      throw TestFailure.expectedRejection("decoded copy accepted invalid index")
    } catch is BORGVRError {}
    do {
      _ = try reader.getRawBrick(index: index, outputBuffer: buffer)
      throw TestFailure.expectedRejection("raw copy accepted invalid index")
    } catch is BORGVRError {}
  }
  guard buffer[8] == 77 else { throw TestFailure.expectedRejection("invalid raw copy overwrote the sentinel") }
}
