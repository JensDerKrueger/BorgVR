import Foundation
import ImageIO
import simd

@MainActor
final class BorgVRScreenCommandService: BorgVRMCPCommandService {
  typealias DatasetListProvider = () async throws -> [BorgVRMCPDatasetCatalogEntry]
  typealias DatasetOpener = (String) async throws -> Void
  typealias DatasetCloser = () async throws -> Void

  private let session: ScreenBorgVRSession
  private let datasetListProvider: DatasetListProvider
  private let datasetOpener: DatasetOpener
  private let datasetCloser: DatasetCloser

  init(
    session: ScreenBorgVRSession,
    datasetListProvider: @escaping DatasetListProvider = { [] },
    datasetOpener: @escaping DatasetOpener = { _ in
      throw BorgVRMCPCommandError.unsupported("Opening datasets is not available.")
    },
    datasetCloser: @escaping DatasetCloser = {
      throw BorgVRMCPCommandError.unsupported("Closing datasets is not available.")
    }
  ) {
    self.session = session
    self.datasetListProvider = datasetListProvider
    self.datasetOpener = datasetOpener
    self.datasetCloser = datasetCloser
  }

  func listDatasets() async throws -> [BorgVRMCPDatasetCatalogEntry] {
    try await datasetListProvider()
  }

  func openDataset(id: String) async throws {
    try await datasetOpener(id)
  }

  func closeDataset() async throws {
    try await datasetCloser()
  }

  func applicationState() -> BorgVRMCPApplicationState {
    let appModel = session.runtimeState
    let state = session.currentSnapshot()
    let dataset = appModel.activeDataset.map { entry in
      let metadata = appModel.activeDatasetMetadata
      return BorgVRMCPDatasetState(
        id: entry.uniqueId,
        description: entry.description,
        dimensions: metadata.map { [$0.width, $0.height, $0.depth] },
        physicalExtentMeters: metadata.map { $0.physicalExtentMeters.mcpArray }
      )
    }
    return BorgVRMCPApplicationState(
      applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      platform: platformName,
      dataset: dataset,
      rendererReady: appModel.rendererHasActiveDataset,
      completedFrame: appModel.completedRenderFrameCount,
      renderMode: mcpName(for: state.renderMode),
      normalizedIsoValue: state.normalizedIsoValue,
      transform: BorgVRMCPTransformState(
        rotation: state.transform.rotation.mcpArray,
        translation: state.transform.translation.mcpArray,
        scale: state.transform.scale.mcpArray
      ),
      clipMinimum: state.clipMinimum.mcpArray,
      clipMaximum: state.clipMaximum.mcpArray,
      lighting: BorgVRMCPLightingState(
        direction: state.lighting.direction.mcpArray,
        ambient: state.lighting.ambient.mcpArray,
        diffuse: state.lighting.diffuse.mcpArray,
        specular: state.lighting.specular.mcpArray
      ),
      annotationVisibility: BorgVRMCPAnnotationVisibilityState(
        objects: state.objectsVisible,
        measurements: state.measurementsVisible
      ),
      objectCount: state.objectCount,
      measurementCount: state.measurementCount
    )
  }

  func setRenderMode(_ mode: String) throws {
    let renderMode: RenderMode = switch mode.lowercased() {
      case "tf", "transfer", "transfer_function", "transferfunction", "transferfunction1d":
        .transferFunction1D
      case "lighting", "transfer_function_lighting", "tflighting", "transferfunction1dlighting":
        .transferFunction1DLighting
      case "iso", "isovalue":
        .isoValue
      default:
        throw BorgVRMCPCommandError.invalidArgument("Unknown render mode.")
    }
    try session.perform(.setRenderMode(renderMode), source: .mcp)
  }

  func setTransform(
    rotation: SIMD4<Float>?,
    translation: SIMD3<Float>?,
    scale: SIMD3<Float>?
  ) throws {
    let current = session.currentSnapshot().transform
    var updated = current
    if let rotation {
      updated.rotation = rotation
    }
    if let translation {
      updated.translation = translation
    }
    if let scale {
      updated.scale = scale
    }
    try session.perform(.setTransform(updated), source: .mcp)
  }

  func rotate(axis: SIMD3<Float>, degrees: Float) throws {
    try session.perform(.rotate(axis: axis, degrees: degrees), source: .mcp)
  }

