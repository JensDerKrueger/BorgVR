import Foundation
import simd

private enum AutoImportTestError: Error { case failed(String) }

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw AutoImportTestError.failed(message) }
}

private let autoImportTestSettings = BorgVRVolumeConversionSettings(
  brickSize: 8, overlap: 1, useCompression: true, extensionStrategy: .fillZeroes)

private func nrrdFixture(_ url: URL) throws {
  try (Data("NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 2 2\nspacings: 1 1 1\nencoding: raw\n\n".utf8)
    + Data(0..<8)).write(to: url)
}

private func zarrFixture(_ url: URL) throws {
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  let metadata: [String: Any] = [
    "zarr_format": 3, "node_type": "array", "shape": [2, 2, 2],
    "dimension_names": ["z", "y", "x"], "data_type": "uint8", "fill_value": 1,
    "chunk_grid": ["name": "regular", "configuration": ["chunk_shape": [2, 2, 2]]],
    "chunk_key_encoding": ["name": "default", "configuration": ["separator": "/"]],
    "codecs": [["name": "bytes"]], "attributes": [:]
  ]
  try JSONSerialization.data(withJSONObject: metadata).write(to: url.appendingPathComponent("zarr.json"))
}

private final class ChangingImportLogger: LoggerBase {
  var change: (() throws -> Void)?
  func dev(_ message: String) {}
  func info(_ message: String) {
    if message.hasPrefix("Auto-import: reading"), let change {
      self.change = nil
      try! change()
    }
  }
  func warning(_ message: String) {}
  func error(_ message: String) {}
  func progress(_ message: String, _ progress: Double) {}
  func setMinimumLogLevel(_ level: LogLevel) {}
}

func runAutoImporterTests() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("auto-import-tests-\(UUID())")
    .resolvingSymlinksInPath()
  defer { try? fm.removeItem(at: root) }
  let input = root.appendingPathComponent("input")
  let output = root.appendingPathComponent("output")
  try fm.createDirectory(at: input, withIntermediateDirectories: true)
  try Data("Previous import history\n".utf8).write(to: input.appendingPathComponent("log.txt"))
  func results() throws -> [URL] {
    try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).filter { $0.pathExtension == "data" }
  }
  let worker = try BorgVRAutoImporter(input: input, output: output, settings: autoImportTestSettings)
  let source = input.appendingPathComponent("scan.bin")
  try nrrdFixture(source)
  try worker.checkForImports()
  try check(try results().isEmpty, "Imported before the second check")
  let added = input.appendingPathComponent("still-copying.txt")
  try Data([1]).write(to: added)
  try worker.checkForImports()
  try check(try results().isEmpty, "Ignored a newly arrived file")
  try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)
  try worker.checkForImports()
  try check(try results().isEmpty, "Ignored a changed timestamp")
  try worker.checkForImports()
  try check(try results().count == 1, "Content detection did not import NRRD with an unknown extension")
  try check(!fm.fileExists(atPath: source.path), "Successful source was retained")
  try check(!fm.fileExists(atPath: added.path), "Unusable source was not deleted")
  let log = input.appendingPathComponent("log.txt")
  let firstLog = try String(contentsOf: log, encoding: .utf8)
  try check(firstLog.hasPrefix("Previous import history\n"), "Audit log was overwritten")
  try check(firstLog.contains("[SUCCESS]") && firstLog.contains("[FAILED]"), "Audit log missed a result")
  try worker.checkForImports()
  try check(try String(contentsOf: log, encoding: .utf8) == firstLog, "Audit log triggered a retry")

  // Detached, converted NRRD payloads must be removed, never their decoded temporary file alone.
  let header = input.appendingPathComponent("detached.nhdr")
  let payload = input.appendingPathComponent("payload.raw")
  try Data("0 1 2 3 4 5 6 7".utf8).write(to: payload)
  try Data("NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 2 2\nspacings: 1 1 1\nencoding: ascii\ndata file: payload.raw\n\n".utf8).write(to: header)
  try worker.checkForImports(); try worker.checkForImports()
  try check(!fm.fileExists(atPath: header.path) && !fm.fileExists(atPath: payload.path), "Detached NRRD cleanup")
  let qvis = input.appendingPathComponent("qvis.dat")
  let raw = input.appendingPathComponent("qvis.raw")
  try Data(0..<8).write(to: raw)
  try Data("ObjectFileName: qvis.raw\nResolution: 2 2 2\nSliceThickness: 1 1 1\nFormat: UCHAR\n".utf8).write(to: qvis)
  try worker.checkForImports(); try worker.checkForImports()
  try check(!fm.fileExists(atPath: qvis.path) && !fm.fileExists(atPath: raw.path), "QVIS cleanup")

  // Neither collisions nor an input arriving during conversion may destroy existing data.
  let existing = output.appendingPathComponent("scan.data")
  let previousBytes = try Data(contentsOf: existing)
  try nrrdFixture(source)
  try worker.checkForImports(); try worker.checkForImports()
  try check(try Data(contentsOf: existing) == previousBytes, "Overwrote an existing dataset")
  try check(fm.fileExists(atPath: output.appendingPathComponent("scan-2.data").path), "Collision suffix missing")
  let changing = input.appendingPathComponent("changing.nrrd")
  try nrrdFixture(changing)
  let logger = ChangingImportLogger()
  logger.change = { try Data([2]).write(to: input.appendingPathComponent("new.txt")) }
  let changingWorker = try BorgVRAutoImporter(input: input, output: output,
    settings: autoImportTestSettings, logger: logger)
  try changingWorker.checkForImports(); try changingWorker.checkForImports()
  try check(fm.fileExists(atPath: changing.path), "Deleted a source changed during conversion")
  try check(!fm.fileExists(atPath: output.appendingPathComponent("changing.data").path), "Published an unstable source")

  let zarr = input.appendingPathComponent("array.zarr")
  try zarrFixture(zarr)
  let directoryWorker = try BorgVRAutoImporter(input: input, output: output,
    settings: autoImportTestSettings, onImported: { url in
      if url.lastPathComponent == "array.data" {
        try! Data([9]).write(to: zarr.appendingPathComponent("late.txt"))
      }
    })
  try directoryWorker.checkForImports(); try directoryWorker.checkForImports()
  try check(fm.fileExists(atPath: output.appendingPathComponent("array.data").path), "Zarr directory import")
  try check(fm.fileExists(atPath: zarr.appendingPathComponent("late.txt").path), "Recursive cleanup deleted a late file")
  try check(!fm.fileExists(atPath: zarr.appendingPathComponent("zarr.json").path), "Imported directory files were retained")

  let outside = root.appendingPathComponent("outside.raw")
  try Data(0..<8).write(to: outside)
  let unsafeHeader = input.appendingPathComponent("outside.dat")
  try Data("ObjectFileName: ../outside.raw\nResolution: 2 2 2\nSliceThickness: 1 1 1\nFormat: UCHAR\n".utf8).write(to: unsafeHeader)
  let link = input.appendingPathComponent("link.nrrd")
  try fm.createSymbolicLink(at: link, withDestinationURL: outside)
  try worker.checkForImports(); try worker.checkForImports()
  try check(fm.fileExists(atPath: outside.path) && !fm.fileExists(atPath: unsafeHeader.path), "Unsafe header cleanup touched an external source")
  try check(!fm.fileExists(atPath: output.appendingPathComponent("outside.data").path), "Imported an external payload")
  do {
    _ = try BorgVRAutoImporter(input: input, output: input.appendingPathComponent("bad"), settings: autoImportTestSettings)
    throw AutoImportTestError.failed("Allowed output inside input")
  } catch BorgVRAutoImporter.ImportError.overlappingDirectories {}
  worker.stop()
  do {
    try worker.checkForImports()
    throw AutoImportTestError.failed("Ignored cancellation")
  } catch is CancellationError {}
  try runGuidedAutoImporterTests()
  print("Auto-import stability, formats, cleanup, collisions, cancellation, and audit tests passed")
}

