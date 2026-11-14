import Foundation

private final class MandelbulbProgressCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []

  func record(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    messages.append(message)
  }

  func contains(_ message: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return messages.contains(message)
  }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw BORGVRError.other(message) }
}

enum MandelbulbEasterEggTests {
  static func run() throws {
    var trigger = MandelbulbEasterEggTrigger()
    try require(!trigger.tap(at: 0) && !trigger.tap(at: 0.5) && !trigger.tap(at: 1), "Triggered before four taps")
    try require(trigger.tap(at: 2), "Did not accept four taps in two seconds")
    try require(!trigger.tap(at: 2.1), "Did not reset after triggering")
    trigger = MandelbulbEasterEggTrigger()
    for time in [0.0, 0.5, 1.0, 2.01] {
      try require(!trigger.tap(at: time), "Accepted taps outside the two-second window")
    }
    try require(trigger.tap(at: 2.1), "Did not use a rolling two-second window")
    trigger = MandelbulbEasterEggTrigger()
    for time in [10.0, 11, 12, 13, 14] {
      try require(!trigger.tap(at: time), "Slow taps triggered the Easter egg")
    }
    try require(MandelbulbEasterEggSize.allCases.map(\.rawValue) == [512, 1024, 2048, 4096], "Wrong size presets")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mandelbulb-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let token = BorgVRVolumeConversionCancellationToken()
    token.cancel()
    do {
      _ = try MandelbulbEasterEggGenerator.generate(resolution: 16, directory: root,
        cancellationToken: token)
      throw BORGVRError.other("Ignored pre-generation cancellation")
    } catch is CancellationError {}
    let cancelledOutput = try FileManager.default.contentsOfDirectory(atPath: root.path)
    try require(cancelledOutput.isEmpty, "Cancelled run left output")
    for size in MandelbulbEasterEggSize.allCases {
      let n = Int64(size.rawValue)
      try require(size.storage.rawBytes == n * n * n, "Incorrect RAW disk requirement")
      var side = n / 2
      var hierarchy: Int64 = 0
      while side >= 16 {
        hierarchy += side * side * side
        side /= 2
      }
      try require(size.storage.hierarchyBytes == hierarchy, "Incorrect LoD disk requirement")
      try require(size.storage.requiredBytes > size.storage.totalBytes, "Missing storage reserve")
    }
    try MandelbulbEasterEggSize.small.storage.checkSpace(in: root)
    try MandelbulbStorageRequirement.validateCapacity(available: 1000, required: 1000, at: root)
    do {
      try MandelbulbStorageRequirement.validateCapacity(available: 999, required: 1000, at: root)
      throw BORGVRError.other("Accepted insufficient disk space")
    } catch MandelbulbStorageRequirement.SpaceError.insufficient {}

    let first = try MandelbulbEasterEggGenerator.generate(resolution: 16, directory: root,
      cancellationToken: BorgVRVolumeConversionCancellationToken())
    let meta = try BORGVRMetaData(url: first)
    try require(meta.width == 16 && meta.height == 16 && meta.depth == 16, "Wrong generated dimensions")
    try require(meta.componentCount == 1 && meta.bytesPerComponent == 1, "Not a scalar 8-bit volume")
    try require(meta.datasetDescription == "Mandelbulb Easter Egg", "Wrong dataset description")
    try require(meta.brickSize == 32 && meta.overlap == 2 && meta.compression, "Unexpected conversion settings")
    try require(meta.voxelSpacingX == 1 / Float(16), "Incorrect physical size")
    try require(meta.provenance.contains { $0.text.contains("Mandelbulb; exponent=8") }, "Missing provenance")
    let raw = root.appendingPathComponent("verify.raw")
    _ = try BORGVRVolumeExporter.exportRaw(inputURL: first, outputURL: raw)
    let values = try Data(contentsOf: raw)
    try require(values.count == 16 * 16 * 16, "Wrong RAW output size")
    try require(meta.minValue == Int(values.min()!) && meta.maxValue == Int(values.max()!),
      "Global ranges differ from the generated fractal")
    try require(values[0] < values[(8 * 16 + 8) * 16 + 8], "Fractal is empty or inverted")

    let progress = MandelbulbProgressCapture()
    let second = try MandelbulbEasterEggGenerator.generate(resolution: 64, directory: root,
      cancellationToken: BorgVRVolumeConversionCancellationToken()) { phase, message, _ in
        if phase == .converting { progress.record(message) }
      }
    for step in ["Bricking", "Subsampling", "Writing metadata"] {
      try require(progress.contains(step), "Missing conversion progress: \(step)")
    }
    try require(!progress.contains("Determining value ranges"), "Fractal conversion still scans global ranges separately")
    try require(first != second && FileManager.default.fileExists(atPath: first.path), "Overwrote an existing Mandelbulb")
    let secondMeta = try BORGVRMetaData(url: second)
    try require(meta.uniqueID != secondMeta.uniqueID, "Generated datasets share a UUID")

    let during = BorgVRVolumeConversionCancellationToken()
    do {
      _ = try MandelbulbEasterEggGenerator.generate(resolution: 32, directory: root,
        cancellationToken: during) { phase, _, value in
          if phase == .generating && value > 0 { during.cancel() }
        }
      throw BORGVRError.other("Ignored mid-generation cancellation")
    } catch is CancellationError {}
    let output = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    try require(output.filter { $0.pathExtension == "data" }.count == 2, "Cancelled run installed a dataset")
    print("Mandelbulb Easter egg tests passed: tap timing, presets, generation, metadata, provenance, unique output, cancellation")
  }
}
