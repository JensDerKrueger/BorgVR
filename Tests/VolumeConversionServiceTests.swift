import Foundation
import simd
import ImageIO
import CoreGraphics
import Metal

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

private final class CapturingLogger: LoggerBase {
  private(set) var infoMessages: [String] = []

  func dev(_ message: String) {}
  func info(_ message: String) { infoMessages.append(message) }
  func warning(_ message: String) {}
  func error(_ message: String) {}
  func progress(_ message: String, _ progress: Double) {}
  func setMinimumLogLevel(_ level: LogLevel) {}
}

private final class OneShotDelayedDataset: BORGVRDatasetProtocol {
  private let source: BORGVRDatasetProtocol
  private let lock = NSLock()
  private var hasDelayedBrick = false

  init(source: BORGVRDatasetProtocol) {
    self.source = source
  }

  func newRequest() {
    source.newRequest()
  }

  func getMetadata() -> BORGVRMetaData {
    source.getMetadata()
  }

  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let shouldDelay = lock.withLock {
      guard !hasDelayedBrick else { return false }
      hasDelayedBrick = true
      return true
    }
    if shouldDelay {
      throw BORGVRDataError.brickNotYetAvailable(index: index)
    }
    try source.getBrick(index: index, outputBuffer: outputBuffer)
  }

  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try source.getFirstBrick(outputBuffer: outputBuffer)
  }

  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> {
    source.allocateBrickBuffer()
  }
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

private final class QuantizationCancellationLogger: LoggerBase {
  let token: BorgVRVolumeConversionCancellationToken
  init(_ token: BorgVRVolumeConversionCancellationToken) { self.token = token }
  func dev(_ message: String) {}
  func info(_ message: String) {}
  func warning(_ message: String) {}
  func error(_ message: String) {}
  func progress(_ message: String, _ progress: Double) {
    if message == "Quantizing volume" { token.cancel() }
  }
  func setMinimumLogLevel(_ level: LogLevel) {}
}

private func testVolumeQuantization() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-quantization-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let inputURL = directory.appendingPathComponent("input.raw")
  let outputURL = directory.appendingPathComponent("quantized.raw")
  let spacing = Vec3<Float>(x: 0.001, y: 0.002, z: 0.003)

  func source<Value: FixedWidthInteger>(
    _ values: [Value], channels: Int
  ) throws -> RawFileAccessor {
    var data = Data([0xAA]) // Deliberately unaligned payload.
    values.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: inputURL)
    return try RawFileAccessor(filename: inputURL.path,
      size: Vec3(x: values.count / channels, y: 1, z: 1),
      bytesPerComponent: MemoryLayout<Value>.stride, componentCount: channels,
      voxelSpacing: spacing, offset: 1)
  }
  func check<Value: FixedWidthInteger>(
    _ values: [Value], channels: Int, expected: [UInt8], signed: [Bool] = []
  ) throws {
    let original = try source(values, channels: channels)
    let before = try Data(contentsOf: inputURL)
    let logger = CapturingLogger()
    var provenance: [String] = []
    let result = try BorgVRVolumeQuantizer.quantize(original, signedComponents: signed, to: outputURL,
      logger: logger, recordProvenance: { provenance.append($0) })
    let actual: [UInt8] = try result.getData(x: 0, y: 0, z: 0, count: result.totalVoxels)
    try expect(actual == expected, "Incorrect quantized samples: \(actual), expected \(expected)")
    try expect(result.bytesPerComponent == 1 && result.componentCount == channels,
      "Quantization changed the channel layout")
    try expect(result.size == original.size && result.voxelSpacing == spacing,
      "Quantization changed physical geometry")
    let after = try Data(contentsOf: inputURL)
    try expect(after == before, "Quantization modified the original")
    if MemoryLayout<Value>.stride == 1 {
      try expect(result === original, "Existing 8-bit samples were requantized")
      try expect(provenance.isEmpty, "Unchanged 8-bit samples received a quantization entry")
    } else {
      try expect(provenance.count == 1 && provenance[0].contains("channel \(channels):")
        && provenance[0].contains("nearest rounding"), "Quantization did not record original channel ranges")
      try expect(logger.infoMessages.filter { $0.contains("original value range") }.count == channels,
        "Quantization did not log the original range of every channel")
      if signed.first == true {
        try expect(logger.infoMessages.contains { $0.contains("-32768...32767") },
          "Signed range was logged as unsigned values")
      }
    }
  }

  try check([UInt16](arrayLiteral: 100, 1000, 150, 3000, 200, 5000), channels: 2,
    expected: [0, 0, 128, 128, 255, 255])
  try check([UInt32](arrayLiteral: 0, 2_147_483_648, .max), channels: 1,
    expected: [0, 128, 255])
  try check([UInt16](arrayLiteral: 0, 9, 0, 9), channels: 2, expected: [0, 255, 0, 255])
  try check([UInt16](arrayLiteral: 0x8000, 10, 0, 20, 0x7FFF, 30), channels: 2,
    expected: [0, 0, 128, 128, 255, 255], signed: [true, false])
  try check([UInt8](arrayLiteral: 20, 40, 60), channels: 1, expected: [20, 40, 60])

  let original = try source([UInt16](arrayLiteral: 100, 150, 200), channels: 1)
  try FileManager.default.removeItem(at: outputURL)
  let token = BorgVRVolumeConversionCancellationToken()
  try expectThrows("Quantization ignored cancellation") {
    _ = try BorgVRVolumeQuantizer.quantize(original, to: outputURL,
      logger: QuantizationCancellationLogger(token), cancellationToken: token)
  }
  try expect(!FileManager.default.fileExists(atPath: outputURL.path),
    "Cancelled quantization left an incomplete temporary volume")

  for enabled in [false, true] {
    let destination = directory.appendingPathComponent("converted-\(enabled).data")
    try BorgVRVolumeConversionService.convert(.init(
      source: .raw(.init(url: inputURL, offset: 1, size: original.size,
        bytesPerComponent: 2, componentCount: 1, voxelSpacing: spacing)),
      destinationURL: destination, datasetDescription: "Quantized", metaDescription: "",
      settings: .init(brickSize: 4, overlap: 1, useCompression: false,
        extensionStrategy: .clamp, quantizeTo8Bit: enabled)))
    let metadata = try BORGVRMetaData(filename: destination.path)
    try expect(metadata.bytesPerComponent == (enabled ? 1 : 2), "Import ignored quantization setting")
    try expect(metadata.provenance.contains { $0.text == "Import RAW: input.raw" }, "RAW import retained a full path")
    let quantization = metadata.provenance.filter { $0.text.hasPrefix("Quantized to UInt8") }
    try expect(quantization.count == (enabled ? 1 : 0), "Quantization provenance is missing or duplicated")
    if enabled {
      try expect(quantization[0].text.contains("channel 1: 100...200"), "Quantization provenance lost original values")
    }
    try expect(metadata.minValue == (enabled ? 0 : 100) && metadata.maxValue == (enabled ? 255 : 200),
      "Imported value range is incorrect")
    try expect(metadata.voxelSpacingX == spacing.x && metadata.voxelSpacingY == spacing.y
      && metadata.voxelSpacingZ == spacing.z, "Import changed voxel spacing")
  }
}

private func testDICOMImportHistory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-dicom-history-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root); DicomParser.decodedVolumes = [:] }
  let orientation = DicomParser.DicomOrientation(xAxis: .init(x: 1, y: 0, z: 0),
    yAxis: .init(x: 0, y: 1, z: 0), zAxis: .init(x: 0, y: 0, z: 1))
  func source(_ name: String, _ date: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("slice.dcm")
    try Data().write(to: file)
    let values: [UInt16] = [0, 100, 200, 300, 400, 500, 600, 700]
    let bytes = values.withUnsafeBytes { Data($0) }
    let history = DicomProvenanceMetadata(readString: { $0 == .acquisitionDate ? date : nil }).events
    DicomParser.decodedVolumes[file.resolvingSymlinksInPath().standardizedFileURL] = .init(sourceFiles: [file], voxelData: bytes,
      width: 2, height: 2, depth: 2, bytesPerVoxel: 2, voxelSpacing: .init(x: 0.001, y: 0.001, z: 0.001),
      orientation: orientation, origin: .zero, frameOfReferenceUID: "same-frame", isSigned: false,
      pixelPaddingValue: nil, modality: "CT", patientName: nil, seriesDate: nil, provenance: history)
    return directory
  }
  let reference = try source("reference", "20260101"), moving = try source("registered", "20260102")
  let supplied = BORGVRProvenanceEntry("External archive history")
  for pair in [false, true] {
    let destination = root.appendingPathComponent(pair ? "fused.data" : "single.data")
    try BorgVRVolumeConversionService.convert(.init(
      source: pair ? .registeredDICOMPair(reference: reference, moving: moving, filter: .trilinear) : .dicomDirectory(reference),
      destinationURL: destination, datasetDescription: "History test", metaDescription: "",
      settings: .init(brickSize: 4, overlap: 1, useCompression: false, extensionStrategy: .clamp, quantizeTo8Bit: true),
      provenance: [supplied], toolIdentification: "History test tool 3.5"))
    let metadata = try BORGVRMetaData(url: destination)
    let history = metadata.provenance
    try expect(history[0] == supplied, "User-supplied provenance was dropped")
    let sources = history.filter { $0.text.contains("DICOM acquisition") }
    try expect(sources.count == (pair ? 2 : 1) && sources[0].text.contains("date only: 2026-01-01"),
      "DICOM history did not reach the output metadata")
    if pair {
      try expect(sources[0].text.hasPrefix("Reference (channel 1):")
        && sources[1].text.hasPrefix("Registered (channel 2):") && sources[1].text.contains("2026-01-02"),
        "Fusion lost source identity")
      let index = history.firstIndex { $0.text.hasPrefix("Rigid DICOM registration and fusion") }!
      let text = history[index].text
      let matrix = String(text[text.range(of: "matrix: ")!.upperBound...])
      let rows = try JSONDecoder().decode([[Float]].self, from: Data(matrix.utf8))
      try expect(rows == BorgVRVoxelTransform.identity.matrixRows && text.contains("resampling: trilinear"),
        "Fusion provenance did not store the applied voxel matrix/filter")
      try expect(index < history.firstIndex { $0.text.hasPrefix("Quantized") }!, "Fusion/quantization history order is incorrect")
    }
    try expect(history.filter { $0.text.contains("Import DICOM:") }.count == (pair ? 2 : 1), "DICOM import entries duplicated")
    try expect(!history.contains { $0.text.contains(root.path) || $0.text.contains("file://") },
      "DICOM import/fusion retained a full source path")
    try expect(history.last!.text.contains("converted by History test tool 3.5"), "Conversion entry is not last")
  }
}

