import MetalKit
import SwiftUI

@MainActor
final class MobileRenderSurface: ObservableObject {
  private weak var view: MTKView?

  func attach(to view: MTKView) {
    self.view = view
  }

  func localPointAndSize(forGlobalPoint point: CGPoint) -> (point: CGPoint, size: CGSize)? {
    guard let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
      return nil
    }
    let localPoint = view.convert(point, from: nil)
    return (
      CGPoint(
        x: localPoint.x - view.bounds.minX,
        y: localPoint.y - view.bounds.minY
      ),
      view.bounds.size
    )
  }

  func normalizedScreenPosition(forGlobalPoint point: CGPoint) -> SIMD2<Float>? {
    guard let local = localPointAndSize(forGlobalPoint: point) else { return nil }
    return SIMD2<Float>(
      Float(local.point.x / local.size.width),
      Float(1 - local.point.y / local.size.height)
    )
  }
}

struct MobileMetalView: UIViewRepresentable {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings
  @EnvironmentObject private var sharePlay: SharePlayCoordinator
  let renderSurface: MobileRenderSurface

  func makeCoordinator() -> MobileVolumeRenderer {
    MobileVolumeRenderer(
      appModel: appModel,
      appSettings: appSettings,
      renderingParameters: renderingParameters,
      sharePlay: sharePlay
    )
  }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView()
    view.device = MTLCreateSystemDefaultDevice()
    view.colorPixelFormat = .bgra8Unorm_srgb
    view.depthStencilPixelFormat = .depth32Float
    view.clearDepth = 0
    view.isOpaque = false
    view.backgroundColor = .clear
    view.layer.isOpaque = false
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.preferredFramesPerSecond = 60
    view.delegate = context.coordinator
    context.coordinator.attach(to: view)
    renderSurface.attach(to: view)
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    let coordinator = context.coordinator
    DispatchQueue.main.async {
      coordinator.updateIfNeeded(for: view)
    }
  }
}
