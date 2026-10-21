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
    let movingSliceStride = try checkedProduct(
      moving.source.size.x, moving.source.size.y, bytesPerComponent
    )
    let movingRowStride = try checkedProduct(moving.source.size.x, bytesPerComponent)

    logger?.info("Fusing DICOM series into a two-channel intermediate volume.")
    for z in 0..<size.z {
      try cancellationToken?.checkCancellation()
      var outputSlice = [UInt8](repeating: 0, count: outputSliceByteCount)
      for y in 0..<size.y {
        for x in 0..<size.x {
          let referenceOffset = z * referenceSliceStride + y * referenceRowStride
            + x * bytesPerComponent
          let movingCoordinate = continuousMovingVoxelCoordinate(
            forReference: Vec3<Int>(x: x, y: y, z: z),
            referenceToMoving: referenceToMoving
          )
          let outputOffset = (y * size.x + x) * outputVoxelByteCount
          for byte in 0..<bytesPerComponent {
            outputSlice[outputOffset + byte] = referenceAccessor.mappedMemory
              .load(fromByteOffset: referenceOffset + byte, as: UInt8.self)
          }
          if let movingCoordinate,
             let movingValue = sampleMovingVolume(
               accessor: movingAccessor,
               coordinate: movingCoordinate,
               size: moving.source.size,
               bytesPerComponent: bytesPerComponent,
               sliceStride: movingSliceStride,
               rowStride: movingRowStride,
               isSigned: movingIsSigned,
               filter: filter
             ) {
            writeSample(
              movingValue,
              to: &outputSlice,
              at: outputOffset + bytesPerComponent,
              bytesPerComponent: bytesPerComponent,
              isSigned: movingIsSigned
            )
          }
        }
      }
      try output.write(contentsOf: Data(outputSlice))
      logger?.progress("Fusing DICOM volumes", Double(z + 1) / Double(size.z))
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

  private static func sampleMovingVolume(
    accessor: RawFileAccessor,
    coordinate: Vec3<Float>,
    size: Vec3<Int>,
    bytesPerComponent: Int,
    sliceStride: Int,
    rowStride: Int,
    isSigned: Bool,
    filter: BorgVRVolumeResamplingFilter
  ) -> Double? {
    switch filter {
      case .nearestNeighbor:
        guard let x = Int(exactly: coordinate.x.rounded()),
              let y = Int(exactly: coordinate.y.rounded()),
              let z = Int(exactly: coordinate.z.rounded()),
              (0..<size.x).contains(x),
              (0..<size.y).contains(y),
              (0..<size.z).contains(z) else {
          return nil
        }
        return readSample(
          from: accessor.mappedMemory,
          at: z * sliceStride + y * rowStride + x * bytesPerComponent,
          bytesPerComponent: bytesPerComponent,
          isSigned: isSigned
        )
      case .trilinear:
        guard coordinate.x >= 0, coordinate.x <= Float(size.x - 1),
              coordinate.y >= 0, coordinate.y <= Float(size.y - 1),
              coordinate.z >= 0, coordinate.z <= Float(size.z - 1) else {
          return nil
        }
        let x0 = Int(coordinate.x.rounded(.down))
        let y0 = Int(coordinate.y.rounded(.down))
        let z0 = Int(coordinate.z.rounded(.down))
        let x1 = min(x0 + 1, size.x - 1)
        let y1 = min(y0 + 1, size.y - 1)
        let z1 = min(z0 + 1, size.z - 1)
        let tx = Double(coordinate.x - Float(x0))
        let ty = Double(coordinate.y - Float(y0))
        let tz = Double(coordinate.z - Float(z0))

        func sample(_ x: Int, _ y: Int, _ z: Int) -> Double {
          readSample(
            from: accessor.mappedMemory,
            at: z * sliceStride + y * rowStride + x * bytesPerComponent,
            bytesPerComponent: bytesPerComponent,
            isSigned: isSigned
          )
        }
        let c00 = sample(x0, y0, z0) * (1 - tx) + sample(x1, y0, z0) * tx
        let c10 = sample(x0, y1, z0) * (1 - tx) + sample(x1, y1, z0) * tx
        let c01 = sample(x0, y0, z1) * (1 - tx) + sample(x1, y0, z1) * tx
        let c11 = sample(x0, y1, z1) * (1 - tx) + sample(x1, y1, z1) * tx
        let c0 = c00 * (1 - ty) + c10 * ty
        let c1 = c01 * (1 - ty) + c11 * ty
        return c0 * (1 - tz) + c1 * tz
    }
  }

  private static func readSample(
    from pointer: UnsafeMutableRawPointer,
    at offset: Int,
    bytesPerComponent: Int,
    isSigned: Bool
  ) -> Double {
    if isSigned {
      switch bytesPerComponent {
        case 1:
          return Double(pointer.load(fromByteOffset: offset, as: Int8.self))
        case 2:
          return Double(pointer.load(fromByteOffset: offset, as: Int16.self))
        case 4:
          return Double(pointer.load(fromByteOffset: offset, as: Int32.self))
        default:
          return 0
      }
    }
    var value: UInt32 = 0
    for byte in 0..<bytesPerComponent {
      let part = UInt32(pointer.load(fromByteOffset: offset + byte, as: UInt8.self))
      value |= part << UInt32(byte * 8)
    }
    return Double(value)
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