  func setNormalizedIsoValue(_ value: Float) throws {
    try session.perform(.setNormalizedIsoValue(value), source: .mcp)
  }

  func setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) throws {
    try session.perform(
      .setClipping(minimum: minimum, maximum: maximum),
      source: .mcp
    )
  }

  func setLighting(
    direction: SIMD3<Float>?,
    ambient: SIMD3<Float>?,
    diffuse: SIMD3<Float>?,
    specular: SIMD3<Float>?
  ) throws {
    try session.perform(
      .setLighting(
        direction: direction,
        ambient: ambient,
        diffuse: diffuse,
        specular: specular
      ),
      source: .mcp
    )
  }

  func setAnnotationVisibility(objects: Bool?, measurements: Bool?) throws {
    try session.perform(
      .setAnnotationVisibility(objects: objects, measurements: measurements),
      source: .mcp
    )
  }

  func listMeshAssets() -> [BorgVRMeshAssetCommandState] {
    let appModel = session.runtimeState
    appModel.refreshSceneMeshCatalog()
    return appModel.sceneMeshAssets.values
      .map(BorgVRMeshAssetCommandState.init)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func listObjects() -> [BorgVRObjectCommandState] {
    let appModel = session.runtimeState
    return appModel.volumeMarkers.map { .marker(BorgVRMarkerCommandState($0)) }
      + appModel.sceneMeshInstances.map { .mesh(BorgVRMeshInstanceCommandState($0)) }
  }

  func upsertObject(_ object: BorgVRObjectCommandState) throws {
    try session.perform(.upsertObject(object), source: .mcp)
  }

  func removeObject(id: UUID) throws {
    try session.perform(.removeObject(id), source: .mcp)
  }

  func clearObjects() throws {
    try session.perform(.clearObjects, source: .mcp)
  }

  func listMeasurements() -> [BorgVRMeasurementCommandState] {
    session.runtimeState.volumeMeasurements.map(BorgVRMeasurementCommandState.init)
  }

  func upsertMeasurement(_ measurement: BorgVRMeasurementCommandState) throws {
    try session.perform(.upsertMeasurement(measurement), source: .mcp)
  }

  func removeMeasurement(id: UUID) throws {
    try session.perform(.removeMeasurement(id), source: .mcp)
  }

  func clearMeasurements() throws {
    try session.perform(.clearMeasurements, source: .mcp)
  }

  func reset(_ scope: BorgVRMCPResetScope) throws {
    let sessionScope: BorgVRStateResetScope = switch scope {
      case .all: .all
      case .transform: .transform
      case .clipping: .clipping
      case .transferFunction: .transferFunction
      case .lighting: .lighting
    }
    try session.perform(.reset(sessionScope), source: .mcp)
  }

  func waitUntilRendered(after frame: UInt64, timeout: TimeInterval) async throws {
    let appModel = session.runtimeState
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(timeout)
    while appModel.completedRenderFrameCount <= frame ||
          appModel.lastCompletedFrameDatasetKey != appModel.activeDatasetRenderKey {
      if clock.now >= deadline { throw BorgVRMCPCommandError.timeout }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  func captureScreenshot() async throws -> BorgVRMCPImage {
    let appModel = session.runtimeState
    guard appModel.activeDataset != nil else { throw BorgVRMCPCommandError.noDataset }

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("BorgVR-MCP-\(UUID().uuidString)")
      .appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let url = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<URL, Error>) in
      let gate = BorgVRMCPContinuationGate(continuation)
      appModel.requestRenderScreenshot(to: temporaryURL, accessURL: nil) { result in
        gate.resume(with: result)
      }
      Task {
        try? await Task.sleep(for: .seconds(10))
        gate.resume(with: .failure(BorgVRMCPCommandError.timeout))
      }
    }
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    return BorgVRMCPImage(
      pngData: data,
      width: width,
      height: height,
      renderedFrame: appModel.completedRenderFrameCount
    )
  }

  private var platformName: String {
#if os(macOS)
    "macOS"
#else
    "iOS"
#endif
  }

  private func mcpName(for mode: RenderMode) -> String {
    switch mode {
      case .transferFunction1D: "transfer_function"
      case .transferFunction1DLighting: "transfer_function_lighting"
      case .isoValue: "isovalue"
    }
  }

}
