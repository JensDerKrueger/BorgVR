import Foundation

@main
struct VolumeLibraryMetadataTests {
  struct Catalog: Decodable { let datasets: [Row] }
  struct Row: Decodable {
    let file: String
    let name: String
    let action: String
    let dimensions: [Int]
    let bits: Int
    let size_mode: String
    let size_x: Double
  }

  static func main() throws {
    let args = CommandLine.arguments
    let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    var count = 0
    for row in catalog.datasets where row.action != "variant" {
      let path = URL(fileURLWithPath: args[1]).appendingPathComponent(row.name + ".data")
      let handle = try FileHandle(forReadingFrom: path)
      let offset = try handle.read(upToCount: 8)!.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
      try handle.seek(toOffset: offset)
      let metadata = try BORGVRMetaData(fromData: handle.readToEnd()!)
      try handle.close()
      if row.action == "keep-existing" {
        precondition(metadata.bytesPerComponent == 2, "Lost original precision: \(row.name)")
        continue
      }
      precondition([metadata.width, metadata.height, metadata.depth] == row.dimensions, "Incorrect dimensions: \(row.name)")
      precondition(metadata.componentType == .unsignedInteger, "Unexpected sample type: \(row.name)")
      precondition(metadata.bytesPerComponent == (row.bits == 16 ? 2 : 1), "Incorrect sample width: \(row.name)")
      precondition(metadata.componentCount == (row.bits == 24 ? 3 : 1), "Incorrect channels: \(row.name)")
      let extent = Double(metadata.width) * Double(metadata.voxelSpacingX)
      precondition(abs(extent - row.size_x) <= max(1e-10, row.size_x * 1e-6), "Incorrect physical size: \(row.name)")
      let texts = metadata.provenance.map(\.text)
      precondition(texts.contains { $0.contains("Downloaded on \(args[3]) as PVM from http://volume.open-terrain.org/\(row.file)") }, "Missing download: \(row.name)")
      precondition(texts.contains { $0.contains("Commercial use is prohibited") }, "Missing terms: \(row.name)")
      precondition(texts.contains { $0.contains("converted by") }, "Missing conversion event: \(row.name)")
      if row.size_mode != "force" {
        precondition(texts.contains { $0.hasPrefix(row.size_mode == "display" ? "Display X extent:" : "Estimated X extent:") }, "Missing size qualification: \(row.name)")
      }
      count += 1
      print("Verified \(row.name): \(metadata.width) x \(metadata.height) x \(metadata.depth)")
    }
    print("Verified \(count) Volume Library imports and retained higher-precision originals.")
  }
}
