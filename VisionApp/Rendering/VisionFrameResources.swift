import CompositorServices
import Metal

/// Reuses per-frame render targets and foveation parameters, independently of scene content.
/// Access is serialized by the renderer actor.
final class VisionFrameResources {
  private let device: MTLDevice
  private let rasterSampleCount: Int
  private let bufferCount: Int
  /// Current index into the memoryless target textures.
  var currentRenderTargetIndex: Int = 0
  /// Current index into the CPU-readable interaction-depth textures.
  var currentInteractionDepthIndex: Int = 0
  /// An array of memoryless target textures for multisampled rendering.
  var memorylessTargets: [(color: MTLTexture, depth: MTLTexture, interactionDepth: MTLTexture)?]
  /// Resolved interaction depth from recent frames.
  var interactionDepthTextures: [MTLTexture?]
  /// Parameter data copied from the drawable rasterization-rate map for shader-side foveation decisions.
  var rasterizationRateMapBuffer: MTLBuffer?

  init(device: MTLDevice, rasterSampleCount: Int, bufferCount: Int) {
    self.device = device
    self.rasterSampleCount = rasterSampleCount
    self.bufferCount = max(1, bufferCount)
    memorylessTargets = .init(repeating: nil, count: self.bufferCount)
    interactionDepthTextures = .init(repeating: nil, count: self.bufferCount)
  }

  func memorylessRenderTargets(
    drawable: LayerRenderer.Drawable,
    interactionDepthResolveTexture: MTLTexture
  ) -> (color: MTLTexture, depth: MTLTexture, interactionDepth: MTLTexture) {

    func renderTarget(resolveTexture: MTLTexture, cachedTexture: MTLTexture?) -> MTLTexture {
      if let cachedTexture,
        resolveTexture.width == cachedTexture.width && resolveTexture.height == cachedTexture.height
      {
        return cachedTexture
      } else {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: resolveTexture.pixelFormat,
          width: resolveTexture.width,
          height: resolveTexture.height,
          mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.textureType = .type2DMultisampleArray
        descriptor.sampleCount = rasterSampleCount
        descriptor.storageMode = .memoryless
        descriptor.arrayLength = resolveTexture.arrayLength
        return resolveTexture.device.makeTexture(descriptor: descriptor)!
      }
    }

    currentRenderTargetIndex = (currentRenderTargetIndex + 1) % bufferCount

    let cachedTargets = memorylessTargets[currentRenderTargetIndex]
    let newTargets = (
      renderTarget(
        resolveTexture: drawable.colorTextures[0],
        cachedTexture: cachedTargets?.color
      ),
      renderTarget(
        resolveTexture: drawable.depthTextures[0],
        cachedTexture: cachedTargets?.depth
      ),
      renderTarget(
        resolveTexture: interactionDepthResolveTexture,
        cachedTexture: cachedTargets?.interactionDepth
      )
    )

    memorylessTargets[currentRenderTargetIndex] = newTargets

    return newTargets
  }

  func interactionDepthTexture(drawable: LayerRenderer.Drawable) -> MTLTexture {
    currentInteractionDepthIndex =
      (currentInteractionDepthIndex + 1) % bufferCount
    let source = drawable.colorTextures[0]
    let viewCount = max(drawable.views.count, 1)
    if let texture = interactionDepthTextures[currentInteractionDepthIndex],
      texture.width == source.width,
      texture.height == source.height,
      texture.arrayLength == viewCount
    {
      return texture
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r32Float,
      width: source.width,
      height: source.height,
      mipmapped: false
    )
    descriptor.textureType = .type2DArray
    descriptor.arrayLength = viewCount
    descriptor.storageMode = .shared
    descriptor.usage = .renderTarget
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      fatalError("Failed to create the volume interaction-depth texture")
    }
    texture.label = "Volume Interaction Depth \(currentInteractionDepthIndex)"
    interactionDepthTextures[currentInteractionDepthIndex] = texture
    return texture
  }

  func bindRasterizationRateMap(
    _ rateMap: MTLRasterizationRateMap?,
    to renderEncoder: MTLRenderCommandEncoder
  ) {
    guard let rateMap else { return }

    let sizeAndAlign = rateMap.parameterDataSizeAndAlign
    let bufferLength = rasterizationRateMapBuffer?.length ?? 0
    if bufferLength < sizeAndAlign.size {
      rasterizationRateMapBuffer = device.makeBuffer(
        length: sizeAndAlign.size, options: .storageModeShared)
      rasterizationRateMapBuffer?.label = "Rasterization Rate Map Parameters"
    }

    guard let rasterizationRateMapBuffer else { return }
    rateMap.copyParameterData(buffer: rasterizationRateMapBuffer, offset: 0)
    renderEncoder.setFragmentBuffer(
      rasterizationRateMapBuffer,
      offset: 0,
      index: FragmentBufferIndex.rateMap.rawValue)
  }

}