private func testPhysicalSizeOverrides() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-size-override-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("source.raw")
  try Data(repeating: 1, count: 8).write(to: input)
  for physical in [false, true] { for force in [false, true] {
    let output = root.appendingPathComponent("\(physical)-\(force).data")
    try BorgVRVolumeConversionService.convert(.init(
      source: .raw(.init(url: input, offset: 0, size: .init(x: 2, y: 2, z: 2),
        bytesPerComponent: 1, componentCount: 1, voxelSpacing: .init(x: 0.01, y: 0.02, z: 0.03),
        hasPhysicalVoxelSpacing: physical)),
      destinationURL: output, datasetDescription: "Size test", metaDescription: "",
      settings: .init(brickSize: 4, overlap: 1, useCompression: false, extensionStrategy: .clamp),
      sizeXMeters: 0.2, forceSizeX: force))
    let metadata = try BORGVRMetaData(url: output)
    let applied = force || !physical
    try expect(abs(metadata.voxelSpacingX - (applied ? 0.1 : 0.01)) < 0.000_001
      && abs(metadata.voxelSpacingY - metadata.voxelSpacingX * 2) < 0.000_001
      && abs(metadata.voxelSpacingZ - metadata.voxelSpacingX * 3) < 0.000_001,
      "Physical X size changed proportions or ignored fallback/override semantics")
    try expect(metadata.provenance.filter { $0.text.hasPrefix("Set physical X extent") }.count == (applied ? 1 : 0),
      "Physical size provenance was missing or recorded without scaling")
  } }
}

private func testNRRDProvenanceExport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-nrrd-history-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let raw = root.appendingPathComponent("input.raw"), data = root.appendingPathComponent("source.data")
  try Data(0..<64).write(to: raw)
  let history = [BORGVRProvenanceEntry(timestampMilliseconds: 1_793_491_200_000,
    text: "Source: Gefäße 🧠\n\nencoding: ascii\r# not a real field\0"),
    BORGVRProvenanceEntry("Processing\n[1, 0, 0, 0]")]
  let volume = try RawFileAccessor(filename: raw.path, size: .init(x: 4, y: 4, z: 4),
    bytesPerComponent: 1, componentCount: 1, voxelSpacing: .init(x: 0.001, y: 0.002, z: 0.003))
  try BrickedVolumeReorganizer(inputVolume: volume, brickSize: 4, overlap: 1, extensionStrategy: .clamp)
    .reorganize(to: data.path, datasetDescription: "Provenance test", metaDescription: "", provenance: history)
  let originalHistory = try BORGVRMetaData(url: data).provenance
  for level in [0, 1] {
    let output = root.appendingPathComponent("level-\(level).nrrd")
    _ = try BORGVRVolumeExporter.export(inputURL: data, outputURL: output, level: level)
    let bytes = try Data(contentsOf: output)
    let split = bytes.range(of: Data("\n\n".utf8))!
    let header = bytes[..<split.lowerBound]
    try expect(header.allSatisfy { $0 < 128 }, "NRRD header contains non-ASCII text")
    let prefix = "# BorgVR provenance: "
    let entries = try String(decoding: header, as: UTF8.self).components(separatedBy: "\n")
      .filter { $0.hasPrefix(prefix) }.map {
        try JSONDecoder().decode(BORGVRProvenanceEntry.self, from: Data($0.dropFirst(prefix.count).utf8))
      }
    try expect(Array(entries.dropLast()) == originalHistory, "NRRD export changed provenance timestamps/text/order")
    try expect(entries.last!.text.contains("Exported to NRRD from LoD \(level)"), "NRRD export step is missing")
    let parsed = try NRRDParser(filename: output.path)
    try expect(parsed.size == (level == 0 ? .init(x: 4, y: 4, z: 4) : .init(x: 2, y: 2, z: 2)),
      "NRRD provenance comments changed header parsing")
    if level == 0 { try expect(bytes.suffix(64) == Data(0..<64), "Provenance changed exported voxel data") }
  }
  let unchanged = try BORGVRMetaData(url: data)
  try expect(unchanged.provenance == originalHistory, "NRRD export mutated the input history")
}

private func testImageSequences() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-image-tests-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  func image(_ directory: URL, _ name: String, rgba: Bool, value: UInt8, width: Int = 2) throws {
    let channels = rgba ? 4 : 3
    let pixel: [UInt8] = rgba ? [value, value, value, 128] : [value, value, value]
    let samples = (0..<(width * 2)).flatMap { _ in pixel }
    let provider = CGDataProvider(data: Data(samples) as CFData)!
    let cgImage = CGImage(width: width, height: 2, bitsPerComponent: 8, bitsPerPixel: channels * 8,
      bytesPerRow: width * channels, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: rgba ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
      "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cgImage, nil)
    try expect(CGImageDestinationFinalize(destination), "Could not create image fixture")
  }
  let settings = BorgVRVolumeConversionSettings(brickSize: 4, overlap: 1,
    useCompression: true, extensionStrategy: .clamp)
  for rgba in [false, true] {
    let directory = root.appendingPathComponent(rgba ? "rgba" : "rgb")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try image(directory, "10.png", rgba: rgba, value: 160)
    try image(directory, "02.png", rgba: rgba, value: 40)
    try Data("ignore sidecar".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    let output = root.appendingPathComponent("\(directory.lastPathComponent).data")
    let request = BorgVRVolumeConversionRequest(source: .imageSequence(directory), destinationURL: output,
      datasetDescription: "Image sequence", metaDescription: "", settings: settings,
      physicalSizeMeters: Vec3(x: 0.2, y: 0.4, z: 0.6))
    try BorgVRVolumeConversionService.convert(request)
    let metadata = try BORGVRMetaData(url: output)
    try expect(metadata.width == 2 && metadata.height == 2 && metadata.depth == 2,
      "Image sequence dimensions changed")
    try expect(abs(metadata.voxelSpacingX - 0.1) < 0.00001 && abs(metadata.voxelSpacingY - 0.2) < 0.00001
      && abs(metadata.voxelSpacingZ - 0.3) < 0.00001, "Image physical extent was not retained")
    try expect(metadata.channelInterpretation == (rgba ? .rgba : .rgb), "Incorrect image color interpretation")
    let automatic = root.appendingPathComponent("automatic-\(directory.lastPathComponent).data")
    let sources = try BorgVRAutomaticVolumeConversion.convert(source: directory, destination: automatic,
      settings: settings, logger: nil, cancellationToken: BorgVRVolumeConversionCancellationToken(),
      physicalSizeMeters: Vec3(x: 0.2, y: 0.4, z: 0.6), validateSources: { _ in })
    let automaticMetadata = try BORGVRMetaData(url: automatic)
    try expect(sources == [directory] && automaticMetadata.channelInterpretation == metadata.channelInterpretation,
      "Guided image import did not preserve color or cleanup sources")
    let ranges = rgba ? [BORGVRComponentRange(minValue: 128, maxValue: 128)] : []
    try expect(metadata.componentRanges == ranges && metadata.brickMetadata.allSatisfy { $0.componentRanges == ranges },
      "RGB must omit min/max; RGBA must record alpha only")
    let flat = root.appendingPathComponent("\(directory.lastPathComponent).nrrd")
    _ = try BORGVRVolumeExporter.export(inputURL: output, outputURL: flat, level: 0)
    let parser = try NRRDParser(filename: flat.path)
    defer { if parser.dataIsTempCopy { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) } }
    let bytes = try Data(contentsOf: URL(fileURLWithPath: parser.absoluteFilename))
    let samples = Array(bytes.dropFirst(parser.offset))
    let channels = rgba ? 4 : 3
    try expect(abs(Int(samples[0]) - 40) <= 1 && abs(Int(samples[4 * channels]) - 160) <= 1,
      "Slices are not sorted by filename or colors changed")
    if rgba { try expect(samples[3] == 128, "Alpha was changed") }
    let token = BorgVRVolumeConversionCancellationToken(); token.cancel()
    try expectThrows("Cancelled image import succeeded") {
      try BorgVRVolumeConversionService.convert(request, cancellationToken: token)
    }
    try image(directory, "11.png", rgba: rgba, value: 80, width: 3)
    let previous = try Data(contentsOf: output)
    try expectThrows("Mismatched slice dimensions were accepted") { try BorgVRVolumeConversionService.convert(request) }
    let afterFailure = try Data(contentsOf: output)
    try expect(afterFailure == previous, "Failed import replaced existing output")
    try expectThrows("Missing physical image dimensions were accepted") {
      try BorgVRVolumeConversionService.convert(.init(source: .imageSequence(directory), destinationURL: output,
        datasetDescription: "", metaDescription: "", settings: settings))
    }
  }
  print("Image sequence import, color ranges, order, extent, cancellation and atomic failure tests passed")
}

