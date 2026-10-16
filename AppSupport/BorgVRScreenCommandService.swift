import Foundation
import ImageIO
import simd

@MainActor
final class BorgVRScreenCommandService: BorgVRMCPCommandService {
  typealias DatasetListProvider = () async throws -> [BorgVRMCPDatasetCatalogEntry]
  typealias DatasetOpener = (String) async throws -> Void
  typealias DatasetCloser = () async throws -> Void

  private weak var appModel: AppModel?
  private weak var renderingParameters: RenderingParameters?
  private let datasetListProvider: DatasetListProvider
  private let datasetOpener: DatasetOpener
  private let datasetCloser: DatasetCloser
  private let synchronizeTransform: () -> Void
  private let synchronizeState: () -> Void
  private let synchronizeFullState: () -> Void
  private let renderModeDidChange: (RenderMode) -> Void

  init(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    synchronizeTransform: @escaping () -> Void = {},
    synchronizeState: @escaping () -> Void = {},
    synchronizeFullState: @escaping () -> Void = {},
    renderModeDidChange: @escaping (RenderMode) -> Void = { _ in },
    datasetListProvider: @escaping DatasetListProvider = { [] },
    datasetOpener: @escaping DatasetOpener = { _ in
      throw BorgVRMCPCommandError.unsupported("Opening datasets is not available.")
    },
    datasetCloser: @escaping DatasetCloser = {
      throw BorgVRMCPCommandError.unsupported("Closing datasets is not available.")
    }
  ) {
    self.appModel = appModel
    self.renderingParameters = renderingParameters
    self.synchronizeTransform = synchronizeTransform
    self.synchronizeState = synchronizeState
    self.synchronizeFullState = synchronizeFullState
    self.renderModeDidChange = renderModeDidChange
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
    guard let appModel, let parameters = renderingParameters else {
      return unavailableState
    }
    let dataset = appModel.activeDataset.map { entry in
      let metadata = appModel.activeDatasetMetadata
      return BorgVRMCPDatasetState(
        id: entry.uniqueId,
        description: entry.description,
        dimensions: metadata.map { [$0.width, $0.height, $0.depth] },
        physicalExtentMeters: metadata.map { $0.physicalExtentMeters.mcpArray }
      )
    }
    let orientation = parameters.orientation.vector
    return BorgVRMCPApplicationState(
      applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      platform: platformName,
      dataset: dataset,
      rendererReady: appModel.rendererHasActiveDataset,
      completedFrame: appModel.completedRenderFrameCount,
      renderMode: mcpName(for: parameters.renderMode),
      normalizedIsoValue: parameters.normIsoValue,
      transform: BorgVRMCPTransformState(
        rotation: orientation.mcpArray,
        translation: [parameters.pan.x, parameters.pan.y, 0],
        scale: [parameters.scale, parameters.scale, parameters.scale]
      ),
      clipMinimum: parameters.clipMin.mcpArray,
      clipMaximum: parameters.clipMax.mcpArray,
      lighting: BorgVRMCPLightingState(
        direction: parameters.lightDirection.mcpArray,
        ambient: parameters.ambientLightColor.mcpArray,
        diffuse: parameters.diffuseLightColor.mcpArray,
        specular: parameters.specularLightColor.mcpArray
      ),
      annotationVisibility: BorgVRMCPAnnotationVisibilityState(
        objects: !appModel.objectsHidden,
        measurements: !appModel.measurementsHidden
      ),
      objectCount: appModel.volumeMarkers.count + appModel.sceneMeshInstances.count,
      measurementCount: appModel.volumeMeasurements.count
    )
  }

