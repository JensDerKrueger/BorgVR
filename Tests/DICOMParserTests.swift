import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): return message
    }
  }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
  do {
    try body()
    throw TestFailure.failed(message)
  } catch is TestFailure {
    throw TestFailure.failed(message)
  } catch {}
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
  data.append(UInt8(truncatingIfNeeded: value))
  data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
  data.append(UInt8(truncatingIfNeeded: value))
  data.append(UInt8(truncatingIfNeeded: value >> 8))
  data.append(UInt8(truncatingIfNeeded: value >> 16))
  data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func uint16Data(_ value: UInt16) -> Data {
  var data = Data()
  appendUInt16LE(value, to: &data)
  return data
}

private func appendExplicitElement(
  group: UInt16,
  element: UInt16,
  vr: String,
  value: Data,
  to data: inout Data
) {
  appendUInt16LE(group, to: &data)
  appendUInt16LE(element, to: &data)
  data.append(vr.data(using: .ascii)!)
  appendUInt16LE(UInt16(value.count), to: &data)
  data.append(value)
}

private func makeSlice(
  rows: UInt16 = 1,
  columns: UInt16 = 1,
  samples: UInt16 = 1,
  bits: UInt16 = 8,
  pixelData: Data
) -> DicomParser.DicomSlice {
  DicomParser.DicomSlice(
    rows: rows,
    columns: columns,
    pixelData: pixelData,
    samplesPerPixel: samples,
    bitsAllocated: bits,
    bitsStored: bits,
    pixelRepresentation: 0,
    pixelPaddingValue: nil,
    sliceThickness: nil,
    spaceBetweenSlices: nil,
    pixelSpacing: nil,
    position: nil,
    orientation: nil,
    frameOfReferenceUID: nil,
    instanceNumber: nil,
    modality: nil,
    patientName: nil,
    seriesDate: nil
  )
}

private func rleHeader(segmentOffsets: [UInt32]) -> Data {
  var data = Data()
  appendUInt32LE(UInt32(segmentOffsets.count), to: &data)
  for offset in segmentOffsets {
    appendUInt32LE(offset, to: &data)
  }
  data.append(Data(repeating: 0, count: 64 - data.count))
  return data
}

private func testTruncatedLongVR() throws {
  var data = Data([0x28, 0x00, 0x10, 0x00])
  data.append("OB".data(using: .ascii)!)
  data.append(contentsOf: [0, 0])
  try expectThrows("A truncated long-VR header was accepted") {
    _ = try DicomParser.readElement(at: 0, in: data, using: .explicitVRLittleEndian)
  }
}

private func testElementValueOutsideData() throws {
  var data = Data([0x28, 0x00, 0x10, 0x00])
  data.append("US".data(using: .ascii)!)
  appendUInt16LE(4, to: &data)
  try expectThrows("An element extending beyond the input was accepted") {
    _ = try DicomParser.readElement(at: 0, in: data, using: .explicitVRLittleEndian)
  }
}

private func testUndefinedSequenceOffset() throws {
  var data = Data([0x08, 0x00, 0x10, 0x11])
  data.append("SQ".data(using: .ascii)!)
  data.append(contentsOf: [0, 0])
  appendUInt32LE(UInt32.max, to: &data)
  let result = try DicomParser.readElement(at: 0, in: data, using: .explicitVRLittleEndian)
  try expect(result.element.length == Int(UInt32.max), "Undefined sequence length was changed")
  try expect(result.nextOffset == 12, "Undefined sequence produced an invalid next offset")
}

private func testBigEndianElement() throws {
  let data = Data([
    0x00, 0x28, 0x00, 0x10,
    0x55, 0x53, 0x00, 0x02,
    0x01, 0x02
  ])
  let result = try DicomParser.readElement(at: 0, in: data, using: .explicitVRBigEndian)
  try expect(result.element.tag == .rows, "Big-endian tag was decoded incorrectly")
  try expect(result.element.length == 2 && result.nextOffset == 10,
             "Big-endian element length was decoded incorrectly")
}

