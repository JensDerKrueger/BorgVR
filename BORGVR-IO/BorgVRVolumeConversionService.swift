import Foundation

public final class BorgVRVolumeConversionCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  public func checkCancellation() throws {
    if isCancelled {
      throw CancellationError()
    }
  }
}

public struct BorgVRVolumeConversionSettings: Sendable {
  public let brickSize: Int
  public let overlap: Int
  public let useCompression: Bool
  public let extensionStrategy: ExtensionStrategy

  public init(
    brickSize: Int,
    overlap: Int,
    useCompression: Bool,
    extensionStrategy: ExtensionStrategy
  ) {
    self.brickSize = brickSize
    self.overlap = overlap
    self.useCompression = useCompression
    self.extensionStrategy = extensionStrategy
  }

  public func validate() throws {
    guard brickSize > 0 else {
      throw BorgVRVolumeConversionError.invalidBrickSize(brickSize)
    }
    guard overlap >= 0, overlap <= (brickSize - 1) / 2 else {
      throw BorgVRVolumeConversionError.invalidOverlap(
        overlap: overlap,
        brickSize: brickSize
      )
    }
  }
}

public struct BorgVRRawVolumeSource: Sendable {
  public let url: URL
  public let offset: Int
  public let size: Vec3<Int>
  public let bytesPerComponent: Int
  public let componentCount: Int
  public let voxelSpacing: Vec3<Float>

  public init(
    url: URL,
    offset: Int,
    size: Vec3<Int>,
    bytesPerComponent: Int,
    componentCount: Int,
    voxelSpacing: Vec3<Float>
  ) {
    self.url = url
    self.offset = offset
    self.size = size
    self.bytesPerComponent = bytesPerComponent
    self.componentCount = componentCount
    self.voxelSpacing = voxelSpacing
  }
}

public enum BorgVRVolumeResamplingFilter: String, Sendable {
  case nearestNeighbor
  case trilinear
}

public enum BorgVRVolumeConversionSource: Sendable {
  case file(URL)
  case dicomDirectory(URL)
  case registeredDICOMPair(
    reference: URL,
    moving: URL,
    filter: BorgVRVolumeResamplingFilter
  )
  case raw(BorgVRRawVolumeSource)
}

struct BorgVRUnbrickedVolumeChannelMetadata: Sendable {
  let description: String
  let modality: String?
  let patientName: String?
  let seriesDate: String?
  let isSigned: Bool
  let pixelPaddingValue: Int32?
}

struct BorgVRUnbrickedVolume: Sendable {
  let source: BorgVRRawVolumeSource
  let orientation: DicomParser.DicomOrientation?
  let origin: Vec3<Float>?
  let frameOfReferenceUID: String?
  let channels: [BorgVRUnbrickedVolumeChannelMetadata]
}

enum BorgVRDICOMVolumeFusion {
  private struct WriteContext {
    let referenceAccessor: RawFileAccessor
    let movingAccessor: RawFileAccessor
    let movingSize: Vec3<Int>
    let movingPaddingValue: Int32?
    let referenceToMoving: BorgVRVoxelTransform
    let filter: BorgVRVolumeResamplingFilter
    let output: FileHandle
    let size: Vec3<Int>
    let bytesPerComponent: Int
    let outputSliceByteCount: Int
    let outputVoxelByteCount: Int
    let referenceSliceStride: Int
    let referenceRowStride: Int
    let logger: LoggerBase?
    let cancellationToken: BorgVRVolumeConversionCancellationToken?
  }

