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
      channels: []
    )
  }

  _ = try BorgVRDICOMVolumeFusion.fuse(
    reference: volume(
      url: referenceURL,
      size: Vec3<Int>(x: 3, y: 1, z: 1),
      spacing: Vec3<Float>(x: 0.5, y: 1, z: 1)
    ),
    moving: volume(
      url: movingURL,
      size: Vec3<Int>(x: 2, y: 1, z: 1),
      spacing: Vec3<Float>(x: 1, y: 1, z: 1)
    ),
    referenceToMoving: .identity,
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
    abs(transformedOrigin.x - 0.06) < 0.0001
      && abs(transformedOrigin.y - 0.1) < 0.0001
      && abs(transformedOrigin.z - 0.05) < 0.0001,
    "Recursive registration did not preserve the DICOM initial transform"
  )
}

@main
private enum VolumeConversionServiceTestRunner {
  static func main() throws {
    try testSettingsAndCancellation()
    try testRawConversionAndAtomicReplacement()
    try testDICOMFusionInterleavesChannels()
    try testDICOMFusionUsesPatientGeometry()
    try testDICOMFusionTrilinearFiltering()
    try testRegistrationDownsamplingHandlesAnisotropyAndOddSizes()
    try testRegistrationDownsamplingPreservesPaddingOnlyRegions()
    try testRegistrationDownsamplingPreservesSignedSamples()
    try testRecursiveRegistrationPreservesDICOMInitialTransform()
    print("Volume conversion service tests passed")
  }
}
