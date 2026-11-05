import Foundation
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum BorgVRMCPDefaults {
  static let port = 8765
  static let enabled = false
  static let allowRemoteConnections = false
  static let accessToken = ""
}

struct BorgVRMCPConfiguration: Equatable, Sendable {
  var enabled: Bool
  var port: Int
  var allowRemoteConnections: Bool
  var accessToken: String
  var tlsCertificateData: Data = Data()
  var tlsCertificatePassword: String = ""

  var normalizedPort: UInt16 {
    UInt16(clamping: min(max(port, 1), 65_535))
  }

  var usesTLS: Bool {
    allowRemoteConnections
  }

  var scheme: String {
    usesTLS ? "https" : "http"
  }

  func hasSameListenerConfiguration(as other: Self) -> Bool {
    enabled == other.enabled
      && normalizedPort == other.normalizedPort
      && allowRemoteConnections == other.allowRemoteConnections
      && tlsCertificateData == other.tlsCertificateData
      && tlsCertificatePassword == other.tlsCertificatePassword
  }
}

struct BorgVRMCPDatasetState: Codable, Sendable {
  var id: String
  var description: String
  var dimensions: [Int]?
  var physicalExtentMeters: [Float]?
}

struct BorgVRMCPDatasetMetadata: Codable, Sendable {
  var longDescription: String
  var dimensions: [Int]
  var voxelSpacingMeters: [Float]
  var physicalExtentMeters: [Float]
  var componentCount: Int
  var bytesPerComponent: Int
  var bitsPerComponent: Int
  var valueRange: [Double]
  var componentRanges: [[Double]]
  var valueType: String
  var channelInterpretation: String
  var provenance: [BORGVRProvenanceEntry]
  var meta: String
  var brickSize: Int
  var overlap: Int
  var levelCount: Int
  var brickCount: Int
  var compressed: Bool

  init(_ metadata: BORGVRMetaData) {
    longDescription = metadata.metaDescription
    dimensions = [metadata.width, metadata.height, metadata.depth]
    voxelSpacingMeters = [
      metadata.voxelSpacingX,
      metadata.voxelSpacingY,
      metadata.voxelSpacingZ
    ]
    physicalExtentMeters = metadata.physicalExtentMeters.mcpArray
    componentCount = metadata.componentCount
    bytesPerComponent = metadata.bytesPerComponent
    bitsPerComponent = metadata.bytesPerComponent * 8
    valueRange = [metadata.valueRange.minimum, metadata.valueRange.maximum]
    componentRanges = metadata.componentRanges.map { [$0.minimum, $0.maximum] }
    valueType = metadata.componentType.valueTypeName
    channelInterpretation = metadata.channelInterpretation.name
    provenance = metadata.provenance
    meta = metadata.meta
    brickSize = metadata.brickSize
    overlap = metadata.overlap
    levelCount = metadata.levelMetadata.count
    brickCount = metadata.brickMetadata.count
    compressed = metadata.compression
  }
}

struct BorgVRMCPDatasetSource: Codable, Equatable, Sendable {
  var kind: String
  var address: String?
  var port: Int?
  var passwordProtected: Bool
}

struct BorgVRMCPDatasetCatalogEntry: Codable, Sendable {
  var id: String
  var description: String
  var metadata: BorgVRMCPDatasetMetadata?
  var metadataError: String?
  var sources: [BorgVRMCPDatasetSource]
}

enum BorgVRMCPDatasetLocation: Sendable {
  case local(URL)
  case builtIn(URL)
  case remote(address: String, port: Int, password: String)

  var source: BorgVRMCPDatasetSource {
    switch self {
      case .local:
        return BorgVRMCPDatasetSource(
          kind: "local", address: nil, port: nil, passwordProtected: false
        )
      case .builtIn:
        return BorgVRMCPDatasetSource(
          kind: "built_in", address: nil, port: nil, passwordProtected: false
        )
      case .remote(let address, let port, let password):
        return BorgVRMCPDatasetSource(
          kind: "remote",
          address: address,
          port: port,
          passwordProtected: !password.isEmpty
        )
    }
  }

