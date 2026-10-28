import Foundation
import zlib

enum I3MParserTests {
  private struct Failure: Swift.Error { let message: String }

  private static func expect(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }

  private static func volume(size: Vec3<UInt32>, spacing: [Float]) -> Data {
    var data = Data()
    for word in [UInt32(69426942), 1, size.x, size.y, size.z] + spacing.map(\.bitPattern) {
      append(word, to: &data)
    }
    for i in 0..<(Int(size.x) * Int(size.y) * Int(size.z)) {
      data.append(contentsOf: [71, 129, 222, UInt8(truncatingIfNeeded: i)])
    }
    return data
  }

  private static func deflate(_ data: Data) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
      Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw Failure(message: "Could not prepare ZIP fixture")
    }
    defer { deflateEnd(&stream) }
    var result = Data(count: Int(compressBound(uLong(data.count))))
    let count = try data.withUnsafeBytes { input in
      try result.withUnsafeMutableBytes { output in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
        stream.avail_in = uInt(input.count)
        stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
        stream.avail_out = uInt(output.count)
        try expect(zlib.deflate(&stream, Z_FINISH) == Z_STREAM_END, "Could not compress ZIP fixture")
        return Int(stream.total_out)
      }
    }
    result.count = count
    return result
  }

  private struct Entry {
    let name: String
    let data: Data
    var method: UInt16 = 8
    var descriptor = false
  }

  private static func archive(_ entries: [Entry]) throws -> Data {
    var data = Data(), directory = Data()
    for entry in entries {
      let payload = entry.method == 8 ? try deflate(entry.data) : entry.data
      let checksum = entry.data.withUnsafeBytes {
        UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)))
      }
      let name = Data(entry.name.utf8)
      let offset = UInt32(data.count)
      let flags: UInt16 = entry.descriptor ? 8 : 0
      append(UInt32(0x04034b50), to: &data)
      for word: UInt16 in [20, flags, entry.method, 0, 0] { append(word, to: &data) }
      for word in [checksum, UInt32(payload.count), UInt32(entry.data.count)] {
        append(entry.descriptor ? UInt32(0) : word, to: &data)
      }
      append(UInt16(name.count), to: &data); append(UInt16(0), to: &data)
      data.append(name); data.append(payload)
      if entry.descriptor {
        for word in [UInt32(0x08074b50), checksum, UInt32(payload.count), UInt32(entry.data.count)] {
          append(word, to: &data)
        }
      }
      append(UInt32(0x02014b50), to: &directory)
      for word: UInt16 in [20, 20, flags, entry.method, 0, 0] { append(word, to: &directory) }
      for word in [checksum, UInt32(payload.count), UInt32(entry.data.count)] { append(word, to: &directory) }
      for word: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { append(word, to: &directory) }
      append(UInt32(0), to: &directory); append(offset, to: &directory)
      directory.append(name)
    }
    let offset = UInt32(data.count)
    data.append(directory)
    append(UInt32(0x06054b50), to: &data)
    for word: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { append(word, to: &data) }
    append(UInt32(directory.count), to: &data); append(offset, to: &data)
    append(UInt16(0), to: &data)
    return data
  }

  static func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-i3m-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = volume(size: Vec3(3, 2, 2), spacing: [1, 2, 6])
    let expected = Data((0..<12).map(UInt8.init))

    func verify(_ data: Data, name: String, expected: Data) throws {
      let url = root.appendingPathComponent(name)
      try data.write(to: url)
      let parser = try VolumeFileParserFactory.parser(for: url.path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      try expect(parser.components == 1 && parser.bytesPerComponent == 1 && parser.offset == 0 && parser.dataIsTempCopy,
        "I3M import exposed the encoded gradients as volume channels")
      try expect(try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename)) == expected,
        "I3M scalar data or voxel order changed")
    }
    try verify(raw, name: "sample.I3M", expected: expected)
    let single = root.appendingPathComponent("sample.I3M")
    let parser = try I3MParser(filename: single.path)
    defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
    try expect(parser.size == Vec3(3, 2, 2), "I3M dimensions changed")
    try expect(abs(parser.voxelSpacing.x - 1 / 12) < 1e-6 && abs(parser.voxelSpacing.y - 1 / 6) < 1e-6 &&
      parser.voxelSpacing.z == 0.5, "Relative I3M spacing was not normalized proportionally")

    let zip = try archive([
      Entry(name: "__MACOSX/._sample.i3m", data: Data([1])),
      Entry(name: "folder/sample.I3M", data: raw, descriptor: true),
      Entry(name: "sample.i3m.1dt", data: Data("companion TF".utf8))
    ])
    try verify(zip, name: "sample.i3m.ZIP", expected: expected)
    try verify(try archive([Entry(name: "sample.i3m", data: raw, method: 0)]),
      name: "stored.zip", expected: expected)
    let large = volume(size: Vec3(97, 53, 53), spacing: [1, 1, 1])
    let largeExpected = Data((0..<(97 * 53 * 53)).map { UInt8(truncatingIfNeeded: $0) })
    try verify(large, name: "large.i3m", expected: largeExpected)
    try verify(try archive([Entry(name: "large.i3m", data: large)]), name: "large.zip", expected: largeExpected)

    func reject(_ data: Data, name: String) throws {
      let url = root.appendingPathComponent(name)
      try data.write(to: url)
      do {
        let parser = try I3MParser(filename: url.path)
        try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
      } catch is I3MParser.Error { return }
      throw Failure(message: "Malformed I3M accepted: \(name)")
    }
    for count in 0..<32 { try reject(Data(raw.prefix(count)), name: "short.i3m") }
    try reject(Data(raw.dropLast()), name: "truncated.i3m")
    try reject(raw + Data([0]), name: "trailing.i3m")
    for (offset, value): (Int, UInt32) in [(0, 0), (4, 2), (8, 0), (20, Float.nan.bitPattern),
                                         (24, Float(-1).bitPattern)] {
      var invalid = raw
      var word = Data(); append(value, to: &word)
      invalid.replaceSubrange(offset..<(offset + 4), with: word)
      try reject(invalid, name: "bad-header.i3m")
    }
    var overflow = raw
    overflow.replaceSubrange(8..<20, with: Data(repeating: 255, count: 12))
    try reject(overflow, name: "overflow.i3m")
    try reject(try archive([Entry(name: "a.i3m", data: raw), Entry(name: "b.i3m", data: raw)]), name: "multiple.zip")
    try reject(try archive([Entry(name: "mesh.obj", data: raw)]), name: "no-volume.zip")
    try reject(Data(zip.dropLast()), name: "truncated.zip")
    var badCRC = try archive([Entry(name: "a.i3m", data: raw, method: 0)])
    badCRC[30 + "a.i3m".utf8.count + 35] ^= 1
    try reject(badCRC, name: "crc.zip")
    var encrypted = try archive([Entry(name: "a.i3m", data: raw)])
    let central = encrypted.count - 22 - 46 - "a.i3m".utf8.count
    encrypted[central + 8] |= 1
    try reject(encrypted, name: "encrypted.zip")

    // Exercise the shared parser-to-bricking path, not just standalone decoding.
    let input = root.appendingPathComponent("sample.i3m.ZIP")
    let destination = root.appendingPathComponent("converted.data")
    try BorgVRVolumeConversionService.convert(.init(source: .file(input), destinationURL: destination,
      datasetDescription: "I3M test", metaDescription: "", settings: .init(brickSize: 8, overlap: 2,
        useCompression: true, extensionStrategy: .clamp)))
    let dataset = try BORGVRFileData(filename: destination.path)
    let metadata = dataset.getMetadata()
    try expect(metadata.componentCount == 1 && metadata.bytesPerComponent == 1 &&
      metadata.width == 3 && metadata.height == 2 && metadata.depth == 2,
      "Converted I3M metadata is incorrect")
    let buffer = dataset.allocateBrickBuffer()
    defer { buffer.deallocate() }
    try dataset.getBrick(index: 0, outputBuffer: buffer)
    for z in 0..<2 { for y in 0..<2 { for x in 0..<3 {
      try expect(buffer[(x + 2) + (y + 2) * 8 + (z + 2) * 64] == expected[x + y * 3 + z * 6],
        "I3M conversion changed scalar voxels")
    } } }

    // Optional real legacy files: pass the old app's Resources directory to the test script.
    for directory in CommandLine.arguments.dropFirst() {
      for name in ["c60", "engine", "hand", "head", "tooth"] {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).i3m.zip")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "*.i3m"]
        process.standardOutput = pipe
        try process.run()
        let original = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0 && original.count >= 32, "Could not read legacy fixture")
        let scalarData = Data(stride(from: 35, to: original.count, by: 4).map { original[$0] })
        try verify(try Data(contentsOf: url), name: "legacy-\(name).zip", expected: scalarData)
        print("Legacy \(name).i3m.zip matches original scalar data (\(scalarData.count) voxels)")
      }
    }
    print("IV3Dm parser, ZIP validation, and conversion tests passed")
  }
}