  static func fuse(
    reference: BorgVRUnbrickedVolume,
    moving: BorgVRUnbrickedVolume,
    referenceToMoving: BorgVRVoxelTransform,
    filter: BorgVRVolumeResamplingFilter,
    outputURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRUnbrickedVolume {
    guard reference.source.componentCount == 1,
          moving.source.componentCount == 1,
          reference.source.bytesPerComponent == moving.source.bytesPerComponent,
          [1, 2, 4].contains(reference.source.bytesPerComponent) else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    let usesPatientGeometry = reference.orientation != nil
      && reference.origin != nil
      && moving.orientation != nil
      && moving.origin != nil
    if !usesPatientGeometry && reference.source.size != moving.source.size {
      throw BorgVRVolumeConversionError.missingDICOMGeometryForFusion
    }

    let referenceAccessor = try RawFileAccessor(
      filename: reference.source.url.path,
      size: reference.source.size,
      bytesPerComponent: reference.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: reference.source.voxelSpacing,
      offset: reference.source.offset,
      readOnly: true
    )
    let movingAccessor = try RawFileAccessor(
      filename: moving.source.url.path,
      size: moving.source.size,
      bytesPerComponent: moving.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: moving.source.voxelSpacing,
      offset: moving.source.offset,
      readOnly: true
    )

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
      throw BorgVRVolumeConversionError.cannotCreateTemporaryVolume(outputURL)
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    let size = reference.source.size
    let bytesPerComponent = reference.source.bytesPerComponent
    let movingIsSigned = moving.channels.first?.isSigned ?? false
    let outputVoxelByteCount = try checkedProduct(bytesPerComponent, 2)
    let outputSliceByteCount = try checkedProduct(
      size.x, size.y, outputVoxelByteCount
    )
    let referenceSliceStride = try checkedProduct(size.x, size.y, bytesPerComponent)
    let referenceRowStride = try checkedProduct(size.x, bytesPerComponent)

    logger?.info("Fusing DICOM series into a two-channel intermediate volume.")
    let context = WriteContext(
      referenceAccessor: referenceAccessor,
      movingAccessor: movingAccessor,
      movingSize: moving.source.size,
      movingPaddingValue: moving.channels.first?.pixelPaddingValue,
      referenceToMoving: referenceToMoving,
      filter: filter,
      output: output,
      size: size,
      bytesPerComponent: bytesPerComponent,
      outputSliceByteCount: outputSliceByteCount,
      outputVoxelByteCount: outputVoxelByteCount,
      referenceSliceStride: referenceSliceStride,
      referenceRowStride: referenceRowStride,
      logger: logger,
      cancellationToken: cancellationToken
    )
    switch (bytesPerComponent, movingIsSigned) {
      case (1, false):
        try writeFusedVolume(movingType: UInt8.self, context: context)
      case (1, true):
        try writeFusedVolume(movingType: Int8.self, context: context)
      case (2, false):
        try writeFusedVolume(movingType: UInt16.self, context: context)
      case (2, true):
        try writeFusedVolume(movingType: Int16.self, context: context)
      case (4, false):
        try writeFusedVolume(movingType: UInt32.self, context: context)
      case (4, true):
        try writeFusedVolume(movingType: Int32.self, context: context)
      default:
        throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    return BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: outputURL,
        offset: 0,
        size: size,
        bytesPerComponent: bytesPerComponent,
        componentCount: 2,
        voxelSpacing: reference.source.voxelSpacing
      ),
      orientation: reference.orientation,
      origin: reference.origin,
      frameOfReferenceUID: reference.frameOfReferenceUID,
      channels: reference.channels + moving.channels
    )
  }

  private static func writeFusedVolume<MovingValue: FixedWidthInteger>(
    movingType: MovingValue.Type,
    context: WriteContext
  ) throws {
    _ = movingType
    guard context.movingAccessor.supportsAlignedTypedAccess,
          MemoryLayout<MovingValue>.size == context.bytesPerComponent else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }
    let sampler = BorgVRIntegerVolumeSampler(
      values: UnsafePointer(
        context.movingAccessor.mappedMemory.assumingMemoryBound(to: MovingValue.self)
      ),
      size: context.movingSize,
      paddingValue: context.movingPaddingValue.map { MovingValue(truncatingIfNeeded: $0) }
    )

