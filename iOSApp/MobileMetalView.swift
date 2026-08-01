import MetalKit
import SwiftUI

struct MobileMetalView: UIViewRepresentable {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var renderingParameters: RenderingParameters
  @EnvironmentObject var appSettings: AppSettings

  func makeCoordinator() -> MobileVolumeRenderer {
    MobileVolumeRenderer(
      appModel: appModel,
      appSettings: appSettings,
      renderingParameters: renderingParameters
    )
  }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView()
    view.device = MTLCreateSystemDefaultDevice()
    view.colorPixelFormat = .bgra8Unorm_srgb
    view.depthStencilPixelFormat = .depth32Float
    view.isOpaque = false
    view.backgroundColor = .clear
    view.layer.isOpaque = false
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.preferredFramesPerSecond = 60
    view.delegate = context.coordinator
    context.coordinator.attach(to: view)
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    let coordinator = context.coordinator
    DispatchQueue.main.async {
      coordinator.updateIfNeeded(for: view)
    }
  }
}
