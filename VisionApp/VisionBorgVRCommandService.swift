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

  private weak var runtimeAppModel: RuntimeAppModel?
  private weak var sharedAppModel: SharedAppModel?
  private let datasetListProvider: DatasetListProvider
  private let datasetOpener: DatasetOpener
  private let datasetCloser: DatasetCloser

  init(
    runtimeAppModel: RuntimeAppModel,
    sharedAppModel: SharedAppModel,
    datasetListProvider: @escaping DatasetListProvider,
    datasetOpener: @escaping DatasetOpener,
    datasetCloser: @escaping DatasetCloser
  ) {
    self.runtimeAppModel = runtimeAppModel
    self.sharedAppModel = sharedAppModel
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
    guard let runtime = runtimeAppModel, let shared = sharedAppModel else {
      return unavailableState
    }
    let info = runtime.activeDatasetInfo
    let dataset = runtime.activeDataset.map {
      BorgVRMCPDatasetState(
        id: $0.uniqueId,
        description: $0.description,
        dimensions: info.map { [$0.width, $0.height, $0.depth] },
        physicalExtentMeters: info.map { $0.physicalExtentMeters.mcpArray }
      )
    }
    let transform = shared.modelTransform
    return BorgVRMCPApplicationState(
      applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      platform: "visionOS",
      dataset: dataset,
      rendererReady: runtime.immersiveSpaceState == .open && info != nil,
      completedFrame: runtime.mcpRenderBridge.completedFrameCount,
      renderMode: mcpName(for: shared.renderMode),
      normalizedIsoValue: shared.normIsoValue,
      transform: BorgVRMCPTransformState(
        rotation: transform.rotation.vector.mcpArray,
        translation: transform.translation.mcpArray,
        scale: transform.scale.mcpArray
      ),
      clipMinimum: shared.clipMin.mcpArray,
      clipMaximum: shared.clipMax.mcpArray,
      lighting: BorgVRMCPLightingState(
        direction: shared.lightDirection.mcpArray,
        ambient: shared.ambientLightColor.mcpArray,
        diffuse: shared.diffuseLightColor.mcpArray,
        specular: shared.specularLightColor.mcpArray
      ),
      annotationVisibility: BorgVRMCPAnnotationVisibilityState(
        objects: !shared.objectsHidden,
        measurements: !shared.measurementsHidden
      ),
      objectCount: shared.volumeMarkers.count + shared.sceneMeshInstances.count,
      measurementCount: shared.volumeMeasurements.count
    )
  }

  func setRenderMode(_ mode: String) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    shared.renderMode = switch mode.lowercased() {
      case "tf", "transfer", "transfer_function", "transferfunction", "transferfunction1d":
        .transferFunction1D
      case "lighting", "transfer_function_lighting", "tflighting", "transferfunction1dlighting":
        .transferFunction1DLighting
      case "iso", "isovalue":
        .isoValue
      default:
        throw BorgVRMCPCommandError.invalidArgument("Unknown render mode.")
    }
    shared.synchronize(kind: .stateOnly)
  }

  func setTransform(
    rotation: SIMD4<Float>?,
    translation: SIMD3<Float>?,
    scale: SIMD3<Float>?
  ) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    var transform = shared.modelTransform
    if let rotation {
      guard simd_length_squared(rotation) > 0.000_001 else {
        throw BorgVRMCPCommandError.invalidArgument("Rotation quaternion must not be zero.")
      }
      transform.rotation = simd_normalize(simd_quatf(vector: rotation))
    }
    if let translation { transform.translation = translation }
    if let scale {
      guard scale.x > 0, scale.y > 0, scale.z > 0 else {
        throw BorgVRMCPCommandError.invalidArgument("Scale must be positive.")
      }
      transform.scale = scale
    }
    shared.modelTransform = transform
    shared.lastModelTransform = transform
    shared.synchronize(kind: .transformOnly)
  }

  func rotate(axis: SIMD3<Float>, degrees: Float) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    guard simd_length_squared(axis) > 0.000_001 else {
      throw BorgVRMCPCommandError.invalidArgument("Rotation axis must not be zero.")
    }
    var transform = shared.modelTransform
    let delta = simd_quatf(
      angle: degrees * .pi / 180,
      axis: simd_normalize(axis)
    )
    transform.rotation = simd_normalize(delta * transform.rotation)
    shared.modelTransform = transform
    shared.lastModelTransform = transform
    shared.synchronize(kind: .transformOnly)
  }

  func setNormalizedIsoValue(_ value: Float) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    guard value.isFinite, (0...1).contains(value) else {
      throw BorgVRMCPCommandError.invalidArgument("Normalized isovalue must be between zero and one.")
    }
    shared.normIsoValue = value
    shared.synchronize(kind: .stateOnly)
  }

  func setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    guard minimum.x >= 0, minimum.y >= 0, minimum.z >= 0,
          maximum.x <= 1, maximum.y <= 1, maximum.z <= 1,
          minimum.x <= maximum.x,
          minimum.y <= maximum.y,
          minimum.z <= maximum.z else {
      throw BorgVRMCPCommandError.invalidArgument(
        "Clipping bounds must be ordered and contained in zero to one."
      )
    }
    shared.clipMin = minimum
    shared.clipMax = maximum
    shared.lastTranslationClipping = .zero
    shared.synchronize(kind: .stateOnly)
  }

  func setLighting(
    direction: SIMD3<Float>?,
    ambient: SIMD3<Float>?,
    diffuse: SIMD3<Float>?,
    specular: SIMD3<Float>?
  ) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    if let direction {
      guard simd_length_squared(direction) > 0.000_001 else {
        throw BorgVRMCPCommandError.invalidArgument("Light direction must not be zero.")
      }
      shared.lightDirection = simd_normalize(direction)
    }
    if let ambient { shared.ambientLightColor = try validatedColor(ambient) }
    if let diffuse { shared.diffuseLightColor = try validatedColor(diffuse) }
    if let specular { shared.specularLightColor = try validatedColor(specular) }
    shared.synchronize(kind: .stateOnly)
  }

  func setAnnotationVisibility(objects: Bool?, measurements: Bool?) throws {
    guard let shared = sharedAppModel else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    guard objects != nil || measurements != nil else {
      throw BorgVRMCPCommandError.invalidArgument(
        "At least one annotation visibility value is required."
      )
    }
    if let objects { shared.objectsHidden = !objects }
    if let measurements { shared.measurementsHidden = !measurements }
  }

  func reset(_ scope: BorgVRMCPResetScope) throws {
    guard let shared = sharedAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    switch scope {
      case .all:
        shared.resetModel()
        shared.resetClipBoundsToVolume()
        for transferFunction in shared.transferFunctions { transferFunction.reset() }
        shared.resetIsoValue()
        shared.renderMode = .transferFunction1D
        shared.brickVis = false
        applyDefaultLighting(to: shared)
        shared.synchronize(kind: .full)
      case .transform:
        shared.resetModel()
        shared.synchronize(kind: .transformOnly)
      case .clipping:
        shared.resetClipBoundsToVolume()
        shared.synchronize(kind: .stateOnly)
      case .transferFunction:
        let channel = runtimeAppModel?.selectedTransferFunctionChannel ?? 0
        shared.transferFunction(channel: channel).reset()
        shared.synchronize(kind: .full)
      case .lighting:
        applyDefaultLighting(to: shared)
        shared.synchronize(kind: .stateOnly)
    }
  }

  func waitUntilRendered(after frame: UInt64, timeout: TimeInterval) async throws {
    guard let bridge = runtimeAppModel?.mcpRenderBridge else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(timeout)
    while bridge.completedFrameCount <= frame {
      if clock.now >= deadline { throw BorgVRMCPCommandError.timeout }
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(16))
    }
  }

  func captureScreenshot() async throws -> BorgVRMCPImage {
    guard let runtime = runtimeAppModel else { throw BorgVRMCPCommandError.rendererUnavailable }
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

  private var unavailableState: BorgVRMCPApplicationState {
    BorgVRMCPApplicationState(
      applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      platform: "visionOS",
      dataset: nil,
      rendererReady: false,
      completedFrame: 0,
      renderMode: "transfer_function",
      normalizedIsoValue: 0,
      transform: BorgVRMCPTransformState(
        rotation: [0, 0, 0, 1], translation: [0, 0, 0], scale: [1, 1, 1]
      ),
      clipMinimum: [0, 0, 0],
      clipMaximum: [1, 1, 1],
      lighting: BorgVRMCPLightingState(
        direction: [0, 0, 1], ambient: [0, 0, 0], diffuse: [0, 0, 0], specular: [0, 0, 0]
      ),
      annotationVisibility: BorgVRMCPAnnotationVisibilityState(
        objects: true,
        measurements: true
      ),
      objectCount: 0,
      measurementCount: 0
    )
  }

  private func applyDefaultLighting(to shared: SharedAppModel) {
    let lighting = BorgVRLightingState.default
    shared.lightDirection = lighting.direction
    shared.ambientLightColor = lighting.ambientColor
    shared.diffuseLightColor = lighting.diffuseColor
    shared.specularLightColor = lighting.specularColor
  }

  private func validatedColor(_ value: SIMD3<Float>) throws -> SIMD3<Float> {
    guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
          (0...1).contains(value.x),
          (0...1).contains(value.y),
          (0...1).contains(value.z) else {
      throw BorgVRMCPCommandError.invalidArgument("Light colors must be between zero and one.")
    }
    return value
  }

  private func mcpName(for mode: RenderMode) -> String {
    switch mode {
      case .transferFunction1D: "transfer_function"
      case .transferFunction1DLighting: "transfer_function_lighting"
      case .isoValue: "isovalue"
    }
  }
}
