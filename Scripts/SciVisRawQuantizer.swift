import Accelerate
import Foundation

// Streaming conversion for the very large Open SciVis floating-point RAW files.
@main
struct SciVisRawQuantizer {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count == 4, ["float32", "float64"].contains(args[1]) else {
      throw NSError(domain: "SciVisRawQuantizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: quantizer float32|float64 input.raw output.raw"])
    }
    let width = args[1] == "float32" ? 4 : 8
    let source = URL(fileURLWithPath: args[2])
    let destination = URL(fileURLWithPath: args[3])
    guard source.standardizedFileURL != destination.standardizedFileURL,
          !FileManager.default.fileExists(atPath: destination.path) else {
      throw NSError(domain: "SciVisRawQuantizer", code: 2)
    }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    var minimum = Double.infinity
    var maximum = -Double.infinity
    var finiteCount: UInt64 = 0
    var nonfiniteCount: UInt64 = 0
    func values(_ body: (Data) throws -> Void) throws {
      while let data = try input.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
        guard data.count % width == 0 else {
          throw NSError(domain: "SciVisRawQuantizer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Truncated floating-point sample"])
        }
        try body(data)
      }
    }
    func sample(_ bytes: UnsafeRawBufferPointer, _ index: Int) -> Double {
      if width == 4 {
        return Double(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))))
      }
      return Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)))
    }
    try values { data in
      data.withUnsafeBytes { bytes in
        for index in 0..<(data.count / width) {
          let value = sample(bytes, index)
          if value.isFinite {
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            finiteCount += 1
          } else {
            nonfiniteCount += 1
          }
        }
      }
    }
    guard finiteCount > 0 else {
      throw NSError(domain: "SciVisRawQuantizer", code: 4, userInfo: [NSLocalizedDescriptionKey: "No finite samples"])
    }
    FileHandle.standardError.write(Data("Original finite range: \(minimum) ... \(maximum); nonfinite values: \(nonfiniteCount)\n".utf8))
    try input.seek(toOffset: 0)
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw NSError(domain: "SciVisRawQuantizer", code: 5)
    }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    let normalizer = max(abs(minimum), abs(maximum))
    let range = normalizer > 0 ? maximum / normalizer - minimum / normalizer : 0
    var multiplier = range > 0 ? 65535 / range : 0
    var offset = range > 0 ? -(minimum / normalizer) * multiplier + 0.5 : 0
    var lower = 0.0
    var upper = 65535.0
    try values { data in
      let count = data.count / width
      var samples = [Double](repeating: 0, count: count)
      data.withUnsafeBytes { bytes in
        for index in 0..<count {
          let value = sample(bytes, index)
          samples[index] = value.isFinite && normalizer > 0 ? value / normalizer : (normalizer > 0 ? minimum / normalizer : 0)
        }
      }
      var integers = [UInt16](repeating: 0, count: count)
      samples.withUnsafeMutableBufferPointer { floats in
        vDSP_vsmsaD(floats.baseAddress!, 1, &multiplier, &offset, floats.baseAddress!, 1, vDSP_Length(count))
        vDSP_vclipD(floats.baseAddress!, 1, &lower, &upper, floats.baseAddress!, 1, vDSP_Length(count))
        integers.withUnsafeMutableBufferPointer { words in
          vDSP_vfixu16D(floats.baseAddress!, 1, words.baseAddress!, 1, vDSP_Length(count))
        }
      }
      try integers.withUnsafeBytes { try output.write(contentsOf: Data($0)) }
    }
    try output.synchronize()
    let result: [String: Any] = ["minimum": minimum, "maximum": maximum, "finiteCount": finiteCount, "nonfiniteCount": nonfiniteCount]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
  }
}