private func testSupportingFileAccess() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-file-access-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let header = root.appendingPathComponent("scan.dat"), raw = root.appendingPathComponent("scan.dat.raw")
  try Data("header".utf8).write(to: header)
  let bytes = Data([1, 2, 3, 4])
  try bytes.write(to: raw)
  let access = VolumeImportSourceAccess(url: header, selectedURLs: [header, raw])
  let result = try BorgVRImportFileAccess.withReadAccess(primary: access.url, supporting: raw) { try Data(contentsOf: $0) }
  try expect(result == bytes && access.url == header, "Supporting file access changed the URL or data")
  struct BodyError: Error {}
  do {
    try BorgVRImportFileAccess.withReadAccess(primary: header, supporting: raw) { _ in throw BodyError() }
    throw TestFailure.failed("Supporting file access swallowed a conversion error")
  } catch is BodyError {}
  do {
    try BorgVRImportFileAccess.withReadAccess(primary: header, supporting: root.appendingPathComponent("missing.raw")) { _ in
      throw TestFailure.failed("Missing supporting file reached conversion")
    }
    throw TestFailure.failed("Missing file was accepted")
  } catch is BorgVRImportFileAccess.Error {
    throw TestFailure.failed("Missing file incorrectly requested sandbox permission")
  } catch is TestFailure { throw TestFailure.failed("Missing file was accepted") }
  catch {}
  try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: raw.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: raw.path) }
  do {
    try BorgVRImportFileAccess.withReadAccess(primary: header, supporting: raw) { _ in
      throw TestFailure.failed("Denied supporting file reached conversion")
    }
    throw TestFailure.failed("Unreadable supporting file was accepted")
  } catch BorgVRImportFileAccess.Error.permissionRequired(let url) {
    try expect(url == raw, "Permission request points to the wrong supporting file")
  }
  try expect(!NSFileCoordinator.filePresenters.contains { $0.presentedItemURL == raw },
    "Related file presenter was not unregistered after failure")
  print("Supporting file access passed: original URLs, unchanged bytes, conversion errors, missing/denied files and presenter cleanup")
}

private func testQVISColorImport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-qvis-color-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  func header(_ name: String, format: String, model: String?, components: String? = nil,
              resolution: String = "2 2 2") throws -> URL {
    let url = root.appendingPathComponent("\(name).dat")
    var lines = ["ObjectFileName: \(name).raw", "TaggedFileName: ---", "Resolution: \(resolution)",
      "SliceThickness: 0.333333\t0.333333\t1", "Format: \(format)",
      "ObjectType: TEXTURE_VOLUME_OBJECT", "GridType: EQUIDISTANT", "Endianess: LITTLE"]
    if let model { lines.append("ObjectModel: \(model)") }
    if let components { lines.append("Components: \(components)") }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .ascii)
    return url
  }
  let visibleHuman = try header("VisibleHumanFullColor-SCANLINE-36-lz4.dat", format: "UCHAR4",
    model: "RGBA", resolution: "1728 1008 1878")
  let parsed = try QVISParser(filename: visibleHuman.path)
  try expect(parsed.size == Vec3(x: 1728, y: 1008, z: 1878) && parsed.components == 4
    && parsed.bytesPerComponent == 1 && parsed.channelInterpretation == .rgba
    && parsed.isLittleEndian && abs(parsed.voxelSpacing.x - 0.333333) < 0.000001
    && parsed.voxelSpacing.z == 1 && parsed.absoluteFilename.hasSuffix("-lz4.dat.raw"),
    "Visible Human UCHAR4/RGBA header was parsed incorrectly")
  let cases: [(String, String?, String?, Int, BORGVRChannelInterpretation)] = [
    ("UCHAR3", "RGB", nil, 3, .independentChannels), ("UCHAR4", "rgba", nil, 4, .rgba),
    ("UCHAR", "RGBA", "4", 4, .independentChannels), ("BYTE", "RGB", "3", 3, .independentChannels),
    ("UCHAR3", nil, nil, 3, .independentChannels),
    ("UCHAR3", "RGBA", "3", 3, .independentChannels),
    ("UCHAR4", "I", nil, 4, .independentChannels),
    ("UCHAR4", "RGB", "4", 4, .independentChannels),
    ("UCHAR4", nil, nil, 4, .independentChannels),
    ("UCHAR4", "unknown", nil, 4, .independentChannels),
    ("UCHAR4", "RGBA", "4", 4, .rgba),
    ("UCHAR", "RGBA", "1", 1, .independentChannels)
  ]
  let settings = BorgVRVolumeConversionSettings(brickSize: 4, overlap: 1,
    useCompression: true, extensionStrategy: .clamp)
  for (index, entry) in cases.enumerated() {
    let (format, model, count, channels, interpretation) = entry
    let input = try header("case-\(index)", format: format, model: model, components: count)
    let expected = Data((0..<(8 * channels)).map { UInt8($0 * 7) })
    try expected.write(to: input.deletingPathExtension().appendingPathExtension("raw"))
    let output = root.appendingPathComponent("case-\(index).data")
    try BorgVRVolumeConversionService.convert(.init(source: .file(input), destinationURL: output,
      datasetDescription: "QVIS color", metaDescription: "", settings: settings))
    let metadata = try BORGVRMetaData(url: output)
    try expect(metadata.channelInterpretation == interpretation && metadata.componentCount == channels,
      "QVIS import lost the color interpretation or component count")
    if interpretation == .rgb {
      try expect(metadata.componentRanges.isEmpty && metadata.brickMetadata.allSatisfy { $0.componentRanges.isEmpty },
        "QVIS RGB stored unnecessary value ranges")
    } else if interpretation == .rgba {
      try expect(metadata.componentRanges == [BORGVRComponentRange(minValue: 21, maxValue: 217)]
        && metadata.brickMetadata.allSatisfy { $0.componentRanges.count == 1 }, "QVIS RGBA did not retain alpha-only bounds")
    } else {
      try expect(metadata.componentRanges.count == channels, "QVIS independent channels lost their bounds")
    }
    let flat = root.appendingPathComponent("case-\(index).nrrd")
    _ = try BORGVRVolumeExporter.export(inputURL: output, outputURL: flat, level: 0)
    let exported = try Data(contentsOf: flat)
    guard let split = exported.range(of: Data("\n\n".utf8)) else { throw TestFailure.failed("Missing NRRD header") }
    try expect(Data(exported[split.upperBound...]) == expected, "QVIS color import changed raw RGB/alpha samples")
  }
  for (format, model, count) in [
    ("USHORT", "RGBA", "4"), ("UINT", "RGB", "3"),
    ("USHORT", "RGBA", "1"), ("UINT", "RGBA", "1")
  ] {
    let input = try header("scalar", format: format, model: model, components: count)
    let scalar = try QVISParser(filename: input.path)
    try expect(scalar.channelInterpretation == .independentChannels && scalar.components == Int(count),
      "ObjectModel changed a non-UCHAR4 format")
  }
  for (format, model, components) in [
    ("UCHAR3", "RGB", "4"), ("UCHAR4", "RGBA", "3"),
    ("UCHAR", "I", "garbage"), ("UCHAR", "I", "0")
  ] {
    let input = try header("invalid", format: format, model: model, components: components)
    try expectThrows("Invalid QVIS format/components was accepted") { _ = try QVISParser(filename: input.path) }
  }
  print("QVIS UCHAR4/RGBA import, ignored ObjectModel for other formats, alpha bounds and raw payload passed")
}

