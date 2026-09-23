import MetalKit
import UIKit

@MainActor
final class MobileVolumeRenderer: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
  private let appModel: AppModel
  private let sharePlay: SharePlayCoordinator
  private let core: ScreenVolumeRendererCore
  private var twoFingerPanRecognizer: UIPanGestureRecognizer?
  private var frameInFlight = false

  init(
    appModel: AppModel,
    appSettings: AppSettings,
    renderingParameters: RenderingParameters,
    sharePlay: SharePlayCoordinator
  ) {
    self.appModel = appModel
    self.sharePlay = sharePlay
    self.core = ScreenVolumeRendererCore(
      appModel: appModel,
      appSettings: appSettings,
      renderingParameters: renderingParameters,
      pipelineLabelPrefix: "iOS",
      loadLocalDataset: { try BORGVRFileData(filename: $0) },
      fallbackDrawableScale: { $0.contentScaleFactor }
    )
    super.init()
  }

  func attach(to view: MTKView) {
    core.attach(to: view)
    installInteractionGestures(on: view)
  }

  func updateIfNeeded(for view: MTKView) {
    _ = core.updateIfNeeded(for: view)
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

    frame.commandBuffer.addCompletedHandler { [weak self] commandBuffer in
      Task { @MainActor in
        guard let self else { return }
        _ = self.core.completeFrame(commandBuffer)
        self.frameInFlight = false
      }
    }
    frame.commandBuffer.present(frame.drawable)
    frame.commandBuffer.commit()
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
        if appModel.interactionMode == .marker {
          _ = core.moveSelectedMarkerInDepth(by: delta.y)
        } else {
          core.panModel(by: delta, in: view)
        }
      case .ended, .cancelled, .failed:
        recognizer.setTranslation(.zero, in: view)
        if appModel.interactionMode == .marker {
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
