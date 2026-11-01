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

private func testReadingDICOMDirectoryContents() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-dicom-directory-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  for index in 0..<3 {
    var data = Data(repeating: 0, count: 128)
    data.append(Data("DICM".utf8))
    appendExplicitElement(group: 0x0002, element: 0x0010, vr: "UI",
      value: Data("1.2.840.10008.1.2.1\0".utf8), to: &data)
    let fields: [(UInt16, UInt16)] = [(0x0010, 2), (0x0011, 2), (0x0002, 1),
                                     (0x0100, 8), (0x0101, 8), (0x0103, 0)]
    for (element, value) in fields {
      appendExplicitElement(group: 0x0028, element: element, vr: "US",
        value: uint16Data(value), to: &data)
    }
    appendExplicitElement(group: 0x0020, element: 0x0013, vr: "IS",
      value: Data("\(index) ".utf8), to: &data)
    appendExplicitElement(group: 0x0020, element: 0x0032, vr: "DS",
      value: Data("0\\0\\\(index) ".utf8), to: &data)
    appendExplicitElement(group: 0x0020, element: 0x0037, vr: "DS",
      value: Data("1\\0\\0\\0\\1\\0 ".utf8), to: &data)
    appendExplicitElement(group: 0x0008, element: 0x002A, vr: "DT",
      value: Data("20261101120000+0200".utf8), to: &data)
    appendExplicitElement(group: 0x7FE0, element: 0x0010, vr: "US",
      value: Data(repeating: UInt8(index + 1), count: 4), to: &data)
    try data.write(to: directory.appendingPathComponent("slice-\(index)"))
  }
  try Data("Unrelated file".utf8).write(to: directory.appendingPathComponent("README.txt"))
  let files = try FileManager.default.contentsOfDirectory(at: directory,
    includingPropertiesForKeys: nil)
  let volume = try DicomParser.decodeVolume(from: files)
  try expect(volume.width == 2 && volume.height == 2 && volume.depth == 3,
    "DICOM directory contents were not read as one volume")
  try expect(volume.voxelData == [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3],
    "Coordinated DICOM reads changed slice ordering or pixel data")
  try expect(volume.provenance.count == 1 && volume.provenance[0].text.contains("acquisition"),
    "Slice histories were lost or identical events were repeated")
}

private func testProvenanceDates() throws {
  func event(_ fields: [DicomTag: String], containing name: String = "acquisition") -> DicomProvenanceMetadata.Event {
    DicomProvenanceMetadata(readString: { fields[$0] }).events.first { $0.text.contains(name) }!
  }
  let utc = ISO8601DateFormatter()
  let combined = event([.acquisitionDateTime: "20261101003045.123456+0200", .timezoneOffsetFromUTC: "-0500"])
  try expect(abs(combined.date!.timeIntervalSince1970 - utc.date(from: "2026-10-31T22:30:45Z")!.timeIntervalSince1970 - 0.123456) < 0.000001,
    "DT fractional seconds or explicit offset were ignored")
  let separate = event([.acquisitionDate: "20261101", .acquisitionTime: "003045", .timezoneOffsetFromUTC: "+0200"])
  try expect(utc.string(from: separate.date!) == "2026-10-31T22:30:45Z", "DA/TM timezone rollover failed")
  for offset in ["-1200", "+1400", "invalid"] {
    let day = event([.acquisitionDate: "20261101", .timezoneOffsetFromUTC: offset])
    try expect(utc.string(from: day.date!) == "2026-11-01T00:00:00Z" && day.text.contains("date only: 2026-11-01"),
      "Date-only source was shifted by a time zone")
  }
  let noZone = event([.acquisitionDateTime: "20261101123045"])
  try expect(noZone.date == nil && noZone.text.contains("timezone unspecified") && noZone.text.contains("20261101123045"),
    "Missing timezone was invented or original timestamp was lost")
  for raw in ["20260230", "20260001", "20261101240000+0000", "20261101126000+0000", "20261101123000+1460", "20261101123000-0000", "20261101123000.", "202611", ""] {
    try expect(event([.acquisitionDateTime: raw]).date == nil, "Invalid/incomplete DICOM timestamp was accepted: \(raw)")
  }
  let shortTime = event([.acquisitionDate: "20261101", .acquisitionTime: "12", .timezoneOffsetFromUTC: "+0000"])
  try expect(utc.string(from: shortTime.date!) == "2026-11-01T12:00:00Z", "Reduced time precision was rejected")
  let missingDate = event([.derivationDescription: "Filtered"], containing: "content creation")
  try expect(missingDate.date == nil && missingDate.text.contains("Filtered"), "Undated derivation was lost")
}

