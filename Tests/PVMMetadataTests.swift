import Foundation

@main
struct PVMMetadataTests {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fixture.pvm")
    func write(_ text: String, terminate: Bool = true) throws {
      var data = Data("PVM3\n1 1 1\n1 1 1\n1\n".utf8)
      data.append(42)
      data.append(contentsOf: text.utf8)
      if terminate { data.append(contentsOf: [0, 0, 0, 0]) }
      try data.write(to: file)
    }
    let longCredit = String(repeating: "Official attribution and acquisition details. ", count: 30)
    try write(longCredit)
    let parser = try PVMParser(filename: file.path)
    precondition(parser.datasetDescription == longCredit, "Long PVM3 attribution was truncated")
    try write(String(repeating: "x", count: (1 << 20) + 1))
    do {
      _ = try PVMParser(filename: file.path)
      preconditionFailure("Oversized metadata accepted")
    } catch PVMParser.Error.invalidHeader { }
    try write("Missing terminator", terminate: false)
    do {
      _ = try PVMParser(filename: file.path)
      preconditionFailure("Unterminated metadata accepted")
    } catch PVMParser.Error.invalidHeader { }
    print("PVM3 metadata tests passed (long attributions, bounded size, terminators).")
  }
}