private func testValidRLE() throws {
  var data = rleHeader(segmentOffsets: [64])
  data.append(contentsOf: [0, 42])
  let pixels = try makeSlice(pixelData: data).decodedPixels(using: .rle)
  try expect(pixels == [42], "Valid one-pixel RLE data decoded incorrectly")
}

private func testDescendingRLEOffsets() throws {
  var data = rleHeader(segmentOffsets: [66, 64])
  data.append(contentsOf: [0, 1, 0, 2])
  try expectThrows("Descending RLE segment offsets were accepted") {
    _ = try makeSlice(bits: 16, pixelData: data).decodedPixels(using: .rle)
  }
}

private func testMissingRLEBytePlane() throws {
  var data = rleHeader(segmentOffsets: [64])
  data.append(contentsOf: [0, 1])
  try expectThrows("A 16-bit RLE image with one byte plane was accepted") {
    _ = try makeSlice(bits: 16, pixelData: data).decodedPixels(using: .rle)
  }
}

private func testOversizedEncapsulatedFragment() throws {
  var data = Data()
  appendUInt16LE(0xFFFE, to: &data)
  appendUInt16LE(0xE000, to: &data)
  appendUInt32LE(0, to: &data)
  appendUInt16LE(0xFFFE, to: &data)
  appendUInt16LE(0xE000, to: &data)
  appendUInt32LE(100, to: &data)
  try expectThrows("An oversized encapsulated fragment was accepted") {
    _ = try makeSlice(pixelData: data).decodedPixels(using: .jpegBaseline)
  }
}

private func testTruncatedMetaHeader() throws {
  var data = Data(repeating: 0, count: 128)
  data.append("DICM".data(using: .ascii)!)
  data.append(contentsOf: [0x02, 0x00, 0x00, 0x00, 0x4F, 0x42, 0x00, 0x00])
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-truncated-dicom-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: url) }
  try data.write(to: url)
  try expectThrows("A truncated file-meta long-VR header was accepted") {
    _ = try DicomParser.parseDicomHeader(from: url)
  }
}

private func testValidTransferSyntaxHeader() throws {
  var data = Data(repeating: 0, count: 128)
  data.append("DICM".data(using: .ascii)!)
  appendExplicitElement(
    group: 0x0002,
    element: 0x0010,
    vr: "UI",
    value: Data("1.2.840.10008.1.2.1\0".utf8),
    to: &data
  )
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-valid-dicom-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: url) }
  try data.write(to: url)
  let file = try DicomParser.parseDicomHeader(from: url)
  switch file.transferSyntax.elementEncoding {
    case .explicitVRLittleEndian: break
    default: throw TestFailure.failed("Transfer syntax was decoded incorrectly")
  }
}

private func testOrientationBasis() throws {
  let orientation = DicomParser.orientationBasis(
    from: [0, 2, 0, -3, 0.01, 0]
  )
  guard let orientation else {
    throw TestFailure.failed("A valid DICOM orientation was rejected")
  }

  try expect(abs(orientation.xAxis.x) < 0.0001, "DICOM X axis was decoded incorrectly")
  try expect(abs(orientation.xAxis.y - 1) < 0.0001, "DICOM X axis was not normalized")
  try expect(abs(orientation.yAxis.x + 1) < 0.0001, "DICOM Y axis was decoded incorrectly")
  try expect(abs(orientation.xAxis.dot(orientation.yAxis)) < 0.0001,
             "DICOM axes were not orthogonalized")
  try expect(abs(orientation.zAxis.z - 1) < 0.0001,
             "DICOM slice normal was decoded incorrectly")
}

private func testInvalidOrientationBasis() throws {
  try expect(
    DicomParser.orientationBasis(from: [1, 0, 0, 2, 0, 0]) == nil,
    "A degenerate DICOM orientation was accepted"
  )
}

