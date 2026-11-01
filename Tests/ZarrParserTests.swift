import Foundation
import zlib

@main
struct ZarrParserTests {
  static var checks = 0
  static func check(_ value: Bool, _ message: String) {
    precondition(value, message); checks += 1
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-zarr-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["bytes", "gzip", "zstd"] {
      let directory = root.appendingPathComponent(name + ".zarr")
      try fixture(directory, codec: name)
      let expected = (0..<2).flatMap { z in (0..<3).flatMap { y in (0..<5).flatMap { x in
        (0..<2).flatMap { c -> [UInt8] in
          let value = c * 100 + z * 30 + y * 5 + x
          return [UInt8(value), 0]
        }
      } } }
      try verify(directory, expected: Data(expected))
      let archive = root.appendingPathComponent(name + ".ozx")
      try zip(directory, to: archive, zip64: name == "zstd")
      try verify(archive, expected: Data(expected))
      if name == "bytes" {
        let deflated = root.appendingPathComponent("deflated.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", "-9", deflated.path, "."]
        process.currentDirectoryURL = directory
        try process.run(); process.waitUntilExit()
        check(process.terminationStatus == 0, "deflated ZIP fixture")
        try verify(deflated, expected: Data(expected))
      }
      var cancelled = false
      do {
        _ = try ZarrParser(filename: directory.path, cancellationCheck: { cancelled = true; throw CancellationError() })
        preconditionFailure("ignored cancellation")
      } catch is CancellationError { check(cancelled, "cancellation not checked") }
      if name == "bytes" {
        let renamed = root.appendingPathComponent("folder-without-extension")
        try FileManager.default.moveItem(at: directory, to: renamed)
        try verify(renamed, expected: Data(expected))
      }
    }
    for location in ["start", "end"] {
      let directory = root.appendingPathComponent("shards-\(location).zarr")
      try shardFixture(directory, location: location)
      let parser = try ZarrParser(filename: directory.path)
      defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      let raw = try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename))
      check(Array(raw) == [1,2,3,4,5,6,7,8], "shard placement")
      let indexPath = directory.appendingPathComponent("c/0/0/0")
      var corrupt = try Data(contentsOf: indexPath)
      corrupt[location == "start" ? 0 : corrupt.count - 1] ^= 1
      try corrupt.write(to: indexPath)
      do { _ = try ZarrParser(filename: directory.path); preconditionFailure("accepted corrupt shard") }
      catch { checks += 1 }
    }
    let fillDirectory = root.appendingPathComponent("fill.zarr")
    try FileManager.default.createDirectory(at: fillDirectory, withIntermediateDirectories: true)
    var metadata = array(shape: [2,2,2], chunk: [2,2,2], names: ["z","y","x"], bytes: 1)
    metadata["fill_value"] = 7
    try json(metadata, to: fillDirectory.appendingPathComponent("zarr.json"))
    let filled = try ZarrParser(filename: fillDirectory.path)
    defer { try? FileManager.default.removeItem(atPath: filled.absoluteFilename) }
    check(try Data(contentsOf: URL(fileURLWithPath: filled.absoluteFilename)) == Data(repeating: 7, count: 8), "missing chunk fill")
    try numericTests(root)
    if CommandLine.arguments.count > 1 {
      let real = try ZarrParser(filename: CommandLine.arguments[1])
      defer { try? FileManager.default.removeItem(atPath: real.absoluteFilename) }
      check(real.size == Vec3(x: 256, y: 128, z: 64), "public OZX dimensions")
      let raw = try Data(contentsOf: URL(fileURLWithPath: real.absoluteFilename))
      check(raw.count == 256 * 128 * 64 && raw.min() == 0 && raw.max() == 253, "public OZX values")
    }
    print("Zarr/OZX import tests passed: \(checks)")
  }

  static func numericTests(_ root: URL) throws {
    for endian in ["big", "little"] {
      for bytes in [1, 2, 4] {
        let sign = UInt64(1) << (bytes * 8 - 1)
        let mask = sign * 2 - 1
        let values = [sign, mask, 0, sign - 1]
        var expected = Data()
        for value in values { for b in 0..<bytes { expected.append(UInt8(truncatingIfNeeded: (value ^ sign) >> (b * 8))) } }
        try numeric(root, type: "int\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: [values], expected: expected)
        try numeric(root, type: "int\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: [values], expected: Data(repeating: 0, count: 8 * bytes),
                    fill: -Double(sign), missing: true)
      }
      for bytes in [4, 8] {
        func bits(_ value: Double) -> UInt64 { bytes == 4 ? UInt64(Float(value).bitPattern) : value.bitPattern }
        let channels: [[Double]] = [[-2, -1, 0, 2], [100, 200, 300, 500]]
        var expected = Data()
        for value: UInt16 in [0, 0, 16384, 16384, 32768, 32768, 65535, 65535] { expected.appendLE(value) }
        try numeric(root, type: "float\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: channels.map { $0.map(bits) }, expected: expected)
        var special = Data()
        for value: UInt16 in [0, 0, 65535, 0] { special.appendLE(value) }
        try numeric(root, type: "float\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: [[Double.nan, -.infinity, .infinity, 42].map(bits)], expected: special)
        try numeric(root, type: "float\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: [[Double](repeating: .nan, count: 4).map(bits)], expected: Data(repeating: 0, count: 8))
        try numeric(root, type: "float\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: [[Double](repeating: 42, count: 4).map(bits)], expected: Data(repeating: 0, count: 16),
                    fill: 42, missing: true)
        try numeric(root, type: "float\(bytes * 8)", bytes: bytes, endian: endian,
                    channels: [[Double](repeating: 0, count: 4).map(bits)], expected: Data(repeating: 0, count: 16),
                    fill: "NaN", missing: true)
      }
    }
    let extreme = Double.greatestFiniteMagnitude
    var expected = Data()
    for value: UInt16 in [0, 32768, 65535, 32768] { expected.appendLE(value) }
    try numeric(root, type: "float64", bytes: 8, endian: "little",
                channels: [[-extreme, 0, extreme, 0].map(\.bitPattern)], expected: expected)
  }

  static func numeric(_ root: URL, type: String, bytes: Int, endian: String,
                      channels: [[UInt64]], expected: Data, fill: Any = 0, missing: Bool = false) throws {
    let directory = root.appendingPathComponent("numeric-\(UUID()).zarr")
    var metadata = array(shape: [channels.count, 1, 1, missing ? 8 : 4], chunk: [1,1,1,2],
                         names: ["c","z","y","x"], bytes: bytes)
    metadata["data_type"] = type
    metadata["fill_value"] = fill
    metadata["codecs"] = [["name": "bytes", "configuration": ["endian": endian]]]
    try json(metadata, to: directory.appendingPathComponent("zarr.json"))
    if !missing {
      for c in channels.indices { for chunk in 0..<2 {
        let path = directory.appendingPathComponent("c/\(c)/0/0/\(chunk)")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for value in channels[c][chunk * 2..<chunk * 2 + 2] {
          for b in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> ((endian == "little" ? b : bytes - 1 - b) * 8))) }
        }
        try data.write(to: path)
      } }
    }
    var logs: [String] = [], progress: [Double] = []
    let parser = try VolumeFileParserFactory.parser(for: directory.path,
      progress: { progress.append($0) }, log: { logs.append($0) })
    defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
    check(parser.bytesPerComponent == (type.hasPrefix("float") ? 2 : bytes), "converted component width")
    check(try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename)) == expected,
          "numeric mapping \(type)/\(endian), missing=\(missing)")
    check(progress.last == 1 && Swift.zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 }, "numeric progress")
    if type.hasPrefix("float") {
      check(logs.count == channels.count && logs.allSatisfy { $0.contains("original finite range") }, "range log")
      let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        .filter { $0.hasPrefix("borgvr-zarr-") && $0.hasSuffix(".raw") }.sorted()
      do {
        _ = try ZarrParser(filename: directory.path, cancellationCheck: {
          if progress.last == 0.9 { throw CancellationError() }
        }, progress: { progress.append($0) })
        preconditionFailure("ignored float conversion cancellation")
      } catch is CancellationError { checks += 1 }
      let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        .filter { $0.hasPrefix("borgvr-zarr-") && $0.hasSuffix(".raw") }.sorted()
      check(before == after, "cancelled conversion leaked temporary file")
    }
  }

  static func verify(_ url: URL, expected: Data) throws {
    FileHandle.standardError.write(Data("Testing \(url.path)\n".utf8))
    var progress: [Double] = []
    let parser: VolumeFileParser
    if url.pathExtension == "zip" {
      parser = try ZarrParser(filename: url.path, progress: { progress.append($0) })
    } else {
      parser = try VolumeFileParserFactory.parser(for: url.path, progress: { progress.append($0) })
    }
    defer { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
    check(parser.size == Vec3(x: 5, y: 3, z: 2), "axis order")
    check(parser.components == 2 && parser.bytesPerComponent == 2, "component layout")
    check(abs(parser.voxelSpacing.x - 0.002) < 1e-8, "physical units")
    check(try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename)) == expected, "odd boundaries/endian/interleaving")
    check(progress.last == 1 && Swift.zip(progress, progress.dropFirst()).allSatisfy({ $0 <= $1 }), "progress")
  }

  static func array(shape: [Int], chunk: [Int], names: [String], bytes: Int) -> [String: Any] {
    ["zarr_format": 3, "node_type": "array", "shape": shape, "data_type": "uint\(bytes * 8)",
     "dimension_names": names, "fill_value": 0,
     "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": chunk]],
     "chunk_key_encoding": ["name": "default", "configuration": ["separator": "/"]],
     "codecs": [["name": "bytes", "configuration": ["endian": "big"]]]]
  }
  static func json(_ value: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value).write(to: url)
  }
  static func fixture(_ url: URL, codec: String) throws {
    let names = ["x", "c", "z", "y"]
    let axes = names.map { name -> [String: Any] in
      name == "c" ? ["name": name, "type": "channel"] : ["name": name, "type": "space", "unit": "millimeter"]
    }
    let dataset: [String: Any] = ["path": "0", "coordinateTransformations": [["type": "scale", "scale": [2,1,3,4]]]]
    let ome: [String: Any] = ["version": "0.5", "multiscales": [["axes": axes, "datasets": [dataset]]]]
    let root: [String: Any] = ["zarr_format": 3, "node_type": "group", "attributes": ["ome": ome]]
    try json(root, to: url.appendingPathComponent("zarr.json"))
    var metadata = array(shape: [5,2,2,3], chunk: [3,1,2,2], names: names, bytes: 2)
    if codec != "bytes" { metadata["codecs"] = [["name": "bytes", "configuration": ["endian": "big"]], ["name": codec]] }
    try json(metadata, to: url.appendingPathComponent("0/zarr.json"))
    for bx in 0..<2 { for c in 0..<2 { for by in 0..<2 {
      var raw = Data()
      for dx in 0..<3 { for z in 0..<2 { for dy in 0..<2 {
        let value = c * 100 + z * 30 + (by * 2 + dy) * 5 + bx * 3 + dx
        raw.append(contentsOf: [0, UInt8(value)])
      } } }
      let path = url.appendingPathComponent("0/c/\(bx)/\(c)/0/\(by)")
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoded: Data
      if codec == "zstd" { encoded = try zstd(raw, in: url) }
      else if codec == "gzip" {
        let process = Process(), pipe = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        process.standardInput = input; process.standardOutput = pipe
        try process.run(); try input.fileHandleForWriting.write(contentsOf: raw); try input.fileHandleForWriting.close()
        encoded = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        check(process.terminationStatus == 0, "gzip fixture")
      } else { encoded = raw }
      try encoded.write(to: path)
    } } }
  }
  static func zstd(_ raw: Data, in directory: URL) throws -> Data {
    guard let executable = ProcessInfo.processInfo.environment["ZSTD_EXECUTABLE"], !executable.isEmpty else {
      // A valid RFC 8878 raw block keeps parser tests independent of external tools.
      precondition(raw.count < 256)
      let header = raw.count * 8 + 1
      return Data([0x28,0xb5,0x2f,0xfd,0x20,UInt8(raw.count),UInt8(header & 255),UInt8(header >> 8),0]) + raw
    }
    let file = directory.appendingPathComponent("fixture.raw")
    try raw.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-q", "-c", file.path]; process.standardOutput = pipe
    try process.run()
    let result = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    check(process.terminationStatus == 0, "zstd fixture")
    return result
  }
  static func shardFixture(_ url: URL, location: String) throws {
    var metadata = array(shape: [2,2,2], chunk: [2,2,2], names: ["z","y","x"], bytes: 1)
    metadata["codecs"] = [["name": "sharding_indexed", "configuration": [
      "chunk_shape": [1,1,1], "codecs": [["name": "bytes"]], "index_location": location,
      "index_codecs": [["name": "bytes", "configuration": ["endian": "little"]], ["name": "crc32c"]]]]]
    try json(metadata, to: url.appendingPathComponent("zarr.json"))
    var index = Data()
    for i in 0..<8 { index.appendLE(UInt64(i + (location == "start" ? 132 : 0))); index.appendLE(UInt64(1)) }
    index.appendLE(ZarrCompression.crc32c(index))
    let payload = Data(1...8)
    let path = url.appendingPathComponent("c/0/0/0")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (location == "start" ? index + payload : payload + index).write(to: path)
  }
  static func zip(_ directory: URL, to url: URL, zip64: Bool) throws {
    let directory = directory.resolvingSymlinksInPath()
    let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
    var archive = Data(), central = Data(), count = 0
    for case let file as URL in iterator {
      guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      let raw = try Data(contentsOf: file)
      let name = Data(file.resolvingSymlinksInPath().path.dropFirst(directory.path.count + 1).utf8)
      let crc = raw.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
      let offset = archive.count
      archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0)); archive.appendLE(UInt32(0)); archive.appendLE(UInt32(crc))
      archive.appendLE(UInt32(raw.count)); archive.appendLE(UInt32(raw.count))
      archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0)); archive += name; archive += raw
      central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(45)); central.appendLE(UInt16(45))
      central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(UInt32(crc))
      central.appendLE(zip64 ? UInt32.max : UInt32(raw.count)); central.appendLE(zip64 ? UInt32.max : UInt32(raw.count))
      central.appendLE(UInt16(name.count)); central.appendLE(UInt16(zip64 ? 28 : 0)); central.appendLE(UInt16(0))
      central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0))
      central.appendLE(zip64 ? UInt32.max : UInt32(offset)); central += name
      if zip64 {
        central.appendLE(UInt16(1)); central.appendLE(UInt16(24))
        central.appendLE(UInt64(raw.count)); central.appendLE(UInt64(raw.count)); central.appendLE(UInt64(offset))
      }
      count += 1
    }
    let centralStart = archive.count
    archive += central
    if zip64 {
      let zip64Start = archive.count
      archive.appendLE(UInt32(0x06064b50)); archive.appendLE(UInt64(44)); archive.appendLE(UInt16(45)); archive.appendLE(UInt16(45))
      archive.appendLE(UInt32(0)); archive.appendLE(UInt32(0)); archive.appendLE(UInt64(count)); archive.appendLE(UInt64(count))
      archive.appendLE(UInt64(central.count)); archive.appendLE(UInt64(centralStart))
      archive.appendLE(UInt32(0x07064b50)); archive.appendLE(UInt32(0)); archive.appendLE(UInt64(zip64Start)); archive.appendLE(UInt32(1))
    }
    archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt32(0))
    archive.appendLE(zip64 ? UInt16.max : UInt16(count)); archive.appendLE(zip64 ? UInt16.max : UInt16(count))
    archive.appendLE(zip64 ? UInt32.max : UInt32(central.count)); archive.appendLE(zip64 ? UInt32.max : UInt32(centralStart)); archive.appendLE(UInt16(0))
    try archive.write(to: url)
  }
}

private extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var word = value.littleEndian
    Swift.withUnsafeBytes(of: &word) { append(contentsOf: $0) }
  }
}