  fileprivate var priority: Int {
    switch self {
      case .local: 0
      case .builtIn: 1
      case .remote: 2
    }
  }
}

struct BorgVRMCPDatasetRecord: Sendable {
  var catalogEntry: BorgVRMCPDatasetCatalogEntry
  var preferredLocation: BorgVRMCPDatasetLocation
}

enum BorgVRMCPDatasetCatalog {
  static func load(
    localDirectory: URL?,
    servers: [StoredServer],
    timeout: TimeInterval
  ) async -> [BorgVRMCPDatasetRecord] {
    await Task.detached(priority: .userInitiated) {
      var records: [String: BorgVRMCPDatasetRecord] = [:]

      if let localDirectory {
        let urls = (try? FileManager.default.contentsOfDirectory(
          at: localDirectory,
          includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == "data" {
          addLocalDataset(at: url, location: .local(url), to: &records)
        }
      }

      for url in Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) ?? [] {
        addLocalDataset(at: url, location: .builtIn(url), to: &records)
      }

      for server in servers where server.isEnabled && !server.address.isEmpty {
        let location = BorgVRMCPDatasetLocation.remote(
          address: server.address,
          port: server.port,
          password: server.password
        )
        do {
          let manager = BORGVRRemoteDataManager(
            host: server.address,
            port: UInt16(clamping: server.port),
            authSecret: server.password,
            logger: nil
          )
          try manager.connect(timeout: timeout)
          let datasets = try manager.requestDatasetList()
          for dataset in datasets {
            if var record = records[dataset.id] {
              appendSource(location.source, to: &record.catalogEntry.sources)
              if location.priority < record.preferredLocation.priority {
                record.preferredLocation = location
              }
              records[dataset.id] = record
              continue
            }

            do {
              let metadataManager = BORGVRRemoteDataManager(
                host: server.address,
                port: UInt16(clamping: server.port),
                authSecret: server.password,
                logger: nil
              )
              try metadataManager.connect(timeout: timeout)
              let remoteData = try metadataManager.openDataset(
                datasetID: dataset.id,
                timeout: timeout
              )
              let metadata = remoteData.getMetadata()
              records[dataset.id] = BorgVRMCPDatasetRecord(
                catalogEntry: BorgVRMCPDatasetCatalogEntry(
                  id: dataset.id,
                  description: dataset.description,
                  metadata: BorgVRMCPDatasetMetadata(metadata),
                  metadataError: nil,
                  sources: [location.source]
                ),
                preferredLocation: location
              )
            } catch {
              records[dataset.id] = BorgVRMCPDatasetRecord(
                catalogEntry: BorgVRMCPDatasetCatalogEntry(
                  id: dataset.id,
                  description: dataset.description,
                  metadata: nil,
                  metadataError: error.localizedDescription,
                  sources: [location.source]
                ),
                preferredLocation: location
              )
            }
          }
        } catch {
          continue
        }
      }

      return records.values.sorted {
        $0.catalogEntry.description.localizedCaseInsensitiveCompare(
          $1.catalogEntry.description
        ) == .orderedAscending
      }
    }.value
  }

  private static func addLocalDataset(
    at url: URL,
    location: BorgVRMCPDatasetLocation,
    to records: inout [String: BorgVRMCPDatasetRecord]
  ) {
    guard let metadata = try? BORGVRMetaData(url: url) else { return }
    let source = location.source
    if var record = records[metadata.uniqueID] {
      appendSource(source, to: &record.catalogEntry.sources)
      if location.priority < record.preferredLocation.priority {
        record.preferredLocation = location
      }
      records[metadata.uniqueID] = record
      return
    }
    records[metadata.uniqueID] = BorgVRMCPDatasetRecord(
      catalogEntry: BorgVRMCPDatasetCatalogEntry(
        id: metadata.uniqueID,
        description: metadata.datasetDescription,
        metadata: BorgVRMCPDatasetMetadata(metadata),
        metadataError: nil,
        sources: [source]
      ),
      preferredLocation: location
    )
  }

  private static func appendSource(
    _ source: BorgVRMCPDatasetSource,
    to sources: inout [BorgVRMCPDatasetSource]
  ) {
    guard !sources.contains(source) else { return }
    sources.append(source)
  }
}

struct BorgVRMCPTransformState: Codable, Sendable {
  var rotation: [Float]
  var translation: [Float]
  var scale: [Float]
}

struct BorgVRMCPLightingState: Codable, Sendable {
  var direction: [Float]
  var ambient: [Float]
  var diffuse: [Float]
  var specular: [Float]
}

struct BorgVRMCPAnnotationVisibilityState: Codable, Sendable {
  var objects: Bool
  var measurements: Bool
}

struct BorgVRMCPRenderingOptions: Codable, Sendable {
  var brickVisualizationEnabled: Bool
  var residentBricksVisible: Bool
  var emptyBricksVisible: Bool
  var missingBricksVisible: Bool
  var subbrickSkipping: Bool
  var opacityAdaptiveSampling: Bool
  var alphaEpsilon: Float
  var screenFieldOfViewDegrees: Float? = nil
  var parallelProjection: Bool? = nil
  var datasetBoundingBoxVisible: Bool = false
}

struct BorgVRMCPApplicationState: Codable, Sendable {
  var applicationVersion: String
  var platform: String
  var dataset: BorgVRMCPDatasetState?
  var rendererReady: Bool
  var completedFrame: UInt64
  var renderMode: String
  var normalizedIsoValue: Float
  var transform: BorgVRMCPTransformState
  var clipMinimum: [Float]
  var clipMaximum: [Float]
  var lighting: BorgVRMCPLightingState
  var annotationVisibility: BorgVRMCPAnnotationVisibilityState
  var objectCount: Int
  var measurementCount: Int
  var renderingOptions: BorgVRMCPRenderingOptions
  var volumeEditing: BorgVRVolumeEditingState? = nil
  var transferFunctionCount: Int = 0
  var background: BorgVRMCPBackgroundState? = nil
}

struct BorgVRMCPImage: Sendable {
  var pngData: Data
  var width: Int
  var height: Int
  var renderedFrame: UInt64
}

struct BorgVRMCPIsoSurfaceExport: Codable, Sendable {
  var outputPath: String
  var vertexCount: Int
  var triangleCount: Int
  var normalizedIsoValue: Float
}

enum BorgVRMCPResetScope: String, CaseIterable, Sendable {
  case all
  case transform
  case clipping
  case transferFunction = "transfer_function"
  case lighting
}

enum BorgVRMCPCommandError: LocalizedError {
  case invalidArgument(String)
  case noDataset
  case rendererUnavailable
  case isoSurfaceUnavailable
  case screenshotUnavailable
  case timeout
  case unsupported(String)
  case datasetNotFound(String)

