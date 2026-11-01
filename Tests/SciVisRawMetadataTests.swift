import Foundation

@main
struct SciVisRawMetadataTests {
  struct Row: Decodable { let size: [Int] }
  static func main() throws {
    let args = CommandLine.arguments
    let catalog = try JSONDecoder().decode([String: Row].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let name = args[3]
    let row = catalog[name]!
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[2]))
    defer { try? handle.close() }
    let offset = try handle.read(upToCount: 8)!.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    try handle.seek(toOffset: offset)
    let metadata = try BORGVRMetaData(fromData: handle.readToEnd()!)
    precondition([metadata.width, metadata.height, metadata.depth] == row.size, "Incorrect dimensions")
    precondition(metadata.componentCount == 1 && metadata.bytesPerComponent == 2 && metadata.componentType == .unsignedInteger, "Not renderer-compatible UInt16")
    let expected = name == "3d_neurons_15_sept_2016" ? 2048 * 0.267345e-6 : 1.0
    precondition(abs(Double(metadata.width) * Double(metadata.voxelSpacingX) - expected) < expected * 1e-6, "Incorrect X extent")
    let sources = metadata.provenance.map(\.text)
    precondition(sources.contains { $0.contains("Downloaded on \(args[4]) as little-endian RAW") && $0.contains("/\(name)/") }, "Missing provenance")
    precondition(sources.contains { $0.contains("converted by") }, "Missing conversion event")
    precondition(sources.contains { $0.hasPrefix("Original source and acknowledgements:") }, "Missing original attribution")
    if name != "3d_neurons_15_sept_2016" {
      precondition(sources.contains { $0.contains("quantized linearly to UInt16 using finite source range") }, "Missing original scalar range")
    }
    print("Verified RAW import \(name): unsigned 16-bit, expected geometry and provenance.")
  }
}
