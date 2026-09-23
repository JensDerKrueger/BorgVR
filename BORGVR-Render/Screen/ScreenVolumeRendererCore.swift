import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

#if os(iOS) || os(macOS)

enum ScreenDatasetUpdate {
  case unchanged
  case cleared
  case loaded(String)
  case failed(String, Error)
}

struct ScreenVolumeEncodedFrame {
  let commandBuffer: MTLCommandBuffer
  let drawable: CAMetalDrawable
}

@MainActor
final class ScreenVolumeRendererCore {
  private weak var view: MTKView?
  private let appModel: AppModel
  private let appSettings: AppSettings
  private let renderingParameters: RenderingParameters
  private let pipelineLabelPrefix: String
  private let loadLocalDataset: (String) throws -> BORGVRDatasetProtocol
  private let releaseDatasetAccess: () -> Void
  private let fallbackDrawableScale: (MTKView) -> CGFloat

  private var device: MTLDevice?
  private var commandQueue: MTLCommandQueue?
  private var pipelineStateTF: MTLRenderPipelineState?
  private var pipelineStateTFL: MTLRenderPipelineState?
  private var pipelineStateIso: MTLRenderPipelineState?
  private var pipelineStateBrickVis: MTLRenderPipelineState?
  private var pipelineStateMarker: MTLRenderPipelineState?
  private var pipelineStateMarkerComposite: MTLRenderPipelineState?
  private var depthState: MTLDepthStencilState?
  private var cubeBuffer: MTLBuffer?
  private var vertexCount = 0
  private var uniformBufferVertex: AlignedBuffer<VertexUniformsArray>?
  private var uniformBufferFragment: AlignedBuffer<FragmentUniformsArray>?

  private var dataset: BORGVRDatasetProtocol?
  private var volumeAtlas: VolumeAtlas?
  private var hashTable: GPUHashtable?
  private var volumeScale = matrix_identity_float4x4
  private(set) var loadedDatasetKey = ""
  private var pipelineDrawableWidth: Float = 0
  private(set) var activeOversampling: Float = 1
  private var configuredOversamplingMode = ""
  let timer = CPUFrameTimer()
  private let cameraDistance: Float = 2.4
  private let fieldOfViewY: Float = .pi / 4
  private let minimumPipelineDrawableWidth: Float = 64
  private let pipelineWidthChangeThreshold: Float = 32
  private let markerRenderer = ScreenVolumeMarkerRenderer()

  init(
    appModel: AppModel,
    appSettings: AppSettings,
    renderingParameters: RenderingParameters,
    pipelineLabelPrefix: String,
    loadLocalDataset: @escaping (String) throws -> BORGVRDatasetProtocol,
    releaseDatasetAccess: @escaping () -> Void = {},
    fallbackDrawableScale: @escaping (MTKView) -> CGFloat
  ) {
    self.appModel = appModel
    self.appSettings = appSettings
    self.renderingParameters = renderingParameters
    self.pipelineLabelPrefix = pipelineLabelPrefix
    self.loadLocalDataset = loadLocalDataset
    self.releaseDatasetAccess = releaseDatasetAccess
    self.fallbackDrawableScale = fallbackDrawableScale
    DispatchQueue.main.async { [appModel, timer] in
      appModel.timer = timer
    }
  }

  func attach(to view: MTKView) {
    self.view = view
    self.device = view.device
    self.commandQueue = view.device?.makeCommandQueue()
    renderingParameters.transferFunction.initMetal(device: view.device!)

    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .greater
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
    appModel.markerPositionHandler = { [weak self] screenPosition, existingPosition in
      self?.markerPosition(at: screenPosition, preservingDepthOf: existingPosition)
    }
    appModel.markerHitTestHandler = { [weak self] screenPosition in
      self?.markerHit(at: screenPosition)
    }
    appModel.markerDirectionOriginHandler = { [weak self] screenPosition in
      self?.markerDirectionOrigin(at: screenPosition)
    }
    appModel.markerDepthAdjustmentHandler = { [weak self] position, worldDistance in
      self?.markerPosition(position, offsetAlongViewRayBy: worldDistance)
    }
  }