private func testNRRDChannelInterpretationRoundTrip() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-nrrd-color-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let settings = BorgVRVolumeConversionSettings(
    brickSize: 4, overlap: 1, useCompression: false, extensionStrategy: .clamp)

  func writeNRRD(name: String, kind: String, channels: Int, width: Int = 1) throws -> URL {
    let url = root.appendingPathComponent("\(name).nrrd")
    let header = [
      "NRRD0005", "type: uint\(width * 8)", "dimension: 4",
      "sizes: \(channels) 2 2 2", "spacings: nan 1 1 1",
      "kinds: \(kind) domain domain domain", "endian: little", "encoding: raw"
    ].joined(separator: "\n") + "\n\n"
    let payload = Data((0..<(8 * channels * width)).map { UInt8(truncatingIfNeeded: $0 * 7) })
    try (Data(header.utf8) + payload).write(to: url)
    return url
  }

  func convert(_ input: URL, to output: URL) throws -> BORGVRMetaData {
    try BorgVRVolumeConversionService.convert(.init(
      source: .file(input), destinationURL: output,
      datasetDescription: "NRRD channel interpretation test", metaDescription: "", settings: settings))
    return try BORGVRMetaData(url: output)
  }

  let cases: [(kind: String, channels: Int, interpretation: BORGVRChannelInterpretation)] = [
    ("RGB-color", 3, .rgb), ("RGBA-color", 4, .rgba),
    ("vector", 3, .independentChannels), ("vector", 4, .independentChannels)
  ]
  for test in cases {
    let name = "\(test.kind)-\(test.channels)"
    let source = try writeNRRD(name: name, kind: test.kind, channels: test.channels)
    let imported = root.appendingPathComponent("\(name).data")
    let metadata = try convert(source, to: imported)
    try expect(metadata.channelInterpretation == test.interpretation,
      "\(name): import lost the explicit channel interpretation")

    let exported = root.appendingPathComponent("\(name)-exported.nrrd")
    _ = try BORGVRVolumeExporter.export(inputURL: imported, outputURL: exported, level: 0)
    let bytes = try Data(contentsOf: exported)
    guard let split = bytes.range(of: Data("\n\n".utf8)) else {
      throw TestFailure.failed("\(name): exported NRRD has no header terminator")
    }
    let fields = String(decoding: bytes[..<split.lowerBound], as: UTF8.self)
      .components(separatedBy: "\n")
    try expect(fields.contains("kinds: \(test.kind) domain domain domain"),
      "\(name): export changed the NRRD channel kind")
    try expect(fields.contains("dimension: 4") && fields.contains("sizes: \(test.channels) 2 2 2"),
      "\(name): export changed the component-first layout")
    let expected = Data((0..<(8 * test.channels)).map { UInt8($0 * 7) })
    try expect(Data(bytes[split.upperBound...]) == expected,
      "\(name): color/vector export changed interleaved samples")

    let reimported = try convert(exported, to: root.appendingPathComponent("\(name)-reimported.data"))
    try expect(reimported.channelInterpretation == test.interpretation,
      "\(name): reimport lost the channel interpretation")
    for result in [metadata, reimported] {
      try expect(result.width == 2 && result.height == 2 && result.depth == 2
        && result.componentCount == test.channels && result.bytesPerComponent == 1,
        "\(name): import/reimport changed dimensions or sample layout")
    }
  }

  for (name, kind, channels, width) in [
    ("rgb-four-channels", "RGB-color", 4, 1),
    ("rgb-sixteen-bit", "RGB-color", 3, 2),
    ("rgba-sixteen-bit", "RGBA-color", 4, 2)
  ] {
    let source = try writeNRRD(name: name, kind: kind, channels: channels, width: width)
    try expectThrows("\(name): invalid NRRD color layout was accepted") {
      _ = try convert(source, to: root.appendingPathComponent("\(name).data"))
    }
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

@MainActor
private func testRGBAEditing() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-rgba-edits-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let size = Vec3<Int>(x: 7, y: 5, z: 3)
  let spacing = Vec3<Float>(x: 0.1, y: 0.2, z: 0.3)
  let original = (0..<(size.x * size.y * size.z)).flatMap { voxel in
    [UInt8(voxel % 101 + 20), UInt8(voxel % 71 + 90), UInt8(voxel % 31 + 180), UInt8(192)]
  }
  let settings = BorgVRVolumeConversionSettings(brickSize: 4, overlap: 1,
    useCompression: true, extensionStrategy: .clamp)
  func convert(_ bytes: [UInt8], name: String) throws -> BORGVRFileData {
    let raw = root.appendingPathComponent(name + ".raw"), output = root.appendingPathComponent(name + ".data")
    try Data(bytes).write(to: raw)
    try BorgVRVolumeConversionService.convert(.init(source: .raw(.init(url: raw, offset: 0,
      size: size, bytesPerComponent: 1, componentCount: 4, voxelSpacing: spacing, channelInterpretation: .rgba)),
      destinationURL: output, datasetDescription: name, metaDescription: "", settings: settings))
    return try BORGVRFileData(filename: output.path)
  }
  let source = try convert(original, name: "source"), m = source.getMetadata()
  let sample = BorgVRVolumeBrushSample(center: SIMD3(0.35, 0.4, 0.45), radius: 0.29)
  let physicalSpacing = SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ))
  var expected = original
  for z in 0..<size.z { for y in 0..<size.y { for x in 0..<size.x {
    let d = (SIMD3<Double>(SIMD3(x, y, z)) + SIMD3(repeating: 0.5)) * physicalSpacing - sample.center
    if d.x * d.x + d.y * d.y + d.z * d.z <= sample.radius * sample.radius {
      expected[((z * size.y + y) * size.x + x) * 4 + 3] = 0
    }
  } } }
  try expect(expected != original, "RGBA edit fixture did not erase any voxels")
  let oracle = try convert(expected, name: "oracle")
  func bytes(_ dataset: BORGVRDatasetProtocol, _ index: Int) throws -> [UInt8] {
    let buffer = dataset.allocateBrickBuffer()
    defer { buffer.deallocate() }
    try dataset.getBrick(index: index, outputBuffer: buffer)
    return Array(UnsafeBufferPointer(start: buffer, count: 4 * 4 * 4 * 4))
  }
  func compare(_ dataset: BORGVRDatasetProtocol, to expected: BORGVRDatasetProtocol) throws {
    for id in m.brickMetadata.indices {
      let actual = try bytes(dataset, id), reference = try bytes(expected, id)
      try expect(actual == reference, "RGBA edit differs from dense oracle at brick \(id)")
      try expect(dataset.visibilityMetadata(index: id)?.componentRanges == expected.visibilityMetadata(index: id)?.componentRanges,
        "RGBA visibility does not contain exactly the edited alpha range")
    }
  }
  var mask = try BorgVRVolumeEditMask(size: SIMD3(size.x, size.y, size.z), spacing: physicalSpacing, componentCount: 4)
  try mask.apply(sample, mode: .erase, channels: .selected([3]))
  let cpu = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp)
  for gpu in [false, true] {
    let builder = try BorgVRVolumeEditMaterializer(source: source, usesMetal: gpu)
    for id in m.brickMetadata.indices.reversed() {
      let result = try builder.materialize(index: id, mask: mask, revision: 1, revisions: nil,
        useGPU: gpu, cached: { _, _ in nil }, store: { _ in }, isCancelled: { false })
      let reference = try cpu.materialize(index: id, mask: mask, revision: 1)
      let expectedBytes = try bytes(oracle, id)
      let difference = result.bytes.indices.first { result.bytes[$0] != expectedBytes[$0] }
      try expect(result.bytes == expectedBytes,
        "RGBA dense oracle differs: GPU \(gpu), brick \(id), byte \(difference ?? -1), got \(difference.map { result.bytes[$0] } ?? 0), expected \(difference.map { expectedBytes[$0] } ?? 0), CPU \(difference.map { reference.bytes[$0] } ?? 0)")
      try expect(result.bytes == reference.bytes, "RGBA CPU/Metal bytes differ: GPU \(gpu), brick \(id)")
      try expect(result.componentRanges == oracle.getMetadata().brickMetadata[id].componentRanges,
        "RGBA alpha ranges differ: GPU \(gpu), brick \(id), got \(result.componentRanges), expected \(oracle.getMetadata().brickMetadata[id].componentRanges)")
      try expect(result.componentRanges == reference.componentRanges, "RGBA CPU/Metal ranges differ: GPU \(gpu), brick \(id)")
    }
    if gpu, MTLCreateSystemDefaultDevice() != nil { try expect(builder.metalBrickCount > 0, "RGBA edits did not use Metal") }
  }
  var erasedMask = try BorgVRVolumeEditMask(size: mask.size, spacing: physicalSpacing, componentCount: 4)
  try erasedMask.apply(.init(center: .zero, radius: 100), mode: .erase)
  let builder = try BorgVRVolumeEditMaterializer(source: source)
  let erased = try builder.materialize(index: 0, mask: erasedMask, revision: 1)
  try expect(erased.componentRanges == [.init(minValue: 0, maxValue: 0)] && erased.bytes.allSatisfy { $0 == 0 },
    "Fully erased RGBA brick has the wrong alpha range layout")

  let model = VolumeBrushModel()
  defer { model.close() }
  let sourceURL = root.appendingPathComponent("source.data")
  let edited = model.open(source, datasetURL: sourceURL)
  try await model.waitForStateReady()
  try expect(model.channels == .selected([3]) && model.channelInterpretation == .rgba,
    "RGBA UI must erase alpha and preserve straight RGB colors")
  try await model.editVolume(mode: .erase, samples: [sample])
  try await model.prepareVolumeEdits()
  try compare(edited, to: oracle)
  let exported = root.appendingPathComponent("edited.data")
  let job = try model.startVolumeExport(to: exported, name: nil, description: nil)
  _ = try await model.waitForVolumeExport(id: job.id)
  let baked = try BORGVRFileData(filename: exported.path)
  try expect(baked.getMetadata().channelInterpretation == .rgba && baked.getMetadata().componentRanges.count == 1,
    "RGBA edit export lost color interpretation or alpha-only ranges")
  try compare(baked, to: oracle)
  model.close()
  let reopened = model.open(source, datasetURL: sourceURL)
  try await model.waitForStateReady()
  try compare(reopened, to: oracle)
  try await model.editVolume(mode: .restore, samples: [sample])
  try await model.prepareVolumeEdits()
  try compare(reopened, to: source)
  print("RGBA editing passed: alpha-only erase/restore, odd LODs, CPU/Metal, cache reopen and data export")
}

private func testDICOMFusionInterleavesChannels() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-dicom-fusion-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let fusedURL = directory.appendingPathComponent("fused.raw")
  try Data([1, 2, 3, 4]).write(to: referenceURL)
  try Data([10, 20, 30, 40]).write(to: movingURL)
  let size = Vec3<Int>(x: 2, y: 2, z: 1)
  let spacing = Vec3<Float>(x: 0.1, y: 0.1, z: 0.1)

  func volume(url: URL, description: String) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: spacing
      ),
      orientation: nil,
      origin: nil,
      frameOfReferenceUID: nil,
      channels: [BorgVRUnbrickedVolumeChannelMetadata(
        description: description,
        modality: nil,
        patientName: nil,
        seriesDate: nil,
        isSigned: false,
        pixelPaddingValue: nil
      )]
    )
  }

  let fused = try BorgVRDICOMVolumeFusion.fuse(
    reference: volume(url: referenceURL, description: "Reference"),
    moving: volume(url: movingURL, description: "Moving"),
    referenceToMoving: .identity,
    filter: .nearestNeighbor,
    outputURL: fusedURL,
    logger: nil,
    cancellationToken: nil
  )
  try expect(fused.source.componentCount == 2, "Fusion did not create two channels")
  try expect(fused.channels.count == 2, "Fusion discarded channel metadata")
  try expect(fused.source.size == size, "Fusion changed the reference grid")
  let fusedData = try Data(contentsOf: fusedURL)
  try expect(
    fusedData == Data([1, 10, 2, 20, 3, 30, 4, 40]),
    "Fusion did not interleave the two channels"
  )

  let brickedURL = directory.appendingPathComponent("fused.data")
  let accessor = try RawFileAccessor(
    filename: fusedURL.path,
    size: size,
    bytesPerComponent: 1,
    componentCount: 2,
    voxelSpacing: spacing
  )
  try BrickedVolumeReorganizer(
    inputVolume: accessor,
    brickSize: 4,
    overlap: 1,
    extensionStrategy: .clamp
  ).reorganize(
    to: brickedURL.path,
    datasetDescription: "Fused",
    metaDescription: "Component range test"
  )
  let metadata = try BORGVRMetaData(url: brickedURL)
  try expect(
    metadata.componentRanges == [
      BORGVRComponentRange(minValue: 1, maxValue: 4),
      BORGVRComponentRange(minValue: 10, maxValue: 40)
    ],
    "Bricking did not preserve per-component dataset ranges"
  )
  try expect(
    metadata.brickMetadata.allSatisfy {
      $0.componentRanges == [
        BORGVRComponentRange(minValue: 1, maxValue: 4),
        BORGVRComponentRange(minValue: 10, maxValue: 40)
      ]
    },
    "Bricking did not preserve per-component brick ranges"
  )
}

