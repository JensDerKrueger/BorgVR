import Foundation
import RealityKit
import simd

final class VisionMCPRenderBridge: @unchecked Sendable {
  typealias Completion = (Result<BorgVRMCPImage, Error>) -> Void

  struct Request {
    let id: UUID
    let completion: Completion
  }

  private let lock = NSLock()
  private var pendingRequest: Request?
  private var frameCount: UInt64 = 0

  func requestScreenshot(id: UUID, completion: @escaping Completion) {
    lock.lock()
    defer { lock.unlock() }
    guard pendingRequest == nil else {
      completion(.failure(BorgVRMCPCommandError.screenshotUnavailable))
      return
    }
    pendingRequest = Request(id: id, completion: completion)
  }

  func cancelScreenshot(id: UUID) {
    lock.lock()
    guard pendingRequest?.id == id else {
      lock.unlock()
      return
    }
    let request = pendingRequest
    pendingRequest = nil
    lock.unlock()
    request?.completion(.failure(BorgVRMCPCommandError.timeout))
  }

  func takeScreenshotRequest() -> Request? {
    lock.lock()
    defer { lock.unlock() }
    let request = pendingRequest
    pendingRequest = nil
    return request
  }

  @discardableResult
  func recordFrame() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    frameCount &+= 1
    return frameCount
  }

  var completedFrameCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return frameCount
  }
}

@MainActor
final class VisionBorgVRCommandService: BorgVRMCPCommandService {
  typealias DatasetListProvider = () async throws -> [BorgVRMCPDatasetCatalogEntry]
  typealias DatasetOpener = (String) async throws -> Void
  typealias DatasetCloser = () async throws -> Void

  private let session: VisionBorgVRSession
  private let datasetListProvider: DatasetListProvider
  private let datasetOpener: DatasetOpener
  private let datasetCloser: DatasetCloser

  init(
    session: VisionBorgVRSession,
    datasetListProvider: @escaping DatasetListProvider,
    datasetOpener: @escaping DatasetOpener,
    datasetCloser: @escaping DatasetCloser
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
    let runtime = session.runtimeState
    let state = session.currentSnapshot()
    let info = runtime.activeDatasetInfo
    let dataset = runtime.activeDataset.map {
      BorgVRMCPDatasetState(
        id: $0.uniqueId,
        description: $0.description,
        dimensions: info.map { [$0.width, $0.height, $0.depth] },
        physicalExtentMeters: info.map { $0.physicalExtentMeters.mcpArray }
      )
    }
    return BorgVRMCPApplicationState(
      applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      platform: "visionOS",
      dataset: dataset,
      rendererReady: runtime.immersiveSpaceState == .open && info != nil,
      completedFrame: runtime.mcpRenderBridge.completedFrameCount,
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
    var transform = session.currentSnapshot().transform
    if let rotation { transform.rotation = rotation }
    if let translation { transform.translation = translation }
    if let scale { transform.scale = scale }
    try session.perform(.setTransform(transform), source: .mcp)
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
    let shared = session.visualizationState
    shared.refreshSceneMeshCatalog()
    return shared.sceneMeshAssets.values
      .map(BorgVRMeshAssetCommandState.init)
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func listObjects() -> [BorgVRObjectCommandState] {
    let shared = session.visualizationState
    return shared.volumeMarkers.map { .marker(BorgVRMarkerCommandState($0)) }
      + shared.sceneMeshInstances.map { .mesh(BorgVRMeshInstanceCommandState($0)) }
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
    session.visualizationState.volumeMeasurementsSnapshot()
      .map(BorgVRMeasurementCommandState.init)
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
    let bridge = session.runtimeState.mcpRenderBridge
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(timeout)
    while bridge.completedFrameCount <= frame {
      if clock.now >= deadline { throw BorgVRMCPCommandError.timeout }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  func captureScreenshot() async throws -> BorgVRMCPImage {
    let runtime = session.runtimeState
    guard runtime.activeDataset != nil else { throw BorgVRMCPCommandError.noDataset }
    let requestID = UUID()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<BorgVRMCPImage, Error>) in
      let gate = BorgVRMCPContinuationGate(continuation)
      runtime.mcpRenderBridge.requestScreenshot(id: requestID) { result in
        gate.resume(with: result)
      }
      Task {
        try? await Task.sleep(for: .seconds(10))
        runtime.mcpRenderBridge.cancelScreenshot(id: requestID)
        gate.resume(with: .failure(BorgVRMCPCommandError.timeout))
      }
    }
  }

  private func mcpName(for mode: RenderMode) -> String {
    switch mode {
      case .transferFunction1D: "transfer_function"
      case .transferFunction1DLighting: "transfer_function_lighting"
      case .isoValue: "isovalue"
    }
  }
}
