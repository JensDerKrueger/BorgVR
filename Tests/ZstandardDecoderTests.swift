import Foundation

@main
struct ZstandardDecoderTests {
  static func main() throws {
    let golden = Data(base64Encoded: "KLUv/QRYLQEA2FphcnIgLiBWb2x1bWUgdi4gMDEyMzQ1Njc4OQMQA92SOARZC90paR4=")!
    let text = Data("Zarr Zarr Zarr Zarr. Volume volume volume. 01234567890123456789".utf8)
    let goldenDecoded = try ZstandardDecoder.decode(golden, expectedSize: text.count)
    precondition(goldenDecoded == text)
    guard let executable = ProcessInfo.processInfo.environment["ZSTD_EXECUTABLE"], !executable.isEmpty else {
      print("Zstandard golden frame passed; optional CLI reference comparisons skipped (zstd not installed).")
      return
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-zstd-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var seed: UInt64 = 12345
    func random() -> UInt8 {
      seed = seed &* 6364136223846793005 &+ 1
      return UInt8(truncatingIfNeeded: seed >> 32)
    }
    let ramp = Data((0..<250000).map { UInt8(truncatingIfNeeded: $0 / 19 + $0 % 13) })
    let noise = Data((0..<200000).map { _ in random() })
    let patterned = Data((0..<400000).map { i in i % 59 == 0 ? random() : UInt8(i % 4) })
    var inputs: [Data] = [Data(), Data([42]), Data(repeating: 17, count: 400000), ramp, noise, patterned]
    for alphabet in [3, 7, 23, 97, 251] {
      let skewed = Data((0..<180000).map { i -> UInt8 in
        let value = random()
        return i % 11 == 0 ? value : UInt8(Int(value) % alphabet)
      })
      inputs.append(skewed)
    }
    var checks = 0
    for (index, original) in inputs.enumerated() {
      let source = directory.appendingPathComponent("source")
      try original.write(to: source)
      for level in [1, 3, 9, 19] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-q", "-\(level)", "-c", source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let compressed = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        do {
          let decoded = try ZstandardDecoder.decode(compressed, expectedSize: original.count)
          precondition(decoded == original, "input \(index), level \(level)")
        } catch {
          print("FAILED input \(index), level \(level): \(error)")
          throw error
        }
        checks += 1
        for length in Set([0, 1, 4, compressed.count / 2, max(0, compressed.count - 1)]) {
          do {
            _ = try ZstandardDecoder.decode(compressed.prefix(length), expectedSize: original.count)
            preconditionFailure("accepted truncation")
          } catch { checks += 1 }
        }
        if !original.isEmpty {
          do {
            _ = try ZstandardDecoder.decode(compressed, expectedSize: original.count - 1)
            preconditionFailure("accepted output overflow")
          } catch { checks += 1 }
        }
        for _ in 0..<20 {
          var mutation = compressed
          let index = Int(random()) % mutation.count
          mutation[index] ^= random() | 1
          _ = try? ZstandardDecoder.decode(mutation, expectedSize: original.count)
          checks += 1
        }
      }
    }
    print("Zstandard reference comparisons and bounds checks passed: \(checks)")
  }
}