  var errorDescription: String? {
    switch self {
      case .invalidArgument(let message): return message
      case .noDataset: return "No dataset is open."
      case .rendererUnavailable: return "The renderer is not available."
      case .isoSurfaceUnavailable: return "Isosurface extraction is not available."
      case .screenshotUnavailable: return "Screenshot capture is not available."
      case .timeout: return "The renderer did not finish before the timeout."
      case .unsupported(let message): return message
      case .datasetNotFound(let id): return "No dataset with ID '\(id)' was found."
    }
  }
}

final class BorgVRMCPContinuationGate<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  func resume(with result: Result<Value, Error>) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

@MainActor
protocol BorgVRMCPCommandService: AnyObject {
  var windowAutomation: (any BorgVRWindowAutomation)? { get }
  var volumeEditing: any BorgVRVolumeEditingCommands { get }
  func activateVolumeEditing()
  func listDatasets() async throws -> [BorgVRMCPDatasetCatalogEntry]
  func openDataset(id: String) async throws
  func closeDataset() async throws
  func applicationState() -> BorgVRMCPApplicationState
  func setRenderMode(_ mode: String) throws
  var transferFunctionCount: Int { get }
  func settingsStore() -> BorgVRSettingsStore
  func transferFunction(channel: Int) throws -> BorgVRMCPTransferFunction
  func setTransferFunction(_ value: BorgVRMCPTransferFunction) throws
  func background() -> BorgVRMCPBackgroundState
  func setBackground(_ value: BorgVRMCPBackgroundState) throws
  func datasetViewStateData() throws -> Data
  func restoreDatasetViewState(_ data: Data) throws
  func setBrickVisualization(enabled: Bool?, resident: Bool?, empty: Bool?, missing: Bool?) throws
  func setRenderOptimizations(subbrickSkipping: Bool?, opacityAdaptiveSampling: Bool?, alphaEpsilon: Float?) throws
  func setScreenProjection(fieldOfView: Float?, parallel: Bool?) throws
  func setBoundingBox(visible: Bool) throws
  func setTransform(
    rotation: SIMD4<Float>?,
    translation: SIMD3<Float>?,
    scale: SIMD3<Float>?
  ) throws
  func rotate(axis: SIMD3<Float>, degrees: Float) throws
  func setNormalizedIsoValue(_ value: Float) throws
  func setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) throws
  func setLighting(
    direction: SIMD3<Float>?,
    ambient: SIMD3<Float>?,
    diffuse: SIMD3<Float>?,
    specular: SIMD3<Float>?
  ) throws
  func setAnnotationVisibility(objects: Bool?, measurements: Bool?) throws
  func listMeshAssets() -> [BorgVRMeshAssetCommandState]
  func listObjects() -> [BorgVRObjectCommandState]
  func upsertObject(_ object: BorgVRObjectCommandState) throws
  func removeObject(id: UUID) throws
  func clearObjects() throws
  func listMeasurements() -> [BorgVRMeasurementCommandState]
  func upsertMeasurement(_ measurement: BorgVRMeasurementCommandState) throws
  func removeMeasurement(id: UUID) throws
  func clearMeasurements() throws
  func reset(_ scope: BorgVRMCPResetScope) throws
  func waitUntilRendered(after frame: UInt64, timeout: TimeInterval) async throws
  func exportIsoSurface(
    to outputURL: URL,
    normalizedIsoValue: Float?
  ) async throws -> BorgVRMCPIsoSurfaceExport
  func captureScreenshot(includeAlpha: Bool) async throws -> BorgVRMCPImage
}