    for z in 0..<context.size.z {
      try context.cancellationToken?.checkCancellation()
      var outputSlice = [UInt8](repeating: 0, count: context.outputSliceByteCount)
      for y in 0..<context.size.y {
        for x in 0..<context.size.x {
          let referenceOffset = z * context.referenceSliceStride
            + y * context.referenceRowStride + x * context.bytesPerComponent
          let movingCoordinate = continuousMovingVoxelCoordinate(
            forReference: Vec3<Int>(x: x, y: y, z: z),
            referenceToMoving: context.referenceToMoving
          )
          let outputOffset = (y * context.size.x + x) * context.outputVoxelByteCount
          for byte in 0..<context.bytesPerComponent {
            outputSlice[outputOffset + byte] = context.referenceAccessor.mappedMemory
              .load(fromByteOffset: referenceOffset + byte, as: UInt8.self)
          }
          guard let movingCoordinate else { continue }
          let movingValue: Double?
          switch context.filter {
            case .nearestNeighbor:
              movingValue = sampler.nearestNeighbor(at: movingCoordinate)
            case .trilinear:
              movingValue = sampler.trilinear(at: movingCoordinate)
          }
          if let movingValue {
            writeSample(
              movingValue,
              to: &outputSlice,
              at: outputOffset + context.bytesPerComponent,
              bytesPerComponent: context.bytesPerComponent,
              isSigned: MovingValue.isSigned
            )
          }
        }
      }
      try context.output.write(contentsOf: Data(outputSlice))
      context.logger?.progress(
        "Fusing DICOM volumes",
        Double(z + 1) / Double(context.size.z)
      )
    }
  }

  private static func continuousMovingVoxelCoordinate(
    forReference coordinate: Vec3<Int>,
    referenceToMoving: BorgVRVoxelTransform
  ) -> Vec3<Float>? {
    let floatingCoordinate = referenceToMoving.applying(
      to: Vec3<Float>(
        x: Float(coordinate.x),
        y: Float(coordinate.y),
        z: Float(coordinate.z)
      )
    )
    guard floatingCoordinate.x.isFinite,
          floatingCoordinate.y.isFinite,
          floatingCoordinate.z.isFinite else {
      return nil
    }
    return floatingCoordinate
  }

  private static func writeSample(
    _ value: Double,
    to data: inout [UInt8],
    at offset: Int,
    bytesPerComponent: Int,
    isSigned: Bool
  ) {
    let rounded: UInt64
    if isSigned {
      switch bytesPerComponent {
        case 1:
          rounded = UInt64(UInt8(bitPattern: Int8(clamping: Int64(value.rounded()))))
        case 2:
          rounded = UInt64(UInt16(bitPattern: Int16(clamping: Int64(value.rounded()))))
        case 4:
          rounded = UInt64(UInt32(bitPattern: Int32(clamping: Int64(value.rounded()))))
        default:
          return
      }
    } else {
      let maximum = Double(UInt64(1) << UInt64(bytesPerComponent * 8)) - 1
      rounded = UInt64(min(max(value.rounded(), 0), maximum))
    }
    for byte in 0..<bytesPerComponent {
      data[offset + byte] = UInt8(truncatingIfNeeded: rounded >> UInt64(byte * 8))
    }
  }

  private static func checkedProduct(_ values: Int...) throws -> Int {
    var result = 1
    for value in values {
      let next = result.multipliedReportingOverflow(by: value)
      guard value >= 0, !next.overflow else {
        throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
      }
      result = next.partialValue
    }
    return result
  }
}

public struct BorgVRVolumeConversionRequest: Sendable {
  public let source: BorgVRVolumeConversionSource
  public let destinationURL: URL
  public let datasetDescription: String
  public let metaDescription: String
  public let settings: BorgVRVolumeConversionSettings

  public init(
    source: BorgVRVolumeConversionSource,
    destinationURL: URL,
    datasetDescription: String,
    metaDescription: String,
    settings: BorgVRVolumeConversionSettings
  ) {
    self.source = source
    self.destinationURL = destinationURL
    self.datasetDescription = datasetDescription
    self.metaDescription = metaDescription
    self.settings = settings
  }
}