private func testIntegerVolumeSamplerHandlesInterpolationAndPadding() throws {
  let size = Vec3<Int>(x: 2, y: 2, z: 2)
  let values: [Int16] = [0, 10, 20, 30, 40, 50, 60, 70]
  try values.withUnsafeBufferPointer { buffer in
    let sampler = BorgVRIntegerVolumeSampler(
      values: buffer.baseAddress!,
      size: size,
      paddingValue: nil
    )
    try expect(
      sampler.nearestNeighbor(at: Vec3<Float>(repeating: 0.6)) == 70,
      "Nearest-neighbor sampling returned the wrong voxel"
    )
    try expect(
      sampler.trilinear(at: Vec3<Float>(repeating: 0.5)) == 35,
      "Trilinear sampling returned the wrong interpolation"
    )

    let paddedSampler = BorgVRIntegerVolumeSampler(
      values: buffer.baseAddress!,
      size: size,
      paddingValue: 70
    )
    try expect(
      paddedSampler.nearestNeighbor(at: Vec3<Float>(repeating: 1)) == nil,
      "Nearest-neighbor sampling treated padding as image data"
    )
    try expect(
      paddedSampler.trilinear(at: Vec3<Float>(repeating: 0.5)) == nil,
      "Trilinear sampling treated padding as image data"
    )
  }
}

private func testDICOMFusionTreatsMovingPaddingAsMissing() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-dicom-fusion-padding-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let fusedURL = directory.appendingPathComponent("fused.raw")
  try Data([1, 2]).write(to: referenceURL)
  try Data([10, 255]).write(to: movingURL)
  let size = Vec3<Int>(x: 2, y: 1, z: 1)
  let spacing = Vec3<Float>(repeating: 0.1)

  func volume(
    url: URL,
    description: String,
    paddingValue: Int32?
  ) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: spacing
      ),
      orientation: nil,
      origin: nil,
      frameOfReferenceUID: nil,
      channels: [BorgVRUnbrickedVolumeChannelMetadata(
        description: description,
        modality: nil,
        patientName: nil,
        seriesDate: nil,
        isSigned: false,
        pixelPaddingValue: paddingValue
      )]
    )
  }

  _ = try BorgVRDICOMVolumeFusion.fuse(
    reference: volume(url: referenceURL, description: "Reference", paddingValue: nil),
    moving: volume(url: movingURL, description: "Moving", paddingValue: 255),
    referenceToMoving: .identity,
    filter: .nearestNeighbor,
    outputURL: fusedURL,
    logger: nil,
    cancellationToken: nil
  )
  let fusedData = try Data(contentsOf: fusedURL)
  try expect(
    fusedData == Data([1, 10, 2, 0]),
    "DICOM fusion copied padding into the moving channel"
  )
}

private func testIsoSurfaceExtractionUsesUniqueCellsAndChannelMinimum() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-isosurface-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  func extract(
    componentCount: Int,
    brickSize: Int,
    overlap: Int,
    name: String,
    voxelSpacing: Vec3<Float> = Vec3<Float>(x: 0.1, y: 0.2, z: 0.3)
  ) throws -> Int {
    let size = Vec3<Int>(x: 4, y: 4, z: 4)
    let rawURL = directory.appendingPathComponent("\(name).raw")
    let dataURL = directory.appendingPathComponent("\(name).data")
    let objURL = directory.appendingPathComponent("\(name).obj")
    var values = [UInt8]()
    values.reserveCapacity(size.x * size.y * size.z * componentCount)
    for _ in 0..<size.z {
      for _ in 0..<size.y {
        for x in 0..<size.x {
          values.append(x >= 2 ? 255 : 0)
          if componentCount == 2 {
            // With a channel maximum this would make every voxel solid. The
            // channel minimum must retain the plane from the first channel.
            values.append(255)
          }
        }
      }
    }
    try Data(values).write(to: rawURL)
    let accessor = try RawFileAccessor(
      filename: rawURL.path,
      size: size,
      bytesPerComponent: 1,
      componentCount: componentCount,
      voxelSpacing: voxelSpacing
    )
    try BrickedVolumeReorganizer(
      inputVolume: accessor,
      brickSize: brickSize,
      overlap: overlap,
      extensionStrategy: .clamp
    ).reorganize(
      to: dataURL.path,
      datasetDescription: "Isosurface test",
      metaDescription: "Marching Cubes regression test"
    )

    let source = try BORGVRFileData(filename: dataURL.path)
    let result = try BorgVRIsoSurfaceExtractor.extract(
      dataset: name == "overlap" ? OneShotDelayedDataset(source: source) : source,
      normalizedIsoValue: 0.5,
      outputURL: objURL
    )
    _ = try BorgVRIsoSurfaceExtractor.extract(
      dataset: BORGVRFileData(filename: dataURL.path),
      normalizedIsoValue: 0.5,
      outputURL: objURL
    )
    let obj = try String(contentsOf: objURL, encoding: .utf8)
    let faces = obj.split(separator: "\n").filter { $0.hasPrefix("f ") }
    try expect(result.triangleCount == faces.count, "OBJ face count differs from result")

    let normalizedURL = directory.appendingPathComponent("\(name)-normalized.obj")
    let normalizedResult = try BorgVRIsoSurfaceExtractor.extract(
      dataset: source, normalizedIsoValue: 0.5, outputURL: normalizedURL, normalize: true
    )
    let normalizedOBJ = try String(contentsOf: normalizedURL, encoding: .utf8)
    func lines(_ text: String, prefix: String) -> [Substring] {
      text.split(separator: "\n").filter { $0.hasPrefix(prefix) }
    }
    let vertices = lines(obj, prefix: "v ")
    let normalizedVertices = lines(normalizedOBJ, prefix: "v ")
    try expect(vertices.count == normalizedVertices.count &&
      result.triangleCount == normalizedResult.triangleCount,
      "Normalization changed the extracted geometry")
    let scale = 2 / max(Double(size.x) * Double(voxelSpacing.x),
                        Double(size.y) * Double(voxelSpacing.y),
                        Double(size.z) * Double(voxelSpacing.z))
    for (physical, normalized) in zip(vertices, normalizedVertices) {
      let physicalCoordinates = physical.split(separator: " ").dropFirst().compactMap { Double($0) }
      let normalizedCoordinates = normalized.split(separator: " ").dropFirst().compactMap { Double($0) }
      try expect(physicalCoordinates.count == 3 && normalizedCoordinates.count == 3,
                 "Exported vertex coordinates are invalid")
      for (coordinate, normalizedCoordinate) in zip(physicalCoordinates, normalizedCoordinates) {
        try expect(abs(normalizedCoordinate - coordinate * scale) < 0.000001 &&
          abs(normalizedCoordinate) <= 1,
          "Normalization did not uniformly scale the source volume to [-1, 1]")
      }
    }
    try expect(lines(obj, prefix: "vn ") == lines(normalizedOBJ, prefix: "vn ") &&
      faces == lines(normalizedOBJ, prefix: "f "),
      "Normalization changed normals, topology or winding")
    try expect(obj.contains("Coordinates are expressed in meters.") &&
      normalizedOBJ.contains("coordinates are unitless."),
      "OBJ header does not describe the export coordinate system")
    return faces.count
  }

  let overlappingFaceCount = try extract(
    componentCount: 1, brickSize: 4, overlap: 1, name: "overlap"
  )
  try expect(
    overlappingFaceCount == 18,
    "Overlapping bricks duplicated or omitted level-zero cells"
  )
  let multiChannelFaceCount = try extract(
    componentCount: 2, brickSize: 2, overlap: 0, name: "minimum"
  )
  try expect(
    multiChannelFaceCount == 18,
    "Multi-channel extraction did not use the component minimum"
  )
  let picometerFaceCount = try extract(
    componentCount: 1,
    brickSize: 4,
    overlap: 1,
    name: "picometer",
    voxelSpacing: Vec3<Float>(repeating: 1.1e-11)
  )
  try expect(
    picometerFaceCount == 18,
    "Physical-scale degeneracy check rejected a picometer-sized isosurface"
  )
  _ = try extract(componentCount: 1, brickSize: 4, overlap: 1, name: "longest-x",
                  voxelSpacing: Vec3<Float>(x: 0.6, y: 0.2, z: 0.1))
}