struct BorgVRMCPWindowState: Codable, Sendable {
  var contentSizePoints: [Double]
  var contentSizePixels: [Int]
  var framePoints: [Double]
  var frameSizePixels: [Int]
  var backingScaleFactor: Double
  var fullscreen: Bool
  var transitioning: Bool
}

@MainActor
protocol BorgVRWindowAutomation: AnyObject {
  func windowState() throws -> BorgVRMCPWindowState
  func resize(width: Int, height: Int, units: String, area: String) async throws -> BorgVRMCPWindowState
  func setFullscreen(_ enabled: Bool) async throws -> BorgVRMCPWindowState
}

struct BorgVRMCPTransferFunction: Codable, Equatable, Sendable {
  var channel: Int
  /// Straight RGBA bytes, ordered from scalar zero to scalar one.
  var samples: [[UInt8]]

  init(channel: Int, samples: [SIMD4<UInt8>]) {
    self.channel = channel
    self.samples = samples.map { [$0.x, $0.y, $0.z, $0.w] }
  }

  init(channel: Int, samples: [[UInt8]]) {
    self.channel = channel
    self.samples = samples
  }

  func validatedSamples(count: Int? = nil) throws -> [SIMD4<UInt8>] {
    guard channel >= 0, channel < 4, !samples.isEmpty,
          samples.count <= TransferFunction1D.maximumEntryCount,
          samples.allSatisfy({ $0.count == 4 }) else {
      throw BorgVRMCPCommandError.invalidArgument("Provide 1...65536 RGBA byte entries and a valid zero-based channel.")
    }
    let source = samples.map { SIMD4<UInt8>($0[0], $0[1], $0[2], $0[3]) }
    guard let count, count != source.count else { return source }
    // Allow compact color ramps; the renderer keeps its existing TF resolution.
    return (0..<count).map { index in
      let position = Float(index) * Float(source.count - 1) / Float(max(count - 1, 1))
      let lower = Int(position), upper = min(lower + 1, source.count - 1)
      let t = position - Float(lower)
      let value = SIMD4<Float>(source[lower]) * (1-t) + SIMD4<Float>(source[upper]) * t
      return SIMD4<UInt8>(value.rounded(.toNearestOrAwayFromZero))
    }
  }
}