  func updateIfNeeded(for view: MTKView) -> ScreenDatasetUpdate {
    let key = appModel.activeDatasetRenderKey
    guard key != loadedDatasetKey else { return .unchanged }

    guard !key.isEmpty else {
      clearDatasetResources()
      return .cleared
    }

    clearPipelineStates()
    do {
      try loadDataset(for: view)
      loadedDatasetKey = key
      return .loaded(key)
    } catch {
      clearDatasetResources()
      appModel.logger.error("Renderer setup failed: \(error.localizedDescription)")
      return .failed(key, error)
    }
  }

  func drawableSizeWillChange(_ size: CGSize) {
    let width = Float(size.width)
    if pipelineDrawableWidth > 0,
       abs(width - pipelineDrawableWidth) > pipelineWidthChangeThreshold {
      clearPipelineStates()
    }
  }

  func encodeFrame(in view: MTKView) -> ScreenVolumeEncodedFrame? {
    guard let commandQueue,
          let cubeBuffer,
          let volumeAtlas,
          let hashTable,
          let uniformBufferVertex,
          let uniformBufferFragment,
          let depthState else {
      return nil
    }

    guard ensurePipelines(for: view),
          let drawable = view.currentDrawable,
          let renderPassDescriptor = view.currentRenderPassDescriptor,
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let device = view.device else {
      return nil
    }

    updateUniforms(for: view)
    updateEmptiness()

    let markerMatrices = markerFrameMatrices(for: view)
    guard let markerTargets = markerRenderer.renderPrepass(
      commandBuffer: commandBuffer,
      device: device,
      drawableSize: view.drawableSize,
      colorFormat: view.colorPixelFormat,
      depthFormat: view.depthStencilPixelFormat,
      markers: appModel.volumeMarkers,
      spatialStylusPreviews: appModel.activeRemoteSpatialStylusPreviews(),
      selectedMarkerID: appModel.selectedVolumeMarkerID,
      viewProjection: markerMatrices.projection * markerMatrices.view,
      modelMatrix: markerMatrices.model,
      volumeScale: volumeScale,
      eyePosition: SIMD3<Float>(0, 0, cameraDistance)
    ),
    let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      return nil
    }

    renderEncoder.setCullMode(.front)
    renderEncoder.setFrontFacing(.counterClockwise)
    renderEncoder.setDepthStencilState(depthState)

    guard let pipelineState = activePipelineState() else {
      renderEncoder.endEncoding()
      return nil
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
    markerRenderer.bindDepth(markerTargets.depth, to: renderEncoder)

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    markerRenderer.composite(
      colorTexture: markerTargets.color,
      depthTexture: markerTargets.depth,
      to: renderEncoder
    )
    renderEncoder.endEncoding()
    return ScreenVolumeEncodedFrame(commandBuffer: commandBuffer, drawable: drawable)
  }

  func completeFrame(_ commandBuffer: MTLCommandBuffer) -> Int {
    let missingBrickCount = readBackHashTable(commandBuffer: commandBuffer)
    timer.frameRendered()
    return missingBrickCount
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
    pipelineStateMarker = nil
    pipelineStateMarkerComposite = nil
    pipelineDrawableWidth = 0
    markerRenderer.resetTargets()
  }

  private func clearDatasetResources() {
    releaseDatasetAccess()
    dataset = nil
    volumeAtlas = nil
    hashTable = nil
    loadedDatasetKey = ""
    timer.reset()
    clearPipelineStates()
  }