private func testProvenanceSequences() throws {
  for undefined in [false, true] {
    var data = Data(repeating: 0, count: 128)
    data.append(Data("DICM".utf8))
    appendExplicitElement(group: 0x0028, element: 0x0010, vr: "US", value: uint16Data(1), to: &data)
    appendExplicitElement(group: 0x0028, element: 0x0011, vr: "US", value: uint16Data(1), to: &data)
    func text(_ tag: DicomTag, _ vr: String, _ value: String, to bytes: inout Data) {
      var encoded = Data(value.utf8)
      if encoded.count % 2 != 0 { encoded.append(32) }
      appendExplicitElement(group: tag.group, element: tag.element, vr: vr, value: encoded, to: &bytes)
    }
    text(.specificCharacterSet, "CS", "ISO_IR 192", to: &data)
    text(.studyDate, "DA", "20261001", to: &data)
    text(.seriesDate, "DA", "20261101", to: &data)
    text(.acquisitionDateTime, "DT", "20261101093000+0100", to: &data)
    text(.contentDate, "DA", "20261101", to: &data)
    text(.contentTime, "TM", "103000", to: &data)
    text(.timezoneOffsetFromUTC, "SH", "+0100", to: &data)
    text(.derivationDescription, "ST", "Gefilterte Gefäße", to: &data)
    var items = Data()
    for index in 1...2 {
      var item = Data()
      text(.contributionDateTime, "DT", "202611011\(index)0000+0100", to: &item)
      text(.contributionDescription, "ST", "Processing step \(index)", to: &item)
      text(.softwareVersions, "LO", "v\(index).0", to: &item)
      // Nested values must not overwrite the dataset's own acquisition metadata.
      text(.acquisitionDateTime, "DT", "20000101000000+0000", to: &item)
      appendUInt16LE(0xFFFE, to: &items); appendUInt16LE(0xE000, to: &items)
      appendUInt32LE(undefined ? UInt32.max : UInt32(item.count), to: &items)
      items.append(item)
      if undefined {
        appendUInt16LE(0xFFFE, to: &items); appendUInt16LE(0xE00D, to: &items)
        appendUInt32LE(0, to: &items)
      }
    }
    appendUInt16LE(0x0018, to: &data); appendUInt16LE(0xA001, to: &data)
    data.append(Data("SQ".utf8)); appendUInt16LE(0, to: &data)
    appendUInt32LE(undefined ? UInt32.max : UInt32(items.count), to: &data)
    data.append(items)
    if undefined {
      appendUInt16LE(0xFFFE, to: &data); appendUInt16LE(0xE0DD, to: &data)
      appendUInt32LE(0, to: &data)
    }
    appendExplicitElement(group: 0x7FE0, element: 0x0010, vr: "US", value: uint16Data(42), to: &data)
    let file = DicomParser.DicomFile(transferSyntax: .init(elementEncoding: .explicitVRLittleEndian,
      pixelDataEncoding: .uncompressed), rawData: data)
    let slice = try DicomParser.openSlice(from: file)
    try expect(slice.seriesDate == "20261101" && slice.provenanceMetadata.studyDate == "20261001",
      "Series date and study date were confused")
    try expect(slice.provenanceMetadata.acquisitionDateTime == "20261101093000+0100",
      "A nested date replaced the top-level acquisition timestamp")
    try expect(slice.provenanceMetadata.derivationDescription == "Gefilterte Gefäße",
      "UTF-8 derivation text was lost")
    let contributions = slice.provenanceMetadata.events.filter { $0.text.contains("equipment contribution") }
    try expect(contributions.count == 2 && contributions[0].text.contains("Processing step 1")
      && contributions[1].text.contains("software: v2.0") && contributions.allSatisfy { $0.date != nil },
      "Contribution items were mixed or lost")
    try expect(slice.pixelData == uint16Data(42), "Sequence parsing changed pixel offsets")
  }
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
    try testReadingDICOMDirectoryContents()
    try testProvenanceDates()
    try testProvenanceSequences()
    print("DICOM parser tests passed")
  }
}