struct BorgVRMCPBackgroundState: Codable, Equatable, Sendable {
  var mode: String
  var primary: [Float]
  var secondary: [Float]

  static let passthrough = Self(mode: "passthrough", primary: [0, 0, 0, 0], secondary: [0, 0, 0, 0])

  func validate() throws {
    guard ["system", "solid", "gradient", "passthrough"].contains(mode),
          primary.count == 4, secondary.count == 4,
          (primary + secondary).allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      throw BorgVRMCPCommandError.invalidArgument("Background requires a known mode and RGBA colors in 0...1.")
    }
  }
}

/// A single portable picture configuration; viewState uses the same validated
/// document as the native UI, including head-relative positioning on visionOS.
struct BorgVRMCPVisualizationDocument: Codable {
  var format = "borgvr.visualization"
  var version = 1
  var viewState: Data
  var transferFunctions: [BorgVRMCPTransferFunction]
  var background: BorgVRMCPBackgroundState
  var fieldOfViewDegrees: Float?
  var parallelProjection: Bool?
}

extension BorgVRMCPCommandService {
  var windowAutomation: (any BorgVRWindowAutomation)? { nil }

  func windowState() throws -> BorgVRMCPWindowState {
    guard let windowAutomation else {
      throw BorgVRMCPCommandError.unsupported("Window automation is available only on macOS.")
    }
    return try windowAutomation.windowState()
  }

  func resizeWindow(width: Int, height: Int, units: String = "points", area: String = "content") async throws -> BorgVRMCPWindowState {
    guard let windowAutomation else {
      throw BorgVRMCPCommandError.unsupported("Window automation is available only on macOS.")
    }
    return try await windowAutomation.resize(width: width, height: height, units: units, area: area)
  }

  func setFullscreen(_ enabled: Bool) async throws -> BorgVRMCPWindowState {
    guard let windowAutomation else {
      throw BorgVRMCPCommandError.unsupported("Window automation is available only on macOS.")
    }
    return try await windowAutomation.setFullscreen(enabled)
  }