private func testIsoSurfaceInterpolatesSampleGradients() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-isosurface-normals-\(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let previousBackend = ProcessInfo.processInfo.environment["BORGVR_DISABLE_METAL_ISOSURFACE"]
  defer {
    try? FileManager.default.removeItem(at: directory)
    if let previousBackend { setenv("BORGVR_DISABLE_METAL_ISOSURFACE", previousBackend, 1) }
    else { unsetenv("BORGVR_DISABLE_METAL_ISOSURFACE") }
  }

  func checkField(name: String, size: Vec3<Int>, spacing: Vec3<Float>, threshold: Double,
                  requiresCenter: Bool = false, sample: (SIMD3<Int>) -> UInt16) throws {
    let rawURL = directory.appendingPathComponent(name + ".raw")
    var data = Data()
    for z in 0..<size.z { for y in 0..<size.y { for x in 0..<size.x {
      let value = sample(SIMD3(x, y, z))
      data.append(UInt8(truncatingIfNeeded: value))
      data.append(UInt8(truncatingIfNeeded: value >> 8))
    } } }
    try data.write(to: rawURL)
    let dimensions = SIMD3(size.x, size.y, size.z)
    let physicalSpacing = SIMD3(Double(spacing.x), Double(spacing.y), Double(spacing.z))

    func expectedNormal(at voxel: SIMD3<Double>) -> SIMD3<Double> {
      let lower = SIMD3(Int(floor(voxel.x)), Int(floor(voxel.y)), Int(floor(voxel.z)))
      let fraction = voxel - SIMD3(Double(lower.x), Double(lower.y), Double(lower.z))
      var gradient = SIMD3<Double>.zero
      for z in 0...1 { for y in 0...1 { for x in 0...1 {
        let position = simd_clamp(lower &+ SIMD3(x, y, z), .zero, dimensions &- SIMD3(repeating: 1))
        let weight = (x == 0 ? 1 - fraction.x : fraction.x) *
          (y == 0 ? 1 - fraction.y : fraction.y) * (z == 0 ? 1 - fraction.z : fraction.z)
        for axis in 0..<3 {
          var before = position
          var after = position
          before[axis] = max(0, position[axis] - 1)
          after[axis] = min(dimensions[axis] - 1, position[axis] + 1)
          gradient[axis] += weight * (Double(sample(after)) - Double(sample(before))) /
            (Double(after[axis] - before[axis]) * physicalSpacing[axis])
        }
      } } }
      return simd_length_squared(gradient) > 0 ? -simd_normalize(gradient) : .zero
    }

    for (brickSize, overlap) in [(4, 0), (4, 1), (8, 2)] {
      let dataURL = directory.appendingPathComponent("\(name)-\(brickSize)-\(overlap).data")
      let accessor = try RawFileAccessor(filename: rawURL.path, size: size,
        bytesPerComponent: 2, componentCount: 1, voxelSpacing: spacing)
      try BrickedVolumeReorganizer(inputVolume: accessor, brickSize: brickSize, overlap: overlap,
        extensionStrategy: .fillZeroes).reorganize(to: dataURL.path,
          datasetDescription: name, metaDescription: "")
      let source = try BORGVRFileData(filename: dataURL.path)
      var cpuOutput: [Substring] = []
      for cpu in [true, false] {
        setenv("BORGVR_DISABLE_METAL_ISOSURFACE", cpu ? "1" : "0", 1)
        let objURL = directory.appendingPathComponent("\(name)-\(brickSize)-\(overlap)-\(cpu).obj")
        try BorgVRIsoSurfaceExtractor.extract(dataset: source,
          normalizedIsoValue: threshold / 65535, outputURL: objURL)
        let output = try String(contentsOf: objURL, encoding: .utf8).split(separator: "\n").filter {
          $0.hasPrefix("v ") || $0.hasPrefix("vn ") || $0.hasPrefix("f ")
        }
        if cpu { cpuOutput = output }
        else { try expect(output == cpuOutput, "CPU and Metal normals or geometry differ: \(name)") }
        var position = SIMD3<Double>.zero
        var normals: [SIMD3<Double>: SIMD3<Double>] = [:]
        var foundCenter = false
        for line in output {
          let fields = line.split(separator: " ")
          guard fields[0] == "v" || fields[0] == "vn" else { continue }
          let vector = SIMD3(Double(fields[1])!, Double(fields[2])!, Double(fields[3])!)
          if fields[0] == "v" { position = vector; continue }
          try expect(vector.x.isFinite && vector.y.isFinite && vector.z.isFinite &&
            abs(simd_length(vector) - 1) < 0.000001, "Invalid surface normal: \(name)")
          let voxel = position / physicalSpacing +
            SIMD3(Double(size.x), Double(size.y), Double(size.z)) / 2 - SIMD3(repeating: 0.5)
          let expected = expectedNormal(at: voxel)
          if simd_length_squared(expected) > 0 {
            try expect(simd_length(vector - expected) < 0.00001,
              "Surface normal does not interpolate sample gradients: \(name), \(voxel)")
          }
          if let previous = normals[position] {
            try expect(simd_length(previous - vector) < 0.000001,
              "Shared surface point has inconsistent normals across cells/bricks: \(name)")
          }
          normals[position] = vector
          if simd_length(voxel - SIMD3(repeating: 1.5)) < 0.000001 { foundCenter = true }
        }
        try expect(!requiresCenter || foundCenter, "MC33 interior vertex was not tested")
      }
    }
  }

  try checkField(name: "anisotropic-curve", size: Vec3(x: 7, y: 6, z: 5),
    spacing: Vec3(x: 0.25, y: 0.5, z: 0.75), threshold: 320) { p in
      UInt16(100 + 8 * p.x * p.x + 4 * p.y * p.y + 2 * p.z * p.z)
    }
  let corners = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                 SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
  try checkField(name: "mc33-center", size: Vec3(x: 4, y: 4, z: 4),
    spacing: Vec3(x: 0.25, y: 0.5, z: 0.75), threshold: 100, requiresCenter: true) { p in
      if let corner = corners.firstIndex(of: p &- SIMD3(repeating: 1)) {
        return 90 & (1 << corner) != 0 ? 200 : 0
      }
      return UInt16(100 + 30 * p.x + 20 * p.y + 10 * p.z)
    }
}

private func testEmptyDICOMDirectory() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-empty-dicom-\(UUID())")
  try FileManager.default.createDirectory(at: directory.appendingPathComponent("subfolder"),
    withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    try BorgVRVolumeConversionService.convert(.init(source: .dicomDirectory(directory),
      destinationURL: directory.appendingPathComponent("output.data"), datasetDescription: "Test",
      metaDescription: "", settings: .init(brickSize: 8, overlap: 2, useCompression: false,
        extensionStrategy: .clamp)))
    throw TestFailure.failed("An empty DICOM directory was accepted")
  } catch BorgVRVolumeConversionError.noDICOMFiles(let url) {
    try expect(url == directory, "The error does not identify the selected DICOM directory")
  }
}

private func testMarchingCubes33Cases() throws {
  let edgeCorners = [
    (0, 1), (1, 2), (2, 3), (3, 0),
    (4, 5), (5, 6), (6, 7), (7, 4),
    (0, 4), (1, 5), (2, 6), (3, 7)
  ]
  for mask in 1..<255 {
    let values = (0..<8).map { mask & (1 << $0) == 0 ? -1.0 : 1.0 }
    let triangles = BorgVRMarchingCubes33.triangles(values: values, threshold: 0)
    let complement = BorgVRMarchingCubes33.triangles(
      values: values.map(-),
      threshold: 0
    )
    try expect(
      triangles.count == complement.count,
      "Complementary MC33 cases produced different triangle counts for mask \(mask)"
    )
    for edge in triangles.flatMap(\.edges) where edge < 12 {
      let corners = edgeCorners[edge]
      try expect(
        values[corners.0].sign != values[corners.1].sign,
        "MC33 case \(mask) referenced an edge without an isosurface crossing"
      )
    }
  }

  // Case 10.1.1 examples from Vega et al. 2019, Figure 7 and Section 3.
  let firstCase10 = [-7.0, 2, 3, -6, 3, -6, -7, 2]
  let secondCase10 = [-12.0, 4, 6, -10, 3, -5, -6, 2]
  try expect(
    BorgVRMarchingCubes33.triangles(values: firstCase10, threshold: 0).count == 4,
    "The corrected MC33 interior test misclassified the first case 10.1.1 regression"
  )
  try expect(
    BorgVRMarchingCubes33.triangles(values: secondCase10, threshold: 0).count == 4,
    "The corrected MC33 interior test misclassified the second case 10.1.1 regression"
  )
}

private func testDICOMFusionUsesPatientGeometry() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-dicom-geometry-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let fusedURL = directory.appendingPathComponent("fused.raw")
  try Data([1, 2, 3]).write(to: referenceURL)
  try Data([10, 20]).write(to: movingURL)
  let orientation = DicomParser.DicomOrientation(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
  )
  let spacing = Vec3<Float>(x: 0.1, y: 0.1, z: 0.1)

  func volume(
    url: URL,
    size: Vec3<Int>,
    origin: Vec3<Float>
  ) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: spacing
      ),
      orientation: orientation,
      origin: origin,
      frameOfReferenceUID: "shared-frame",
      channels: []
    )
  }

  let reference = volume(
    url: referenceURL,
    size: Vec3<Int>(x: 3, y: 1, z: 1),
    origin: .zero
  )
  let moving = volume(
    url: movingURL,
    size: Vec3<Int>(x: 2, y: 1, z: 1),
    origin: Vec3<Float>(x: 0.1, y: 0, z: 0)
  )
  let transform = try BorgVRDICOMRigidRegistration.register(
    reference: reference,
    moving: moving,
    logger: nil
  )
  _ = try BorgVRDICOMVolumeFusion.fuse(
    reference: reference,
    moving: moving,
    referenceToMoving: transform,
    filter: .nearestNeighbor,
    outputURL: fusedURL,
    logger: nil,
    cancellationToken: nil
  )
  let fusedData = try Data(contentsOf: fusedURL)
  try expect(
    fusedData == Data([1, 0, 2, 10, 3, 20]),
    "Fusion ignored DICOM patient-space origins"
  )
}

private func testDICOMFusionTrilinearFiltering() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-dicom-trilinear-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let fusedURL = directory.appendingPathComponent("fused.raw")
  try Data([1, 2, 3]).write(to: referenceURL)
  try Data([0, 100]).write(to: movingURL)
  let orientation = DicomParser.DicomOrientation(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
  )

  func volume(
    url: URL,
    size: Vec3<Int>,
    spacing: Vec3<Float>
  ) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: spacing
      ),
      orientation: orientation,
      origin: .zero,
      frameOfReferenceUID: nil,
      channels: []
    )
  }

  let reference = volume(
    url: referenceURL,
    size: Vec3<Int>(x: 3, y: 1, z: 1),
    spacing: Vec3<Float>(x: 0.5, y: 1, z: 1)
  )
  let moving = volume(
    url: movingURL,
    size: Vec3<Int>(x: 2, y: 1, z: 1),
    spacing: Vec3<Float>(x: 1, y: 1, z: 1)
  )
  _ = try BorgVRDICOMVolumeFusion.fuse(
    reference: reference,
    moving: moving,
    referenceToMoving: BorgVRVoxelTransform(
      metricTransform: .identity,
      referenceSpacing: reference.source.voxelSpacing,
      movingSpacing: moving.source.voxelSpacing
    ),
    filter: .trilinear,
    outputURL: fusedURL,
    logger: nil,
    cancellationToken: nil
  )
  let fusedData = try Data(contentsOf: fusedURL)
  try expect(
    fusedData == Data([1, 0, 2, 50, 3, 100]),
    "Trilinear fusion did not interpolate the moving channel"
  )
}

