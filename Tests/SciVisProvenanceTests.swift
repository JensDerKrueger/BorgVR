import Foundation

@main
struct SciVisProvenanceTests {
  static func main() throws {
    let args = CommandLine.arguments
    guard (5...7).contains(args.count) else {
      fatalError("Usage: audit DATA_DIRECTORY DATASET_TSV PROVENANCE_TSV DOWNLOAD_DAY [--allow-partial]")
    }
    let root = URL(fileURLWithPath: args[1])
    let downloadTimestamp = BORGVRProvenanceEntry.parseDate(args[4] + "T00:00:00Z")!
    let sources = try rows(args[3])
    let sizes = try rows(URL(fileURLWithPath: args[2]).deletingLastPathComponent().appendingPathComponent("scivis-sizes.tsv").path)
    var checked = 0, missing = 0
    for row in try rows(args[2]) {
      let name = row[0], type = row[1]
      let url = root.appendingPathComponent(name + ".data")
      guard FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
      let metadata = try BORGVRMetaData(url: url)
      for entry in metadata.provenance {
        precondition(!entry.text.contains("attributed separately above") &&
                     !entry.text.contains("day precision") &&
                     !entry.text.contains("midnight UTC placeholder") &&
                     !entry.text.hasPrefix("Attribution recorded for this import"), "Redundant provenance commentary: \(name)")
      }
      precondition(metadata.componentType == .unsignedInteger, "Renderer-incompatible sample type: \(name)")
      let width = type.hasPrefix("float") || type == "int16" || type == "uint16" ? 2 : type == "uint32" ? 4 : 1
      precondition(metadata.bytesPerComponent == width, "Unexpected sample width: \(name)")
      for source in sources where source[0] == name {
        let timestamp = source[1] == "recorded" ? downloadTimestamp : BORGVRProvenanceEntry.parseDate(source[1])!
        precondition(metadata.provenance.contains { $0.date == timestamp && $0.text.hasSuffix(source[2]) },
                     "Missing original source: \(name): \(source[2])")
      }
      let downloads = metadata.provenance.filter { $0.text.hasPrefix("Downloaded on ") }
      precondition(downloads.count == 1 && downloads[0].date == downloadTimestamp &&
                   downloads[0].text.contains(row[3]) && downloads[0].text.contains(args[4]), "Download provenance: \(name)")
      let suppliedSources = metadata.provenance.filter { $0.date <= downloadTimestamp }
      precondition(suppliedSources.last?.text == downloads[0].text, "Download must follow source attributions: \(name)")
      precondition(metadata.provenance.contains { $0.date > downloadTimestamp && $0.text.contains("converted by") }, "Missing automatic conversion event: \(name)")
      if args.contains("--check-sizes") {
        let size = sizes.first { $0[0] == name }!
        let expected = Double(size[2])!
        let actual = Double(metadata.width) * Double(metadata.voxelSpacingX)
        precondition(abs(actual - expected) <= max(1e-10, expected * 1e-6), "Incorrect X extent: \(name)")
        let prefix = size[1] == "display" ? "Display X extent:" : "Estimated X extent:"
        if size[1] != "force" && size[1] != "hint" {
          precondition(metadata.provenance.contains { $0.text == "\(prefix) \(size[2]) m. \(size[3])" ||
            $0.text == "\(prefix) \(size[2]) m; not a physical calibration. \(size[3])" }, "Missing size qualification: \(name)")
        } else {
          precondition(!metadata.provenance.contains { $0.text.hasPrefix("Estimated X extent:") || $0.text.hasPrefix("Display X extent:") || $0.text.hasPrefix("Physical X extent:") }, "Unexpected verified-size annotation: \(name)")
        }
      }
      checked += 1
      print("Verified \(name): unsigned \(width * 8)-bit, \(metadata.provenance.count) provenance entries")
    }
    precondition(checked > 0, "No converted datasets found")
    precondition(missing == 0 || args.contains("--allow-partial"), "Missing \(missing) datasets")
    print("SciVis provenance verified: \(checked) datasets; \(missing) not yet present.")
  }

  private static func rows(_ path: String) throws -> [[String]] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
      .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
  }
}