  func saveSettings(to url: URL, includeCredentials: Bool, overwrite: Bool = false) throws {
    try BorgVRAutomationFile.write(settingsStore().export(includeCredentials: includeCredentials),
      to: url, overwrite: overwrite)
    if includeCredentials { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
  }

  func loadSettings(from url: URL) throws {
    let data = try BorgVRAutomationFile.read(url, maximumBytes: BorgVRSettingsStore.maximumFileSize)
    try settingsStore().importForAutomation(data)
  }

  func resetSettings() throws { try settingsStore().resetForAutomation() }

  func loadTransferFunction(channel: Int, from url: URL) throws {
    let data = try BorgVRAutomationFile.read(url, maximumBytes: TransferFunction1D.maximumFileByteCount)
    let tf = try TransferFunction1D(from: data)
    try setTransferFunction(.init(channel: channel, samples: tf.data))
  }

  func saveTransferFunction(channel: Int, to url: URL, overwrite: Bool = false) throws {
    let value = try transferFunction(channel: channel)
    let tf = try TransferFunction1D(samples: value.validatedSamples())
    try BorgVRAutomationFile.write(tf.serialize(), to: url, overwrite: overwrite)
  }

  func saveVisualizationState(to url: URL, overwrite: Bool = false) throws {
    let state = applicationState()
    guard state.dataset != nil, state.rendererReady else { throw BorgVRMCPCommandError.noDataset }
    var functions: [BorgVRMCPTransferFunction] = []
    // Full-color volumes have no transfer functions to save.
    for channel in 0..<transferFunctionCount { functions.append(try transferFunction(channel: channel)) }
    let document = try BorgVRMCPVisualizationDocument(viewState: datasetViewStateData(),
      transferFunctions: functions, background: background(),
      fieldOfViewDegrees: state.renderingOptions.screenFieldOfViewDegrees,
      parallelProjection: state.renderingOptions.parallelProjection)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try BorgVRAutomationFile.write(encoder.encode(document), to: url, overwrite: overwrite)
  }

  func loadVisualizationState(from url: URL) throws {
    let data = try BorgVRAutomationFile.read(url, maximumBytes: 16_000_000)
    let document = try JSONDecoder().decode(BorgVRMCPVisualizationDocument.self, from: data)
    let view = try DatasetViewStateDocument.decode(from: document.viewState)
    guard document.format == "borgvr.visualization", document.version == 1,
          view.datasetID == applicationState().dataset?.id,
          document.transferFunctions.count == transferFunctionCount,
          Set(document.transferFunctions.map(\.channel)).count == document.transferFunctions.count else {
      throw BorgVRMCPCommandError.invalidArgument("Invalid visualization configuration, or a different dataset is open.")
    }
    try document.background.validate()
    guard (background().mode == "passthrough") == (document.background.mode == "passthrough") else {
      throw BorgVRMCPCommandError.unsupported("This background mode is not available on this platform.")
    }
    if let fov = document.fieldOfViewDegrees, !fov.isFinite || !(10...120).contains(fov) {
      throw BorgVRMCPCommandError.invalidArgument("Field of view must be in 10...120 degrees.")
    }
    // Validate all channels before changing the live visualization.
    for value in document.transferFunctions {
      _ = try transferFunction(channel: value.channel)
      _ = try value.validatedSamples()
    }
    try restoreDatasetViewState(document.viewState)
    for value in document.transferFunctions { try setTransferFunction(value) }
    try setBackground(document.background)
    if document.fieldOfViewDegrees != nil || document.parallelProjection != nil,
       applicationState().platform != "visionOS" {
      try setScreenProjection(fieldOfView: document.fieldOfViewDegrees, parallel: document.parallelProjection)
    }
  }

  func captureScreenshot() async throws -> BorgVRMCPImage {
    try await captureScreenshot(includeAlpha: true)
  }
}

enum BorgVRAutomationFile {
  static func read(_ url: URL, maximumBytes: Int) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= maximumBytes else {
      throw BorgVRMCPCommandError.invalidArgument("The configuration file is too large.")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= maximumBytes else { throw BorgVRMCPCommandError.invalidArgument("The file is too large.") }
    return data
  }

  static func write(_ data: Data, to url: URL, overwrite: Bool) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
  }
}

extension BorgVRMCPImage {
  func composited(over background: BorgVRMCPBackgroundState) throws -> Self {
    try background.validate()
    guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(rect)
    func color(_ components: [Float]) -> CGColor {
      CGColor(colorSpace: context.colorSpace!, components: components.map(CGFloat.init))!
    }
    if background.mode == "gradient" {
      let colors = [color(background.primary), color(background.secondary)] as CFArray
      if let gradient = CGGradient(colorsSpace: context.colorSpace, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
      }
    } else if background.mode != "passthrough" {
      context.setFillColor(color(background.primary))
      context.fill(rect)
    }
    context.draw(image, in: rect)
    let result = NSMutableData()
    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else { throw BorgVRMCPCommandError.screenshotUnavailable }
    return Self(pngData: result as Data, width: width, height: height, renderedFrame: renderedFrame)
  }
}

extension SIMD3 where Scalar == Float {
  var mcpArray: [Float] { [x, y, z] }
}

extension SIMD4 where Scalar == Float {
  var mcpArray: [Float] { [x, y, z, w] }
}
