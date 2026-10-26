import Foundation

private struct TestFailure: Error { let message: String }

@main
private enum FileExportRecoveryTests {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "borgvr-export-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("BorgVR Markers.marker")
    let destination = directory.appendingPathComponent("melanix_32.marker")
    let original = Data("untouched source".utf8)
    let replacement = Data("replacement".utf8)
    try original.write(to: source)
    try Data("old destination".utf8).write(to: destination)
    let duplicate = NSError(domain: NSOSStatusErrorDomain, code: -48)
    let wrapped = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
      userInfo: [
        NSMultipleUnderlyingErrorsKey: [duplicate], "NSDestinationURL": destination,
        NSFilePathErrorKey: source.path,
      ])
    try CoordinatedFileExportRecovery.finish(.failure(wrapped)) { replacement }
    guard try Data(contentsOf: source) == original, try Data(contentsOf: destination) == replacement
    else {
      throw TestFailure(message: "Replacement modified or removed the wrong file")
    }
    try CoordinatedFileExportRecovery.finish(.success(destination)) {
      throw TestFailure(message: "Successful export encoded/wrote a second time")
    }
    for error in [
      NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
        userInfo: ["NSDestinationURL": destination]),
      NSError(
        domain: NSOSStatusErrorDomain, code: -48, userInfo: [NSFilePathErrorKey: source.path]),
    ] {
      do {
        try CoordinatedFileExportRecovery.finish(.failure(error)) { replacement }
        throw TestFailure(message: "Unrelated error was treated as a confirmed replacement")
      } catch is TestFailure {
        throw TestFailure(message: "Unrelated error was treated as a confirmed replacement")
      } catch {}
    }
    guard try Data(contentsOf: source) == original else {
      throw TestFailure(message: "Source file was removed")
    }
    print("Coordinated object/measurement export recovery tests passed")
  }
}
