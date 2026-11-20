import AppKit
import Metal
import MetalKit

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
    appModel.renderAtlasPurgeHandler = { [weak self] in
      self?.core.requestAtlasPurge()
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
      let normalize = self.appSettings.normalizeIsoSurfaceExport
      let edits = appModel.volumeBrush
      let exportID: UUID
      do { exportID = try edits.beginReadOnlyExport { cancellationToken.cancel() } }
      catch { completion(.failure(error)); return }
      Task {
        let result: Result<BorgVRIsoSurfaceExtractor.Result, Error>
        do {
          try await edits.prepareReadOnlyExport(id: exportID)
          try cancellationToken.checkCancellation()
          result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
              continuation.resume(returning: Result {
                try BorgVRIsoSurfaceExtractor.extract(
                  dataset: sendableDataset.value,
                  normalizedIsoValue: normalizedIsoValue,
                  outputURL: outputURL,
                  normalize: normalize,
                  logger: logger,
                  cancellationToken: cancellationToken,
                  progress: progress
                )
              })
            }
          }
        } catch { result = .failure(error) }
        edits.finishReadOnlyExport(id: exportID)
        completion(result)
      }
    }
    setDisplaySyncEnabled(appModel.renderDisplaySyncEnabled)
  }

  func detach() {
    core.detach()
    view = nil
  }

  func updateIfNeeded(for view: MTKView) async {
    switch await core.updateIfNeeded(for: view) {
      case .unchanged:
        break
      case .cleared:
        cancelAllScreenshots(error: AppModelError.rendererUnavailable)
        appModel.markRenderedDataset(key: "")
        resetRenderTracking()
      case .loaded(let key, let metadata, let requestID):
        cancelAllScreenshots(error: BorgVRMCPCommandError.screenshotUnavailable)
        resetRenderTracking()
        appModel.prepareDatasetRenderer(key: key, metadata: metadata, requestID: requestID)
        appModel.loadAutomaticallyManagedDatasetState(
          appSettings: appSettings,
          metadata: metadata,
          renderingParameters: renderingParameters
        )
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

    let screenshotCapture = makeScreenshotCapture(from: frame)
    frame.commandBuffer.addCompletedHandler { [weak self] commandBuffer in
      Task { @MainActor in
        guard let self, self.core.isAttached else { return }
        if commandBuffer.status == .completed, frame.renderedVolume,
           self.appModel.markRenderedDataset(key: frame.datasetKey, requestID: frame.requestID) {
          self.sharePlay.datasetRendererDidLoad()
        }
        let missingBrickCount = self.core.completeFrame(frame)
        self.appModel.recordCompletedRenderFrame(
          datasetKey: frame.datasetKey,
          missingBrickCount: missingBrickCount
        )
        if commandBuffer.status == .completed {
          self.finishScreenshotCapture(screenshotCapture)
        } else if let screenshotCapture {
          self.finishScreenshotRequest(id: screenshotCapture.id, result: .failure(MetalScreenshotError.readbackFailed))
        }
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
      completion(.failure(BorgVRMCPCommandError.noDataset))
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
    appModel.screenshotCache.begin(id)
    guard let view else {
      cancelScreenshot(id: id, error: AppModelError.rendererUnavailable)
      return
    }
    view.draw()
  }

  private func resetRenderTracking() {
    appModel.resetBrickReadbackState()
    appModel.performanceModel.history = PerformanceHistory()
    appModel.atlasPagingModel.reset()
    recordAtlasPaging()
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
    recordAtlasPaging()
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

  private func recordAtlasPaging() {
    guard let statistics = core.atlasPagingStatistics else { return }
    appModel.atlasPagingModel.record(timestamp: CACurrentMediaTime(), statistics: statistics)
  }

  private struct ScreenshotCapture {
    let id: UUID
    let readback: MetalPairedScreenshotReadback
  }

  private func makeScreenshotCapture(from frame: ScreenVolumeEncodedFrame) -> ScreenshotCapture? {
    guard let request = screenshotRequests.takePending() else { return nil }
    do {
      return ScreenshotCapture(id: request.id, readback: try MetalScreenshotEncoder.encodePairedReadback(
        color: frame.drawable.texture, depth: frame.interactionDepthTexture,
        textureToClip: frame.textureToClip, commandBuffer: frame.commandBuffer))
    } catch {
      finishScreenshotRequest(id: request.id, result: .failure(error))
      return nil
    }
  }

  private func finishScreenshotCapture(_ capture: ScreenshotCapture?) {
    guard let capture,
          let request = screenshotRequests.complete(id: capture.id) else { return }
    defer {
      storedAppModel.stopAccessingDataDirectory(request.accessURL)
    }

    do {
      let png = try MetalScreenshotEncoder.pngData(from: capture.readback.color)
      try png.write(to: request.url, options: .atomic)
      if let positions = capture.readback.positionReadback?.positions() {
        appModel.screenshotCache.store(positions, id: request.id, renderedFrame: appModel.completedRenderFrameCount)
      }
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

}
