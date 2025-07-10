import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import Observation
import RealityKit

// MARK: Custom Error

/**
 An error type representing failures in the renderer.
 */
enum RendererError: Error {
  /// Indicates that the provided vertex descriptor is invalid.
  case badVertexDescriptor

  /// A localized description of the error.
  var errorDescription: String? {
    switch self {
      case .badVertexDescriptor:
        return "Vertex Descriptor is invalid"
    }
  }
}

/**
 An actor responsible for rendering volume data with Metal.

 The Renderer actor creates and manages Metal objects such as buffers,
 pipeline states, and command queues. It also manages volume data and
 transfers data between CPU and GPU for rendering. The renderer uses an
 ARKit session for spatial tracking and integrates with a volume atlas.
 */
final actor Renderer {

  // MARK: Variables

  /// The Metal device used for rendering.
  let device: MTLDevice
  /// The command queue for issuing rendering commands.
  let commandQueue: MTLCommandQueue
  /// A dynamic buffer for vertex uniforms.
  var uniformBufferVertex: AlignedBuffer<VertexUniformsArray>
  /// A dynamic buffer for fragment uniforms.
  var uniformBufferFragment: AlignedBuffer<FragmentUniformsArray>
  /// Render pipeline state for transfer function rendering.
  var pipelineStateTF: MTLRenderPipelineState
  /// Render pipeline state for transfer function rendering with lighting.
  var pipelineStateTFL: MTLRenderPipelineState
  /// Render pipeline state for isosurface rendering.
  var pipelineStateIso: MTLRenderPipelineState
  /// Render pipeline state for visualizing bricks.
  var pipelineStateBrickVis: MTLRenderPipelineState
  /// Depth stencil state for rendering.
  var depthState: MTLDepthStencilState

  /// The BorgVR dataset.
  var borgData: BORGVRDatasetProtocol
  /// The volume atlas used for managing brick data.
  var volumeAtlas: VolumeAtlas
  /// A matrix representing the scale applied to the volume.
  var volumeScale: float4x4
  /// A GPU hashtable for indexing volume bricks.
  var hashTable: GPUHashtable

  /// A semaphore used to limit the number of frames in flight.
  let inFlightSemaphore: DispatchSemaphore

  /// The number of samples per pixel used during rasterization.
  let rasterSampleCount: Int
  /// Current index into the memoryless target textures.
  var currentRenderTargetIndex: Int = 0
  /// An array of memoryless target textures (color and depth) for rendering.
  var memorylessTargets: [(color: MTLTexture, depth: MTLTexture)?]

  /// An ARKit session for augmented reality tracking.
  let borgARProvider : BorgARProvider

  /// Current rotation value for the scene.
  var rotation: Float = 0

  /// A buffer containing vertex data for a cube.
  let cubeBuffer: MTLBuffer
  /// The number of vertices in the cube buffer.
  let vertexCount: Int

  /// The layer renderer used for rendering.
  let layerRenderer: LayerRenderer
  /// The application model containing global settings.
  let appModel: AppModel
  /// Application settings.
  let appSettings: AppSettings
  /// Rendering parameters such as transfer functions and isosurface values.
  let renderingParamaters: RenderingParamaters
  /// A CPU frame timer.
  let timer: CPUFrameTimer
  /// The initial oversampling factor.
  let initialOversampling: Float
  /// The drop FPS threshold.
  let dropFPS: Int
  /// The recovery FPS threshold.
  let recoveryFPS: Int
  /// A flag indicating whether dynamic oversampling is enabled.
  let dynamicOverSampling: Bool
  /// An optional logger for debug and error messages.
  let logger: LoggerBase?

  nonisolated(unsafe) var autoRotationAngle : Float

  var autoRotationStartTime : CFTimeInterval

  /// The current active oversampling factor (nonisolated).
  nonisolated(unsafe) var activeOversampling: Float

  // MARK: Init

  /**
   Initializes a new Renderer with the given parameters.

   This initializer creates all necessary Metal objects, pages in initial volume bricks,
   configures uniform buffers, builds render pipelines, and sets up AR and spatial
   tracking using ARKit.

   - Parameters:
   - layerRenderer: The layer renderer to be used.
   - appModel: The global application model.
   - appSettings: Application settings.
   - renderingParamaters: Rendering parameters including transfer function and
   isosurface value.
   - timer: A CPU frame timer.
   - dataset: The BorgVR dataset.
   - logger: An optional logger.
   */
  init(_ layerRenderer: LayerRenderer,
       appModel: AppModel,
       appSettings: AppSettings,
       renderingParamaters: RenderingParamaters,
       timer: CPUFrameTimer,
       dataset: BORGVRDatasetProtocol,
       logger: LoggerBase? = nil) throws {

    logger?.info("Loading dataset \(dataset.getMetadata().datasetDescription)")

    self.timer = timer
    self.initialOversampling = Float(appSettings.oversampling)
    self.activeOversampling = self.initialOversampling
    self.dropFPS = appSettings.dropFPS
    self.recoveryFPS = appSettings.recoveryFPS
    self.dynamicOverSampling = appSettings.oversamplingMode ==
    OversamplingMode.dynamicMode.rawValue
    self.logger = logger

    self.layerRenderer = layerRenderer
    self.device = layerRenderer.device
    self.commandQueue = self.device.makeCommandQueue()!
    self.appModel = appModel
    self.renderingParamaters = renderingParamaters

    self.autoRotationAngle = 0
    self.autoRotationStartTime = 0

    self.borgData = dataset

    let atlasSizeMB = AppSettings.int("atlasSizeMB")

    do {
      volumeAtlas = try VolumeAtlas(
        device: device,
        maxMemory: atlasSizeMB * 1024 * 1024,
        borgData: borgData,
        transferFunction: renderingParamaters.transferFunction,
        isoValue: renderingParamaters.isoValue,
        logger: logger
      )
      logger?.dev("VolumeAtlas created successfully.")
    } catch {
      logger?.error("Failed to create volume atlas: \(error)")
      fatalError()
    }

    let metadata = borgData.getMetadata()

    // Page in initial bricks for smoother rendering.
    let maxInitialBricks = AppSettings.int("initialBricks")

    let start = metadata.brickMetadata.count-3
    let count = min(maxInitialBricks,metadata.brickMetadata.count-2)
    let initialIDs = (0..<count).map { start - $0 }

    do {
      try volumeAtlas.pageIn(IDs: initialIDs)
      logger?.dev("\(initialIDs.count) initial bricks paged in successfully.")
    } catch {
      logger?.warning("Failed to page in all of the initial bricks: \(error)")
    }

    let minHashTableSize = AppSettings.int("minHashTableSize")


    let minTableElementCount : Int = Int(ceil(Double(minHashTableSize * 1024 * 1024) / Double(metadata.componentCount * metadata.bytesPerComponent * metadata.brickSize * metadata.brickSize * metadata.brickSize)))

    logger?.dev("HashTableSize of \(minHashTableSize) MB is converted to \(minTableElementCount) table elements.")

    self.hashTable = GPUHashtable(minTableElementCount: minTableElementCount, device: device, logger: logger)
    self.inFlightSemaphore = DispatchSemaphore(value: appModel.maxBuffersInFlight)

    let maxExtend = Float(max(metadata.width, metadata.height, metadata.depth))
    let scale = SIMD3<Float>(metadata.aspectX * Float(metadata.width) / maxExtend,
                             metadata.aspectY * Float(metadata.height) / maxExtend,
                             metadata.aspectZ * Float(metadata.depth) / maxExtend)
    self.volumeScale = Transform(scale: scale).matrix

    let device = self.device
    if appModel.useMultisamplingIfAvailable && device.supports32BitMSAA &&
        device.supportsTextureSampleCount(4) {
      self.rasterSampleCount = 4
    } else {
      self.rasterSampleCount = 1
    }

    self.memorylessTargets = .init(repeating: nil, count: appModel.maxBuffersInFlight)

    self.uniformBufferVertex = try AlignedBuffer<VertexUniformsArray>(
      device: device,
      capacity: appModel.maxBuffersInFlight
    )

    self.uniformBufferFragment = try AlignedBuffer<FragmentUniformsArray>(
      device: device,
      capacity: appModel.maxBuffersInFlight
    )

    do {
      (pipelineStateTF, pipelineStateTFL, pipelineStateIso, pipelineStateBrickVis) =
      try Renderer.buildRenderPipelinesWithDevice(
        device: device,
        layerRenderer: layerRenderer,
        rasterSampleCount: rasterSampleCount,
        borgVRMetaData: borgData.getMetadata(),
        hasTable: hashTable)
    } catch {
      fatalError("Unable to compile render pipeline state. Error info: \(error)")
    }

    let depthStateDescriptor = MTLDepthStencilDescriptor()
    depthStateDescriptor.depthCompareFunction = .greater
    depthStateDescriptor.isDepthWriteEnabled = true
    self.depthState = device.makeDepthStencilState(
      descriptor: depthStateDescriptor)!

    let cube = Tesselation.genBrick(
      center: SIMD3<Float>(x: 0, y: 0, z: 0),
      size: SIMD3<Float>(x: 1, y: 1, z: 1),
      texScale: SIMD3<Float>(x: 1, y: 1, z: 1)
    ).unpack()

    let alignedVertexDataCount = (cube.vertices.count + 15) & -16
    let vertexDataSize = MemoryLayout<SIMD3<Float>>.stride *
    alignedVertexDataCount

    var alignedVertices = cube.vertices
    let paddingCount = alignedVertexDataCount - cube.vertices.count
    let paddingElement = SIMD3<Float>(0, 0, 0)
    alignedVertices.append(contentsOf: Array(
      repeating: paddingElement, count: paddingCount))
    cubeBuffer = self.device.makeBuffer(
      length: vertexDataSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    cubeBuffer.contents().copyMemory(from: alignedVertices, byteCount: vertexDataSize)

    vertexCount = cube.vertices.count

    self.borgARProvider = BorgARProvider(logger: logger)
    self.appSettings = appSettings

    renderingParamaters.transferFunction.initMetal(device: device)

    logger?.dev("Renderer initialized")
  }

  deinit {
    logger?.dev("Renderer deinitialized")
    // TODO: figure out a better way to detect that the immersive space
    //       has been closed due to external circumstances, such as pressing
    //       home
    let model = appModel
    Task { @MainActor in
      model.currentState = .selectData
    }
  }

}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