  private func loadDataset(for view: MTKView) throws {
    guard let device = view.device else { return }
    let newDataset: BORGVRDatasetProtocol
    guard let activeDataset = appModel.activeDataset else { return }
    releaseDatasetAccess()
    switch activeDataset.source {
      case .builtIn:
        newDataset = try BORGVRFileData(filename: activeDataset.identifier)
      case .local:
        newDataset = try loadLocalDataset(activeDataset.identifier)
      case let .remote(address, port, password):
        let manager = BORGVRRemoteDataManager(
          host: address,
          port: UInt16(port),
          authSecret: password,
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
    timer.reset()
    renderingParameters.reset()
    let metadata = newDataset.getMetadata()
    renderingParameters.updateRanges(
      minValue: metadata.minValue,
      maxValue: metadata.maxValue,
      rangeMax: metadata.rangeMax
    )
    if appSettings.autoloadTF, let tfURL = appModel.transferFunctionFileURL(for: activeDataset) {
      try? renderingParameters.loadTransferFunction(from: tfURL)
    }

    activeOversampling = Float(appSettings.oversampling)
    configurePerformanceTracking()
    let atlasSizeMB = appSettings.atlasSizeMB
    volumeAtlas = try VolumeAtlas(
      device: device,
      maxMemory: atlasSizeMB * 1024 * 1024,
      borgData: newDataset,
      transferFunction: renderingParameters.transferFunction,
      isoValue: renderingParameters.isoValue,
      logger: appModel.logger
    )
    if let volumeAtlas {
      try? VolumeRenderResources.pageInInitialBricks(
        atlas: volumeAtlas,
        dataset: newDataset,
        maximumCount: appSettings.initialBricks
      )
    }

    let minTableElementCount = VolumeRenderResources.minimumHashTableElementCount(
      metadata: metadata,
      representedMemoryMB: appSettings.minHashTableSize,
      minimumElementCount: 64
    )
    hashTable = GPUHashtable(minTableElementCount: minTableElementCount, device: device, logger: appModel.logger)
    volumeScale = VolumeRenderResources.volumeScale(for: metadata)
  }

  private var pipelinesAreBuilt: Bool {
    pipelineStateTF != nil &&
      pipelineStateTFL != nil &&
      pipelineStateIso != nil &&
      pipelineStateBrickVis != nil &&
      pipelineStateMarker != nil &&
      pipelineStateMarkerComposite != nil
  }

  private func effectiveDrawableWidth(for view: MTKView) -> Float {
    let drawableWidth = Float(view.drawableSize.width)
    if drawableWidth >= minimumPipelineDrawableWidth {
      return drawableWidth
    }

    let scaledBoundsWidth = Float(view.bounds.width * fallbackDrawableScale(view))
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
      labelPrefix: pipelineLabelPrefix
    )
    pipelineStateTF = states.tf
    pipelineStateTFL = states.tfl
    pipelineStateIso = states.iso
    pipelineStateBrickVis = states.brick
    pipelineStateMarker = states.marker
    pipelineStateMarkerComposite = states.markerComposite
    markerRenderer.configure(
      device: device,
      markerPipeline: states.marker,
      compositePipeline: states.markerComposite
    )
  }

  private func markerFrameMatrices(for view: MTKView) -> (
    projection: simd_float4x4,
    view: simd_float4x4,
    model: simd_float4x4
  ) {
    let aspect = Float(max(view.drawableSize.width, 1) / max(view.drawableSize.height, 1))
    let projection = matrixPerspective(fovyRadians: fieldOfViewY, aspect: aspect, nearZ: 0.05, farZ: 100)
    let viewMatrix = matrixTranslation(SIMD3<Float>(0, 0, -cameraDistance))
    let modelMatrix =
      matrixTranslation(SIMD3<Float>(renderingParameters.pan.x, renderingParameters.pan.y, 0)) *
      simd_float4x4(renderingParameters.orientation) *
      matrixScale(SIMD3<Float>(repeating: renderingParameters.scale))
    return (projection, viewMatrix, modelMatrix)
  }

  private func markerRay(at normalizedScreenPosition: SIMD2<Float>) -> (
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    model: simd_float4x4
  )? {
    guard let view else { return nil }
    let matrices = markerFrameMatrices(for: view)
    let inverseViewProjection = simd_inverse(matrices.projection * matrices.view)
    let clipX = normalizedScreenPosition.x * 2 - 1
    let clipY = normalizedScreenPosition.y * 2 - 1
    var near = inverseViewProjection * SIMD4<Float>(clipX, clipY, 1, 1)
    var far = inverseViewProjection * SIMD4<Float>(clipX, clipY, 0, 1)
    guard abs(near.w) > 0.000001, abs(far.w) > 0.000001 else { return nil }
    near /= near.w
    far /= far.w
    let origin = SIMD3<Float>(near.x, near.y, near.z)
    let direction = simd_normalize(SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z))
    return (origin, direction, matrices.model)
  }

