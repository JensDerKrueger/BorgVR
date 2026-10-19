import MetalKit
import UIKit

@MainActor
final class MobileVolumeRenderer: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
  private let session: ScreenBorgVRSession
  private let appModel: AppModel
  private let appSettings: AppSettings
  private let sharePlay: SharePlayCoordinator
  private let renderingParameters: RenderingParameters
  private let core: ScreenVolumeRendererCore
  private var twoFingerPanRecognizer: UIPanGestureRecognizer?
  private var frameInFlight = false
  private let screenshotRequests = ScreenScreenshotRequestQueue()

  init(
    session: ScreenBorgVRSession,
    sharePlay: SharePlayCoordinator
  ) {
    let appModel = session.runtimeState
    let appSettings = session.settingsState
    let renderingParameters = session.visualizationState
    self.session = session
    self.appModel = appModel
    self.appSettings = appSettings
    self.sharePlay = sharePlay
    self.renderingParameters = renderingParameters
    self.core = ScreenVolumeRendererCore(
      session: session,
      pipelineLabelPrefix: "iOS",
      loadLocalDataset: { try BORGVRFileData(filename: $0) },
      remoteCacheFilename: { datasetID in
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
          .appendingPathComponent("\(datasetID).data")
          .path
      },
      fallbackDrawableScale: { $0.contentScaleFactor }
    )
    super.init()
  }

  func attach(to view: MTKView) {
    core.attach(to: view)
    installInteractionGestures(on: view)
    appModel.renderScreenshotHandler = { [weak self, weak view] id, requestedURL, _, completion in
      Task { @MainActor in
        guard let self else {
          completion(.failure(AppModelError.rendererUnavailable))
          return
        }
        guard self.appModel.activeDataset != nil else {
          completion(.failure(BorgVRMCPCommandError.noDataset))
          return
        }
        let url = requestedURL ?? FileManager.default.temporaryDirectory
          .appendingPathComponent("BorgVR-\(UUID().uuidString)")
          .appendingPathExtension("png")
        let request = ScreenScreenshotRequest(
          id: id,
          url: url,
          accessURL: nil,
          completion: completion
        )
        guard self.screenshotRequests.enqueue(request) else {
          completion(.failure(BorgVRMCPCommandError.screenshotUnavailable))
          return
        }
        guard let view else {
          self.cancelScreenshot(id: id, error: AppModelError.rendererUnavailable)
          return
        }
        view.draw()
      }
    }
    appModel.renderScreenshotCancelHandler = { [weak self] id, error in
      self?.cancelScreenshot(id: id, error: error)
    }
  }

  func updateIfNeeded(for view: MTKView) {
    switch core.updateIfNeeded(for: view) {
      case .unchanged:
        break
      case .cleared:
        cancelAllScreenshots(error: AppModelError.rendererUnavailable)
        appModel.markRenderedDataset(key: "")
      case .loaded(let key, let metadata):
        cancelAllScreenshots(error: BorgVRMCPCommandError.screenshotUnavailable)
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

    let screenshot = makeScreenshotReadback(
      from: frame.drawable.texture,
      commandBuffer: frame.commandBuffer
    )
    frame.commandBuffer.addCompletedHandler { [weak self] commandBuffer in
      Task { @MainActor in
        guard let self else { return }
        let missingBrickCount = self.core.completeFrame(frame)
        self.appModel.recordCompletedRenderFrame(
          datasetKey: self.core.loadedDatasetKey,
          missingBrickCount: missingBrickCount
        )
        self.finishScreenshot(screenshot)
        self.frameInFlight = false
      }
    }
    frame.commandBuffer.present(frame.drawable)
    frame.commandBuffer.commit()
  }

  private struct PendingScreenshot {
    let id: UUID
    let readback: MetalScreenshotReadback
  }

  private func makeScreenshotReadback(
    from texture: MTLTexture,
    commandBuffer: MTLCommandBuffer
  ) -> PendingScreenshot? {
    guard let request = screenshotRequests.takePending() else { return nil }
    do {
      return PendingScreenshot(
        id: request.id,
        readback: try MetalScreenshotEncoder.encodeReadback(
          from: texture,
          commandBuffer: commandBuffer
        )
      )
    } catch {
      finishScreenshotRequest(id: request.id, result: .failure(error))
      return nil
    }
  }

  private func finishScreenshot(_ screenshot: PendingScreenshot?) {
    guard let screenshot,
          let request = screenshotRequests.complete(id: screenshot.id) else { return }
    do {
      let data = try MetalScreenshotEncoder.pngData(from: screenshot.readback)
      try data.write(to: request.url, options: .atomic)
      request.completion(.success(request.url))
    } catch {
      request.completion(.failure(error))
    }
  }

  private func finishScreenshotRequest(id: UUID, result: Result<URL, Error>) {
    guard let request = screenshotRequests.complete(id: id) else { return }
    request.completion(result)
  }

  private func cancelScreenshot(id: UUID, error: Error) {
    guard let request = screenshotRequests.cancel(id: id) else { return }
    request.completion(.failure(error))
  }

  private func cancelAllScreenshots(error: Error) {
    for request in screenshotRequests.cancelAll() {
      request.completion(.failure(error))
    }
  }

  private func installInteractionGestures(on view: MTKView) {
    guard twoFingerPanRecognizer == nil else { return }

    let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
    recognizer.minimumNumberOfTouches = 2
    recognizer.maximumNumberOfTouches = 2
    recognizer.cancelsTouchesInView = false
    recognizer.delegate = self
    view.addGestureRecognizer(recognizer)
    twoFingerPanRecognizer = recognizer
  }

  @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
    guard let view = recognizer.view as? MTKView else { return }

    guard appModel.interactionMode != .clipping else {
      recognizer.setTranslation(.zero, in: view)
      return
    }

    switch recognizer.state {
      case .began:
        recognizer.setTranslation(.zero, in: view)
      case .changed:
        let delta = recognizer.translation(in: view)
        recognizer.setTranslation(.zero, in: view)
        if appModel.interactionMode == .objectPlacement {
          if core.moveSelectedMarkerInDepth(by: delta.y) {
            session.commitExternalMutation(source: .touch, domain: .objects)
            sharePlay.synchronizeMarkers()
          }
        } else if appModel.interactionMode == .measurement {
          if core.moveSelectedMeasurementPointInDepth(by: delta.y) {
            session.commitExternalMutation(source: .touch, domain: .measurements)
            sharePlay.synchronizeMeasurements()
          }
        } else {
          core.panModel(by: delta, in: view)
          session.commitExternalMutation(source: .touch, domain: .visualization)
          sharePlay.synchronize(kind: .transformOnly)
        }
      case .ended, .cancelled, .failed:
        recognizer.setTranslation(.zero, in: view)
        if appModel.interactionMode == .objectPlacement || appModel.interactionMode == .measurement {
          sharePlay.flushSynchronization()
        }
      default:
        break
    }
  }

  nonisolated func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}
