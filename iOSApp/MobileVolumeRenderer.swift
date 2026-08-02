import Foundation
import Metal
import MetalKit
import simd
import UIKit

@MainActor
final class MobileVolumeRenderer: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
  private weak var view: MTKView?
  private let appModel: AppModel
  private let appSettings: AppSettings
  private let renderingParameters: RenderingParameters

  private var device: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineStateTF: MTLRenderPipelineState?
  private var pipelineStateTFL: MTLRenderPipelineState?
  private var pipelineStateIso: MTLRenderPipelineState?
  private var pipelineStateBrickVis: MTLRenderPipelineState?
  private var depthState: MTLDepthStencilState?
  private var cubeBuffer: MTLBuffer?
  private var vertexCount = 0
  private var uniformBufferVertex: AlignedBuffer<VertexUniformsArray>?
  private var uniformBufferFragment: AlignedBuffer<FragmentUniformsArray>?

  private var dataset: BORGVRDatasetProtocol?
  private var volumeAtlas: VolumeAtlas?
  private var hashTable: GPUHashtable?
  private var volumeScale = matrix_identity_float4x4
  private var loadedDatasetKey = ""
  private var pipelineDrawableWidth: Float = 0
  private var activeOversampling: Float = 1
  private let timer = CPUFrameTimer()
  private var twoFingerPanRecognizer: UIPanGestureRecognizer?
  private let cameraDistance: Float = 2.4
  private let fieldOfViewY: Float = .pi / 4
  private let minimumPipelineDrawableWidth: Float = 64
  private let pipelineWidthChangeThreshold: Float = 32
  private var frameInFlight = false

  init(appModel: AppModel, appSettings: AppSettings, renderingParameters: RenderingParameters) {
    self.appModel = appModel
    self.appSettings = appSettings
    self.renderingParameters = renderingParameters
    super.init()
    DispatchQueue.main.async { [appModel, timer] in
      appModel.timer = timer
    }
  }

  func attach(to view: MTKView) {
    self.view = view
    self.device = view.device
    self.commandQueue = view.device?.makeCommandQueue()
    renderingParameters.transferFunction.initMetal(device: view.device!)
    installInteractionGestures(on: view)

    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .less
    depthDescriptor.isDepthWriteEnabled = true
    depthState = view.device?.makeDepthStencilState(descriptor: depthDescriptor)

    let cube = Tesselation.genBrick(
      center: SIMD3<Float>(0, 0, 0),
      size: SIMD3<Float>(1, 1, 1),
      texScale: SIMD3<Float>(1, 1, 1)
    ).unpack()
    vertexCount = cube.vertices.count
    cubeBuffer = view.device?.makeBuffer(
      bytes: cube.vertices,
      length: MemoryLayout<SIMD3<Float>>.stride * cube.vertices.count,
      options: .storageModeShared
    )

    uniformBufferVertex = try? AlignedBuffer<VertexUniformsArray>(device: view.device!, capacity: 2)
    uniformBufferFragment = try? AlignedBuffer<FragmentUniformsArray>(device: view.device!, capacity: 2)
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
    guard let view = recognizer.view else { return }

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

        let viewWidth = max(1, Float(view.bounds.width))
        let viewHeight = max(1, Float(view.bounds.height))
        let visibleHeight = 2 * tan(fieldOfViewY * 0.5) * cameraDistance
        let visibleWidth = visibleHeight * viewWidth / viewHeight

        renderingParameters.pan.x += Float(delta.x) * visibleWidth / viewWidth
        renderingParameters.pan.y -= Float(delta.y) * visibleHeight / viewHeight
      case .ended, .cancelled, .failed:
        recognizer.setTranslation(.zero, in: view)
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

  func updateIfNeeded(for view: MTKView) {
    let key = appModel.activeDataset.map { "\($0.source)-\($0.identifier)" } ?? ""
    guard key != loadedDatasetKey else { return }

    guard !key.isEmpty else {
      clearDatasetResources()
      return
    }

    clearPipelineStates()
    do {
      try loadDataset(for: view)
      loadedDatasetKey = key
    } catch {
      clearPipelineStates()
      loadedDatasetKey = ""
      appModel.logger.error("Renderer setup failed: \(error.localizedDescription)")
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    let width = Float(size.width)
    if pipelineDrawableWidth > 0,
       abs(width - pipelineDrawableWidth) > pipelineWidthChangeThreshold {
      clearPipelineStates()
    }
  }

  func draw(in view: MTKView) {
    guard !frameInFlight else { return }

    guard let commandQueue,
          let cubeBuffer,
          let volumeAtlas,
          let hashTable,
          let uniformBufferVertex,
          let uniformBufferFragment,
          let depthState else {
      return
    }

    guard ensurePipelines(for: view),
          let drawable = view.currentDrawable,
          let renderPassDescriptor = view.currentRenderPassDescriptor,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      return
    }
    frameInFlight = true

    updateUniforms(for: view)
    updateEmptiness()

    renderEncoder.setCullMode(.front)
    renderEncoder.setFrontFacing(.counterClockwise)
    renderEncoder.setDepthStencilState(depthState)

    guard let pipelineState = activePipelineState() else {
      renderEncoder.endEncoding()
      commandBuffer.addCompletedHandler { [weak self] _ in
        Task { @MainActor in
          self?.frameInFlight = false
        }
      }
      commandBuffer.present(drawable)
      commandBuffer.commit()
      return
    }
    renderEncoder.setRenderPipelineState(pipelineState)

    renderEncoder.setVertexBuffer(cubeBuffer, offset: 0, index: VertexBufferIndex.meshPositions.rawValue)
    uniformBufferVertex.bindVertex(to: renderEncoder, index: VertexBufferIndex.uniforms.rawValue)
    uniformBufferFragment.bindFragment(to: renderEncoder, index: FragmentBufferIndex.uniforms.rawValue)
    volumeAtlas.bind(
      to: renderEncoder,
      atlasIndex: TextureIndex.volumeAtlas.rawValue,
      metaIndex: FragmentBufferIndex.brickMeta.rawValue,
      levelIndex: FragmentBufferIndex.levelTable.rawValue
    )
    do {
      try renderingParameters.transferFunction.bind(to: renderEncoder, index: TextureIndex.transferFunction.rawValue)
    } catch {
      appModel.logger.error("Failed to bind transfer function: \(error.localizedDescription)")
    }
    hashTable.bind(to: renderEncoder, index: FragmentBufferIndex.hashTable.rawValue)

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    renderEncoder.endEncoding()

    commandBuffer.addCompletedHandler { [weak self] completedBuffer in
      Task { @MainActor in
        guard let self else { return }
        self.readBackHashTable(commandBuffer: completedBuffer)
        self.timer.frameRendered()
        self.frameInFlight = false
      }
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func activePipelineState() -> MTLRenderPipelineState? {
    if renderingParameters.brickVis {
      return pipelineStateBrickVis
    }

    switch renderingParameters.renderMode {
      case .transferFunction1D:
        return pipelineStateTF
      case .transferFunction1DLighting:
        return pipelineStateTFL
      case .isoValue:
        return pipelineStateIso
    }
  }

  private func clearPipelineStates() {
    pipelineStateTF = nil
    pipelineStateTFL = nil
    pipelineStateIso = nil
    pipelineStateBrickVis = nil
    pipelineDrawableWidth = 0
  }

  private func clearDatasetResources() {
    dataset = nil
    volumeAtlas = nil
    hashTable = nil
    loadedDatasetKey = ""
    clearPipelineStates()
  }

  private func loadDataset(for view: MTKView) throws {
    guard let device = view.device else { return }
    let newDataset: BORGVRDatasetProtocol
    guard let activeDataset = appModel.activeDataset else { return }
    switch activeDataset.source {
      case .builtIn:
        newDataset = try BORGVRFileData(filename: activeDataset.identifier)
      case .local:
        newDataset = try BORGVRFileData(filename: activeDataset.identifier)
      case let .remote(address, port):
        let manager = BORGVRRemoteDataManager(
          host: address,
          port: UInt16(port),
          logger: appModel.logger,
          notifier: nil
        )
        try manager.connect(timeout: appSettings.timeout)
        let cacheURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
          .appendingPathComponent("\(activeDataset.identifier).data")
        if let cacheURL, appSettings.makeLocalCopy {
          appModel.logger.dev("Remote dataset will be cached at \(cacheURL.path)")
        }
        newDataset = try manager.openDataset(
          datasetID: activeDataset.identifier,
          timeout: appSettings.timeout,
          localCacheFilename: appSettings.makeLocalCopy ? cacheURL?.path : nil
        )
    }

    dataset = newDataset
    renderingParameters.reset()
    let metadata = newDataset.getMetadata()
    renderingParameters.updateRanges(
      minValue: metadata.minValue,
      maxValue: metadata.maxValue,
      rangeMax: metadata.rangeMax
    )
    if activeDataset.source == .local && appSettings.autoloadTF {
      let tfURL = URL(fileURLWithPath: activeDataset.identifier).deletingPathExtension().appendingPathExtension("tf1d")
      try? renderingParameters.transferFunction.load(from: tfURL)
    }

    activeOversampling = Float(appSettings.oversampling)
    let atlasSizeMB = appSettings.atlasSizeMB
    volumeAtlas = try VolumeAtlas(
      device: device,
      maxMemory: atlasSizeMB * 1024 * 1024,
      borgData: newDataset,
      transferFunction: renderingParameters.transferFunction,
      isoValue: renderingParameters.isoValue,
      logger: appModel.logger
    )
    pageInInitialBricks(dataset: newDataset)

    let minTableElementCount = minimumHashTableElements(metadata: metadata)
    hashTable = GPUHashtable(minTableElementCount: minTableElementCount, device: device, logger: appModel.logger)
    let maxExtend = Float(max(metadata.width, metadata.height, metadata.depth))
    let scale = SIMD3<Float>(
      metadata.aspectX * Float(metadata.width) / maxExtend,
      metadata.aspectY * Float(metadata.height) / maxExtend,
      metadata.aspectZ * Float(metadata.depth) / maxExtend
    )
    volumeScale = matrixScale(scale)
  }

  private func pageInInitialBricks(dataset: BORGVRDatasetProtocol) {
    guard let volumeAtlas else { return }
    let metadata = dataset.getMetadata()
    let start = metadata.brickMetadata.count - 2
    let count = min(appSettings.initialBricks, metadata.brickMetadata.count - 1)
    guard start >= 0, count > 0 else { return }
    let ids = (0..<count).map { start - $0 }
    try? volumeAtlas.pageIn(IDs: ids)
  }

  private func minimumHashTableElements(metadata: BORGVRMetaData) -> Int {
    let bytesPerBrick = metadata.componentCount * metadata.bytesPerComponent *
      metadata.brickSize * metadata.brickSize * metadata.brickSize
    return max(64, Int(ceil(Double(appSettings.minHashTableSize * 1024 * 1024) / Double(bytesPerBrick))))
  }

  private var pipelinesAreBuilt: Bool {
    pipelineStateTF != nil &&
      pipelineStateTFL != nil &&
      pipelineStateIso != nil &&
      pipelineStateBrickVis != nil
  }

  private func effectiveDrawableWidth(for view: MTKView) -> Float {
    let drawableWidth = Float(view.drawableSize.width)
    if drawableWidth >= minimumPipelineDrawableWidth {
      return drawableWidth
    }

    let scaledBoundsWidth = Float(view.bounds.width * view.contentScaleFactor)
    if scaledBoundsWidth >= minimumPipelineDrawableWidth {
      return scaledBoundsWidth
    }

    return 0
  }

  private func ensurePipelines(for view: MTKView) -> Bool {
    guard let dataset else { return false }
    let drawableWidth = effectiveDrawableWidth(for: view)
    guard drawableWidth >= minimumPipelineDrawableWidth else { return false }

    if pipelinesAreBuilt,
       abs(drawableWidth - pipelineDrawableWidth) <= pipelineWidthChangeThreshold {
      return true
    }

    do {
      try buildPipelines(for: view, metadata: dataset.getMetadata(), drawableWidth: drawableWidth)
      pipelineDrawableWidth = drawableWidth
      return true
    } catch {
      clearPipelineStates()
      appModel.logger.error("Pipeline setup failed: \(error.localizedDescription)")
      return false
    }
  }

  private func buildPipelines(for view: MTKView, metadata: BORGVRMetaData, drawableWidth: Float) throws {
    guard let device = view.device, let hashTable else { return }
    let states = try VolumeRendererPipeline.buildRenderPipelines(
      device: device,
      colorFormat: view.colorPixelFormat,
      depthFormat: view.depthStencilPixelFormat,
      drawableWidth: drawableWidth,
      metadata: metadata,
      hashTable: hashTable,
      appSettings: appSettings,
      labelPrefix: "iOS"
    )
    pipelineStateTF = states.tf
    pipelineStateTFL = states.tfl
    pipelineStateIso = states.iso
    pipelineStateBrickVis = states.brick
  }

  private func updateUniforms(for view: MTKView) {
    guard let dataset,
          let uniformBufferVertex,
          let uniformBufferFragment else { return }
    uniformBufferVertex.advance()
    uniformBufferFragment.advance()

    let metadata = dataset.getMetadata()
    let aspect = Float(max(view.drawableSize.width, 1) / max(view.drawableSize.height, 1))
    let projection = matrixPerspective(fovyRadians: fieldOfViewY, aspect: aspect, nearZ: 0.05, farZ: 100)
    let viewMatrix = matrixTranslation(SIMD3<Float>(0, 0, -cameraDistance))
    let modelMatrix =
      matrixTranslation(SIMD3<Float>(renderingParameters.pan.x, renderingParameters.pan.y, 0)) *
      simd_float4x4(renderingParameters.orientation) *
      matrixScale(SIMD3<Float>(repeating: renderingParameters.scale)) *
      volumeScale

    let textureOffset = matrixTranslation(SIMD3<Float>(0.5, 0.5, 0.5))
    let viewToTexture = textureOffset * simd_inverse(viewMatrix * modelMatrix)
    let borderSize = Float(metadata.overlap + 1) / SIMD3<Float>(
      Float(metadata.width),
      Float(metadata.height),
      Float(metadata.depth)
    )
    let clipMin = renderingParameters.clipMin + borderSize
    let clipMax = renderingParameters.clipMax - borderSize
    let clipScale = clipMax - clipMin
    let clipMatrix = matrixTranslation(0.5 * (clipMax + clipMin - SIMD3<Float>(repeating: 1))) *
      matrixScale(clipScale)

    var vertexUniforms = VertexUniformsArray()
    vertexUniforms.uniforms.0 = VertexUniforms(
      modelViewProjectionMatrix: projection * viewMatrix * modelMatrix * clipMatrix,
      clipMatrix: clipMatrix
    )
    vertexUniforms.uniforms.1 = vertexUniforms.uniforms.0

    var fragmentUniforms = FragmentUniformsArray()
    fragmentUniforms.uniforms.0 = FragmentUniforms(
      isoValue: renderingParameters.isoValue,
      oversampling: activeOversampling,
      transferBias: renderingParameters.transferFunction.textureBias,
      cameraPosInTextureSpace: simd_make_float3(viewToTexture * SIMD4<Float>(0, 0, 0, 1)),
      cameraPosInTextureSpaceVoxelScaled: simd_make_float3(viewToTexture * SIMD4<Float>(0, 0, 0, 1)),
      cubeBounds: (clipMin, clipMax),
      modelView: viewMatrix * modelMatrix,
      modelViewIT: simd_transpose(simd_inverse(viewMatrix * modelMatrix))
    )
    fragmentUniforms.uniforms.1 = fragmentUniforms.uniforms.0

    uniformBufferVertex.current = vertexUniforms
    uniformBufferFragment.current = fragmentUniforms
  }

  private func updateEmptiness() {
    guard let volumeAtlas else { return }
    switch renderingParameters.renderMode {
      case .transferFunction1D, .transferFunction1DLighting:
        volumeAtlas.updateEmptiness(transferFunction: renderingParameters.transferFunction)
      case .isoValue:
        volumeAtlas.updateEmptiness(isoValue: renderingParameters.isoValue)
    }
  }

  private func readBackHashTable(commandBuffer: MTLCommandBuffer) {
    guard let hashTable, let volumeAtlas else { return }
    let missingBricks = hashTable.getValues(from: commandBuffer)
    guard !missingBricks.isEmpty else { return }
    try? volumeAtlas.pageIn(IDs: missingBricks.map(Int.init).sorted(by: >))
  }
}