private func testRegistrationDownsamplingHandlesAnisotropyAndOddSizes() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-registration-pyramid-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("source.raw")
  let size = Vec3<Int>(x: 5, y: 5, z: 3)
  var values = [UInt8](repeating: 10, count: size.x * size.y * size.z)
  values[(1 * size.y + 2) * size.x + 2] = 255
  try Data(values).write(to: sourceURL)

  let volume = BorgVRUnbrickedVolume(
    source: BorgVRRawVolumeSource(
      url: sourceURL,
      offset: 0,
      size: size,
      bytesPerComponent: 1,
      componentCount: 1,
      voxelSpacing: Vec3<Float>(x: 0.0005, y: 0.0005, z: 0.004)
    ),
    orientation: nil,
    origin: nil,
    frameOfReferenceUID: nil,
    channels: [BorgVRUnbrickedVolumeChannelMetadata(
      description: "Pyramid test",
      modality: nil,
      patientName: nil,
      seriesDate: nil,
      isSigned: false,
      pixelPaddingValue: 255
    )]
  )

  let sourceLevel = BorgVRRegistrationLevel(
    source: volume.source,
    isSigned: false,
    pixelPaddingValue: 255,
    temporaryURL: nil
  )
  let firstLevel = try BorgVRRegistrationDownsampler.downsample(
    sourceLevel,
    factors: Vec3<Int>(x: 2, y: 2, z: 1)
  )
  try expect(
    firstLevel.size == Vec3<Int>(x: 3, y: 3, z: 3),
    "Registration downsampling mishandled odd source dimensions"
  )
  try expect(
    firstLevel.source.voxelSpacing == Vec3<Float>(x: 0.001, y: 0.001, z: 0.004),
    "Registration downsampling changed spacing on an unreduced axis"
  )
  let firstAccessor = try RawFileAccessor(
    filename: firstLevel.source.url.path,
    size: firstLevel.size,
    bytesPerComponent: 1,
    componentCount: 1,
    voxelSpacing: firstLevel.source.voxelSpacing
  )
  let firstValues: [UInt8] = try firstAccessor.getData(
    x: 0,
    y: 0,
    z: 0,
    count: firstLevel.size.x * firstLevel.size.y * firstLevel.size.z
  )
  try expect(
    firstValues.allSatisfy { $0 == 10 },
    "DICOM padding contributed to registration samples"
  )

  let secondLevel = try BorgVRRegistrationDownsampler.downsample(
    firstLevel,
    factors: Vec3<Int>(x: 2, y: 2, z: 1)
  )
  try expect(
    secondLevel.size == Vec3<Int>(x: 2, y: 2, z: 3),
    "Registration downsampling did not reduce axes independently"
  )
}

private func testRegistrationDownsamplingPreservesPaddingOnlyRegions() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-registration-padding-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("padding.raw")
  try Data([UInt8](repeating: 7, count: 27)).write(to: sourceURL)
  let volume = BorgVRUnbrickedVolume(
    source: BorgVRRawVolumeSource(
      url: sourceURL,
      offset: 0,
      size: Vec3<Int>(x: 3, y: 3, z: 3),
      bytesPerComponent: 1,
      componentCount: 1,
      voxelSpacing: Vec3<Float>(x: 1, y: 1, z: 1)
    ),
    orientation: nil,
    origin: nil,
    frameOfReferenceUID: nil,
    channels: [BorgVRUnbrickedVolumeChannelMetadata(
      description: "Padding test",
      modality: nil,
      patientName: nil,
      seriesDate: nil,
      isSigned: false,
      pixelPaddingValue: 7
    )]
  )

  let level = try BorgVRRegistrationDownsampler.downsample(
    BorgVRRegistrationLevel(
      source: volume.source,
      isSigned: false,
      pixelPaddingValue: 7,
      temporaryURL: nil
    ),
    factors: Vec3<Int>(x: 2, y: 2, z: 2)
  )
  let accessor = try RawFileAccessor(
    filename: level.source.url.path,
    size: level.size,
    bytesPerComponent: 1,
    componentCount: 1,
    voxelSpacing: level.source.voxelSpacing
  )
  let downsampledValues: [UInt8] = try accessor.getData(
    x: 0,
    y: 0,
    z: 0,
    count: level.size.x * level.size.y * level.size.z
  )
  try expect(
    downsampledValues.allSatisfy { $0 == 7 },
    "Padding-only registration regions lost their padding value"
  )
}

private func testRegistrationDownsamplingPreservesSignedSamples() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-registration-signed-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("signed.raw")
  let input = [Int16(-100), Int16(-50), Int16(100)]
  try input.withUnsafeBytes { try Data($0).write(to: sourceURL) }
  let source = BorgVRRawVolumeSource(
    url: sourceURL,
    offset: 0,
    size: Vec3<Int>(x: 3, y: 1, z: 1),
    bytesPerComponent: 2,
    componentCount: 1,
    voxelSpacing: Vec3<Float>(x: 1, y: 1, z: 1)
  )
  let level = try BorgVRRegistrationDownsampler.downsample(
    BorgVRRegistrationLevel(
      source: source,
      isSigned: true,
      pixelPaddingValue: nil,
      temporaryURL: nil
    ),
    factors: Vec3<Int>(x: 2, y: 1, z: 1)
  )
  let accessor = try RawFileAccessor(
    filename: level.source.url.path,
    size: level.size,
    bytesPerComponent: 2,
    componentCount: 1,
    voxelSpacing: level.source.voxelSpacing
  )
  let values: [Int16] = try accessor.getData(x: 0, y: 0, z: 0, count: 2)
  try expect(
    values == [-75, 25],
    "Registration downsampling interpreted signed samples as unsigned"
  )
}

private func testRecursiveRegistrationPreservesDICOMInitialTransform() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-recursive-registration-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let size = Vec3<Int>(x: 65, y: 3, z: 3)
  let values = Data([UInt8](repeating: 10, count: size.x * size.y * size.z))
  try values.write(to: referenceURL)
  try values.write(to: movingURL)
  let orientation = DicomParser.DicomOrientation(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
  )

  func volume(url: URL, origin: Vec3<Float>) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: Vec3<Float>(x: 0.001, y: 0.002, z: 0.003)
      ),
      orientation: orientation,
      origin: origin,
      frameOfReferenceUID: "shared-frame",
      channels: []
    )
  }

  let transform = try BorgVRDICOMRigidRegistration.register(
    reference: volume(url: referenceURL, origin: Vec3<Float>(x: 0.1, y: 0.2, z: 0.3)),
    moving: volume(url: movingURL, origin: Vec3<Float>(x: 0.04, y: 0.1, z: 0.25)),
    logger: nil
  )
  let transformedOrigin = transform.applying(to: .zero)
  try expect(
    abs(transformedOrigin.x - 60) < 0.0001
      && abs(transformedOrigin.y - 50) < 0.0001
      && abs(transformedOrigin.z - (50.0 / 3.0)) < 0.0001,
    "Recursive registration did not preserve the DICOM initial transform"
  )
}

private func testVoxelTransformCombinesSpacingRotationAndTranslation() throws {
  let metricTransform = BorgVRRigidTransform(
    xAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    yAxis: Vec3<Float>(x: -1, y: 0, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1),
    translation: Vec3<Float>(x: 0.006, y: 0.01, z: -0.012)
  )
  let transform = BorgVRVoxelTransform(
    metricTransform: metricTransform,
    referenceSpacing: Vec3<Float>(x: 0.002, y: 0.004, z: 0.006),
    movingSpacing: Vec3<Float>(x: 0.001, y: 0.005, z: 0.003)
  )
  let result = transform.applying(to: Vec3<Float>(x: 2, y: 3, z: 4))
  try expect(
    abs(result.x + 6) < 0.0001
      && abs(result.y - 2.8) < 0.0001
      && abs(result.z - 4) < 0.0001,
    "Voxel transform did not combine spacing, rotation and translation correctly"
  )
}

private func testRegistrationCentersVolumesFromDifferentDICOMFrames() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-registration-frame-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let referenceSize = Vec3<Int>(x: 5, y: 3, z: 3)
  let movingSize = Vec3<Int>(x: 9, y: 5, z: 3)
  try Data(repeating: 10, count: referenceSize.x * referenceSize.y * referenceSize.z)
    .write(to: referenceURL)
  try Data(repeating: 10, count: movingSize.x * movingSize.y * movingSize.z)
    .write(to: movingURL)
  let orientation = DicomParser.DicomOrientation(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
  )

  func volume(
    url: URL,
    size: Vec3<Int>,
    spacing: Vec3<Float>,
    origin: Vec3<Float>,
    frame: String
  ) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: spacing
      ),
      orientation: orientation,
      origin: origin,
      frameOfReferenceUID: frame,
      channels: []
    )
  }

  let transform = try BorgVRDICOMRigidRegistration.register(
    reference: volume(
      url: referenceURL,
      size: referenceSize,
      spacing: Vec3<Float>(x: 0.002, y: 0.003, z: 0.004),
      origin: Vec3<Float>(x: -10, y: 20, z: -30),
      frame: "reference-frame"
    ),
    moving: volume(
      url: movingURL,
      size: movingSize,
      spacing: Vec3<Float>(x: 0.001, y: 0.002, z: 0.006),
      origin: Vec3<Float>(x: 100, y: -200, z: 300),
      frame: "moving-frame"
    ),
    logger: nil
  )
  let mappedCenter = transform.applying(to: Vec3<Float>(x: 2, y: 1, z: 1))
  try expect(
    (mappedCenter - Vec3<Float>(x: 4, y: 2, z: 1)).magnitude < 0.0001,
    "Registration used incomparable DICOM origins instead of aligning physical centers"
  )
}

