import Foundation
import zlib

@main
enum UVFParserTests {
  struct Failure: Error { let message: String }

  static func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
  }

  static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data, bigEndian: Bool = false) {
    var value = bigEndian ? value.bigEndian : value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
  }

  static func compressed(_ raw: Data, codec: UInt32) throws -> Data {
    if codec == 0 { return raw }
    if codec == 3 {
      // A valid raw LZ4 block with one literal-only final sequence.
      var result = Data([UInt8(min(15, raw.count) << 4)])
      if raw.count >= 15 {
        var remaining = raw.count - 15
        while remaining >= 255 { result.append(255); remaining -= 255 }
        result.append(UInt8(remaining))
      }
      result.append(raw)
      return result
    }
    var result = Data(count: Int(compressBound(uLong(raw.count))))
    var count = uLongf(result.count)
    let status = result.withUnsafeMutableBytes { output in
      raw.withUnsafeBytes { input in
        compress2(output.bindMemory(to: UInt8.self).baseAddress!, &count,
          input.bindMemory(to: UInt8.self).baseAddress!, uLong(raw.count), Z_BEST_COMPRESSION)
      }
    }
    try expect(status == Z_OK, "Could not compress fixture")
    result.count = Int(count)
    return result
  }

  static func block(_ payload: Data, semantic: UInt64, last: Bool, bigEndian: Bool = false) -> Data {
    let name = Data("fixture".utf8)
    var data = Data()
    append(UInt64(name.count), to: &data, bigEndian: bigEndian)
    data.append(name)
    for value in [semantic, 0, last ? 0 : UInt64(32 + name.count + payload.count)] {
      append(value, to: &data, bigEndian: bigEndian)
    }
    data.append(payload)
    return data
  }

  struct Fixture {
    let file: Data
    let voxels: Data
    let size = Vec3(7, 5, 3)
  }

  static func toc(codec: UInt32 = 0, componentType: UInt32 = 1,
                  channels: Int = 2, normals: Bool = false, bigEndian: Bool = false) throws -> Fixture {
    let size = [7, 5, 3], brick = [6, 6, 6], overlap = 1, core = 4
    let bytes = [0, 4].contains(componentType) ? 1 : [1, 5].contains(componentType) ? 2 : 4
    var levels = [size]
    while levels.last! != [1, 1, 1] { levels.append(levels.last!.map { ($0 + 1) / 2 }) }
    var bricks: [Data] = [], expected = Data()
    func sample(x: Int, y: Int, z: Int, channel: Int) -> Data {
      let value = x + 7 * y + 35 * z + 1000 * channel
      var data = Data()
      if componentType == 8 {
        append(Float(value).bitPattern, to: &data, bigEndian: bigEndian)
      } else if bytes == 4 {
        append(UInt32(value), to: &data, bigEndian: bigEndian)
      } else if bytes == 1 {
        data.append(UInt8(truncatingIfNeeded: value))
      } else {
        append(UInt16(value), to: &data, bigEndian: bigEndian)
      }
      return data
    }
    for z in 0..<size[2] { for y in 0..<size[1] { for x in 0..<size[0] {
      for c in (normals ? [0] : Array(0..<channels)) {
        // Output is always little endian, even for a big-endian input.
        let raw = sample(x: x, y: y, z: z, channel: c)
        expected.append(bigEndian ? Data(raw.reversed()) : raw)
      }
    } } }
    for (level, dimensions) in levels.enumerated() {
      let counts = dimensions.map { ($0 + core - 1) / core }
      for bz in 0..<counts[2] { for by in 0..<counts[1] { for bx in 0..<counts[0] {
        let origin = [bx * core, by * core, bz * core]
        let stored = (0..<3).map { min(core, dimensions[$0] - origin[$0]) + 2 * overlap }
        var raw = Data()
        for z in 0..<stored[2] { for y in 0..<stored[1] { for x in 0..<stored[0] {
          let global = [x, y, z].enumerated().map { origin[$0.offset] + $0.element - overlap }
          for c in 0..<channels {
            if level == 0 && (0..<3).allSatisfy({ global[$0] >= 0 && global[$0] < dimensions[$0] }) {
              raw.append(sample(x: global[0], y: global[1], z: global[2], channel: c))
            } else { raw.append(Data(repeating: 0xEE, count: bytes)) }
          }
        } } }
        bricks.append(try compressed(raw, codec: codec))
      } } }
    }
    // TOC records remain logical scanline order; physical data is deliberately reversed.
    let headerSize = 105 + 36 * bricks.count
    var offsets = [Int](repeating: 0, count: bricks.count), payload = Data()
    for i in bricks.indices.reversed() {
      offsets[i] = headerSize + payload.count
      payload.append(bricks[i])
    }
    var octree = Data()
    append(componentType, to: &octree)
    append(UInt64(channels), to: &octree)
    octree.append(normals ? 1 : 0)
    for dimension in size { append(UInt64(dimension), to: &octree) }
    for spacing: Double in [1, 2, 3] { append(spacing.bitPattern, to: &octree) }
    for dimension in brick { append(UInt64(dimension), to: &octree) }
    append(UInt32(overlap), to: &octree)
    append(UInt32(2), to: &octree)
    append(UInt64(headerSize + payload.count), to: &octree)
    append(UInt32(4), to: &octree)
    for i in bricks.indices {
      append(UInt64(offsets[i]), to: &octree)
      append(UInt64(bricks[i].count), to: &octree)
      append(codec, to: &octree)
      append(UInt64(bricks[i].count), to: &octree)
      append(UInt32(0), to: &octree)
      append(UInt32(0), to: &octree)
    }
    try expect(octree.count == headerSize, "Fixture header size is incorrect")
    octree.append(payload)
    var file = Data("UVF-DATA".utf8)
    file.append(bigEndian ? 1 : 0)
    for value: UInt64 in [5, 0, 0, 0] { append(value, to: &file, bigEndian: bigEndian) }
    file.append(block(Data("ignored geometry".utf8), semantic: 8, last: false, bigEndian: bigEndian))
    file.append(block(octree, semantic: 9, last: true, bigEndian: bigEndian))
    return Fixture(file: file, voxels: expected)
  }

  static func raster(bigEndian: Bool) -> Fixture {
    let size = [7, 5, 3], core = 3, brick = 4
    var header = Data(), payload = Data(), expected = Data()
    func integer(_ value: Int) { append(UInt64(value), to: &header, bigEndian: bigEndian) }
    integer(3)
    for axis in [1, 2, 3] { integer(axis) }
    for row in 0..<4 { for column in 0..<4 {
      let value = row == column ? Double(row == 3 ? 1 : row + 1) : 0
      append(value.bitPattern, to: &header, bigEndian: bigEndian)
    } }
    for values in [size, [brick, brick, brick], [1, 1, 1], [2, 2, 2], [0, 0, 0]] {
      for value in values { integer(value) }
    }
    for value in [1, 1, 1, 0, 16, 16] { integer(value) }
    header.append(0) // Unsigned elements.
    integer(0) // No padding before the brick payload.
    for z in 0..<3 { for y in 0..<5 { for x in 0..<7 {
      append(UInt16(x + 7 * y + 35 * z), to: &expected)
    } } }
    let counts = size.map { max(1, ($0 - 1 + core - 1) / core) }
    for bz in 0..<counts[2] { for by in 0..<counts[1] { for bx in 0..<counts[0] {
      let origin = [bx * core, by * core, bz * core]
      let stored = (0..<3).map { min(brick, size[$0] - origin[$0]) }
      for z in 0..<stored[2] { for y in 0..<stored[1] { for x in 0..<stored[0] {
        let value = origin[0] + x + 7 * (origin[1] + y) + 35 * (origin[2] + z)
        append(UInt16(value), to: &payload, bigEndian: bigEndian)
      } } }
    } } }
    var file = Data("UVF-DATA".utf8)
    file.append(bigEndian ? 1 : 0)
    for value: UInt64 in [4, 0, 0, 0] { append(value, to: &file, bigEndian: bigEndian) }
    file.append(block(header + payload, semantic: 1, last: true, bigEndian: bigEndian))
    return Fixture(file: file, voxels: expected)
  }

  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-uvf-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for codec: UInt32 in [0, 1, 3] {
      let fixture = try toc(codec: codec)
      let source = root.appendingPathComponent("test-\(codec).UVF")
      try fixture.file.write(to: source)
      var progress: [Double] = []
      let parser = try VolumeFileParserFactory.parser(for: source.path, progress: { progress.append($0) })
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      try expect(parser.size == fixture.size && parser.bytesPerComponent == 2 && parser.components == 2,
        "UVF sample layout changed")
      try expect(parser.dataIsTempCopy && parser.offset == 0 && parser.isLittleEndian,
        "UVF must expose a temporary little-endian RAW file")
      try expect(!parser.hasPhysicalVoxelSpacing && abs(parser.voxelSpacing.x - 0.1) < 1e-6 &&
        abs(parser.voxelSpacing.y - 0.2) < 1e-6 && abs(parser.voxelSpacing.z - 0.3) < 1e-6,
        "UVF relative spacing was not normalized proportionally")
      try expect(try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename)) == fixture.voxels,
        "UVF LoD 0 reconstruction changed voxels, overlap, or ordering (codec \(codec))")
      try expect(progress.last == 1 && zip(progress, progress.dropFirst()).allSatisfy({ $0.0 <= $0.1 }),
        "UVF progress must be monotonic and finish at 1")
    }

    for (type, channels): (UInt32, Int) in [(0, 3), (0, 4), (2, 1), (5, 1), (8, 2)] {
      let fixture = try toc(componentType: type, channels: channels)
      let source = root.appendingPathComponent("samples-\(type)-\(channels).uvf")
      try fixture.file.write(to: source)
      let parser = try UVFParser(filename: source.path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      var expected = fixture.voxels
      if type == 5 {
        for i in stride(from: 1, to: expected.count, by: 2) { expected[i] ^= 0x80 }
      } else if type == 8 {
        expected = Data()
        for i in 0..<105 {
          let value = UInt16((Double(i) / 104 * 65535).rounded())
          for _ in 0..<channels { append(value, to: &expected) }
        }
      }
      try expect(try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename)) == expected,
        "UVF sample conversion is incorrect for type \(type)")
      if type == 0 {
        try expect(parser.channelInterpretation == (channels == 3 ? .rgb : .rgba), "UVF color semantics were lost")
      }
    }
    let normals = try toc(componentType: 0, channels: 4, normals: true)
    let normalsURL = root.appendingPathComponent("normals.uvf")
    try normals.file.write(to: normalsURL)
    let scalar = try UVFParser(filename: normalsURL.path)
    defer { try? FileManager.default.removeItem(atPath: scalar.absoluteFilename) }
    try expect(scalar.components == 1 && scalar.channelInterpretation == .independentChannels,
      "UVF precomputed normals were exposed as color channels")
    try expect(try Data(contentsOf: URL(fileURLWithPath: scalar.absoluteFilename)) == normals.voxels,
      "UVF scalar channel was lost when removing normals")

    for bigEndian in [false, true] {
      let fixture = raster(bigEndian: bigEndian)
      let source = root.appendingPathComponent("raster-\(bigEndian).uvf")
      try fixture.file.write(to: source)
      let parser = try UVFParser(filename: source.path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      try expect(parser.size == fixture.size && parser.bytesPerComponent == 2 && parser.components == 1,
        "Legacy UVF metadata changed")
      try expect(try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename)) == fixture.voxels,
        "Legacy UVF overlap removal or endianness conversion failed")
    }

    let valid = try toc()
    let damaged = root.appendingPathComponent("damaged.uvf")
    for count in [0, 8, 40, 80, valid.file.count - 1] {
      try Data(valid.file.prefix(count)).write(to: damaged)
      do {
        let parser = try UVFParser(filename: damaged.path)
        try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
        throw Failure(message: "Truncated UVF accepted (\(count) bytes)")
      } catch is UVFParser.Error {}
    }
    let source = root.appendingPathComponent("cancel.uvf")
    try valid.file.write(to: source)
    do {
      let parser = try UVFParser(filename: source.path, cancellationCheck: { throw CancellationError() })
      try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
      throw Failure(message: "UVF cancellation was ignored")
    } catch is CancellationError {}

    // Optional pairs: original UVF and LoD-0 NRRD exported by ImageVis3D's converter.
    let args = Array(CommandLine.arguments.dropFirst())
    try expect(args.count % 2 == 0, "Provide pairs of UVF and expected NRRD files")
    for i in stride(from: 0, to: args.count, by: 2) {
      let uvf = try UVFParser(filename: args[i])
      let nrrd = try NRRDParser(filename: args[i + 1])
      defer {
        try? FileManager.default.removeItem(atPath: uvf.absoluteFilename)
        if nrrd.dataIsTempCopy { try? FileManager.default.removeItem(atPath: nrrd.absoluteFilename) }
      }
      let expected = try Data(contentsOf: URL(fileURLWithPath: nrrd.absoluteFilename)).dropFirst(nrrd.offset)
      try expect(uvf.size == nrrd.size && uvf.components == nrrd.components && uvf.bytesPerComponent == nrrd.bytesPerComponent,
        "UVF metadata differs from original converter: \(args[i])")
      try expect(try Data(contentsOf: URL(fileURLWithPath: uvf.absoluteFilename)) == Data(expected),
        "UVF voxels differ from original converter: \(args[i])")
      print("PASS original converter comparison: \(URL(fileURLWithPath: args[i]).lastPathComponent)")
    }
    print("UVF parser tests passed")
  }
}
