import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): message
    }
  }
}

private func expect(
  _ condition: @autoclosure () -> Bool,
  _ message: String
) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func expectThrows(
  _ message: String,
  _ operation: () throws -> Void
) throws {
  do {
    try operation()
    throw TestFailure.failed(message)
  } catch is TestFailure {
    throw TestFailure.failed(message)
  } catch {}
}

private func testSettingsAndCancellation() throws {
  try expectThrows("Zero brick size was accepted") {
    try BorgVRVolumeConversionSettings(
      brickSize: 0,
      overlap: 0,
      useCompression: false,
      extensionStrategy: .fillZeroes
    ).validate()
  }
  try expectThrows("Overlap without an interior brick region was accepted") {
    try BorgVRVolumeConversionSettings(
      brickSize: 8,
      overlap: 4,
      useCompression: false,
      extensionStrategy: .fillZeroes
    ).validate()
  }
  try BorgVRVolumeConversionSettings(
    brickSize: 8,
    overlap: 3,
    useCompression: false,
    extensionStrategy: .fillZeroes
  ).validate()

  let token = BorgVRVolumeConversionCancellationToken()
  try expect(!token.isCancelled, "New cancellation token starts cancelled")
  token.cancel()
  try expect(token.isCancelled, "Cancellation token did not retain cancellation")
  try expectThrows("Cancelled token did not throw") {
    try token.checkCancellation()
  }
}

private func testRawConversionAndAtomicReplacement() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-conversion-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let rawURL = directory.appendingPathComponent("source.raw")
  let destinationURL = directory.appendingPathComponent("converted.data")
  let dimensions = Vec3<Int>(x: 6, y: 5, z: 4)
  let firstValues = (0..<(dimensions.x * dimensions.y * dimensions.z)).map {
    UInt8(truncatingIfNeeded: $0)
  }
  try Data(firstValues).write(to: rawURL)

  let settings = BorgVRVolumeConversionSettings(
    brickSize: 4,
    overlap: 1,
    useCompression: false,
    extensionStrategy: .clamp
  )
  func request(description: String) -> BorgVRVolumeConversionRequest {
    BorgVRVolumeConversionRequest(
      source: .raw(.init(
        url: rawURL,
        offset: 0,
        size: dimensions,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: Vec3<Float>(x: 0.1, y: 0.2, z: 0.3)
      )),
      destinationURL: destinationURL,
      datasetDescription: description,
      metaDescription: "Conversion service test",
      settings: settings
    )
  }

  try BorgVRVolumeConversionService.convert(request(description: "First"))
  var metadata = try BORGVRMetaData(filename: destinationURL.path)
  try expect(metadata.width == dimensions.x, "Converted width changed")
  try expect(metadata.height == dimensions.y, "Converted height changed")
  try expect(metadata.depth == dimensions.z, "Converted depth changed")
  try expect(metadata.datasetDescription == "First", "Dataset description was not written")
  try expect(metadata.minValue == 0, "Converted minimum is incorrect")
  try expect(metadata.maxValue == Int(firstValues.max()!), "Converted maximum is incorrect")

  let replacementValues = [UInt8](repeating: 173, count: firstValues.count)
  try Data(replacementValues).write(to: rawURL, options: .atomic)
  try BorgVRVolumeConversionService.convert(request(description: "Replacement"))
  metadata = try BORGVRMetaData(filename: destinationURL.path)
  try expect(metadata.datasetDescription == "Replacement", "Existing output was not replaced")
  try expect(metadata.minValue == 173 && metadata.maxValue == 173, "Replacement data was ignored")

  let beforeCancellation = try Data(contentsOf: destinationURL)
  let token = BorgVRVolumeConversionCancellationToken()
  token.cancel()
  try expectThrows("Pre-cancelled conversion completed") {
    try BorgVRVolumeConversionService.convert(
      request(description: "Cancelled"),
      cancellationToken: token
    )
  }
  let afterCancellation = try Data(contentsOf: destinationURL)
  try expect(
    afterCancellation == beforeCancellation,
    "Cancelled conversion modified the existing destination"
  )
  let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasSuffix(".tmp") }
  try expect(temporaryFiles.isEmpty, "Conversion left staged files behind")
}

@main
private enum VolumeConversionServiceTestRunner {
  static func main() throws {
    try testSettingsAndCancellation()
    try testRawConversionAndAtomicReplacement()
    print("Volume conversion service tests passed")
  }
}
