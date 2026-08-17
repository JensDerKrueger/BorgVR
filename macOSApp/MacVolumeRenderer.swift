import Foundation
import ImageIO
import Metal
import MetalKit
import simd
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacVolumeRenderer: NSObject, MTKViewDelegate {
  private weak var view: MTKView?
  private let appModel: AppModel
  private let appSettings: AppSettings
  private let renderingParameters: RenderingParameters
  private let storedAppModel: StoredAppModel

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
  private var dataDirectoryAccessURL: URL?
  private var volumeScale = matrix_identity_float4x4
  private var loadedDatasetKey = ""
  private var pipelineDrawableWidth: Float = 0
  private var activeOversampling: Float = 1
  private let timer = CPUFrameTimer()
  private let cameraDistance: Float = 2.4
  private let fieldOfViewY: Float = .pi / 4
  private let minimumPipelineDrawableWidth: Float = 64
  private let pipelineWidthChangeThreshold: Float = 32
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
    self.appModel = appModel
    self.appSettings = appSettings
    self.renderingParameters = renderingParameters
    self.storedAppModel = storedAppModel
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
    let key = appModel.activeDatasetRenderKey
    guard key != loadedDatasetKey else { return }

    guard !key.isEmpty else {
      clearDatasetResources()
      return
    }

    clearPipelineStates()
    do {
      try loadDataset(for: view)
      loadedDatasetKey = key
      appModel.markRenderedDataset(key: key)
    } catch {
      clearPipelineStates()
      loadedDatasetKey = ""
      appModel.markRenderedDatasetFailed(key: key)
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
    let screenshotURL: URL
    if let requestedURL {
      screenshotURL = requestedURL
    } else {
      screenshotURL = uniqueScreenshotURL(in: storedAppModel.resolvedDataDirectoryURL())
    }

    let directoryURL = screenshotURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
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
          guard let self else { return }
          self.frameInFlight = false
          self.drawNextFrameIfDisplaySyncIsDisabled()
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

    let screenshotCapture = makeScreenshotCapture(
      from: drawable.texture,
      on: commandBuffer
    )

    commandBuffer.addCompletedHandler { [weak self] completedBuffer in
      Task { @MainActor in
        guard let self else { return }
        let missingBrickCount = self.readBackHashTable(commandBuffer: completedBuffer)
        self.appModel.recordCompletedRenderFrame(
          datasetKey: self.loadedDatasetKey,
          missingBrickCount: missingBrickCount
        )
        self.finishScreenshotCapture(screenshotCapture)
        self.timer.frameRendered()
        self.frameInFlight = false
        self.drawNextFrameIfDisplaySyncIsDisabled()
      }
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
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
    storedAppModel.stopAccessingDataDirectory(dataDirectoryAccessURL)
    dataDirectoryAccessURL = nil
    dataset = nil
    volumeAtlas = nil
    hashTable = nil
    loadedDatasetKey = ""
    appModel.markRenderedDataset(key: "")
    appModel.resetBrickReadbackState()
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
        let accessURL = storedAppModel.startAccessingDataDirectory()
        do {
          newDataset = try BORGVRFileData(filename: activeDataset.identifier)
          dataDirectoryAccessURL = accessURL
        } catch {
          storedAppModel.stopAccessingDataDirectory(accessURL)
          throw error
        }
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
    appModel.resetBrickReadbackState()
    renderingParameters.reset()
    let metadata = newDataset.getMetadata()
    renderingParameters.updateRanges(
      minValue: metadata.minValue,
      maxValue: metadata.maxValue,
      rangeMax: metadata.rangeMax
    )
    if appSettings.autoloadTF, let tfURL = appModel.transferFunctionFileURL(for: activeDataset) {
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

    let scaledBoundsWidth = Float(view.bounds.width * (view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1))
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
      labelPrefix: "BorgVR"
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

  private func readBackHashTable(commandBuffer: MTLCommandBuffer) -> Int {
    guard let hashTable, let volumeAtlas else { return 0 }
    let missingBricks = hashTable.getValues(from: commandBuffer)
    guard !missingBricks.isEmpty else { return 0 }
    try? volumeAtlas.pageIn(IDs: missingBricks.map(Int.init).sorted(by: >))
    return missingBricks.count
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
    guard let buffer = device?.makeBuffer(length: byteCount, options: .storageModeShared),
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