private func testRegistrationRecoversTranslation() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-registration-optimization-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let size = Vec3<Int>(x: 25, y: 25, z: 25)
  var referenceValues = [UInt8](repeating: 0, count: size.x * size.y * size.z)
  var movingValues = referenceValues
  for z in 5..<20 {
    for y in 5..<20 {
      for x in 5..<18 {
        let value = UInt8(1 + (x * 17 + y * 31 + z * 47 + x * y * 3) % 240)
        referenceValues[(z * size.y + y) * size.x + x] = value
        movingValues[(z * size.y + y) * size.x + x + 2] = 241 - value
      }
    }
  }
  try Data(referenceValues).write(to: referenceURL)
  try Data(movingValues).write(to: movingURL)

  let orientation = DicomParser.DicomOrientation(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
  )
  let spacing = Vec3<Float>(x: 0.001, y: 0.001, z: 0.001)
  func volume(url: URL) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: spacing
      ),
      orientation: orientation,
      origin: .zero,
      frameOfReferenceUID: nil,
      channels: [BorgVRUnbrickedVolumeChannelMetadata(
        description: "Registration optimization test",
        modality: nil,
        patientName: nil,
        seriesDate: nil,
        isSigned: false,
        pixelPaddingValue: 0
      )]
    )
  }

  let transform = try BorgVRDICOMRigidRegistration.register(
    reference: volume(url: referenceURL),
    moving: volume(url: movingURL),
    logger: nil
  )
  let transformedOrigin = transform.applying(to: .zero)
  try expect(
    abs(transformedOrigin.x - 2) < 0.3,
    "NMI registration did not recover the known X translation"
  )
  try expect(
    abs(transformedOrigin.y) < 0.3 && abs(transformedOrigin.z) < 0.3,
    "NMI registration introduced an unexpected transverse translation"
  )
}

private func testSelfRegistrationHasPerfectMetricAndOverlap() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-self-registration-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("volume.raw")
  let size = Vec3<Int>(x: 33, y: 35, z: 37)
  var values = [UInt16]()
  values.reserveCapacity(size.x * size.y * size.z)
  for z in 0..<size.z {
    for y in 0..<size.y {
      for x in 0..<size.x {
        values.append(UInt16((x * 37 + y * 79 + z * 131 + x * y * 7) % 4096))
      }
    }
  }
  try values.withUnsafeBytes { try Data($0).write(to: sourceURL) }

  let volume = BorgVRUnbrickedVolume(
    source: BorgVRRawVolumeSource(
      url: sourceURL,
      offset: 0,
      size: size,
      bytesPerComponent: 2,
      componentCount: 1,
      voxelSpacing: Vec3<Float>(x: 0.0007, y: 0.0011, z: 0.0019)
    ),
    orientation: DicomParser.DicomOrientation(
      xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
      yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
      zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
    ),
    origin: .zero,
    frameOfReferenceUID: nil,
    channels: [BorgVRUnbrickedVolumeChannelMetadata(
      description: "Self-registration test",
      modality: nil,
      patientName: nil,
      seriesDate: nil,
      isSigned: false,
      pixelPaddingValue: nil
    )]
  )
  let logger = CapturingLogger()
  _ = try BorgVRDICOMRigidRegistration.register(
    reference: volume,
    moving: volume,
    logger: logger
  )

  let optimizationMessages = logger.infoMessages.filter {
    $0.contains("DICOM registration level optimized")
  }
  try expect(!optimizationMessages.isEmpty, "Self-registration produced no metric output")
  try expect(
    optimizationMessages.allSatisfy {
      $0.contains("NMI 2.000000 -> 2.000000")
        && $0.contains("overlap 100.0% -> 100.0%")
    },
    "Self-registration did not produce perfect NMI and overlap at every level"
  )
}

private func testRegistrationRecoversRotationAroundVolumeCenter() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-registration-rotation-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let referenceURL = directory.appendingPathComponent("reference.raw")
  let movingURL = directory.appendingPathComponent("moving.raw")
  let size = Vec3<Int>(x: 25, y: 25, z: 25)
  let center = Vec3<Double>(x: 12, y: 12, z: 12)
  let expectedAngle = 4.0 * Double.pi / 180
  let cosine = cos(expectedAngle)
  let sine = sin(expectedAngle)

  func intensity(x: Double, y: Double, z: Double) -> UInt8 {
    func gaussian(
      center: Vec3<Double>,
      width: Vec3<Double>,
      amplitude: Double
    ) -> Double {
      let dx = (x - center.x) / width.x
      let dy = (y - center.y) / width.y
      let dz = (z - center.z) / width.z
      return amplitude * exp(-(dx * dx + dy * dy + dz * dz))
    }
    let value = 5
      + gaussian(
        center: Vec3<Double>(x: 7, y: 10, z: 9),
        width: Vec3<Double>(x: 3, y: 5, z: 4),
        amplitude: 135
      )
      + gaussian(
        center: Vec3<Double>(x: 17, y: 15, z: 14),
        width: Vec3<Double>(x: 4, y: 2, z: 5),
        amplitude: 95
      )
      + gaussian(
        center: Vec3<Double>(x: 14, y: 6, z: 18),
        width: Vec3<Double>(x: 2, y: 3, z: 2),
        amplitude: 55
      )
    return UInt8(clamping: Int(value.rounded()))
  }

  var referenceValues = [UInt8]()
  var movingValues = [UInt8]()
  referenceValues.reserveCapacity(size.x * size.y * size.z)
  movingValues.reserveCapacity(size.x * size.y * size.z)
  for z in 0..<size.z {
    for y in 0..<size.y {
      for x in 0..<size.x {
        referenceValues.append(intensity(x: Double(x), y: Double(y), z: Double(z)))
        let dx = Double(x) - center.x
        let dy = Double(y) - center.y
        let referenceX = cosine * dx + sine * dy + center.x
        let referenceY = -sine * dx + cosine * dy + center.y
        movingValues.append(
          intensity(x: referenceX, y: referenceY, z: Double(z))
        )
      }
    }
  }
  try Data(referenceValues).write(to: referenceURL)
  try Data(movingValues).write(to: movingURL)

  let orientation = DicomParser.DicomOrientation(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1)
  )
  func volume(url: URL) -> BorgVRUnbrickedVolume {
    BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: url,
        offset: 0,
        size: size,
        bytesPerComponent: 1,
        componentCount: 1,
        voxelSpacing: Vec3<Float>(x: 0.001, y: 0.001, z: 0.001)
      ),
      orientation: orientation,
      origin: .zero,
      frameOfReferenceUID: nil,
      channels: [BorgVRUnbrickedVolumeChannelMetadata(
        description: "Registration rotation test",
        modality: nil,
        patientName: nil,
        seriesDate: nil,
        isSigned: false,
        pixelPaddingValue: nil
      )]
    )
  }

  let transform = try BorgVRDICOMRigidRegistration.register(
    reference: volume(url: referenceURL),
    moving: volume(url: movingURL),
    logger: nil
  )
  let recoveredAngle = atan2(Double(transform.xAxis.y), Double(transform.xAxis.x))
  try expect(
    abs(recoveredAngle - expectedAngle) < 1.5 * Double.pi / 180,
    "NMI registration did not recover the known Z rotation"
  )
  let voxelCenter = Vec3<Float>(x: 12, y: 12, z: 12)
  try expect(
    (transform.applying(to: voxelCenter) - voxelCenter).magnitude < 1,
    "Registration rotation did not preserve the volume center"
  )
}

@main
private enum VolumeConversionServiceTestRunner {
  static func main() async throws {
    if let directory = ProcessInfo.processInfo.environment["BORGVR_PROFILE_EDIT_STATE"],
       let dataset = ProcessInfo.processInfo.environment["BORGVR_PROFILE_DATASET"] {
      try profileExistingEditState(directory: URL(fileURLWithPath: directory), dataset: URL(fileURLWithPath: dataset))
      return
    }
    try await testRGBAEditing()
    try runAutoImporterTests()
    try testSettingsAndCancellation()
    try testVolumeQuantization()
    try runVolumeEditTests()
    try await runVolumeEditingAutomationTests()
    try await runVolumeEditCollaborationTests()
    try testRawConversionAndAtomicReplacement()
    try I3MParserTests.run()
    try testDICOMFusionInterleavesChannels()
    try testDICOMImportHistory()
    try testPhysicalSizeOverrides()
    try testNRRDProvenanceExport()
    try testNRRDChannelInterpretationRoundTrip()
    try testQVISColorImport()
    try testSupportingFileAccess()
    try testImageSequences()
    try testEmptyDICOMDirectory()
    try testIntegerVolumeSamplerHandlesInterpolationAndPadding()
    try testDICOMFusionTreatsMovingPaddingAsMissing()
    try testIsoSurfaceExtractionUsesUniqueCellsAndChannelMinimum()
    try testIsoSurfaceInterpolatesSampleGradients()
    try runIsoSurfaceEditTests()
    try testMarchingCubes33Cases()
    try testDICOMFusionUsesPatientGeometry()
    try testDICOMFusionTrilinearFiltering()
    try testRegistrationDownsamplingHandlesAnisotropyAndOddSizes()
    try testRegistrationDownsamplingPreservesPaddingOnlyRegions()
    try testRegistrationDownsamplingPreservesSignedSamples()
    try testRecursiveRegistrationPreservesDICOMInitialTransform()
    try testVoxelTransformCombinesSpacingRotationAndTranslation()
    try testRegistrationCentersVolumesFromDifferentDICOMFrames()
    try testSelfRegistrationHasPerfectMetricAndOverlap()
    try testRegistrationRecoversTranslation()
    try testRegistrationRecoversRotationAroundVolumeCenter()
    print("Volume conversion service tests passed")
  }
}
