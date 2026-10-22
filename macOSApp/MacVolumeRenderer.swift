import AppKit
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

@MainActor
private final class MacRendererDatasetAccess {
  private let storedAppModel: StoredAppModel
  private var accessURL: URL?

  init(storedAppModel: StoredAppModel) {
    self.storedAppModel = storedAppModel
  }

  func load(filename: String) throws -> BORGVRDatasetProtocol {
    let newAccessURL = storedAppModel.startAccessingDataDirectory()
    do {
      let dataset = try BORGVRFileData(filename: filename)
      accessURL = newAccessURL
      return dataset
    } catch {
      storedAppModel.stopAccessingDataDirectory(newAccessURL)
      throw error
    }
  }

  func remoteCacheFilename(datasetID: String) -> String {
    let newAccessURL = storedAppModel.startAccessingDataDirectory()
    accessURL = newAccessURL
    return storedAppModel.resolvedDataDirectoryURL()
      .appendingPathComponent("\(datasetID).data")
      .path
  }

  func release() {
    storedAppModel.stopAccessingDataDirectory(accessURL)
    accessURL = nil
  }
}

@MainActor
final class MacVolumeRenderer: NSObject, MTKViewDelegate {
  private struct SendableDataset: @unchecked Sendable {
    let value: BORGVRDatasetProtocol
  }

  private weak var view: MTKView?
  private let appModel: AppModel
  private let appSettings: AppSettings
  private let storedAppModel: StoredAppModel
  private let sharePlay: SharePlayCoordinator
  private let renderingParameters: RenderingParameters
  private let datasetAccess: MacRendererDatasetAccess
  private let core: ScreenVolumeRendererCore
  private var frameInFlight = false
  private let screenshotRequests = ScreenScreenshotRequestQueue()

  init(
    session: ScreenBorgVRSession,
    storedAppModel: StoredAppModel,
    sharePlay: SharePlayCoordinator
  ) {
    let appModel = session.runtimeState
    let appSettings = session.settingsState
    let renderingParameters = session.visualizationState
    let datasetAccess = MacRendererDatasetAccess(storedAppModel: storedAppModel)
    self.appModel = appModel
    self.appSettings = appSettings
    self.storedAppModel = storedAppModel
    self.sharePlay = sharePlay
    self.renderingParameters = renderingParameters
    self.datasetAccess = datasetAccess
    self.core = ScreenVolumeRendererCore(
      session: session,
      pipelineLabelPrefix: "BorgVR",
      loadLocalDataset: { try datasetAccess.load(filename: $0) },
      remoteCacheFilename: { datasetAccess.remoteCacheFilename(datasetID: $0) },
      releaseDatasetAccess: { datasetAccess.release() },
      fallbackDrawableScale: {
        $0.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
      }
    )
    super.init()
  }