private func decodedPaddingValue(
  pixelRepresentation: UInt16,
  rawPaddingValue: UInt16,
  paddingVR: String
) throws -> Int32? {
  var data = Data(repeating: 0, count: 132)
  appendExplicitElement(
    group: 0x0028,
    element: 0x0010,
    vr: "US",
    value: uint16Data(1),
    to: &data
  )
  appendExplicitElement(
    group: 0x0028,
    element: 0x0011,
    vr: "US",
    value: uint16Data(1),
    to: &data
  )
  appendExplicitElement(
    group: 0x0028,
    element: 0x0103,
    vr: "US",
    value: uint16Data(pixelRepresentation),
    to: &data
  )
  appendExplicitElement(
    group: 0x0028,
    element: 0x0120,
    vr: paddingVR,
    value: uint16Data(rawPaddingValue),
    to: &data
  )
  appendExplicitElement(
    group: 0x7FE0,
    element: 0x0010,
    vr: "US",
    value: uint16Data(0),
    to: &data
  )
  let file = DicomParser.DicomFile(
    transferSyntax: DicomParser.TransferSyntaxInfo(
      elementEncoding: .explicitVRLittleEndian,
      pixelDataEncoding: .uncompressed
    ),
    rawData: data
  )
  return try DicomParser.openSlice(from: file).pixelPaddingValue
}

private func testUnsignedPixelPaddingValue() throws {
  let value = try decodedPaddingValue(
    pixelRepresentation: 0,
    rawPaddingValue: 65530,
    paddingVR: "US"
  )
  try expect(value == 65530, "Unsigned Pixel Padding Value was decoded incorrectly")
}

private func testSignedPixelPaddingValue() throws {
  let expected = Int16(-1024)
  let value = try decodedPaddingValue(
    pixelRepresentation: 1,
    rawPaddingValue: UInt16(bitPattern: expected),
    paddingVR: "SS"
  )
  try expect(value == Int32(expected), "Signed Pixel Padding Value was decoded incorrectly")
}

private func testFrameOfReferenceUID() throws {
  var data = Data(repeating: 0, count: 132)
  appendExplicitElement(
    group: 0x0028,
    element: 0x0010,
    vr: "US",
    value: uint16Data(1),
    to: &data
  )
  appendExplicitElement(
    group: 0x0028,
    element: 0x0011,
    vr: "US",
    value: uint16Data(1),
    to: &data
  )
  appendExplicitElement(
    group: 0x0020,
    element: 0x0052,
    vr: "UI",
    value: Data("1.2.3.4\0".utf8),
    to: &data
  )
  appendExplicitElement(
    group: 0x7FE0,
    element: 0x0010,
    vr: "US",
    value: uint16Data(0),
    to: &data
  )
  let file = DicomParser.DicomFile(
    transferSyntax: DicomParser.TransferSyntaxInfo(
      elementEncoding: .explicitVRLittleEndian,
      pixelDataEncoding: .uncompressed
    ),
    rawData: data
  )
  let slice = try DicomParser.openSlice(from: file)
  try expect(
    slice.frameOfReferenceUID == "1.2.3.4",
    "Frame of Reference UID was decoded incorrectly"
  )
}

@main
private enum DICOMParserTestRunner {
  static func main() throws {
    try testTruncatedLongVR()
    try testElementValueOutsideData()
    try testUndefinedSequenceOffset()
    try testBigEndianElement()
    try testValidRLE()
    try testDescendingRLEOffsets()
    try testMissingRLEBytePlane()
    try testOversizedEncapsulatedFragment()
    try testTruncatedMetaHeader()
    try testValidTransferSyntaxHeader()
    try testOrientationBasis()
    try testInvalidOrientationBasis()
    try testUnsignedPixelPaddingValue()
    try testSignedPixelPaddingValue()
    try testFrameOfReferenceUID()
    print("DICOM parser tests passed")
  }
}
