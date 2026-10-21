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
  var offset = 107 + componentCount * 16
  for _ in 0..<3 {
    let length = Int(readInt64(from: data, at: offset))
    offset += 8 + length
  }
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
    let valid = makeValidMetadata()
    if CommandLine.arguments.count > 1 {
      try valid.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    let parsed = try BORGVRMetaData(fromData: valid)
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

    var invalidSpacing = valid
    invalidSpacing.replaceSubrange(54..<58, with: [0x00, 0x00, 0xc0, 0x7f])
    try expectRejection("non-finite voxel spacing", data: invalidSpacing)

    var invalidOverlap = valid
    writeInt64(2, to: &invalidOverlap, at: 74)
    try expectRejection("invalid brick stride", data: invalidOverlap)

    var invalidBoolean = valid
    let componentCount = Int(readInt64(from: valid, at: 38))
    let compressionOffset = 106 + componentCount * 16
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

    print("Swift BORGVR metadata parser tests passed.")
  }
}
