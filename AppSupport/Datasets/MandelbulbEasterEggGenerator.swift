import Foundation

struct MandelbulbEasterEggTrigger {
  private var taps: [TimeInterval] = []

  mutating func tap(at time: TimeInterval) -> Bool {
    taps.removeAll { time - $0 > 2 || $0 > time }
    taps.append(time)
    guard taps.count == 4 else { return false }
    taps.removeAll()
    return true
  }
}

enum MandelbulbEasterEggSize: Int, CaseIterable, Identifiable {
  case small = 512
  case medium = 1024
  case large = 2048
  case huge = 4096

  var id: Int { rawValue }
  var title: String {
    switch self {
      case .small: String(localized: "mandelbulb_size_small")
      case .medium: String(localized: "mandelbulb_size_medium")
      case .large: String(localized: "mandelbulb_size_large")
      case .huge: String(localized: "mandelbulb_size_huge")
    }
  }

  var storage: MandelbulbStorageRequirement {
    // Calibrated on 2026-11-11: power 8, UInt8, 32^3 bricks, overlap 2, zero borders, LZ4.
    switch self {
      case .small: MandelbulbStorageRequirement(rawBytes: 134_217_728,
        hierarchyBytes: 19_173_376, compressedBytes: 28_561_103)
      case .medium: MandelbulbStorageRequirement(rawBytes: 1_073_741_824,
        hierarchyBytes: 153_391_104, compressedBytes: 177_568_362)
      case .large: MandelbulbStorageRequirement(rawBytes: 8_589_934_592,
        hierarchyBytes: 1_227_132_928, compressedBytes: 1_138_115_376)
      case .huge: MandelbulbStorageRequirement(rawBytes: 68_719_476_736,
        hierarchyBytes: 9_817_067_520, compressedBytes: 7_507_204_431)
    }
  }
}

struct MandelbulbStorageRequirement {
  let rawBytes: Int64
  let hierarchyBytes: Int64
  let compressedBytes: Int64

  var totalBytes: Int64 { rawBytes + hierarchyBytes + compressedBytes }
  var requiredBytes: Int64 { Self.withReserve(totalBytes) }

  static func withReserve(_ bytes: Int64) -> Int64 {
    bytes + max(64 * 1024 * 1024, bytes / 5)
  }

  static func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  enum SpaceError: LocalizedError {
    case insufficient(URL, required: Int64, available: Int64)
    case unavailable(URL)
    var errorDescription: String? {
      switch self {
        case .insufficient(let url, let required, let available):
          String(format: String(localized: "mandelbulb_insufficient_space_format"),
            url.path, MandelbulbStorageRequirement.formatted(required),
            MandelbulbStorageRequirement.formatted(available))
        case .unavailable(let url):
          String(format: String(localized: "mandelbulb_space_unavailable_format"), url.path)
      }
    }
  }

  static func validateCapacity(available: Int64, required: Int64, at directory: URL) throws {
    guard available >= required else {
      throw SpaceError.insufficient(directory, required: required, available: available)
    }
  }

  func checkSpace(in directory: URL) throws {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = files.temporaryDirectory
    let destination = try files.attributesOfFileSystem(forPath: directory.path)
    let source = try files.attributesOfFileSystem(forPath: temporary.path)
    guard let destinationFree = destination[.systemFreeSize] as? NSNumber,
          let sourceFree = source[.systemFreeSize] as? NSNumber,
          let destinationID = destination[.systemNumber] as? NSNumber,
          let sourceID = source[.systemNumber] as? NSNumber else {
      throw SpaceError.unavailable(directory)
    }
    if destinationID == sourceID {
      try Self.validateCapacity(available: min(destinationFree.int64Value, sourceFree.int64Value),
        required: requiredBytes, at: directory)
    } else {
      try Self.validateCapacity(available: sourceFree.int64Value,
        required: Self.withReserve(rawBytes + hierarchyBytes), at: temporary)
      try Self.validateCapacity(available: destinationFree.int64Value,
        required: Self.withReserve(compressedBytes), at: directory)
    }
  }
}

enum MandelbulbEasterEggGenerator {
  static let settings = BorgVRVolumeConversionSettings(brickSize: 32, overlap: 2,
    useCompression: true, extensionStrategy: .fillZeroes)
  enum Phase: Sendable {
    case generating, converting
  }

  static func generate(resolution: Int, directory: URL,
    logger: LoggerBase? = nil,
    cancellationToken: BorgVRVolumeConversionCancellationToken,
    progress: @escaping @Sendable (Phase, String, Double) -> Void = { _, _, _ in }
  ) throws -> URL {
    guard (2...4096).contains(resolution) else {
      throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
    }
    try settings.validate()
    try cancellationToken.checkCancellation()
    let access = directory.startAccessingSecurityScopedResource()
    defer { if access { directory.stopAccessingSecurityScopedResource() } }
    if let size = MandelbulbEasterEggSize(rawValue: resolution) {
      try size.storage.checkSpace(in: directory)
    }
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("borgvr-mandelbulb-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }
    let raw = temporary.appendingPathComponent("mandelbulb.raw")
    let destination = directory.appendingPathComponent("Mandelbulb-\(resolution)-\(UUID().uuidString).data")
    let generationLogger = ProgressLogger(base: logger, phase: .generating, progress: progress)
    progress(.generating, "", 0)
    _ = try computeMandelbulbFloat(filename: raw.path,
      sizeX: resolution, sizeY: resolution, sizeZ: resolution, bytesPerVoxel: 1,
      logger: generationLogger, checkCancellation: { try cancellationToken.checkCancellation() })
    try cancellationToken.checkCancellation()
    progress(.converting, "", 0)
    try BorgVRVolumeConversionService.convert(BorgVRVolumeConversionRequest(
      source: .raw(BorgVRRawVolumeSource(url: raw, offset: 0,
        size: Vec3(repeating: resolution), bytesPerComponent: 1, componentCount: 1,
        voxelSpacing: Vec3(repeating: 1 / Float(resolution)))),
      destinationURL: destination, datasetDescription: "Mandelbulb Easter Egg",
      metaDescription: "Mandelbulb Easter Egg", settings: settings,
      provenance: [BORGVRProvenanceEntry(MandelbulbParameters.provenanceDescription(
        bytesPerVoxel: 1, doublePrecision: false))]),
      logger: ProgressLogger(base: logger, phase: .converting, progress: progress),
      cancellationToken: cancellationToken)
    return destination
  }

  private final class ProgressLogger: LoggerBase {
    let base: LoggerBase?
    let phase: Phase
    let update: @Sendable (Phase, String, Double) -> Void
    private var lastUpdate: TimeInterval = 0
    private var lastMessage = ""
    private var lastValue = 0.0

    init(base: LoggerBase?, phase: Phase, progress: @escaping @Sendable (Phase, String, Double) -> Void) {
      self.base = base
      self.phase = phase
      update = progress
    }
    func dev(_ message: String) { base?.dev(message) }
    func info(_ message: String) { base?.info(message) }
    func warning(_ message: String) { base?.warning(message) }
    func error(_ message: String) { base?.error(message) }
    func setMinimumLogLevel(_ level: LogLevel) { base?.setMinimumLogLevel(level) }
    func progress(_ message: String, _ value: Double) {
      let now = ProcessInfo.processInfo.systemUptime
      let changedStep = message != lastMessage || value < lastValue
      lastMessage = message
      lastValue = value
      guard changedStep || now - lastUpdate >= 0.1 || value >= 1 else { return }
      lastUpdate = now
      update(phase, message, min(max(value, 0), 1))
    }
  }
}