  private func markerPosition(
    at normalizedScreenPosition: SIMD2<Float>,
    preservingDepthOf existingPosition: SIMD3<Float>?
  ) -> SIMD3<Float>? {
    guard let ray = markerRay(at: normalizedScreenPosition) else { return nil }
    let fullModel = ray.model * volumeScale
    let referencePosition = existingPosition ?? SIMD3<Float>(repeating: 0.5)
    let referenceWorld = simd_make_float3(
      fullModel * SIMD4<Float>(referencePosition - SIMD3<Float>(repeating: 0.5), 1)
    )
    let distance = simd_dot(referenceWorld - ray.origin, ray.direction)
    let worldPosition = ray.origin + ray.direction * distance
    let local = simd_make_float3(simd_inverse(fullModel) * SIMD4<Float>(worldPosition, 1))
    return local + SIMD3<Float>(repeating: 0.5)
  }

  private func markerDirectionOrigin(
    at normalizedScreenPosition: SIMD2<Float>
  ) -> SIMD3<Float>? {
    guard let view else { return nil }
    let matrices = markerFrameMatrices(for: view)
    let cameraPosition = simd_make_float3(
      simd_inverse(matrices.view) * SIMD4<Float>(0, 0, 0, 1)
    )
    let fullModel = matrices.model * volumeScale
    let local = simd_make_float3(
      simd_inverse(fullModel) * SIMD4<Float>(cameraPosition, 1)
    )
    return local + SIMD3<Float>(repeating: 0.5)
  }

  private func markerHit(at normalizedScreenPosition: SIMD2<Float>) -> UUID? {
    guard let ray = markerRay(at: normalizedScreenPosition) else { return nil }
    var closestHit: (id: UUID, distance: Float)?
    let radiusScale = max(0.0001, renderingParameters.scale)
    for marker in appModel.volumeMarkers {
      for point in marker.points {
        let center = simd_make_float3(
          ray.model * volumeScale * SIMD4<Float>(point.position - SIMD3<Float>(repeating: 0.5), 1)
        )
        let toCenter = center - ray.origin
        let projectedDistance = simd_dot(toCenter, ray.direction)
        guard projectedDistance >= 0 else { continue }
        let closestPoint = ray.origin + ray.direction * projectedDistance
        guard simd_distance(closestPoint, center) <= point.radius * radiusScale else { continue }
        if closestHit == nil || projectedDistance < closestHit!.distance {
          closestHit = (marker.id, projectedDistance)
        }
      }
    }
    return closestHit?.id
  }

  @discardableResult
  func moveSelectedMarkerInDepth(
    by panDelta: CGFloat,
    sensitivity: Float = 0.003
  ) -> Bool {
    guard panDelta != 0,
          let markerID = appModel.selectedVolumeMarkerID,
          let index = appModel.volumeMarkers.firstIndex(where: { $0.id == markerID }),
          let position = appModel.markerDepthAdjustmentHandler?(
            appModel.volumeMarkers[index].position,
            Float(panDelta) * sensitivity
          ) else { return false }
    appModel.volumeMarkers[index].position = position
    return true
  }

  func panModel(by delta: CGPoint, in view: MTKView) {
    let viewWidth = max(1, Float(view.bounds.width))
    let viewHeight = max(1, Float(view.bounds.height))
    let visibleHeight = 2 * tan(fieldOfViewY * 0.5) * cameraDistance
    let visibleWidth = visibleHeight * viewWidth / viewHeight

    renderingParameters.pan.x += Float(delta.x) * visibleWidth / viewWidth
    renderingParameters.pan.y -= Float(delta.y) * visibleHeight / viewHeight
  }

