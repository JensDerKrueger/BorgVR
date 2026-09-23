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

  func release() {
    storedAppModel.stopAccessingDataDirectory(accessURL)
    accessURL = nil
  }
}

@MainActor
final class MacVolumeRenderer: NSObject, MTKViewDelegate {
  private weak var view: MTKView?
  private let appModel: AppModel
  private let appSettings: AppSettings
  private let storedAppModel: StoredAppModel
  private let datasetAccess: MacRendererDatasetAccess
  private let core: ScreenVolumeRendererCore
  private var frameInFlight = false
  private var pendingScreenshotURL: URL?
  private var pendingScreenshotAccessURL: URL?
  private var pendingScreenshotCompletion: ((Result<URL, Error>) -> Void)?

  init(
    appModel: AppModel,
    appSettings: AppSettings,
    renderingParameters: RenderingParameters,
    storedAppModel: StoredAppModel
  ) {
    let datasetAccess = MacRendererDatasetAccess(storedAppModel: storedAppModel)
    self.appModel = appModel
    self.appSettings = appSettings
    self.storedAppModel = storedAppModel
    self.datasetAccess = datasetAccess
    self.core = ScreenVolumeRendererCore(
      appModel: appModel,
      appSettings: appSettings,
      renderingParameters: renderingParameters,
      pipelineLabelPrefix: "BorgVR",
      loadLocalDataset: { try datasetAccess.load(filename: $0) },
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
    appModel.renderScreenshotHandler = { [weak self] url, accessURL, completion in
      Task { @MainActor in
        guard let self else {
          completion(.failure(AppModelError.rendererUnavailable))
          return
        }
        self.saveScreenshot(to: url, accessURL: accessURL, completion: completion)
      }
    }
    appModel.renderDisplaySyncHandler = { [weak self] enabled in
      self?.setDisplaySyncEnabled(enabled)
    }
    setDisplaySyncEnabled(appModel.renderDisplaySyncEnabled)
  }

  func updateIfNeeded(for view: MTKView) {
    switch core.updateIfNeeded(for: view) {
      case .unchanged:
        break
      case .cleared:
        appModel.markRenderedDataset(key: "")
        resetRenderTracking()
      case .loaded(let key):
        resetRenderTracking()
        appModel.markRenderedDataset(key: key)
      case .failed(let key, _):
        appModel.markRenderedDatasetFailed(key: key)
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    core.drawableSizeWillChange(size)
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
        let missingBrickCount = self.core.completeFrame(commandBuffer)
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
    saveScreenshot(to: nil, accessURL: nil) { [weak appModel] result in
      if case let .failure(error) = result {
        appModel?.logger.error(error.localizedDescription)
      }
    }
  }

  func saveScreenshot(
    to requestedURL: URL?,
    accessURL requestedAccessURL: URL?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard appModel.activeDataset != nil else {
      appModel.logger.warning(String(localized: "screenshot_no_dataset"))
      completion(.failure(ScreenshotError.noDataset))
      return
    }

    let accessURL = requestedAccessURL ?? storedAppModel.startAccessingDataDirectory()
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

    pendingScreenshotURL = screenshotURL
    pendingScreenshotAccessURL = accessURL
    pendingScreenshotCompletion = completion
    guard let view else {
      pendingScreenshotURL = nil
      pendingScreenshotAccessURL = nil
      pendingScreenshotCompletion = nil
      storedAppModel.stopAccessingDataDirectory(accessURL)
      completion(.failure(AppModelError.rendererUnavailable))
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
    let url: URL
    let accessURL: URL?
    let completion: ((Result<URL, Error>) -> Void)?
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    let bytesPerRow: Int
  }

  private func makeScreenshotCapture(
    from texture: MTLTexture,
    on commandBuffer: MTLCommandBuffer
  ) -> ScreenshotCapture? {
    guard let url = pendingScreenshotURL else { return nil }
    let accessURL = pendingScreenshotAccessURL
    let completion = pendingScreenshotCompletion
    pendingScreenshotURL = nil
    pendingScreenshotAccessURL = nil
    pendingScreenshotCompletion = nil

    let width = texture.width
    let height = texture.height
    guard width > 0, height > 0 else {
      storedAppModel.stopAccessingDataDirectory(accessURL)
      appModel.logger.warning(String(localized: "screenshot_failed_empty"))
      completion?(.failure(ScreenshotError.emptyTexture))
      return nil
    }

    let bytesPerPixel = 4
    let unalignedBytesPerRow = width * bytesPerPixel
    let bytesPerRow = ((unalignedBytesPerRow + 255) / 256) * 256
    let byteCount = bytesPerRow * height
    guard let buffer = texture.device.makeBuffer(length: byteCount, options: .storageModeShared),
          let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
      storedAppModel.stopAccessingDataDirectory(accessURL)
      appModel.logger.error(String(localized: "screenshot_failed_readback"))
      completion?(.failure(ScreenshotError.readbackFailed))
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
      url: url,
      accessURL: accessURL,
      completion: completion,
      buffer: buffer,
      width: width,
      height: height,
      bytesPerRow: bytesPerRow
    )
  }

  private func finishScreenshotCapture(_ capture: ScreenshotCapture?) {
    guard let capture else { return }
    defer {
      storedAppModel.stopAccessingDataDirectory(capture.accessURL)
    }

    do {
      try writeScreenshot(capture)
      appModel.logger.info(
        String(
          format: String(localized: "screenshot_saved_format"),
          capture.url.lastPathComponent
        )
      )
      capture.completion?(.success(capture.url))
    } catch {
      appModel.logger.error(
        String(
          format: String(localized: "screenshot_failed_format"),
          error.localizedDescription
        )
      )
      capture.completion?(.failure(error))
    }
  }

  private func writeScreenshot(_ capture: ScreenshotCapture) throws {
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
      capture.url as CFURL,
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