  func setRenderMode(_ mode: String) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
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
    parameters.renderMode = renderMode
    renderModeDidChange(renderMode)
    synchronizeState()
  }

  func setTransform(
    rotation: SIMD4<Float>?,
    translation: SIMD3<Float>?,
    scale: SIMD3<Float>?
  ) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    if let rotation {
      let lengthSquared = simd_length_squared(rotation)
      guard lengthSquared > 0.000_001 else {
        throw BorgVRMCPCommandError.invalidArgument("Rotation quaternion must not be zero.")
      }
      parameters.orientation = simd_normalize(simd_quatf(vector: rotation))
    }
    if let translation {
      parameters.pan = SIMD2<Float>(translation.x, translation.y)
    }
    if let scale {
      guard scale.x > 0, scale.y > 0, scale.z > 0 else {
        throw BorgVRMCPCommandError.invalidArgument("Scale must be positive.")
      }
      parameters.scale = (scale.x + scale.y + scale.z) / 3
    }
    synchronizeTransform()
  }

  func rotate(axis: SIMD3<Float>, degrees: Float) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    guard simd_length_squared(axis) > 0.000_001 else {
      throw BorgVRMCPCommandError.invalidArgument("Rotation axis must not be zero.")
    }
    let rotation = simd_quatf(
      angle: degrees * .pi / 180,
      axis: simd_normalize(axis)
    )
    parameters.orientation = simd_normalize(rotation * parameters.orientation)
    synchronizeTransform()
  }

  func setNormalizedIsoValue(_ value: Float) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    guard value.isFinite, (0...1).contains(value) else {
      throw BorgVRMCPCommandError.invalidArgument("Normalized isovalue must be between zero and one.")
    }
    parameters.normIsoValue = value
    synchronizeState()
  }

  func setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    guard minimum.x >= 0, minimum.y >= 0, minimum.z >= 0,
          maximum.x <= 1, maximum.y <= 1, maximum.z <= 1,
          minimum.x <= maximum.x,
          minimum.y <= maximum.y,
          minimum.z <= maximum.z else {
      throw BorgVRMCPCommandError.invalidArgument(
        "Clipping bounds must be ordered and contained in zero to one."
      )
    }
    parameters.clipMin = minimum
    parameters.clipMax = maximum
    parameters.clippingTranslation = .zero
    synchronizeState()
  }

  func setLighting(
    direction: SIMD3<Float>?,
    ambient: SIMD3<Float>?,
    diffuse: SIMD3<Float>?,
    specular: SIMD3<Float>?
  ) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    if let direction {
      guard simd_length_squared(direction) > 0.000_001 else {
        throw BorgVRMCPCommandError.invalidArgument("Light direction must not be zero.")
      }
      parameters.lightDirection = simd_normalize(direction)
    }
    if let ambient {
      parameters.ambientLightColor = try validatedColor(ambient)
    }
    if let diffuse {
      parameters.diffuseLightColor = try validatedColor(diffuse)
    }
    if let specular {
      parameters.specularLightColor = try validatedColor(specular)
    }
    synchronizeState()
  }

  func setAnnotationVisibility(objects: Bool?, measurements: Bool?) throws {
    guard let appModel else { throw BorgVRMCPCommandError.rendererUnavailable }
    guard objects != nil || measurements != nil else {
      throw BorgVRMCPCommandError.invalidArgument(
        "At least one annotation visibility value is required."
      )
    }
    if let objects { appModel.objectsHidden = !objects }
    if let measurements { appModel.measurementsHidden = !measurements }
  }

  func reset(_ scope: BorgVRMCPResetScope) throws {
    guard let parameters = renderingParameters else {
      throw BorgVRMCPCommandError.rendererUnavailable
    }
    switch scope {
      case .all:
        parameters.reset()
        synchronizeFullState()
      case .transform:
        parameters.resetTransform()
        synchronizeTransform()
      case .clipping:
        parameters.clipMin = .zero
        parameters.clipMax = .one
        parameters.clippingTranslation = .zero
        synchronizeState()
      case .transferFunction:
        parameters.transferFunction.reset()
        parameters.objectWillChange.send()
        synchronizeFullState()
      case .lighting:
        let lighting = BorgVRLightingState.default
        parameters.lightDirection = lighting.direction
        parameters.ambientLightColor = lighting.ambientColor
        parameters.diffuseLightColor = lighting.diffuseColor
        parameters.specularLightColor = lighting.specularColor
        synchronizeState()
    }
  }

  func waitUntilRendered(after frame: UInt64, timeout: TimeInterval) async throws {
    guard let appModel else { throw BorgVRMCPCommandError.rendererUnavailable }
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
    guard let appModel else { throw BorgVRMCPCommandError.rendererUnavailable }
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

  private var unavailableState: BorgVRMCPApplicationState {
    BorgVRMCPApplicationState(
      applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
      platform: platformName,
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

  private func validatedColor(_ value: SIMD3<Float>) throws -> SIMD3<Float> {
    guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
          (0...1).contains(value.x),
          (0...1).contains(value.y),
          (0...1).contains(value.z) else {
      throw BorgVRMCPCommandError.invalidArgument("Light colors must be between zero and one.")
    }
    return value
  }
}
