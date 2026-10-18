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

public enum BorgVRVolumeConversionSource: Sendable {
  case file(URL)
  case dicomDirectory(URL)
  case raw(BorgVRRawVolumeSource)
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

  public var errorDescription: String? {
    switch self {
      case .invalidBrickSize(let brickSize):
        return "Invalid brick size: \(brickSize)."
      case .invalidOverlap(let overlap, let brickSize):
        return "Invalid overlap \(overlap) for brick size \(brickSize)."
      case .noDICOMFiles(let url):
        return "The directory does not contain any DICOM files: \(url.path)"
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
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try volume.voxelData.withUnsafeBytes { bytes in
      try Data(bytes).write(to: temporaryURL)
    }

    let effectiveRequest = BorgVRVolumeConversionRequest(
      source: request.source,
      destinationURL: request.destinationURL,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription.isEmpty
        ? dicomDescription(for: volume)
        : request.metaDescription,
      settings: request.settings
    )
    try convertRaw(
      BorgVRRawVolumeSource(
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
      request: effectiveRequest,
      stagedURL: stagedURL,
      logger: logger,
      cancellationToken: cancellationToken
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