  func attach(to view: MTKView) {
    self.view = view
    core.attach(to: view)
    appModel.renderScreenshotHandler = { [weak self] id, url, accessURL, completion in
      Task { @MainActor in
        guard let self else {
          completion(.failure(AppModelError.rendererUnavailable))
          return
        }
        self.enqueueScreenshot(
          id: id,
          to: url,
          accessURL: accessURL,
          completion: completion
        )
      }
    }
    appModel.renderScreenshotCancelHandler = { [weak self] id, error in
      self?.cancelScreenshot(id: id, error: error)
    }
    appModel.renderDisplaySyncHandler = { [weak self] enabled in
      self?.setDisplaySyncEnabled(enabled)
    }
    appModel.isoSurfaceExtractionHandler = { [weak self] outputURL, normalizedIsoValue,
      cancellationToken, progress, completion in
      guard let self,
            let dataset = core.datasetForReadOnlyOperation() else {
        completion(.failure(AppModelError.rendererUnavailable))
        return
      }
      let sendableDataset = SendableDataset(value: dataset)
      let logger = appModel.logger
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result {
          try BorgVRIsoSurfaceExtractor.extract(
            dataset: sendableDataset.value,
            normalizedIsoValue: normalizedIsoValue,
            outputURL: outputURL,
            logger: logger,
            cancellationToken: cancellationToken,
            progress: progress
          )
        }
        completion(result)
      }
    }
    setDisplaySyncEnabled(appModel.renderDisplaySyncEnabled)
  }

  func updateIfNeeded(for view: MTKView) {
    switch core.updateIfNeeded(for: view) {
      case .unchanged:
        break
      case .cleared:
        cancelAllScreenshots(error: AppModelError.rendererUnavailable)
        appModel.markRenderedDataset(key: "")
        resetRenderTracking()
      case .loaded(let key, let metadata):
        cancelAllScreenshots(error: BorgVRMCPCommandError.screenshotUnavailable)
        resetRenderTracking()
        appModel.markRenderedDataset(key: key, metadata: metadata)
        appModel.loadAutomaticallyManagedDatasetState(
          appSettings: appSettings,
          metadata: metadata,
          renderingParameters: renderingParameters
        )
        sharePlay.datasetRendererDidLoad()
      case .failed(let key, _):
        cancelAllScreenshots(error: AppModelError.rendererUnavailable)
        appModel.markRenderedDatasetFailed(key: key)
    }
    if !appModel.renderDisplaySyncEnabled {
      DispatchQueue.main.async { [weak view] in
        view?.draw()
      }
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    if core.drawableSizeWillChange(size) {
      sharePlay.synchronize(kind: .transformOnly)
    }
  }

  func draw(in view: MTKView) {
    guard !frameInFlight else { return }
    frameInFlight = true
    guard let frame = core.encodeFrame(in: view) else {
      frameInFlight = false
      return
    }

    let screenshotCapture = makeScreenshotCapture(
      from: frame.drawable.texture,
      on: frame.commandBuffer
    )
    frame.commandBuffer.addCompletedHandler { [weak self] commandBuffer in
      Task { @MainActor in
        guard let self else { return }
        let missingBrickCount = self.core.completeFrame(frame)
        self.appModel.recordCompletedRenderFrame(
          datasetKey: self.core.loadedDatasetKey,
          missingBrickCount: missingBrickCount
        )
        self.finishScreenshotCapture(screenshotCapture)
        self.updatePerformanceGraph()
        self.frameInFlight = false
        self.drawNextFrameIfDisplaySyncIsDisabled()
      }
    }
    frame.commandBuffer.present(frame.drawable)
    frame.commandBuffer.commit()
  }

  func saveScreenshotToDataDirectory() {
    appModel.requestRenderScreenshot(to: nil, accessURL: nil) { [weak appModel] result in
      if case let .failure(error) = result {
        appModel?.logger.error(error.localizedDescription)
      }
    }
  }

  private func enqueueScreenshot(
    id: UUID,
    to requestedURL: URL?,
    accessURL requestedAccessURL: URL?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard appModel.activeDataset != nil else {
      appModel.logger.warning(String(localized: "screenshot_no_dataset"))
      completion(.failure(ScreenshotError.noDataset))
      return
    }

    let accessURL = requestedAccessURL ?? (
      requestedURL == nil ? storedAppModel.startAccessingDataDirectory() : nil
    )
    let screenshotURL = requestedURL ?? uniqueScreenshotURL(
      in: storedAppModel.resolvedDataDirectoryURL()
    )
    do {
      try FileManager.default.createDirectory(
        at: screenshotURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      storedAppModel.stopAccessingDataDirectory(accessURL)
      appModel.logger.error(
        String(
          format: String(localized: "screenshot_data_directory_unavailable"),
          error.localizedDescription
        )
      )
      completion(.failure(error))
      return
    }

    let request = ScreenScreenshotRequest(
      id: id,
      url: screenshotURL,
      accessURL: accessURL,
      completion: completion
    )
    guard screenshotRequests.enqueue(request) else {
      storedAppModel.stopAccessingDataDirectory(accessURL)
      completion(.failure(BorgVRMCPCommandError.screenshotUnavailable))
      return
    }
    guard let view else {
      cancelScreenshot(id: id, error: AppModelError.rendererUnavailable)
      return
    }
    view.draw()
  }

  private func resetRenderTracking() {
    appModel.resetBrickReadbackState()
    appModel.performanceModel.history = PerformanceHistory()
  }

  private func setDisplaySyncEnabled(_ enabled: Bool) {
    guard let view else { return }
    view.preferredFramesPerSecond = enabled ? 60 : 0
    (view.layer as? CAMetalLayer)?.displaySyncEnabled = enabled
    if !enabled {
      DispatchQueue.main.async { [weak view] in
        view?.draw()
      }
    }
  }

  private func drawNextFrameIfDisplaySyncIsDisabled() {
    guard !appModel.renderDisplaySyncEnabled, let view else { return }
    view.draw()
  }

  private func updatePerformanceGraph() {
    appModel.performanceModel.history.recoveryThreshold = Double(appSettings.recoveryFPS)
    appModel.performanceModel.history.dropThreshold = Double(appSettings.dropFPS)
    appModel.performanceModel.history.add(
      last: core.timer.lastFPS,
      avg: core.timer.averageFPS,
      smoothed: core.timer.smoothedFPS,
      samplingRate: Double(core.activeOversampling),
      baseSamplingRate: Double(appSettings.oversampling)
    )
  }

  private struct ScreenshotCapture {
    let id: UUID
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    let bytesPerRow: Int
  }

  private func makeScreenshotCapture(
    from texture: MTLTexture,
    on commandBuffer: MTLCommandBuffer
  ) -> ScreenshotCapture? {
    guard let request = screenshotRequests.takePending() else { return nil }

    let width = texture.width
    let height = texture.height
    guard width > 0, height > 0 else {
      appModel.logger.warning(String(localized: "screenshot_failed_empty"))
      finishScreenshotRequest(id: request.id, result: .failure(ScreenshotError.emptyTexture))
      return nil
    }

    let bytesPerPixel = 4
    let unalignedBytesPerRow = width * bytesPerPixel
    let bytesPerRow = ((unalignedBytesPerRow + 255) / 256) * 256
    let byteCount = bytesPerRow * height
    guard let buffer = texture.device.makeBuffer(length: byteCount, options: .storageModeShared),
          let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
      appModel.logger.error(String(localized: "screenshot_failed_readback"))
      finishScreenshotRequest(id: request.id, result: .failure(ScreenshotError.readbackFailed))
      return nil
    }

    blitEncoder.copy(
      from: texture,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: MTLSize(width: width, height: height, depth: 1),
      to: buffer,
      destinationOffset: 0,
      destinationBytesPerRow: bytesPerRow,
      destinationBytesPerImage: byteCount
    )
    blitEncoder.endEncoding()

    return ScreenshotCapture(
      id: request.id,
      buffer: buffer,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow
    )
  }

  private func finishScreenshotCapture(_ capture: ScreenshotCapture?) {
    guard let capture,
          let request = screenshotRequests.complete(id: capture.id) else { return }
    defer {
      storedAppModel.stopAccessingDataDirectory(request.accessURL)
    }

    do {
      try writeScreenshot(capture, to: request.url)
      appModel.logger.info(
        String(
          format: String(localized: "screenshot_saved_format"),
          request.url.lastPathComponent
        )
      )
      request.completion(.success(request.url))
    } catch {
      appModel.logger.error(
        String(
          format: String(localized: "screenshot_failed_format"),
          error.localizedDescription
        )
      )
      request.completion(.failure(error))
    }
  }

  private func finishScreenshotRequest(id: UUID, result: Result<URL, Error>) {
    guard let request = screenshotRequests.complete(id: id) else { return }
    storedAppModel.stopAccessingDataDirectory(request.accessURL)
    request.completion(result)
  }

  private func cancelScreenshot(id: UUID, error: Error) {
    guard let request = screenshotRequests.cancel(id: id) else { return }
    storedAppModel.stopAccessingDataDirectory(request.accessURL)
    request.completion(.failure(error))
  }

  private func cancelAllScreenshots(error: Error) {
    for request in screenshotRequests.cancelAll() {
      storedAppModel.stopAccessingDataDirectory(request.accessURL)
      request.completion(.failure(error))
    }
  }

  private func writeScreenshot(_ capture: ScreenshotCapture, to url: URL) throws {
    let byteCount = capture.bytesPerRow * capture.height
    let data = Data(bytes: capture.buffer.contents(), count: byteCount)
    guard let dataProvider = CGDataProvider(data: data as CFData) else {
      throw ScreenshotError.imageCreationFailed
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
    )
    guard let image = CGImage(
      width: capture.width,
      height: capture.height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: capture.bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo,
      provider: dataProvider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else {
      throw ScreenshotError.imageCreationFailed
    }

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw ScreenshotError.destinationCreationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ScreenshotError.writeFailed
    }
  }

  private func uniqueScreenshotURL(in directory: URL) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let baseName = "BorgVR-\(formatter.string(from: Date()))"
    let fileManager = FileManager.default

    var url = directory.appendingPathComponent(baseName).appendingPathExtension("png")
    var index = 2
    while fileManager.fileExists(atPath: url.path) {
      url = directory
        .appendingPathComponent("\(baseName)-\(index)")
        .appendingPathExtension("png")
      index += 1
    }
    return url
  }

  private enum ScreenshotError: LocalizedError {
    case noDataset
    case emptyTexture
    case readbackFailed
    case imageCreationFailed
    case destinationCreationFailed
    case writeFailed

    var errorDescription: String? {
      switch self {
        case .noDataset:
          return String(localized: "screenshot_no_dataset")
        case .emptyTexture:
          return String(localized: "screenshot_failed_empty")
        case .readbackFailed:
          return String(localized: "screenshot_failed_readback")
        case .imageCreationFailed:
          return String(localized: "screenshot_error_image_creation")
        case .destinationCreationFailed:
          return String(localized: "screenshot_error_destination_creation")
        case .writeFailed:
          return String(localized: "screenshot_error_write")
      }
    }
  }
}
