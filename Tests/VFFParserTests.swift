import Foundation

@main
enum VFFParserTests {
  struct Failure: Error { let message: String }
  static func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message: message) }
  }

  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vff-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func fixture(_ name: String, _ header: String, _ bytes: Data, separator: String = "\u{0c}\n") throws -> URL {
      let url = root.appendingPathComponent(name + ".vff")
      var file = Data(("ncaa\n" + header + separator).utf8)
      file.append(bytes)
      try file.write(to: url)
      return url
    }
    let base = "type=raster;rank=3;bands=1;format=slice;size=3 2 1;spacing=1 2 3;"
    for width in [1, 2, 4] {
      let values: [UInt32] = [0, 1, 10, 128, width == 1 ? 255 : 32768, width == 4 ? .max : 65535]
      var raw = Data(), expected = Data()
      for value in values {
        let mask: UInt32 = width == 4 ? .max : (1 << (width * 8)) - 1
        let stored = value & mask
        let shifted = stored ^ (1 << (width * 8 - 1))
        for byte in (0..<width).reversed() { raw.append(UInt8(truncatingIfNeeded: stored >> (byte * 8))) }
        for byte in 0..<width { expected.append(UInt8(truncatingIfNeeded: shifted >> (byte * 8))) }
      }
      let url = try fixture("signed-\(width)", base + "bits=\(width * 8);", raw)
      let parser = try VolumeFileParserFactory.parser(for: url.path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      let decoded = try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename))
      try expect(decoded == expected, "Signed conversion/endianness must be exact for \(width) bytes")
      try expect(parser.size == Vec3(3, 2, 1) && parser.bytesPerComponent == width, "Dimensions/precision")
      try expect(!parser.hasPhysicalVoxelSpacing && abs(parser.voxelSpacing.y - 0.5) < 0.00001, "Relative spacing fallback")
    }
    let raw = Data([0, 1, 2, 3, 4, 5])
    for (name, fields, expected) in [
      ("ge", "elementsize=0.09289;", Float(0.00009289)),
      ("mm", "elementsize=1;spacingunit=mm;", Float(0.001)),
      ("meters", "spacingunit=m;", Float(1))
    ] {
      let url = try fixture(name, base + "bits=8;" + fields, raw, separator: "\u{0c}\r\n")
      let parser = try VFFParser(filename: url.path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      try expect(parser.hasPhysicalVoxelSpacing && abs(parser.voxelSpacing.x - expected) < 0.00000001, "Physical units")
      try expect(abs(parser.voxelSpacing.z - expected * 3) < 0.00000001, "Anisotropic spacing")
    }
    let plane = try fixture("plane", "type=raster;format=slice;rank=2;bands=1;bits=8;size=2 1;title=\"a;b\";",
                            Data([10, 12]), separator: "\u{0c}")
    let planeParser = try VFFParser(filename: plane.path)
    defer { try? FileManager.default.removeItem(atPath: planeParser.absoluteFilename) }
    try expect(planeParser.size.z == 1, "Rank 2 gets one slice")
    let planeBytes = try Data(contentsOf: URL(fileURLWithPath: planeParser.absoluteFilename))
    try expect(planeBytes == Data([138, 140]), "Do not eat raw bytes resembling header whitespace")
    for header in [
      base + "bits=12;", base + "bits=8;bands=2;", base + "bits=8;size=1 1 1;",
      base + "bits=8;compression=gzip;", base + "bits=8;data_type=float;",
      base + "bits=8;elementsize=nan;", base + "bits=8;spacingunit=feet;",
      "type=raster;rank=3;bands=1;format=slice;bits=32;size=9223372036854775807 2 3;",
      "type=raster;rank=3;bands=1;format=slice;bits=8;size=3 invalid 2 1;",
      base + "bits=8;spacing=1 invalid 2 3;",
      base + "bits=8;title=\"unterminated;", base + "bits=8;unfinished"
    ] {
      let url = try fixture("invalid", header, raw)
      do {
        let parser = try VFFParser(filename: url.path)
        try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
        throw Failure(message: "Accepted malformed/unsupported VFF")
      } catch is VFFParser.Error {}
    }
    let truncated = try fixture("truncated", base + "bits=16;", raw)
    do { _ = try VFFParser(filename: truncated.path); throw Failure(message: "Accepted short payload") }
    catch is VFFParser.Error {}
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
    var checks = 0
    do {
      _ = try VFFParser(filename: plane.path, cancellationCheck: {
        checks += 1
        if checks == 2 { throw CancellationError() }
      })
      throw Failure(message: "Did not cancel")
    } catch is CancellationError {}
    let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
    try expect(!after.subtracting(before).contains { $0.hasPrefix("borgvr-vff-") }, "Cancelled parsing must remove its RAW file")

    for path in CommandLine.arguments.dropFirst() {
      let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
      let parser = try VFFParser(filename: path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      let decoded = try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename), options: .mappedIfSafe)
      let delimiter = data.prefix(1 << 20).firstIndex(of: 12)!
      let payload = delimiter + 2
      try expect(parser.bytesPerComponent == 2 && parser.hasPhysicalVoxelSpacing, "GE fixtures should be signed16 with physical spacing")
      try data.withUnsafeBytes { input in
        try decoded.withUnsafeBytes { output in
          for index in stride(from: 0, to: decoded.count, by: 2) {
            let stored = UInt16(bigEndian: input.loadUnaligned(fromByteOffset: payload + index, as: UInt16.self))
            let actual = UInt16(littleEndian: output.loadUnaligned(fromByteOffset: index, as: UInt16.self))
            if actual != stored ^ 0x8000 { throw Failure(message: "Real sample mismatch at \(index)") }
          }
        }
      }
      print("Verified every voxel: \(URL(fileURLWithPath: path).lastPathComponent), \(parser.size), spacing \(parser.voxelSpacing) m")
    }
    print("VFF signed 8/16/32-bit, units, rank, header/payload validation and cancellation tests passed")
  }
}