private func runGuidedAutoImporterTests() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("guided-import-tests-\(UUID())")
  defer { try? fm.removeItem(at: root) }
  let input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output")
  try fm.createDirectory(at: input, withIntermediateDirectories: true)
  let manifest = input.appendingPathComponent("import.json")
  func write(_ entries: [[String: Any]]) throws {
    try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]).write(to: manifest)
  }
  let worker = try BorgVRAutoImporter(input: input, output: output, mode: .guided, settings: autoImportTestSettings)
  let source = input.appendingPathComponent("scan.nrrd")
  try nrrdFixture(source)
  try worker.checkForImports(); try worker.checkForImports()
  try check(fm.fileExists(atPath: source.path), "Guided mode imported without import.json")
  try write([["source": "scan.nrrd", "destination": "custom.data", "description": "Guided scan",
              "sizeMeters": [0.2, 0.3, 0.4], "sourceDate": "2026-11-01T10:30:45.123Z",
              "sourceNote": "Downloaded from https://example.org/scan"]])
  try worker.checkForImports()
  try check(!fm.fileExists(atPath: output.appendingPathComponent("custom.data").path), "Manifest imported after one check")
  try Data([1]).write(to: input.appendingPathComponent("unrelated.txt"))
  try worker.checkForImports()
  let result = output.appendingPathComponent("custom.data")
  try check(fm.fileExists(atPath: result.path), "Unrelated arrival prevented guided import")
  let metadata = try BORGVRFileData(filename: result.path).getMetadata()
  try check(metadata.provenance.first?.text == "Downloaded from https://example.org/scan" &&
    metadata.provenance.first?.timestampMilliseconds == 1_793_529_045_123 &&
    metadata.provenance.last?.text.hasPrefix("converted by ") == true,
    "Guided import lost source date/time or conversion provenance")
  try check(simd_length(metadata.physicalExtentMeters - SIMD3<Float>(0.2, 0.3, 0.4)) < 0.000_001,
    "Guided size was not saved as total physical dimensions")
  try check(!fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: manifest.path), "Successful guided request was not removed")
  try check(fm.fileExists(atPath: input.appendingPathComponent("unrelated.txt").path), "Guided mode deleted an unlisted source")

  let invalid = input.appendingPathComponent("invalid.bin")
  try Data([1, 2, 3]).write(to: invalid)
  try write([["source": "invalid.bin"]])
  try worker.checkForImports(); try worker.checkForImports()
  try check(!fm.fileExists(atPath: invalid.path) && !fm.fileExists(atPath: manifest.path), "Failed guided import was not cleaned up")
  try Data("not valid JSON".utf8).write(to: manifest)
  try worker.checkForImports(); try worker.checkForImports()
  try check(!fm.fileExists(atPath: manifest.path), "Malformed import.json was retained")

  let outside = root.appendingPathComponent("outside.nrrd")
  try nrrdFixture(outside)
  let original = try Data(contentsOf: outside)
  let link = input.appendingPathComponent("link.nrrd")
  try fm.createSymbolicLink(at: link, withDestinationURL: outside)
  let unsafe: [[String: Any]] = [
    ["source": "../outside.nrrd"], ["source": outside.path], ["source": "."], ["source": ".."],
    ["source": "subdir/file.nrrd"], ["source": "subdir\\file.nrrd"], ["source": "missing.nrrd"],
    ["source": "log.txt"], ["source": "import.json"], ["source": "link.nrrd"],
    ["source": "scan.nrrd", "destination": "../escape.data"],
    ["source": "scan.nrrd", "destination": "/tmp/escape.data"],
    ["source": "scan.nrrd", "destination": "bad.nrrd"],
    ["source": "scan.nrrd", "sizeMeters": [1, 2]],
    ["source": "scan.nrrd", "sizeMeters": [1, -1, 1]],
    ["source": "scan.nrrd", "sizeMeters": [1, 0, 1]]
  ]
  for entry in unsafe {
    try nrrdFixture(source)
    try write(entry["source"] as? String == "scan.nrrd" ? [entry] : [["source": "scan.nrrd"], entry])
    try worker.checkForImports(); try worker.checkForImports()
    try check(!fm.fileExists(atPath: manifest.path), "Rejected manifest was not deleted")
    try check(fm.fileExists(atPath: source.path), "Rejected batch processed an earlier valid entry")
    try check(try Data(contentsOf: outside) == original, "Manifest accessed or modified an external source")
  }
  try fm.removeItem(at: link)
  // A manifest symlink is unlinked, not followed or removed at its target.
  try fm.createSymbolicLink(at: manifest, withDestinationURL: outside)
  try worker.checkForImports(); try worker.checkForImports()
  try check(try Data(contentsOf: outside) == original, "Followed an import.json symlink")
  try check((try? fm.attributesOfItem(atPath: manifest.path)) == nil, "Manifest symlink was retained")

  // A detached header must not read or delete payloads outside the inbox.
  let header = input.appendingPathComponent("external.nhdr")
  try Data("NRRD0005\ntype: uint8\ndimension: 3\nsizes: 2 2 2\nspacings: 1 1 1\nencoding: ascii\ndata file: ../outside.nrrd\n\n".utf8).write(to: header)
  try write([["source": "external.nhdr"]])
  try worker.checkForImports(); try worker.checkForImports()
  try check(!fm.fileExists(atPath: header.path) && !fm.fileExists(atPath: manifest.path), "Unsafe sidecar request was not removed")
  try check(try Data(contentsOf: outside) == original, "Touched an external sidecar")

  // Existing outputs, including symlinks, are never overwritten.
  let existingLink = output.appendingPathComponent("protected.data")
  try fm.createSymbolicLink(at: existingLink, withDestinationURL: outside)
  try write([["source": "scan.nrrd", "destination": "protected.data"]])
  try worker.checkForImports(); try worker.checkForImports()
  try check(fm.fileExists(atPath: output.appendingPathComponent("protected-2.data").path), "Output collision did not use a suffix")
  try check(try Data(contentsOf: outside) == original, "Overwrote an output symlink target")

  // Replacing the control file during conversion preserves the newer request.
  try nrrdFixture(source)
  try nrrdFixture(input.appendingPathComponent("next.nrrd"))
  try write([["source": "scan.nrrd"]])
  let logger = ChangingImportLogger()
  logger.change = { try write([["source": "next.nrrd"]]) }
  let replacing = try BorgVRAutoImporter(input: input, output: output, mode: .guided,
    settings: autoImportTestSettings, logger: logger)
  try replacing.checkForImports(); try replacing.checkForImports()
  try check(fm.fileExists(atPath: manifest.path) && fm.fileExists(atPath: source.path), "Deleted a replacement manifest or pending source")
  try replacing.checkForImports(); try replacing.checkForImports()
  try check(!fm.fileExists(atPath: manifest.path) && !fm.fileExists(atPath: input.appendingPathComponent("next.nrrd").path),
    "Replacement request did not complete")
  let audit = try String(contentsOf: input.appendingPathComponent("log.txt"), encoding: .utf8)
  try check(audit.contains("[REJECTED]") && audit.contains("[FAILED]") && audit.contains("[FINISHED]"), "Guided results missing from audit log")
  print("Guided import stability, cleanup, metadata, path validation, and manifest replacement tests passed")
}