public enum BorgVRVolumeConversionError: LocalizedError {
  case invalidBrickSize(Int)
  case invalidOverlap(overlap: Int, brickSize: Int)
  case noDICOMFiles(URL)
  case incompatibleDICOMSampleFormats
  case missingDICOMGeometryForFusion
  case cannotCreateTemporaryVolume(URL)
  case invalidIntermediateVolumeSize

  public var errorDescription: String? {
    switch self {
      case .invalidBrickSize(let brickSize):
        return "Invalid brick size: \(brickSize)."
      case .invalidOverlap(let overlap, let brickSize):
        return "Invalid overlap \(overlap) for brick size \(brickSize)."
      case .noDICOMFiles(let url):
        return "The directory does not contain any DICOM files: \(url.path)"
      case .incompatibleDICOMSampleFormats:
        return "The DICOM series use incompatible sample formats."
      case .missingDICOMGeometryForFusion:
        return "The DICOM series have different grids and do not provide enough spatial geometry to fuse them."
      case .cannotCreateTemporaryVolume(let url):
        return "The temporary intermediate volume could not be created: \(url.path)"
      case .invalidIntermediateVolumeSize:
        return "The intermediate volume is too large to represent safely."
    }
  }
}

public enum BorgVRVolumeConversionService {
  public static func convert(
    _ request: BorgVRVolumeConversionRequest,
    logger: LoggerBase? = nil,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil
  ) throws {
    try request.settings.validate()
    try cancellationToken?.checkCancellation()

    let fileManager = FileManager.default
    let outputDirectory = request.destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    let stagedURL = outputDirectory.appendingPathComponent(
      ".\(request.destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
    defer { try? fileManager.removeItem(at: stagedURL) }

    switch request.source {
      case .file(let sourceURL):
        try convertFile(
          sourceURL,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
      case .dicomDirectory(let directoryURL):
        try convertDICOMDirectory(
          directoryURL,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
      case .registeredDICOMPair(let referenceURL, let movingURL, let filter):
        try convertRegisteredDICOMPair(
          referenceURL: referenceURL,
          movingURL: movingURL,
          filter: filter,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
      case .raw(let source):
        try convertRaw(
          source,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
    }

    try cancellationToken?.checkCancellation()
    try installStagedOutput(stagedURL, at: request.destinationURL)
  }

  private static func convertFile(
    _ sourceURL: URL,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let parser = try VolumeFileParserFactory.parser(for: sourceURL.path)
    defer {
      if parser.dataIsTempCopy {
        try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
      }
    }

    let rawURL = URL(fileURLWithPath: parser.absoluteFilename)
    let rawAccess = !parser.dataIsTempCopy && rawURL.startAccessingSecurityScopedResource()
    defer {
      if rawAccess {
        rawURL.stopAccessingSecurityScopedResource()
      }
    }

    try convertRaw(
      BorgVRRawVolumeSource(
        url: rawURL,
        offset: parser.offset,
        size: parser.size,
        bytesPerComponent: parser.bytesPerComponent,
        componentCount: parser.components,
        voxelSpacing: parser.voxelSpacing
      ),
      request: request,
      stagedURL: stagedURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
  }

  private static func convertDICOMDirectory(
    _ directoryURL: URL,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let volume = try decodeDICOMDirectory(
      directoryURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
    let temporaryURL = volume.source.url
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let effectiveRequest = BorgVRVolumeConversionRequest(
      source: request.source,
      destinationURL: request.destinationURL,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription.isEmpty
        ? volume.channels.map(\.description).joined(separator: " + ")
        : request.metaDescription,
      settings: request.settings
    )
    try convertRaw(
      volume.source,
      request: effectiveRequest,
      stagedURL: stagedURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
  }

  private static func convertRegisteredDICOMPair(
    referenceURL: URL,
    movingURL: URL,
    filter: BorgVRVolumeResamplingFilter,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let reference = try decodeDICOMDirectory(
      referenceURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
    defer { try? FileManager.default.removeItem(at: reference.source.url) }
    let moving = try decodeDICOMDirectory(
      movingURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
    defer { try? FileManager.default.removeItem(at: moving.source.url) }

    let transform = try BorgVRDICOMRigidRegistration.register(
      reference: reference,
      moving: moving,
      logger: logger,
      cancellationToken: cancellationToken
    )
    let fusedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-fused-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: fusedURL) }
    let fused = try BorgVRDICOMVolumeFusion.fuse(
      reference: reference,
      moving: moving,
      referenceToMoving: transform,
      filter: filter,
      outputURL: fusedURL,
      logger: logger,
      cancellationToken: cancellationToken
    )

    let effectiveRequest = BorgVRVolumeConversionRequest(
      source: request.source,
      destinationURL: request.destinationURL,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription.isEmpty
        ? fused.channels.map(\.description).joined(separator: " + ")
        : request.metaDescription,
      settings: request.settings
    )
    try convertRaw(
      fused.source,
      request: effectiveRequest,
      stagedURL: stagedURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
  }

  private static func decodeDICOMDirectory(
    _ directoryURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRUnbrickedVolume {
    let files = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    guard !files.isEmpty else {
      throw BorgVRVolumeConversionError.noDICOMFiles(directoryURL)
    }

    logger?.info(localized(
      "converter_log_info_scanning_dicom_dir",
      fallback: "Scanning DICOM directory"
    ))
    let volume = try DicomParser.decodeVolume(
      from: files,
      logger: logger,
      cancellationToken: cancellationToken
    )
    try cancellationToken?.checkCancellation()

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-dicom-\(UUID().uuidString).raw")
    do {
      try Data(volume.voxelData).write(to: temporaryURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
    return BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: temporaryURL,
        offset: 0,
        size: Vec3<Int>(x: volume.width, y: volume.height, z: volume.depth),
        bytesPerComponent: volume.bytesPerVoxel,
        componentCount: 1,
        voxelSpacing: Vec3<Float>(
          x: volume.voxelSpacing.x,
          y: volume.voxelSpacing.y,
          z: volume.voxelSpacing.z
        )
      ),
      orientation: volume.orientation,
      origin: volume.origin,
      frameOfReferenceUID: volume.frameOfReferenceUID,
      channels: [BorgVRUnbrickedVolumeChannelMetadata(
        description: dicomDescription(for: volume),
        modality: volume.modality,
        patientName: volume.patientName,
        seriesDate: volume.seriesDate,
        isSigned: volume.isSigned,
        pixelPaddingValue: volume.pixelPaddingValue
      )]
    )
  }

  private static func convertRaw(
    _ source: BorgVRRawVolumeSource,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    try cancellationToken?.checkCancellation()
    let volume = try RawFileAccessor(
      filename: source.url.path,
      size: source.size,
      bytesPerComponent: source.bytesPerComponent,
      componentCount: source.componentCount,
      voxelSpacing: source.voxelSpacing,
      offset: source.offset,
      readOnly: true
    )
    let reorganizer = BrickedVolumeReorganizer(
      inputVolume: volume,
      brickSize: request.settings.brickSize,
      overlap: request.settings.overlap,
      extensionStrategy: request.settings.extensionStrategy
    )
    try reorganizer.reorganize(
      to: stagedURL.path,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription,
      useCompressor: request.settings.useCompression,
      logger: logger,
      cancellationToken: cancellationToken
    )
  }

  private static func installStagedOutput(_ stagedURL: URL, at destinationURL: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: stagedURL,
        backupItemName: nil,
        options: []
      )
    } else {
      try fileManager.moveItem(at: stagedURL, to: destinationURL)
    }
  }

  private static func dicomDescription(for volume: DicomParser.DicomVolume) -> String {
    var parts = [volume.modality.map { "\($0) scan" } ?? "Scan"]
    if let patientName = volume.patientName {
      parts.append("of \(patientName)")
    }
    if let seriesDate = volume.seriesDate {
      parts.append("at \(seriesDate)")
    }
    return parts.joined(separator: " ").replacingOccurrences(of: "^", with: ", ")
  }

  private static func localized(_ key: String, fallback: String) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
  }
}