  private func markerPosition(
    _ position: SIMD3<Float>,
    offsetAlongViewRayBy worldDistance: Float
  ) -> SIMD3<Float>? {
    guard let view else { return nil }
    let matrices = markerFrameMatrices(for: view)
    let fullModel = matrices.model * volumeScale
    let worldPosition = simd_make_float3(
      fullModel * SIMD4<Float>(position - SIMD3<Float>(repeating: 0.5), 1)
    )
    let cameraPosition = simd_make_float3(
      simd_inverse(matrices.view) * SIMD4<Float>(0, 0, 0, 1)
    )
    let cameraToMarker = worldPosition - cameraPosition
    let currentDistance = simd_length(cameraToMarker)
    guard currentDistance > 0.0001 else { return position }

    let newDistance = min(99, max(0.06, currentDistance + worldDistance))
    let newWorldPosition = cameraPosition + cameraToMarker / currentDistance * newDistance
    let localPosition = simd_make_float3(
      simd_inverse(fullModel) * SIMD4<Float>(newWorldPosition, 1)
    )
    return localPosition + SIMD3<Float>(repeating: 0.5)
  }

  private func updateUniforms(for view: MTKView) {
    guard let dataset,
          let uniformBufferVertex,
          let uniformBufferFragment else { return }
    updateActiveOversamplingForCurrentMode()
    updatePerformanceTrackingSettings()
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
      sampleJitter: appSettings.sampleJitter ? 1 : 0,
      transferBias: renderingParameters.transferFunction.textureBias,
      cameraPosInTextureSpace: simd_make_float3(viewToTexture * SIMD4<Float>(0, 0, 0, 1)),
      cameraPosInTextureSpaceVoxelScaled: simd_make_float3(viewToTexture * SIMD4<Float>(0, 0, 0, 1)),
      cubeBounds: (clipMin, clipMax),
      modelView: viewMatrix * modelMatrix,
      modelViewIT: simd_transpose(simd_inverse(viewMatrix * modelMatrix)),
      textureToClip: projection * viewMatrix * modelMatrix * matrixTranslation(SIMD3<Float>(repeating: -0.5))
    )
    fragmentUniforms.uniforms.1 = fragmentUniforms.uniforms.0

    uniformBufferVertex.current = vertexUniforms
    uniformBufferFragment.current = fragmentUniforms
  }

  private func updateActiveOversamplingForCurrentMode() {
    let baseOversampling = Float(appSettings.oversampling)
    if appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue {
      activeOversampling = min(activeOversampling, baseOversampling)
    } else {
      activeOversampling = baseOversampling
    }
  }

  private func updatePerformanceTrackingSettings() {
    timer.dropThreshold = Double(appSettings.dropFPS)
    timer.recoveryThreshold = Double(appSettings.recoveryFPS)
    timer.minimumDropDuration = 0.5
    if configuredOversamplingMode != appSettings.oversamplingMode {
      configurePerformanceTracking()
    }
  }

  private func configurePerformanceTracking() {
    configuredOversamplingMode = appSettings.oversamplingMode
    timer.dropThreshold = Double(appSettings.dropFPS)
    timer.recoveryThreshold = Double(appSettings.recoveryFPS)
    timer.minimumDropDuration = 0.5

    guard appSettings.oversamplingMode == OversamplingMode.dynamicMode.rawValue else {
      timer.onPerformanceTooSlow = nil
      timer.onPerformanceRecovered = nil
      return
    }

    timer.onPerformanceTooSlow = { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.activeOversampling < 0.5 {
          return
        }
        self.activeOversampling -= 0.1
      }
    }

    timer.onPerformanceRecovered = { [weak self] _, _ in
      MainActor.assumeIsolated {
        guard let self else { return false }
        let baseOversampling = Float(self.appSettings.oversampling)
        if self.activeOversampling >= baseOversampling {
          self.activeOversampling = baseOversampling
          return false
        }
        self.activeOversampling += 0.1
        return true
      }
    }
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

  private func readBackHashTable(commandBuffer: MTLCommandBuffer) -> Int {
    guard let hashTable, let volumeAtlas else { return 0 }
    let missingBricks = hashTable.getValues(from: commandBuffer)
    guard !missingBricks.isEmpty else { return 0 }
    try? volumeAtlas.pageIn(IDs: missingBricks.map(Int.init).sorted(by: >))
    return missingBricks.count
  }
}

#endif
