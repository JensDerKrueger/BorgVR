import CompositorServices
import Foundation
import Metal
import MetalKit
import Observation
import RealityKit
import simd
import Spatial

// MARK: Custom Error

/**
 An error type representing failures in the renderer.
 */
enum VisionVolumeRendererError: Error {
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

private final class VisionRendererPerformanceMailbox: @unchecked Sendable {
  struct Pending {
    let slowdownSteps: Int
    let recoverySteps: Int
  }

  private let lock = NSLock()
  private var slowdownSteps = 0
  private var recoverySteps = 0
  private var recoveryFinished = false

  func requestSlowdown() {
    lock.lock()
    slowdownSteps += 1
    recoverySteps = 0
    recoveryFinished = false
    lock.unlock()
  }

  func requestRecovery() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if recoveryFinished {
      recoveryFinished = false
      return false
    }
    recoverySteps += 1
    return true
  }

  func takePending() -> Pending {
    lock.lock()
    let pending = Pending(
      slowdownSteps: slowdownSteps,
      recoverySteps: recoverySteps
    )
    slowdownSteps = 0
    recoverySteps = 0
    lock.unlock()
    return pending
  }

  func markRecoveryFinished() {
    lock.lock()
    recoverySteps = 0
    recoveryFinished = true
    lock.unlock()
  }
}


/**
 An actor responsible for rendering volume data with Metal.

 The VisionVolumeRenderer actor creates and manages Metal objects such as buffers,
 pipeline states, and command queues. It also manages volume data and
 transfers data between CPU and GPU for rendering. The renderer uses an
 ARKit session for spatial tracking and integrates with a volume atlas.
 */
final actor VisionVolumeRenderer {

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
  /// Render pipeline state for opaque volume markers.
  var pipelineStateVolumeMarker: MTLRenderPipelineState
  /// Render pipeline state for opaque scene meshes.
  var pipelineStateSceneMesh: MTLRenderPipelineState
  /// Render pipeline state for lightweight screen-space measurement lines.
  var pipelineStateMeasurementLine: MTLRenderPipelineState
  /// Render pipeline state for compact screen-space measurement control points.
  var pipelineStateMeasurementPoint: MTLRenderPipelineState
  /// Render pipeline state for screen-view participant labels.
  var pipelineStateScreenViewLabel: MTLRenderPipelineState
  /// Screen-view and measurement labels drawn after the volume pass.
  var pipelineStateScreenViewOverlayLabel: MTLRenderPipelineState
  /// Render pipeline state for compositing marker color under the volume.
  var pipelineStateMarkerComposite: MTLRenderPipelineState
  /// Depth stencil state for rendering.
  var depthState: MTLDepthStencilState
  /// Depth stencil state for marker geometry.
  var depthStateMarker: MTLDepthStencilState
  /// Marker depth test without writes, used for back-to-front transparent geometry.
  var depthStateMarkerReadOnly: MTLDepthStencilState
  /// Depth stencil state for marker compositing.
  var depthStateMarkerComposite: MTLDepthStencilState

  /// Render pipeline state for the transfer function HUD overlay.
  var pipelineStateTFHUD: MTLRenderPipelineState
  /// Render pipeline state for transfer function HUD channel controls.
  var pipelineStateTFHUDControls: MTLRenderPipelineState
  /// Depth stencil state for the HUD overlay (no depth writes, always passes).
  var depthStateHUD: MTLDepthStencilState
  // TF panel (3D HUD) configuration
  var tfPanelSizeMeters = SIMD2<Float>(0.55, 0.20)   // width, height in meters
  var tfPanelDistance: Float = 0.80                  // meters in front of head
  var tfPanelYOffset: Float = -0.18                  // meters down
  var tfPanelXOffset: Float = 0.0

  // Updated each frame in updateRenderState
  var lastOriginFromDevice: simd_float4x4 = matrix_identity_float4x4
  var tfPanelWorldMatrix: simd_float4x4 = matrix_identity_float4x4
  var lastModelMatrix: simd_float4x4 = matrix_identity_float4x4
  var lastUnscaledModelMatrix: simd_float4x4 = matrix_identity_float4x4
  var lastClipMatrix: simd_float4x4 = matrix_identity_float4x4
  var lastHeadPosition: SIMD3<Float> = .zero
  var lastSpatialAnchorID: UUID?

  /// The BorgVR dataset.
  var borgData: BORGVRDatasetProtocol
  /// The volume atlas used for managing brick data.
  var volumeAtlas: VolumeAtlas
  /// A matrix representing the scale applied to the volume.
  var volumeScale: float4x4
  /// A GPU hashtable for indexing volume bricks.
  var hashTable: GPUHashtable
  /// The number of samples per pixel used during rasterization.
  let rasterSampleCount: Int
  /// Current index into the memoryless target textures.
  var currentRenderTargetIndex: Int = 0
  /// Current index into the CPU-readable interaction-depth textures.
  var currentInteractionDepthIndex: Int = 0
  /// An array of memoryless target textures for multisampled rendering.
  var memorylessTargets: [(color: MTLTexture, depth: MTLTexture, interactionDepth: MTLTexture)?]
  /// Resolved interaction depth from recent frames.
  var interactionDepthTextures: [MTLTexture?]
  /// Matrices matching the interaction texture currently being rendered.
  var currentTextureToClipMatrices: [simd_float4x4] = []
  var currentWorldToClipMatrices: [simd_float4x4] = []

  /// An ARKit session for augmented reality tracking.
  let borgARProvider : BorgARProvider

  /// Current rotation value for the scene.
  var rotation: Float = 0

  /// A buffer containing vertex data for a cube.
  let cubeBuffer: MTLBuffer
  /// A buffer containing marker sphere vertex positions.
  let markerSphereBuffer: MTLBuffer
  /// A buffer containing marker sphere normals.
  let markerSphereNormalBuffer: MTLBuffer
  /// The number of vertices in the marker sphere buffer.
  let markerSphereVertexCount: Int
  /// A tapered pointer rendered at each tracked spatial controller's aim pose.
  let spatialControllerPointerBuffer: MTLBuffer
  let spatialControllerPointerNormalBuffer: MTLBuffer
  let spatialControllerPointerVertexCount: Int
  /// Cached tube meshes for stroke markers.
  let markerTubeMeshCache: VolumeMarkerTubeMeshCache
  /// Cached GPU resources for imported scene meshes.
  let sceneMeshGPUCache: SceneMeshGPUCache
  /// White fallback used when a scene mesh has no embedded texture.
  let sceneMeshWhiteTexture: MTLTexture
  /// Cached triangle meshes for area and volume measurements.
  let measurementSurfaceMeshCache: MeasurementSurfaceMeshCache
  /// Reusable instance buffer for lightweight measurement lines.
  var measurementLineBuffer: MTLBuffer?
  var measurementLineBufferCapacity = 0
  /// Reusable instance buffer for compact measurement-point rings.
  var measurementPointBuffer: MTLBuffer?
  var measurementPointBufferCapacity = 0
  /// Cached label textures for shared and detached screen views.
  let screenViewLabelTextureCache: ScreenViewLabelTextureCache
  /// Color texture produced by the marker prepass.
  var markerColorTexture: MTLTexture?
  /// Depth texture produced by the marker prepass.
  var markerDepthTexture: MTLTexture?
  /// Parameter data copied from the drawable rasterization-rate map for shader-side foveation decisions.
  var rasterizationRateMapBuffer: MTLBuffer?
  /// The number of vertices in the cube buffer.
  let vertexCount: Int
  /// Stroke currently created by a connected spatial stylus.
  var activeSpatialStylusStrokeID: UUID?
  /// Smoothed surface-writing input from the pressure-sensitive stylus tip.
  var spatialStylusTipFilterState: (
    position: SIMD3<Float>,
    pressure: Float
  )?
  /// Local-only preview sphere shown at the tracked stylus tip.
  var spatialStylusPreviewPoint: VolumeMarkerPoint?
  /// Local-only tool glyph shown at the stylus tip while measuring.
  var spatialStylusMeasurementPreviewMarkers: [VolumeMarker] = []
  /// Controller poses sampled for the current frame and rendered as local-only pointers.
  var spatialControllerSamples: [BorgSpatialInputSample] = []
  /// Local-only spheres at the tracked controller tips.
  var spatialControllerPreviewPoints: [VolumeMarkerPoint] = []
  /// Local-only previews of the selected imported object at controller or stylus tips.
  var spatialSceneObjectPreviewInstances: [SceneMeshInstance] = []
  /// Local-only glyphs that show each controller's independently selected tool.
  var spatialControllerModePreviewMarkers: [VolumeMarker] = []
  /// Timestamp and activity state for the most recent SharePlay tool-tip update.
  var lastSpatialToolPreviewShareTime: TimeInterval
  var spatialToolPreviewsWereShared: Bool
  /// Initial state while the primary stylus button adjusts stroke radius.
  var spatialStylusRadiusAdjustmentStart: (
    position: SIMD3<Float>,
    radius: Float,
    hue: Float
  )?

  /// The layer renderer used for rendering.
  let layerRenderer: LayerRenderer
  /// The application model containing global settings.
  let session: VisionBorgVRSession
  /// Immutable state used by every rendering decision in the current frame.
  var frameSnapshot: BorgVRFrameSnapshot
  var frameState: BorgVRVisualizationSnapshot
  /// VisionVolumeRenderer-owned TF objects; synchronized only when a snapshot revision changes.
  let renderTransferFunctions: RenderTransferFunctionSet
  var atlasPurgeHandled = false
  /// Temporary runtime state for the active app process.
  let runtimeAppModel: RuntimeAppModel
  /// Application settings.
  let storedAppModel: StoredAppModel
  /// Rendering parameters such as transfer functions and isosurface values.
  let sharedAppModel: SharedAppModel
  /// Shared picking state for the transfer function HUD/object panel.
  let transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState
  /// Shared semantic interaction layer for hands, styli, and spatial controllers.
  let immersiveInteraction: ImmersiveInteraction
  /// Thread-safe snapshot of UI-owned interaction state.
  let spatialInputContext: SpatialInputRuntimeContext
  /// A GPU frame timer with a completion-time fallback.
  let timer: GPUFrameTimer
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

  var autoRotationAngle: Float
  var autoRotationStartTime: CFTimeInterval
  var lastRotationCaptureRequestID: UInt64

  /// Performance callbacks enqueue requests here; only the renderer actor changes the factor.
  private let performanceAdjustmentMailbox: VisionRendererPerformanceMailbox
  var activeOversampling: Float

  // MARK: Init

  /**
   Initializes a new VisionVolumeRenderer with the given parameters.

   This initializer creates all necessary Metal objects, pages in initial volume bricks,
   configures uniform buffers, builds render pipelines, and sets up AR and spatial
   tracking using ARKit.

   - Parameters:
   - layerRenderer: The layer renderer to be used.
   - runtimeAppModel: The global application model.
   - storedAppModel: Application settings.
   - sharedAppModel: Rendering parameters including transfer function and
   isosurface value.
   - timer: A GPU frame timer with a completion-time fallback.
   - dataset: The BorgVR dataset.
   - logger: An optional logger.
   */
  init(_ layerRenderer: LayerRenderer,
       session: VisionBorgVRSession,
       timer: GPUFrameTimer,
       dataset: BORGVRDatasetProtocol,
       transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState,
       immersiveInteraction: ImmersiveInteraction,
       logger: LoggerBase? = nil) throws {

    let runtimeAppModel = session.runtimeState
    let storedAppModel = session.settingsState
    let sharedAppModel = session.visualizationState

    logger?.info("Loading dataset \(dataset.getMetadata().datasetDescription)")
    logger?
      .info(
        "  dimensions: \(dataset.getMetadata().width) x \(dataset.getMetadata().height) x \(dataset.getMetadata().depth)"
      )
    logger?.info("  voxel spacing: \(dataset.getMetadata().voxelSpacingX) x \(dataset.getMetadata().voxelSpacingY) x \(dataset.getMetadata().voxelSpacingZ)")
    logger?.info("  brickSize: \(dataset.getMetadata().brickSize)")


    self.timer = timer
    self.initialOversampling = Float(storedAppModel.oversampling)
    self.activeOversampling = self.initialOversampling
    self.dropFPS = storedAppModel.dropFPS
    self.recoveryFPS = storedAppModel.recoveryFPS
    self.dynamicOverSampling = storedAppModel.oversamplingMode ==
    OversamplingMode.dynamicMode.rawValue
    self.logger = logger

    let initialFrameSnapshot = session.frameSnapshot()
    let renderTransferFunctions = RenderTransferFunctionSet(device: layerRenderer.device)
    let metadata = dataset.getMetadata()
    try renderTransferFunctions.synchronize(
      with: initialFrameSnapshot.transferFunctions,
      minValue: metadata.minValue,
      maxValue: metadata.maxValue,
      rangeMax: metadata.rangeMax
    )

    self.layerRenderer = layerRenderer
    self.session = session
    self.frameSnapshot = initialFrameSnapshot
    self.frameState = initialFrameSnapshot.visualization
    self.renderTransferFunctions = renderTransferFunctions
    self.device = layerRenderer.device
    self.commandQueue = self.device.makeCommandQueue()!
    self.runtimeAppModel = runtimeAppModel
    self.sharedAppModel = sharedAppModel
    self.transferFunctionPanelInteractionState = transferFunctionPanelInteractionState
    self.immersiveInteraction = immersiveInteraction
    self.spatialInputContext = runtimeAppModel.spatialInputContext

    self.autoRotationAngle = 0
    self.autoRotationStartTime = 0
    self.lastRotationCaptureRequestID = initialFrameSnapshot.settings.rotationCaptureRequestID
    self.performanceAdjustmentMailbox = VisionRendererPerformanceMailbox()
    self.activeSpatialStylusStrokeID = nil
    self.spatialStylusTipFilterState = nil
    self.spatialStylusPreviewPoint = nil
    self.spatialStylusMeasurementPreviewMarkers = []
    self.spatialSceneObjectPreviewInstances = []
    self.spatialControllerModePreviewMarkers = []
    self.lastSpatialToolPreviewShareTime = 0
    self.spatialToolPreviewsWereShared = false
    self.spatialStylusRadiusAdjustmentStart = nil
    self.markerTubeMeshCache = VolumeMarkerTubeMeshCache()
    self.sceneMeshGPUCache = SceneMeshGPUCache()
    self.measurementSurfaceMeshCache = MeasurementSurfaceMeshCache()
    self.measurementLineBuffer = nil
    self.measurementPointBuffer = nil
    self.screenViewLabelTextureCache = ScreenViewLabelTextureCache()
    self.sharedAppModel.defaultVolumeStrokeColor = SharedAppModel.saturatedStrokeColor(
      preservingHueOf: storedAppModel.markerDefaultColorSIMD
    )

    self.borgData = dataset

    let atlasSizeMB = StoredAppModel.int("atlasSizeMB")

    do {
      volumeAtlas = try VolumeAtlas(
        device: device,
        maxMemory: atlasSizeMB * 1024 * 1024,
        borgData: borgData,
        transferFunctions: renderTransferFunctions.activeTransferFunctions,
        isoValue: initialFrameSnapshot.visualization.isoValue,
        logger: logger
      )
      logger?.dev("VolumeAtlas created successfully.")
    } catch {
      logger?.error("Failed to create volume atlas: \(error)")
      throw error
    }

    let maxInitialBricks = StoredAppModel.int("initialBricks")
    do {
      try VolumeRenderResources.pageInInitialBricks(
        atlas: volumeAtlas,
        dataset: borgData,
        maximumCount: maxInitialBricks
      )
      logger?.dev("Initial bricks paged in successfully.")
    } catch {
      logger?.warning("Failed to page in all of the initial bricks: \(error)")
    }

    let minHashTableSize = StoredAppModel.int("minHashTableSize")
    let minTableElementCount = VolumeRenderResources.minimumHashTableElementCount(
      metadata: metadata,
      representedMemoryMB: minHashTableSize
    )

    logger?.dev("Size of Bricks represented by the Hash Table is \(minHashTableSize) MB. That means a minimum of \(minTableElementCount) table elements.")

    self.hashTable = GPUHashtable(minTableElementCount: minTableElementCount, device: device, logger: logger)

    self.volumeScale = VolumeRenderResources.volumeScale(for: metadata)


    let device = self.device
    if runtimeAppModel.useMultisamplingIfAvailable && device.supports32BitMSAA &&
        device.supportsTextureSampleCount(4) {
      self.rasterSampleCount = 4
    } else {
      self.rasterSampleCount = 1
    }

    self.memorylessTargets = .init(repeating: nil, count: runtimeAppModel.maxBuffersInFlight)
    self.interactionDepthTextures = .init(
      repeating: nil,
      count: runtimeAppModel.maxBuffersInFlight
    )

    self.uniformBufferVertex = try AlignedBuffer<VertexUniformsArray>(
      device: device,
      capacity: runtimeAppModel.maxBuffersInFlight
    )

    self.uniformBufferFragment = try AlignedBuffer<FragmentUniformsArray>(
      device: device,
      capacity: runtimeAppModel.maxBuffersInFlight
    )

    do {
      (pipelineStateTF,
       pipelineStateTFL,
       pipelineStateIso,
       pipelineStateBrickVis,
       pipelineStateVolumeMarker,
       pipelineStateSceneMesh,
       pipelineStateMeasurementLine,
       pipelineStateMeasurementPoint,
       pipelineStateScreenViewLabel,
       pipelineStateScreenViewOverlayLabel,
       pipelineStateMarkerComposite,
       pipelineStateTFHUD,
       pipelineStateTFHUDControls) =
      try VisionVolumeRenderer.buildRenderPipelinesWithDevice(
        device: device,
        layerRenderer: layerRenderer,
        rasterSampleCount: rasterSampleCount,
        borgVRMetaData: borgData.getMetadata(),
        hasTable: hashTable
      )
    } catch {
      fatalError("Unable to compile render pipeline state. Error info: \(error)")
    }

    let whiteTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm_srgb,
      width: 1,
      height: 1,
      mipmapped: false
    )
    whiteTextureDescriptor.usage = .shaderRead
    guard let sceneMeshWhiteTexture = device.makeTexture(descriptor: whiteTextureDescriptor) else {
      fatalError("Unable to allocate the scene mesh fallback texture.")
    }
    var opaqueWhite: UInt32 = 0xFFFF_FFFF
    sceneMeshWhiteTexture.replace(
      region: MTLRegionMake2D(0, 0, 1, 1),
      mipmapLevel: 0,
      withBytes: &opaqueWhite,
      bytesPerRow: MemoryLayout<UInt32>.size
    )
    self.sceneMeshWhiteTexture = sceneMeshWhiteTexture

    let depthStateDescriptor = MTLDepthStencilDescriptor()
    depthStateDescriptor.depthCompareFunction = .greater
    depthStateDescriptor.isDepthWriteEnabled = true
    self.depthState = device.makeDepthStencilState(descriptor: depthStateDescriptor)!

    let markerDepthStateDescriptor = MTLDepthStencilDescriptor()
    markerDepthStateDescriptor.depthCompareFunction = .greater
    markerDepthStateDescriptor.isDepthWriteEnabled = true
    self.depthStateMarker = device.makeDepthStencilState(descriptor: markerDepthStateDescriptor)!

    let markerReadOnlyDepthStateDescriptor = MTLDepthStencilDescriptor()
    markerReadOnlyDepthStateDescriptor.depthCompareFunction = .greater
    markerReadOnlyDepthStateDescriptor.isDepthWriteEnabled = false
    self.depthStateMarkerReadOnly = device.makeDepthStencilState(
      descriptor: markerReadOnlyDepthStateDescriptor
    )!

    let markerCompositeDepthStateDescriptor = MTLDepthStencilDescriptor()
    markerCompositeDepthStateDescriptor.depthCompareFunction = .always
    markerCompositeDepthStateDescriptor.isDepthWriteEnabled = true
    self.depthStateMarkerComposite = device.makeDepthStencilState(descriptor: markerCompositeDepthStateDescriptor)!

    let hudDepthStateDescriptor = MTLDepthStencilDescriptor()
    hudDepthStateDescriptor.depthCompareFunction = .always
    hudDepthStateDescriptor.isDepthWriteEnabled = true
    self.depthStateHUD = device.makeDepthStencilState(descriptor: hudDepthStateDescriptor)!

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

    let sphere = Tesselation.genSphere(
      center: SIMD3<Float>(repeating: 0),
      radius: 1,
      sectorCount: 32,
      stackCount: 16
    ).unpack()
    let alignedSphereVertexDataCount = (sphere.vertices.count + 15) & -16
    let sphereVertexDataSize = MemoryLayout<SIMD3<Float>>.stride *
    alignedSphereVertexDataCount
    var alignedSphereVertices = sphere.vertices
    let spherePaddingCount = alignedSphereVertexDataCount - sphere.vertices.count
    alignedSphereVertices.append(contentsOf: Array(
      repeating: paddingElement, count: spherePaddingCount))
    markerSphereBuffer = self.device.makeBuffer(
      length: sphereVertexDataSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    markerSphereBuffer.contents().copyMemory(
      from: alignedSphereVertices,
      byteCount: sphereVertexDataSize
    )
    var alignedSphereNormals = sphere.normals
    alignedSphereNormals.append(contentsOf: Array(
      repeating: SIMD3<Float>(0, 1, 0), count: spherePaddingCount))
    markerSphereNormalBuffer = self.device.makeBuffer(
      length: sphereVertexDataSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    markerSphereNormalBuffer.contents().copyMemory(
      from: alignedSphereNormals,
      byteCount: sphereVertexDataSize
    )
    markerSphereVertexCount = sphere.vertices.count

    let controllerPointer = Tesselation.genPointerCone(
      radius: 0.012,
      height: 0.055,
      sectorCount: 24
    ).unpack()
    let alignedPointerVertexCount = (controllerPointer.vertices.count + 15) & -16
    let pointerBufferSize = MemoryLayout<SIMD3<Float>>.stride * alignedPointerVertexCount
    let pointerPaddingCount = alignedPointerVertexCount - controllerPointer.vertices.count
    var alignedPointerVertices = controllerPointer.vertices
    alignedPointerVertices.append(contentsOf: Array(
      repeating: paddingElement,
      count: pointerPaddingCount
    ))
    spatialControllerPointerBuffer = self.device.makeBuffer(
      length: pointerBufferSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    spatialControllerPointerBuffer.contents().copyMemory(
      from: alignedPointerVertices,
      byteCount: pointerBufferSize
    )
    var alignedPointerNormals = controllerPointer.normals
    alignedPointerNormals.append(contentsOf: Array(
      repeating: SIMD3<Float>(0, 0, -1),
      count: pointerPaddingCount
    ))
    spatialControllerPointerNormalBuffer = self.device.makeBuffer(
      length: pointerBufferSize,
      options: [MTLResourceOptions.storageModeShared]
    )!
    spatialControllerPointerNormalBuffer.contents().copyMemory(
      from: alignedPointerNormals,
      byteCount: pointerBufferSize
    )
    spatialControllerPointerVertexCount = controllerPointer.vertices.count

    self.borgARProvider = BorgARProvider(
      logger: logger,
      spatialAnchorSessionState: runtimeAppModel.spatialAnchorSessionState
    )
    self.storedAppModel = storedAppModel

    sharedAppModel.initTransferFunctionMetal(device: device)

    logger?.dev("VisionVolumeRenderer initialized")
  }

  deinit {
    logger?.dev("VisionVolumeRenderer deinitialized")
    borgARProvider.stopARSession()
    let model = runtimeAppModel
    Task { @MainActor in
      // The system can destroy the renderer directly when the user presses Home.
      // Route that through the dataset state machine so SharePlay participants are
      // notified before the dataset selection is shown.
      model.immersiveSpaceWasClosedBySystem()
    }
  }

}



// MARK: - Resource setup

extension VisionVolumeRenderer {

  // MARK: Pipeline Setup

  /**
   Builds and returns three render pipeline states used for rendering volume data.

   This function compiles shader code from the "Shaders.metal" file with custom preprocessor
   macros calculated from the BorgVR metadata and application settings. It returns render
   pipeline states for the transfer function, isosurface, and brick visualization passes.

   - Parameters:
   - device: The Metal device used for creating the pipeline states.
   - layerRenderer: The layer renderer providing configuration information.
   - rasterSampleCount: The raster sample count to be used.
   - borgVRMetaData: The metadata of the BorgVR dataset.
   - hasTable: A GPU hashtable used for indexing volume data.
   - Returns: A tuple containing three render pipeline states:
   - The pipeline state for transfer function (TF) rendering.
   - The pipeline state for isosurface (Iso) rendering.
   - The pipeline state for brick visualization.
   - Throws: An error if the render pipeline state creation fails.
   */
  static func buildRenderPipelinesWithDevice(device: MTLDevice,
                                             layerRenderer: LayerRenderer,
                                             rasterSampleCount: Int,
                                             borgVRMetaData: BORGVRMetaData,
                                             hasTable: GPUHashtable) throws ->
  (MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState,
   MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState,
   MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState,
   MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState,
   MTLRenderPipelineState) {
    // Build a render state pipeline object.
    let shaderSource = try RuntimeMetalShaderLoader.loadSource(named: "Shaders")

    let compileOptions = VolumeShaderCompiler.compileOptions(
      metadata: borgVRMetaData,
      hashTableSize: hasTable.size,
      configuration: VolumeShaderConfiguration(
        screenSpaceError: StoredAppModel.float("screenSpaceError"),
        atlasSizeMB: StoredAppModel.int("atlasSizeMB"),
        maximumProbingAttempts: StoredAppModel.int("maxProbingAttempts"),
        requestsLowResolutionLOD: StoredAppModel.bool("requestLowResLOD"),
        stopsOnMissingBrick: StoredAppModel.bool("stopOnMiss"),
        fieldOfViewRadians: 1.663,
        drawableWidth: 1888
      )
    )
    var preprocessorMacros = compileOptions.preprocessorMacros ?? [:]
    preprocessorMacros["VOLUME_SHADER_USES_RATE_MAP"] = NSNumber(
      value: layerRenderer.configuration.isFoveationEnabled ? 1 : 0
    )
    compileOptions.preprocessorMacros = preprocessorMacros

    let library = try device.makeLibrary(source: shaderSource, options: compileOptions)
    let vertexFunction = library.makeFunction(name: "vertexShader")

    let pipelineDescriptorTF = MTLRenderPipelineDescriptor()
    pipelineDescriptorTF.label = "Render Pipeline for 1D TF"
    pipelineDescriptorTF.vertexFunction = vertexFunction
    pipelineDescriptorTF.fragmentFunction = library.makeFunction(name: "fragmentShaderTF")
    pipelineDescriptorTF.rasterSampleCount = rasterSampleCount
    pipelineDescriptorTF.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorTF.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorTF.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorTF.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorTFL = MTLRenderPipelineDescriptor()
    pipelineDescriptorTFL.label = "Render Pipeline for 1D TF with Lighting"
    pipelineDescriptorTFL.vertexFunction = vertexFunction
    pipelineDescriptorTFL.fragmentFunction = library.makeFunction(name: "fragmentShaderTFLighting")
    pipelineDescriptorTFL.rasterSampleCount = rasterSampleCount
    pipelineDescriptorTFL.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorTFL.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorTFL.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorTFL.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorIso = MTLRenderPipelineDescriptor()
    pipelineDescriptorIso.label = "Render Pipeline for Lit Isosurfaces"
    pipelineDescriptorIso.vertexFunction = vertexFunction
    pipelineDescriptorIso.fragmentFunction = library.makeFunction(name: "fragmentShaderIso")
    pipelineDescriptorIso.rasterSampleCount = rasterSampleCount
    pipelineDescriptorIso.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorIso.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorIso.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorIso.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorBrickVis = MTLRenderPipelineDescriptor()
    pipelineDescriptorBrickVis.label = "Render Pipeline visualizing the brick structure"
    pipelineDescriptorBrickVis.vertexFunction = vertexFunction
    pipelineDescriptorBrickVis.fragmentFunction = library.makeFunction(name: "fragmentShaderBrickVis")
    pipelineDescriptorBrickVis.rasterSampleCount = rasterSampleCount
    pipelineDescriptorBrickVis.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorBrickVis.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorBrickVis.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorBrickVis.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    // TF HUD overlay pipeline (2D screen-space panel)
    let hudVertexFunction = library.makeFunction(name: "vertexShaderTFPanel")
    let hudFragmentFunction = library.makeFunction(name: "fragmentShaderTFHUD")
    let hudControlsVertexFunction = library.makeFunction(name: "vertexShaderTFChannelControls")
    let hudControlsFragmentFunction = library.makeFunction(name: "fragmentShaderTFChannelControls")
    let markerVertexFunction = library.makeFunction(name: "vertexShaderVolumeMarker")
    let markerFragmentFunction = library.makeFunction(name: "fragmentShaderVolumeMarker")
    let sceneMeshVertexFunction = library.makeFunction(name: "vertexShaderSceneMesh")
    let sceneMeshFragmentFunction = library.makeFunction(name: "fragmentShaderSceneMesh")
    let measurementLineVertexFunction = library.makeFunction(name: "vertexShaderMeasurementLine")
    let measurementLineFragmentFunction = library.makeFunction(name: "fragmentShaderMeasurementLine")
    let measurementPointVertexFunction = library.makeFunction(name: "vertexShaderMeasurementPoint")
    let measurementPointFragmentFunction = library.makeFunction(name: "fragmentShaderMeasurementPoint")
    let screenViewLabelVertexFunction = library.makeFunction(name: "vertexShaderScreenViewLabel")
    let screenViewLabelFragmentFunction = library.makeFunction(name: "fragmentShaderScreenViewLabel")
    let markerCompositeVertexFunction = library.makeFunction(name: "vertexShaderMarkerComposite")
    let markerCompositeFragmentFunction = library.makeFunction(name: "fragmentShaderMarkerComposite")

    let pipelineDescriptorVolumeMarker = MTLRenderPipelineDescriptor()
    pipelineDescriptorVolumeMarker.label = "Render Pipeline for Volume Markers"
    pipelineDescriptorVolumeMarker.vertexFunction = markerVertexFunction
    pipelineDescriptorVolumeMarker.fragmentFunction = markerFragmentFunction
    pipelineDescriptorVolumeMarker.rasterSampleCount = rasterSampleCount
    pipelineDescriptorVolumeMarker.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorVolumeMarker.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorVolumeMarker.maxVertexAmplificationCount = layerRenderer.properties.viewCount
    if let colorAttachment = pipelineDescriptorVolumeMarker.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .sourceAlpha
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let pipelineDescriptorSceneMesh = MTLRenderPipelineDescriptor()
    pipelineDescriptorSceneMesh.label = "Render Pipeline for Opaque Scene Meshes"
    pipelineDescriptorSceneMesh.vertexFunction = sceneMeshVertexFunction
    pipelineDescriptorSceneMesh.fragmentFunction = sceneMeshFragmentFunction
    pipelineDescriptorSceneMesh.rasterSampleCount = rasterSampleCount
    pipelineDescriptorSceneMesh.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorSceneMesh.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorSceneMesh.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorMeasurementLine = MTLRenderPipelineDescriptor()
    pipelineDescriptorMeasurementLine.label = "Render Pipeline for Measurement Lines"
    pipelineDescriptorMeasurementLine.vertexFunction = measurementLineVertexFunction
    pipelineDescriptorMeasurementLine.fragmentFunction = measurementLineFragmentFunction
    pipelineDescriptorMeasurementLine.rasterSampleCount = rasterSampleCount
    pipelineDescriptorMeasurementLine.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorMeasurementLine.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorMeasurementLine.maxVertexAmplificationCount = layerRenderer.properties.viewCount
    if let colorAttachment = pipelineDescriptorMeasurementLine.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .sourceAlpha
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let pipelineDescriptorMeasurementPoint = MTLRenderPipelineDescriptor()
    pipelineDescriptorMeasurementPoint.label = "Render Pipeline for Measurement Points"
    pipelineDescriptorMeasurementPoint.vertexFunction = measurementPointVertexFunction
    pipelineDescriptorMeasurementPoint.fragmentFunction = measurementPointFragmentFunction
    pipelineDescriptorMeasurementPoint.rasterSampleCount = rasterSampleCount
    pipelineDescriptorMeasurementPoint.colorAttachments[0].pixelFormat =
      layerRenderer.configuration.colorFormat
    pipelineDescriptorMeasurementPoint.depthAttachmentPixelFormat =
      layerRenderer.configuration.depthFormat
    pipelineDescriptorMeasurementPoint.maxVertexAmplificationCount =
      layerRenderer.properties.viewCount
    if let colorAttachment = pipelineDescriptorMeasurementPoint.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .sourceAlpha
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let pipelineDescriptorScreenViewLabel = MTLRenderPipelineDescriptor()
    pipelineDescriptorScreenViewLabel.label = "Render Pipeline for Screen View Labels"
    pipelineDescriptorScreenViewLabel.vertexFunction = screenViewLabelVertexFunction
    pipelineDescriptorScreenViewLabel.fragmentFunction = screenViewLabelFragmentFunction
    pipelineDescriptorScreenViewLabel.rasterSampleCount = rasterSampleCount
    pipelineDescriptorScreenViewLabel.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorScreenViewLabel.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorScreenViewLabel.maxVertexAmplificationCount = layerRenderer.properties.viewCount
    if let colorAttachment = pipelineDescriptorScreenViewLabel.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .one
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let pipelineDescriptorScreenViewOverlayLabel = MTLRenderPipelineDescriptor()
    pipelineDescriptorScreenViewOverlayLabel.label = "Render Pipeline for Screen View Overlay Labels"
    pipelineDescriptorScreenViewOverlayLabel.vertexFunction = screenViewLabelVertexFunction
    pipelineDescriptorScreenViewOverlayLabel.fragmentFunction = screenViewLabelFragmentFunction
    pipelineDescriptorScreenViewOverlayLabel.rasterSampleCount = rasterSampleCount
    pipelineDescriptorScreenViewOverlayLabel.colorAttachments[0].pixelFormat =
      layerRenderer.configuration.colorFormat
    pipelineDescriptorScreenViewOverlayLabel.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorScreenViewOverlayLabel.colorAttachments[1].writeMask = []
    pipelineDescriptorScreenViewOverlayLabel.depthAttachmentPixelFormat =
      layerRenderer.configuration.depthFormat
    pipelineDescriptorScreenViewOverlayLabel.maxVertexAmplificationCount =
      layerRenderer.properties.viewCount
    if let colorAttachment = pipelineDescriptorScreenViewOverlayLabel.colorAttachments[0] {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.rgbBlendOperation = .add
      colorAttachment.alphaBlendOperation = .add
      colorAttachment.sourceRGBBlendFactor = .one
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let pipelineDescriptorMarkerComposite = MTLRenderPipelineDescriptor()
    pipelineDescriptorMarkerComposite.label = "Render Pipeline for Marker Composite"
    pipelineDescriptorMarkerComposite.vertexFunction = markerCompositeVertexFunction
    pipelineDescriptorMarkerComposite.fragmentFunction = markerCompositeFragmentFunction
    pipelineDescriptorMarkerComposite.rasterSampleCount = rasterSampleCount
    pipelineDescriptorMarkerComposite.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorMarkerComposite.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorMarkerComposite.colorAttachments[1].writeMask = []
    pipelineDescriptorMarkerComposite.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorMarkerComposite.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    if let ca = pipelineDescriptorMarkerComposite.colorAttachments[0] {
      ca.isBlendingEnabled = true
      ca.rgbBlendOperation = .add
      ca.alphaBlendOperation = .add
      ca.sourceRGBBlendFactor = .oneMinusDestinationAlpha
      ca.destinationRGBBlendFactor = .one
      ca.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
      ca.destinationAlphaBlendFactor = .one
    }

    let pipelineDescriptorTFHUD = MTLRenderPipelineDescriptor()
    pipelineDescriptorTFHUD.label = "Render Pipeline for TF HUD"
    pipelineDescriptorTFHUD.vertexFunction = hudVertexFunction
    pipelineDescriptorTFHUD.fragmentFunction = hudFragmentFunction
    pipelineDescriptorTFHUD.rasterSampleCount = rasterSampleCount
    pipelineDescriptorTFHUD.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorTFHUD.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorTFHUD.colorAttachments[1].writeMask = []
    pipelineDescriptorTFHUD.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorTFHUD.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    if let ca = pipelineDescriptorTFHUD.colorAttachments[0] {
      ca.isBlendingEnabled = true
      ca.rgbBlendOperation = .add
      ca.alphaBlendOperation = .add
      ca.sourceRGBBlendFactor = .sourceAlpha
      ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
      ca.sourceAlphaBlendFactor = .one
      ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    let pipelineDescriptorTFHUDControls = MTLRenderPipelineDescriptor()
    pipelineDescriptorTFHUDControls.label = "Render Pipeline for TF HUD Channel Controls"
    pipelineDescriptorTFHUDControls.vertexFunction = hudControlsVertexFunction
    pipelineDescriptorTFHUDControls.fragmentFunction = hudControlsFragmentFunction
    pipelineDescriptorTFHUDControls.rasterSampleCount = rasterSampleCount
    pipelineDescriptorTFHUDControls.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorTFHUDControls.colorAttachments[1].pixelFormat = .r32Float
    pipelineDescriptorTFHUDControls.colorAttachments[1].writeMask = []
    pipelineDescriptorTFHUDControls.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorTFHUDControls.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    if let ca = pipelineDescriptorTFHUDControls.colorAttachments[0] {
      ca.isBlendingEnabled = true
      ca.rgbBlendOperation = .add
      ca.alphaBlendOperation = .add
      ca.sourceRGBBlendFactor = .sourceAlpha
      ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
      ca.sourceAlphaBlendFactor = .one
      ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    return (
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorTF),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorTFL),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorIso),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorBrickVis),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorVolumeMarker),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorSceneMesh),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorMeasurementLine),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorMeasurementPoint),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorScreenViewLabel),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorScreenViewOverlayLabel),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorMarkerComposite),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorTFHUD),
      try device.makeRenderPipelineState(descriptor: pipelineDescriptorTFHUDControls)
    )
  }

  func initRenderLoop() async {
    initPerformanceTracking()
    await borgARProvider.startARSession()
  }

  /**
   Initializes performance tracking for dynamic oversampling.

   This method sets up the GPU frame timer's thresholds and callback closures so that the renderer
   can dynamically adjust the oversampling factor based on current performance (FPS).
   */
  func initPerformanceTracking() {
    guard self.dynamicOverSampling else { return }

    timer.dropThreshold = Double(self.dropFPS)
    timer.recoveryThreshold = Double(self.recoveryFPS)
    timer.minimumDropDuration = 0.5

    let performanceAdjustmentMailbox = self.performanceAdjustmentMailbox
    timer.onPerformanceTooSlow = { _, _ in
      performanceAdjustmentMailbox.requestSlowdown()
    }

    timer.onPerformanceRecovered = { _, _ in
      performanceAdjustmentMailbox.requestRecovery()
    }
  }

  private func applyPendingPerformanceAdjustments() {
    let pending = performanceAdjustmentMailbox.takePending()

    for _ in 0..<pending.slowdownSteps {
      guard activeOversampling >= 0.5 else { break }
      activeOversampling -= 0.1
    }

    for _ in 0..<pending.recoverySteps {
      guard activeOversampling < initialOversampling else {
        activeOversampling = initialOversampling
        performanceAdjustmentMailbox.markRecoveryFinished()
        break
      }
      activeOversampling = min(initialOversampling, activeOversampling + 0.1)
      if activeOversampling >= initialOversampling {
        performanceAdjustmentMailbox.markRecoveryFinished()
        break
      }
    }
  }
}



// MARK: - Frame rendering

extension VisionVolumeRenderer {

  private struct ScreenViewVisualization {
    var markers: [VolumeMarker] = []
    var labels: [ScreenViewLabelDescriptor] = []
  }

  private struct MeasurementVisualization {
    struct Line {
      let startAndWidth: SIMD4<Float>
      let end: SIMD4<Float>
      let color: SIMD4<Float>
    }

    struct Surface {
      let measurement: VolumeMeasurement
      let color: SIMD4<Float>
    }

    var points: [MeasurementPointRenderInstance] = []
    var lines: [Line] = []
    var labels: [ScreenViewLabelDescriptor] = []
    var surfaces: [Surface] = []
  }

  private struct ScreenViewLabelDescriptor {
    let text: String
    let color: SIMD4<Float>
    let position: SIMD3<Float>
    var depthOffsetTowardCamera: Float = 0
    var opaqueBackground = false
    var height: Float = 0.052
    var billboardOffset = SIMD2<Float>.zero
  }

  private static let screenViewVisualizationMarkerIDs: [UUID] = [
    UUID(uuidString: "EC000000-0000-0000-0000-000000000001")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000002")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000003")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000004")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000005")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000006")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000007")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000008")!,
    UUID(uuidString: "EC000000-0000-0000-0000-000000000009")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000A")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000B")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000C")!,
    UUID(uuidString: "EC000000-0000-0000-0000-00000000000D")!
  ]
  private static let stylusMeasurementPreviewMarkerIDs: [UUID] = (1...8).map {
    UUID(uuidString: String(format: "ED000000-0000-0000-0000-%012X", $0))!
  }

  private func measurementVisualizationID(_ base: UUID, _ index: Int) -> UUID {
    var uuid = base.uuid
    withUnsafeMutableBytes(of: &uuid) { bytes in
      bytes[12] ^= 0x4D
      bytes[13] ^= UInt8(truncatingIfNeeded: index >> 16)
      bytes[14] ^= UInt8(truncatingIfNeeded: index >> 8)
      bytes[15] ^= UInt8(truncatingIfNeeded: index)
    }
    return UUID(uuid: uuid)
  }

  private func measurementColor(
    for kind: VolumeMeasurementKind,
    selected: Bool
  ) -> SIMD4<Float> {
    let base: SIMD3<Float>
    switch kind {
      case .length: base = SIMD3<Float>(1.0, 0.72, 0.12)
      case .area: base = SIMD3<Float>(0.10, 0.78, 0.92)
      case .volume: base = SIMD3<Float>(0.82, 0.30, 0.95)
    }
    let rgb = selected ? base + (SIMD3<Float>(repeating: 1) - base) * 0.22 : base
    return SIMD4<Float>(rgb, 1)
  }

  private func measurementVisualization(
    measurements: [VolumeMeasurement]
  ) -> MeasurementVisualization {
    var result = MeasurementVisualization()
    let coordinateScale = SIMD3<Float>(
      volumeScale.columns.0.x,
      volumeScale.columns.1.y,
      volumeScale.columns.2.z
    )
    func line(
      from start: SIMD3<Float>,
      to end: SIMD3<Float>,
      color: SIMD4<Float>,
      width: Float
    ) -> MeasurementVisualization.Line? {
      let localStart = (start - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      let localEnd = (end - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      guard localStart.x.isFinite, localStart.y.isFinite, localStart.z.isFinite,
            localEnd.x.isFinite, localEnd.y.isFinite, localEnd.z.isFinite else { return nil }
      return MeasurementVisualization.Line(
        startAndWidth: SIMD4<Float>(localStart, width),
        end: SIMD4<Float>(localEnd, 0),
        color: color
      )
    }

    for measurement in measurements {
      let selected = frameSnapshot.annotations.selectedMeasurementID == measurement.id
      let color = measurementColor(for: measurement.kind, selected: selected)
      let geometry = measurement.geometry

      for (pointIndex, point) in geometry.points.enumerated() {
        let pointSelected = selected &&
          frameSnapshot.annotations.selectedMeasurementPointID == point.id
        let definesAreaPlane = measurement.kind == .area && pointIndex < 3
        let outerColor: SIMD4<Float>
        if pointSelected {
          outerColor = SIMD4<Float>(1, 0.22, 0.03, 1)
        } else {
          outerColor = color
        }
        let localPosition = (point.position - SIMD3<Float>(repeating: 0.5)) *
          coordinateScale
        result.points.append(MeasurementPointRenderInstance(
          centerAndRadius: SIMD4<Float>(
            localPosition,
            pointSelected ? 9 : (definesAreaPlane ? 8 : 7)
          ),
          color: pointSelected
            ? outerColor
            : (definesAreaPlane ? SIMD4<Float>(1, 1, 1, 1) : outerColor)
        ))
      }

      for edge in geometry.edges {
        let displayLength = simd_length((edge.end - edge.start) * coordinateScale)
        guard displayLength.isFinite else { continue }
        let dashCount = max(1, Int(ceil(min(displayLength / 0.035, 4096))))
        for dash in 0..<dashCount {
          let startT = Float(dash) / Float(dashCount)
          let endT = min(1, startT + 0.62 / Float(dashCount))
          let start = edge.start + (edge.end - edge.start) * startT
          let end = edge.start + (edge.end - edge.start) * endT
          if let dashLine = line(
            from: start,
            to: end,
            color: color,
            width: selected ? 4.5 : 3.5
          ) {
            result.lines.append(dashLine)
          }
        }
      }

      if let valueText = measurement.formattedValue(),
         let firstPoint = geometry.points.first {
        result.labels.append(ScreenViewLabelDescriptor(
          text: valueText,
          color: color,
          position: firstPoint.position,
          depthOffsetTowardCamera: 0.010,
          opaqueBackground: true,
          height: 0.021,
          billboardOffset: SIMD2<Float>(0, 0.020)
        ))
      }
      if !geometry.triangleVertices.isEmpty {
        result.surfaces.append(.init(
          measurement: measurement,
          color: SIMD4<Float>(color.x, color.y, color.z, selected ? 0.34 : 0.22)
        ))
      }
    }
    return result
  }

  private func makeBillboardMatrix(position: SIMD3<Float>,
                                   camera: SIMD3<Float>,
                                   up: SIMD3<Float>,
                                   cylindrical: Bool) -> (simd_float4x4, SIMD3<Float>) {
    var forward = camera - position

    if cylindrical {
      // remove component along up -> yaw-only billboard (stays vertical)
      forward -= up * simd_dot(forward, up)
    }

    let fLen = simd_length(forward)
    let f = (fLen.isFinite && fLen > 1e-5)
      ? (forward / fLen)
      : SIMD3<Float>(0, 0, 1)

    var right = simd_cross(up, f)
    var rightLength = simd_length(right)
    if !rightLength.isFinite || rightLength <= 1e-5 {
      right = simd_cross(SIMD3<Float>(1, 0, 0), f)
      rightLength = simd_length(right)
    }
    let r = (rightLength.isFinite && rightLength > 1e-5)
      ? right / rightLength
      : SIMD3<Float>(1, 0, 0)
    let u = simd_cross(f, r) // already normalized if r,f are

    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(r.x, r.y, r.z, 0)
    m.columns.1 = SIMD4<Float>(u.x, u.y, u.z, 0)
    m.columns.2 = SIMD4<Float>(f.x, f.y, f.z, 0)
    m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
    return (m, f)
  }

  private func length3(_ c: SIMD4<Float>) -> Float {
    simd_length(SIMD3<Float>(c.x, c.y, c.z))
  }

  private func translation3(_ m: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
  }

  private func clamp(_ x: Float, _ a: Float, _ b: Float) -> Float {
    min(max(x, a), b)
  }

  // MARK: Pre-Frame Setup

  /**
   Updates the render state with view-projection uniforms and clip parameters per view.

   - Parameters:
   - drawable: The drawable from the current frame.
   - deviceAnchor: The device anchor containing the transform of the Vision Pro.
   */
  private func updateRenderState(drawable: LayerRenderer.Drawable) {
    if frameSnapshot.settings.purgeAtlas, !atlasPurgeHandled {
      volumeAtlas.purge()
      atlasPurgeHandled = true
      Task { @MainActor [weak sharedAppModel] in
        sharedAppModel?.purgeAtlas = false
      }
    } else if !frameSnapshot.settings.purgeAtlas {
      atlasPurgeHandled = false
    }

    let anchors = borgARProvider.getAnchors(for: drawable)
    let originFromDevice = anchors.originFromDevice ?? matrix_identity_float4x4
    let originFromWorldAnchor = anchors.originFromWorldAnchor ?? matrix_identity_float4x4

    self.lastOriginFromDevice = originFromDevice

    // Compute a head-centered transform by averaging eye translations.
    // originFromView = originFromDevice * view.transform (your existing convention)
    let leftEyeOriginFromView = originFromDevice * drawable.views[0].transform
    var headOriginFromView = leftEyeOriginFromView

    if drawable.views.count > 1 {
      let rightEyeOriginFromView = originFromDevice * drawable.views[1].transform

      let tl = SIMD3<Float>(leftEyeOriginFromView.columns.3.x,
                            leftEyeOriginFromView.columns.3.y,
                            leftEyeOriginFromView.columns.3.z)
      let tr = SIMD3<Float>(rightEyeOriginFromView.columns.3.x,
                            rightEyeOriginFromView.columns.3.y,
                            rightEyeOriginFromView.columns.3.z)

      let tc = 0.5 * (tl + tr)
      headOriginFromView.columns.3 = SIMD4<Float>(tc.x, tc.y, tc.z, 1.0)
    }

    sharedAppModel.updateSpatialReference(
      originFromHead: headOriginFromView,
      originFromWorldAnchor: originFromWorldAnchor,
      worldAnchorID: anchors.worldAnchor?.id
    )

    let spatialAnchorID = anchors.worldAnchor?.id
    runtimeAppModel.spatialAnchorSessionState.publishActiveAnchor(
      id: spatialAnchorID,
      isShared: anchors.worldAnchorIsShared
    )
    if lastSpatialAnchorID != spatialAnchorID {
      lastSpatialAnchorID = spatialAnchorID
      let sessionSnapshot = runtimeAppModel.spatialAnchorSessionState.snapshot()
      if sessionSnapshot.sharePlayIsActive && sessionSnapshot.activeAnchorIsShared {
        sharedAppModel.synchronize(kind: .transformOnly)
      }
    }

    let unscaledModelMatrix : simd_float4x4
    let modelMatrix : simd_float4x4
    let frameModelTransform = Transform(
      scale: frameState.transform.scale,
      rotation: simd_normalize(simd_quatf(vector: frameState.transform.rotation)),
      translation: frameState.transform.translation
    )
    if autoRotationAngle > 0 {
      let autoRotationMatrix = rotationYMatrix(degrees: autoRotationAngle)

      let rot = simd_quatf(vector: frameState.transform.rotation)
      let trans = frameState.transform.translation
      let scale = frameState.transform.scale

      let model = Transform(
        scale: scale,
        rotation: simd_quatf(autoRotationMatrix)*rot,
        translation: trans
      ).matrix

      unscaledModelMatrix = originFromWorldAnchor * model
      modelMatrix = unscaledModelMatrix * volumeScale
    } else {
      unscaledModelMatrix = originFromWorldAnchor * frameModelTransform.matrix
      modelMatrix = unscaledModelMatrix * volumeScale
    }

    // Place panel in front of head in "view" coordinates:
    // In camera/view coordinates, forward is typically -Z, so z = -distance is in front.
    let panelLocalFromPanel = Transform(
      translation: SIMD3<Float>(tfPanelXOffset, tfPanelYOffset, -tfPanelDistance)
    ).matrix

    // World/origin transform of the panel
    self.tfPanelWorldMatrix = headOriginFromView * panelLocalFromPanel

    func pos(_ m: simd_float4x4) -> SIMD3<Float> {
      SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    let leftEye = originFromDevice * drawable.views[0].transform
    var headPos = pos(leftEye)

    if drawable.views.count > 1 {
      let rightEye = originFromDevice * drawable.views[1].transform
      headPos = 0.5 * (pos(leftEye) + pos(rightEye))
    }
    self.lastHeadPosition = headPos


    func uniforms(forViewIndex viewIndex: Int) -> (VertexUniforms, FragmentUniforms) {
      let view = drawable.views[viewIndex]
      let viewMatrix = (originFromDevice * view.transform).inverse
      let projection = drawable.computeProjection(viewIndex: viewIndex)

      let viewToTexture = Transform(translation: SIMD3<Float>(0.5, 0.5, 0.5)).matrix * simd_inverse(viewMatrix * modelMatrix)
      let viewToTextureVoxelScaled = Transform(translation: SIMD3<Float>(0.5, 0.5, 0.5)).matrix * simd_inverse(viewMatrix * originFromWorldAnchor * frameModelTransform.matrix)

      let metadata = borgData.getMetadata()
      let borderSize = Float(metadata.overlap + 1) / SIMD3<Float>(Float(metadata.width), Float(metadata.height), Float(metadata.depth))
      let clipMin = frameState.clipMinimum + borderSize
      let clipMax = frameState.clipMaximum - borderSize

      let clipScale = (clipMax - clipMin)
      let clipMatrix = Transform(
        scale: clipScale,
        translation: 0.5 * (clipMax + clipMin - 1)
      ).matrix

      self.lastOriginFromDevice = originFromDevice
      self.lastModelMatrix = modelMatrix
      self.lastUnscaledModelMatrix = unscaledModelMatrix
      self.lastClipMatrix = clipMatrix

      return (
        VertexUniforms(modelViewProjectionMatrix: projection * viewMatrix * modelMatrix * clipMatrix,
                       clipMatrix: clipMatrix),
        FragmentUniforms(
          isoValue: frameState.isoValue,
          oversampling: activeOversampling,
          sampleJitter: frameSnapshot.settings.sampleJitter ? 1 : 0,
          transferBias: frameState.transferBiases,
          cameraPosInTextureSpace: simd_make_float3(viewToTexture * simd_float4(0, 0, 0, 1)),
          cameraPosInTextureSpaceVoxelScaled: simd_make_float3(viewToTextureVoxelScaled * simd_float4(0, 0, 0, 1)),
          cubeBounds: (clipMin, clipMax),
          lightDirection: SIMD4<Float>(frameState.lighting.direction, 0),
          ambientLightColor: SIMD4<Float>(frameState.lighting.ambient, 0),
          diffuseLightColor: SIMD4<Float>(frameState.lighting.diffuse, 0),
          specularLightColor: SIMD4<Float>(frameState.lighting.specular, 0),
          modelView: viewMatrix * modelMatrix,
          modelViewIT: simd_transpose(simd_inverse(viewMatrix * modelMatrix)),
          textureToClip: projection * viewMatrix * modelMatrix * Transform(
            translation: SIMD3<Float>(repeating: -0.5)
          ).matrix
        )
      )
    }

    (uniformBufferVertex.current.uniforms.0, uniformBufferFragment.current.uniforms.0) = uniforms(forViewIndex: 0)
    if drawable.views.count > 1 {
      (uniformBufferVertex.current.uniforms.1, uniformBufferFragment.current.uniforms.1) = uniforms(forViewIndex: 1)
    }
    currentTextureToClipMatrices = drawable.views.indices.map { index in
      index == 0
        ? uniformBufferFragment.current.uniforms.0.textureToClip
        : uniformBufferFragment.current.uniforms.1.textureToClip
    }
    currentWorldToClipMatrices = drawable.views.indices.map { index in
      let viewMatrix = (originFromDevice * drawable.views[index].transform).inverse
      return drawable.computeProjection(viewIndex: index) * viewMatrix
    }

    switch frameState.renderMode {
      case .transferFunction1D, .transferFunction1DLighting:
        volumeAtlas.updateEmptiness(
          transferFunctions: renderTransferFunctions.activeTransferFunctions
        )
      case .isoValue:
        volumeAtlas.updateEmptiness(isoValue: frameState.isoValue)
    }
  }

  func rotationYMatrix(degrees n: Float) -> simd_float4x4 {
    let radians = n * (.pi / 180)
    let cosAngle = cos(radians)
    let sinAngle = sin(radians)

    return simd_float4x4(
      SIMD4<Float>( cosAngle, 0, -sinAngle, 0),
      SIMD4<Float>(       0, 1,        0, 0),
      SIMD4<Float>( sinAngle, 0,  cosAngle, 0),
      SIMD4<Float>(       0, 0,        0, 1)
    )
  }

  /**
   Returns memoryless multisample render targets reused across frames.

   - Parameter drawable: The drawable providing the base textures.
   - Returns: A tuple with a color and depth memoryless MTLTexture.
   */
  private func memorylessRenderTargets(
    drawable: LayerRenderer.Drawable,
    interactionDepthResolveTexture: MTLTexture
  ) -> (color: MTLTexture, depth: MTLTexture, interactionDepth: MTLTexture) {

    func renderTarget(resolveTexture: MTLTexture, cachedTexture: MTLTexture?) -> MTLTexture {
      if let cachedTexture,
         resolveTexture.width == cachedTexture.width && resolveTexture.height == cachedTexture.height {
        return cachedTexture
      } else {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: resolveTexture.pixelFormat,
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

    currentRenderTargetIndex = (currentRenderTargetIndex + 1) % runtimeAppModel.maxBuffersInFlight

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

  private func interactionDepthTexture(drawable: LayerRenderer.Drawable) -> MTLTexture {
    currentInteractionDepthIndex =
      (currentInteractionDepthIndex + 1) % runtimeAppModel.maxBuffersInFlight
    let source = drawable.colorTextures[0]
    let viewCount = max(drawable.views.count, 1)
    if let texture = interactionDepthTextures[currentInteractionDepthIndex],
       texture.width == source.width,
       texture.height == source.height,
       texture.arrayLength == viewCount {
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

  private func markerRenderTargets(drawable: LayerRenderer.Drawable) -> (color: MTLTexture, depth: MTLTexture) {
    let source = drawable.colorTextures[0]
    let viewCount = max(drawable.views.count, 1)

    let needsNewColor = markerColorTexture == nil ||
      markerColorTexture!.width != source.width ||
      markerColorTexture!.height != source.height ||
      markerColorTexture!.arrayLength != viewCount
    if needsNewColor {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: layerRenderer.configuration.colorFormat,
        width: source.width,
        height: source.height,
        mipmapped: false
      )
      descriptor.textureType = .type2DArray
      descriptor.arrayLength = viewCount
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      markerColorTexture = device.makeTexture(descriptor: descriptor)
      markerColorTexture?.label = "Opaque Geometry Color"
    }

    let needsNewDepth = markerDepthTexture == nil ||
      markerDepthTexture!.width != source.width ||
      markerDepthTexture!.height != source.height ||
      markerDepthTexture!.arrayLength != viewCount
    if needsNewDepth {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: layerRenderer.configuration.depthFormat,
        width: source.width,
        height: source.height,
        mipmapped: false
      )
      descriptor.textureType = .type2DArray
      descriptor.arrayLength = viewCount
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      markerDepthTexture = device.makeTexture(descriptor: descriptor)
      markerDepthTexture?.label = "Opaque Geometry Depth"
    }

    return (markerColorTexture!, markerDepthTexture!)
  }

  private func bindRasterizationRateMap(_ rateMap: MTLRasterizationRateMap?,
                                        to renderEncoder: MTLRenderCommandEncoder) {
    guard let rateMap else { return }

    let sizeAndAlign = rateMap.parameterDataSizeAndAlign
    let bufferLength = rasterizationRateMapBuffer?.length ?? 0
    if bufferLength < sizeAndAlign.size {
      rasterizationRateMapBuffer = device.makeBuffer(length: sizeAndAlign.size, options: .storageModeShared)
      rasterizationRateMapBuffer?.label = "Rasterization Rate Map Parameters"
    }

    guard let rasterizationRateMapBuffer else { return }
    rateMap.copyParameterData(buffer: rasterizationRateMapBuffer, offset: 0)
    renderEncoder.setFragmentBuffer(rasterizationRateMapBuffer,
                                    offset: 0,
                                    index: FragmentBufferIndex.rateMap.rawValue)
  }

  /**
   Reads back the GPU hash table and pages in missing bricks.

   - Parameter commandBuffer: The command buffer from the current frame.
   */
  func readBackHashTable(commandBuffer: MTLCommandBuffer) {
    let missingBricks = hashTable.getValues(from: commandBuffer)

    if !missingBricks.isEmpty {
      let intArray = missingBricks.map { Int($0) }.sorted(by: >)

      try? volumeAtlas.pageIn(IDs: intArray)
    }
  }


  /**
   Updates performance counters and appends results to the performance model history.
   */
  func updatePerformanceCounters() {
    applyPendingPerformanceAdjustments()

    let last = timer.lastFPS
    let avg = timer.averageFPS
    let smoothed = timer.smoothedFPS

    if autoRotationAngle > 0 {
      if autoRotationAngle == 1 {
        autoRotationStartTime = CACurrentMediaTime()
      }
      autoRotationAngle += 1
      if autoRotationAngle >= 360 {
        let autoRotationEndTime = CACurrentMediaTime()
        let rotationDuration = autoRotationEndTime - autoRotationStartTime
        autoRotationAngle = 0
        self.logger?.info("Rotation Complete. Total time to complete rotation: \(rotationDuration) seconds. Avergage time per frame: \(rotationDuration / 0.360) ms")
      }
    }

    let rotationCaptureRequestID = frameSnapshot.settings.rotationCaptureRequestID
    if rotationCaptureRequestID != lastRotationCaptureRequestID {
      lastRotationCaptureRequestID = rotationCaptureRequestID
      logger?.info("Start Rotation")
      autoRotationAngle = 1
    }

    let runtimeAppModel = self.runtimeAppModel
    let recoveryThreshold = Double(recoveryFPS)
    let dropThreshold = Double(dropFPS)
    let samplingRate = Double(activeOversampling)
    let baseSamplingRate = Double(initialOversampling)
    DispatchQueue.main.async {
      runtimeAppModel.performanceModel.history.recoveryThreshold = recoveryThreshold
      runtimeAppModel.performanceModel.history.dropThreshold = dropThreshold
      runtimeAppModel.performanceModel.history.add(last: last,
                                                    avg: avg,
                                                    smoothed: smoothed,
                                                    samplingRate: samplingRate,
                                                    baseSamplingRate: baseSamplingRate)

      if runtimeAppModel.logPerformance {
        struct State {
          static var lastTime = CACurrentMediaTime()
        }

        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - State.lastTime

        if elapsed >= 2.0 {
          runtimeAppModel.logger
            .info("Last FPS: \(last), Avg FPS: \(avg), Smoothed FPS: \(smoothed)")
          State.lastTime = currentTime
        }
      }
    }
  }

  // MARK: Render Function

  func updateDynamicBufferState() {
    uniformBufferVertex.advance()
    uniformBufferFragment.advance()
  }

  private func renderTransferfunction(_ renderEncoder: MTLRenderCommandEncoder,
                                      drawable: LayerRenderer.Drawable) {
    renderEncoder.pushDebugGroup("Transfer Function Panel (3D)")

    renderEncoder.setRenderPipelineState(pipelineStateTFHUD)   // keep your name or rename
    renderEncoder.setCullMode(.none)
    renderEncoder.setDepthStencilState(depthStateHUD)
    do {
      try renderTransferFunctions.bind(
        channel: transferFunctionPanelInteractionState.selectedTransferFunctionChannel(),
        to: renderEncoder,
        index: 0
      )
    } catch {
      logger?.error("Failed to bind TF texture for panel: \(error)")
    }

    let viewCount = drawable.views.count
    var mvp = [simd_float4x4](repeating: matrix_identity_float4x4, count: viewCount)

    var panelSize : SIMD2<Float>
    var panelWorldForPicking = tfPanelWorldMatrix
    if frameSnapshot.settings.transferFunctionDisplayMode ==
      TransferFunctionDisplayMode.HUD.rawValue {
      for i in 0..<viewCount {
        let view = drawable.views[i]
        let viewMatrix = (lastOriginFromDevice * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: i)
        mvp[i] = projection * viewMatrix * tfPanelWorldMatrix
      }
      panelSize = tfPanelSizeMeters
      panelWorldForPicking = tfPanelWorldMatrix
    } else {
      // --- Compute panel transform for Object mode ---
      let worldUp = SIMD3<Float>(0, 1, 0)

      // If you want it under the clipped volume, include clipMatrix.
      // If you want it under the full dataset bounds, use lastModelMatrix only.
      let volumeXform = lastModelMatrix * lastClipMatrix

      let volCenter = translation3(volumeXform)
      let volWidth  = length3(volumeXform.columns.0)  // world width of the cube
      let volHeight = length3(volumeXform.columns.1)

      // Panel size derived from volume width (tune clamps/ratios)
      let panelWidth  = clamp(volWidth * 1.05, 0.25, 1.20)
      let panelHeight = panelWidth * 0.35
      panelSize = SIMD2<Float>(panelWidth, panelHeight)

      // Position: under the volume bottom, with margin
      let margin: Float = 0.08
      let bottomCenter = volCenter - worldUp * (0.5 * volHeight)
      let panelPos = bottomCenter - worldUp * (margin + 0.5 * panelHeight)

      // Billboard toward the viewer. Full billboarding keeps the local panel tilt
      // visually stable when the object is moved up, down, or deeper into the scene.
      let (billboard, forward) = makeBillboardMatrix(position: panelPos,
                                                     camera: lastHeadPosition,
                                                     up: worldUp,
                                                     cylindrical: false)

      // Optional: push slightly toward the camera to avoid depth fighting with the volume
      let pushTowardCamera: Float = 0.005
      var panelWorld = billboard
      panelWorld.columns.3.x += forward.x * pushTowardCamera
      panelWorld.columns.3.y += forward.y * pushTowardCamera
      panelWorld.columns.3.z += forward.z * pushTowardCamera
      panelWorldForPicking = panelWorld

      for i in 0..<viewCount {
        let view = drawable.views[i]
        let viewMatrix = (lastOriginFromDevice * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: i)
        mvp[i] = projection * viewMatrix * panelWorld
      }
    }

    transferFunctionPanelInteractionState.updatePanel(
      matrix: panelWorldForPicking,
      size: panelSize,
      isVisible: true
    )

    // buffer(20): mvp array
    mvp.withUnsafeBytes { bytes in
      renderEncoder.setVertexBytes(bytes.baseAddress!,
                                   length: bytes.count,
                                   index: 20)
    }

    renderEncoder.setVertexBytes(&panelSize,
                                 length: MemoryLayout<SIMD2<Float>>.stride,
                                 index: 21)
    let panelInteractionShaderState = transferFunctionPanelInteractionState.shaderState()
    var isFocused: UInt32 = panelInteractionShaderState.isFocused ? 1 : 0
    var hitUV = SIMD4<Float>(
      panelInteractionShaderState.hitUV?.x ?? 0,
      panelInteractionShaderState.hitUV?.y ?? 0,
      panelInteractionShaderState.hitUV == nil ? 0 : panelInteractionShaderState.hitOpacity,
      0
    )
    var channelMask = panelInteractionShaderState.channelMask
    renderEncoder.setFragmentBytes(&panelSize,
                                   length: MemoryLayout<SIMD2<Float>>.stride,
                                   index: 21)
    renderEncoder.setFragmentBytes(&isFocused,
                                   length: MemoryLayout<UInt32>.stride,
                                   index: 22)
    renderEncoder.setFragmentBytes(&hitUV,
                                   length: MemoryLayout<SIMD4<Float>>.stride,
                                   index: 23)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    renderEncoder.setRenderPipelineState(pipelineStateTFHUDControls)
    renderEncoder.setVertexBytes(&panelSize,
                                 length: MemoryLayout<SIMD2<Float>>.stride,
                                 index: 21)
    renderEncoder.setFragmentBytes(&channelMask,
                                   length: MemoryLayout<UInt32>.stride,
                                   index: 24)
    renderEncoder.drawPrimitives(type: .triangle,
                                 vertexStart: 0,
                                 vertexCount: 6,
                                 instanceCount: 4)
    renderEncoder.popDebugGroup()
  }

  private func drawSceneMeshes(
    _ instances: [SceneMeshInstance],
    datasetMaximumExtentMeters: Float,
    renderEncoder: MTLRenderCommandEncoder
  ) {
    guard datasetMaximumExtentMeters.isFinite, datasetMaximumExtentMeters > 0 else { return }

    renderEncoder.pushDebugGroup("Scene Meshes")
    renderEncoder.setRenderPipelineState(pipelineStateSceneMesh)
    renderEncoder.setDepthStencilState(depthStateMarker)
    renderEncoder.setCullMode(.back)
    for instance in instances where instance.isVisible {
      guard let asset = frameSnapshot.annotations.meshAssets[instance.asset.assetID],
            let gpuAsset = sceneMeshGPUCache.asset(for: asset, device: device) else {
        continue
      }
      var modelMatrix = lastUnscaledModelMatrix *
        matrixScale(SIMD3<Float>(repeating: 1 / datasetMaximumExtentMeters)) *
        instance.transformMeters
      var baseColor = asset.baseColor
      renderEncoder.setVertexBuffer(
        gpuAsset.vertexBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &baseColor,
        length: MemoryLayout<SIMD3<Float>>.stride,
        index: 23
      )
      renderEncoder.setFragmentTexture(
        gpuAsset.texture ?? sceneMeshWhiteTexture,
        index: TextureIndex.sceneMeshColor.rawValue
      )
      renderEncoder.drawIndexedPrimitives(
        type: .triangle,
        indexCount: gpuAsset.indexCount,
        indexType: .uint32,
        indexBuffer: gpuAsset.indexBuffer,
        indexBufferOffset: 0
      )
    }
    renderEncoder.popDebugGroup()
  }

  private func drawOpaqueGeometry(_ renderEncoder: MTLRenderCommandEncoder,
                                  drawable: LayerRenderer.Drawable) -> [ScreenViewLabelDescriptor] {
    let screenViews = screenViewVisualization()
    let measurementSnapshot = frameSnapshot.annotations.measurements
    let pendingProjectionCaptureMarkerIDs =
      immersiveInteraction.pendingStrokeProjectionCaptureMarkerIDs()
    let suppressLocalToolWidgets = !pendingProjectionCaptureMarkerIDs.isEmpty
    let persistentMarkers = frameSnapshot.annotations.markers.filter {
      !pendingProjectionCaptureMarkerIDs.contains($0.id)
    }
    let screenViewMarkers = (screenViews.markers + (suppressLocalToolWidgets ? [] : immersiveInteraction.volumeBrushContext.previewMarkers())).filter {
      !pendingProjectionCaptureMarkerIDs.contains($0.id)
    }
    let toolWidgetMarkers = suppressLocalToolWidgets
      ? []
      : spatialStylusMeasurementPreviewMarkers + spatialControllerModePreviewMarkers
    let persistentMeshInstances = frameSnapshot.annotations.meshInstances
    let previewMeshInstances = suppressLocalToolWidgets ? [] : spatialSceneObjectPreviewInstances
    let visibleMeshInstances = (frameState.objectsVisible ? persistentMeshInstances : []) +
      previewMeshInstances
    sceneMeshGPUCache.retainOnly(assetIDs: Set(visibleMeshInstances.map(\.asset.assetID)))
    let remoteToolPreviews = frameSnapshot.annotations.remoteToolPreviews.filter(\.isActive)
    guard (frameState.objectsVisible &&
             (!persistentMarkers.isEmpty || !persistentMeshInstances.isEmpty)) ||
      (frameState.measurementsVisible && !measurementSnapshot.isEmpty) ||
      !screenViewMarkers.isEmpty ||
      !screenViews.labels.isEmpty ||
      !previewMeshInstances.isEmpty ||
      (!suppressLocalToolWidgets && spatialStylusPreviewPoint != nil) ||
      !remoteToolPreviews.isEmpty ||
      (!suppressLocalToolWidgets && !spatialControllerSamples.isEmpty) ||
      (!suppressLocalToolWidgets && !spatialControllerPreviewPoints.isEmpty) else {
      return []
    }

    renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
    renderEncoder.setDepthStencilState(depthStateMarker)
    renderEncoder.setCullMode(.back)
    renderEncoder.setFrontFacing(.counterClockwise)

    let viewCount = drawable.views.count
    guard viewCount > 0 else { return [] }
    var mvp = [simd_float4x4](repeating: matrix_identity_float4x4, count: viewCount)
    var eyePositions = [SIMD3<Float>](repeating: .zero, count: viewCount)
    for i in 0..<viewCount {
      let view = drawable.views[i]
      let eyeMatrix = lastOriginFromDevice * view.transform
      let viewMatrix = eyeMatrix.inverse
      let projection = drawable.computeProjection(viewIndex: i)
      mvp[i] = projection * viewMatrix
      eyePositions[i] = SIMD3<Float>(
        eyeMatrix.columns.3.x,
        eyeMatrix.columns.3.y,
        eyeMatrix.columns.3.z
      )
    }

    func bindMarkerViewData() {
      mvp.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        renderEncoder.setVertexBytes(
          baseAddress,
          length: MemoryLayout<simd_float4x4>.stride * buffer.count,
          index: 20
        )
      }
      eyePositions.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        renderEncoder.setVertexBytes(
          baseAddress,
          length: MemoryLayout<SIMD3<Float>>.stride * buffer.count,
          index: 22
        )
      }
    }
    bindMarkerViewData()

    let physicalExtent = borgData.getMetadata().physicalExtentMeters
    let datasetMaximumExtentMeters = max(
      physicalExtent.x,
      max(physicalExtent.y, physicalExtent.z)
    )
    renderEncoder.setVertexBuffer(
      markerSphereBuffer,
      offset: 0,
      index: VertexBufferIndex.meshPositions.rawValue
    )
    renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)

    let coordinateScale = SIMD3<Float>(
      volumeScale.columns.0.x,
      volumeScale.columns.1.y,
      volumeScale.columns.2.z
    )
    markerTubeMeshCache.retainOnly(
      markerIDs: Set((persistentMarkers + screenViewMarkers + toolWidgetMarkers).map(\.id))
    )
    measurementSurfaceMeshCache.retainOnly(
      measurementIDs: frameState.measurementsVisible
        ? Set(measurementSnapshot.map(\.id))
        : []
    )

    func color(for marker: VolumeMarker) -> SIMD4<Float> {
      VolumeMarkerPresentation.color(
        for: marker,
        isSelected: frameSnapshot.annotations.selectedMarkerIDs.contains(marker.id)
      )
    }

    func drawSphere(_ point: VolumeMarkerPoint, color: SIMD4<Float>) {
      let markerVolumePosition = simd_make_float3(
        volumeScale * SIMD4<Float>(point.position - SIMD3<Float>(repeating: 0.5), 1.0)
      )
      var modelMatrix = lastUnscaledModelMatrix *
        Transform(translation: markerVolumePosition).matrix *
        Transform(scale: SIMD3<Float>(repeating: point.radius)).matrix
      var color = color
      renderEncoder.setVertexBuffer(
        markerSphereBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: markerSphereVertexCount
      )
    }

    func drawControllerPointer(_ sample: BorgSpatialInputSample) {
      var color = SIMD4<Float>(0.62, 0.65, 0.7, 1)
      var pointerMatrix = sample.aimTransform
      renderEncoder.setVertexBuffer(
        spatialControllerPointerBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(
        spatialControllerPointerNormalBuffer,
        offset: 0,
        index: 24
      )
      renderEncoder.setVertexBytes(
        &pointerMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: spatialControllerPointerVertexCount
      )

      var bodyMatrix = sample.aimTransform *
        Transform(translation: SIMD3<Float>(0, 0, 0.055)).matrix *
        Transform(scale: SIMD3<Float>(repeating: 0.015)).matrix
      renderEncoder.setVertexBuffer(
        markerSphereBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(markerSphereNormalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &bodyMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: markerSphereVertexCount
      )
    }

    func drawTube(for marker: VolumeMarker, color: SIMD4<Float>) {
      guard let tubeMesh = markerTubeMeshCache.mesh(
        for: marker,
        coordinateScale: coordinateScale,
        device: device
      ) else { return }
      var modelMatrix = lastUnscaledModelMatrix
      var color = color
      renderEncoder.setVertexBuffer(
        tubeMesh.positionBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(tubeMesh.normalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: tubeMesh.vertexCount
      )
    }

    func drawMarkerGeometry(_ markerGeometry: [VolumeMarker], groupName: String) {
      renderEncoder.pushDebugGroup(groupName)
      for marker in markerGeometry {
        let markerColor = color(for: marker)
        switch marker.geometry {
          case .sphere(let point):
            drawTube(for: marker, color: markerColor)
            drawSphere(point, color: markerColor)

          case .stroke(let points):
            drawTube(for: marker, color: markerColor)
            if let first = points.first {
              drawSphere(first, color: markerColor)
            }
            if points.count > 1, let last = points.last {
              drawSphere(last, color: markerColor)
            }
        }
      }
      renderEncoder.popDebugGroup()
    }

    func drawObjects() {
      guard frameState.objectsVisible else { return }

      drawSceneMeshes(
        persistentMeshInstances,
        datasetMaximumExtentMeters: datasetMaximumExtentMeters,
        renderEncoder: renderEncoder
      )
      renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
      drawMarkerGeometry(persistentMarkers, groupName: "Objects")
    }

    func drawToolWidgets() {
      renderEncoder.pushDebugGroup("Spatial Tool Widgets")
      if !suppressLocalToolWidgets {
        drawSceneMeshes(
          previewMeshInstances,
          datasetMaximumExtentMeters: datasetMaximumExtentMeters,
          renderEncoder: renderEncoder
        )
        renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
        drawMarkerGeometry(toolWidgetMarkers, groupName: "Tool Mode Glyphs")
        if spatialStylusMeasurementPreviewMarkers.isEmpty,
           let spatialStylusPreviewPoint {
          drawSphere(
            spatialStylusPreviewPoint,
            color: frameSnapshot.annotations.localToolColor
          )
        }
        for point in spatialControllerPreviewPoints {
          drawSphere(point, color: frameSnapshot.annotations.localToolColor)
        }
        for sample in spatialControllerSamples {
          drawControllerPointer(sample)
        }
      }
      for preview in remoteToolPreviews {
        drawSphere(preview.point, color: preview.color)
      }
      renderEncoder.popDebugGroup()
    }

    drawObjects()
    drawMarkerGeometry(screenViewMarkers, groupName: "Screen View Avatars")
    drawToolWidgets()

    var measurementLabels: [ScreenViewLabelDescriptor] = []
    func drawMeasurements() {
      guard frameState.measurementsVisible else { return }

      let measurements = measurementVisualization(measurements: measurementSnapshot)
      measurementLabels = measurements.labels
      renderEncoder.pushDebugGroup("Measurements")
      if !measurements.points.isEmpty {
        let byteCount = MemoryLayout<MeasurementPointRenderInstance>.stride *
          measurements.points.count
        if measurementPointBuffer == nil || measurementPointBufferCapacity < byteCount {
          var capacity = max(measurementPointBufferCapacity, 4096)
          while capacity < byteCount {
            capacity *= 2
          }
          measurementPointBuffer = device.makeBuffer(
            length: capacity,
            options: .storageModeShared
          )
          measurementPointBufferCapacity = capacity
          measurementPointBuffer?.label = "Measurement Point Instances"
        }
        if let measurementPointBuffer {
          measurements.points.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            measurementPointBuffer.contents().copyMemory(
              from: baseAddress,
              byteCount: bytes.count
            )
          }
          var modelMatrix = lastUnscaledModelMatrix
          let viewportSizes = drawable.views.map { view in
            SIMD2<Float>(
              Float(view.textureMap.viewport.width),
              Float(view.textureMap.viewport.height)
            )
          }
          renderEncoder.setRenderPipelineState(pipelineStateMeasurementPoint)
          renderEncoder.setDepthStencilState(depthStateMarker)
          renderEncoder.setCullMode(.none)
          bindMarkerViewData()
          renderEncoder.setVertexBytes(
            &modelMatrix,
            length: MemoryLayout<simd_float4x4>.stride,
            index: 21
          )
          renderEncoder.setVertexBuffer(measurementPointBuffer, offset: 0, index: 25)
          viewportSizes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            renderEncoder.setVertexBytes(
              baseAddress,
              length: MemoryLayout<SIMD2<Float>>.stride * buffer.count,
              index: 26
            )
          }
          renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: measurements.points.count
          )
        }
      }
      if !measurements.lines.isEmpty {
      let byteCount = MemoryLayout<MeasurementVisualization.Line>.stride *
        measurements.lines.count
      if measurementLineBuffer == nil || measurementLineBufferCapacity < byteCount {
        var capacity = max(measurementLineBufferCapacity, 4096)
        while capacity < byteCount {
          capacity *= 2
        }
        measurementLineBuffer = device.makeBuffer(
          length: capacity,
          options: .storageModeShared
        )
        measurementLineBuffer?.label = "Measurement Line Instances"
        measurementLineBufferCapacity = capacity
      }
      if let measurementLineBuffer {
        measurements.lines.withUnsafeBytes { bytes in
          if let baseAddress = bytes.baseAddress {
            measurementLineBuffer.contents().copyMemory(
              from: baseAddress,
              byteCount: bytes.count
            )
          }
        }
        var modelMatrix = lastUnscaledModelMatrix
        let viewportSizes = drawable.views.map { view in
          SIMD2<Float>(
            Float(view.textureMap.viewport.width),
            Float(view.textureMap.viewport.height)
          )
        }
        renderEncoder.setRenderPipelineState(pipelineStateMeasurementLine)
        renderEncoder.setDepthStencilState(depthStateMarker)
        renderEncoder.setCullMode(.none)
        bindMarkerViewData()
        renderEncoder.setVertexBytes(
          &modelMatrix,
          length: MemoryLayout<simd_float4x4>.stride,
          index: 21
        )
        renderEncoder.setVertexBuffer(measurementLineBuffer, offset: 0, index: 25)
        viewportSizes.withUnsafeBufferPointer { buffer in
          guard let baseAddress = buffer.baseAddress else { return }
          renderEncoder.setVertexBytes(
            baseAddress,
            length: MemoryLayout<SIMD2<Float>>.stride * buffer.count,
            index: 26
          )
        }
        renderEncoder.drawPrimitives(
          type: .triangle,
          vertexStart: 0,
          vertexCount: 6,
          instanceCount: measurements.lines.count
        )
      }
    }

    let surfaceMeshes = measurements.surfaces.compactMap { surface -> (
      surface: MeasurementVisualization.Surface,
      mesh: MeasurementSurfaceGPUMesh
    )? in
      guard let mesh = measurementSurfaceMeshCache.mesh(
        for: surface.measurement,
        coordinateScale: coordinateScale,
        device: device
      ) else { return nil }
      return (surface, mesh)
    }

    func drawSurface(
      _ mesh: MeasurementSurfaceGPUMesh,
      color: SIMD4<Float>,
      cullMode: MTLCullMode,
      depthStencilState: MTLDepthStencilState
    ) {
      guard mesh.vertexCount >= 3, mesh.vertexCount.isMultiple(of: 3) else { return }
      var modelMatrix = lastUnscaledModelMatrix
      var color = color
      renderEncoder.setRenderPipelineState(pipelineStateVolumeMarker)
      renderEncoder.setDepthStencilState(depthStencilState)
      renderEncoder.setCullMode(cullMode)
      // Labels use slot 22 for their float2 size. Restore the marker shader's
      // per-view eye positions before every draw that follows a label.
      bindMarkerViewData()
      renderEncoder.setVertexBuffer(
        mesh.positionBuffer,
        offset: 0,
        index: VertexBufferIndex.meshPositions.rawValue
      )
      renderEncoder.setVertexBuffer(mesh.normalBuffer, offset: 0, index: 24)
      renderEncoder.setVertexBytes(
        &modelMatrix,
        length: MemoryLayout<simd_float4x4>.stride,
        index: 21
      )
      renderEncoder.setFragmentBytes(
        &color,
        length: MemoryLayout<SIMD4<Float>>.stride,
        index: 23
      )
      renderEncoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: mesh.vertexCount
      )
    }

    // A ray through a convex hull sees at most one exit and one entry surface.
    // Rendering back faces before front faces is therefore deterministic and
    // does not rely on ambiguous triangle-centroid sorting.
    for entry in surfaceMeshes {
      if entry.surface.measurement.kind == .volume {
        drawSurface(
          entry.mesh,
          color: entry.surface.color,
          cullMode: .front,
          depthStencilState: depthStateMarkerReadOnly
        )
        drawSurface(
          entry.mesh,
          color: entry.surface.color,
          cullMode: .back,
          depthStencilState: depthStateMarkerReadOnly
        )
      } else {
        drawSurface(
          entry.mesh,
          color: entry.surface.color,
          cullMode: .none,
          depthStencilState: depthStateMarkerReadOnly
        )
      }
    }

    // Preserve the closest transparent surface depth for volume compositing without
    // blending every surface a second time.
    let transparentDepthColor = SIMD4<Float>(0, 0, 0, 0)
    for entry in surfaceMeshes {
      drawSurface(
        entry.mesh,
        color: transparentDepthColor,
        cullMode: .none,
        depthStencilState: depthStateMarker
      )
    }
      renderEncoder.setCullMode(.back)
      renderEncoder.popDebugGroup()
    }

    drawMeasurements()

    drawScreenViewLabels(
      screenViews.labels,
      renderEncoder: renderEncoder,
      depthStencilState: depthStateMarker,
      pipelineState: pipelineStateScreenViewLabel
    )
    return measurementLabels
  }

  private func drawScreenViewLabels(
    _ labels: [ScreenViewLabelDescriptor],
    renderEncoder: MTLRenderCommandEncoder,
    depthStencilState: MTLDepthStencilState,
    pipelineState: MTLRenderPipelineState
  ) {
    guard !labels.isEmpty else { return }

    for label in labels {
      drawScreenViewLabel(
        label,
        renderEncoder: renderEncoder,
        depthStencilState: depthStencilState,
        pipelineState: pipelineState
      )
    }
  }

  private func screenViewLabelWorldPosition(
    _ label: ScreenViewLabelDescriptor
  ) -> SIMD3<Float> {
    let volumePosition = simd_make_float3(
      volumeScale * SIMD4<Float>(label.position - SIMD3<Float>(repeating: 0.5), 1)
    )
    var worldPosition = simd_make_float3(
      lastUnscaledModelMatrix * SIMD4<Float>(volumePosition, 1)
    )
    guard worldPosition.x.isFinite, worldPosition.y.isFinite, worldPosition.z.isFinite else {
      return lastHeadPosition
    }
    if label.depthOffsetTowardCamera > 0 {
      let cameraDirection = lastHeadPosition - worldPosition
      let lengthSquared = simd_length_squared(cameraDirection)
      if lengthSquared.isFinite, lengthSquared > 0.000_000_1 {
        worldPosition += cameraDirection / sqrt(lengthSquared) * label.depthOffsetTowardCamera
      }
    }
    return worldPosition
  }

  private func drawScreenViewLabel(
    _ label: ScreenViewLabelDescriptor,
    renderEncoder: MTLRenderCommandEncoder,
    depthStencilState: MTLDepthStencilState,
    pipelineState: MTLRenderPipelineState
  ) {

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setDepthStencilState(depthStencilState)
    renderEncoder.setCullMode(.none)

    guard let labelTexture = screenViewLabelTextureCache.texture(
      for: label.text,
      accentColor: label.color,
      opaqueBackground: label.opaqueBackground,
      device: device
    ) else { return }

    let worldPosition = screenViewLabelWorldPosition(label)
    var modelMatrix = makeBillboardMatrix(
      position: worldPosition,
      camera: lastHeadPosition,
      up: SIMD3<Float>(0, 1, 0),
      cylindrical: false
    ).0
    modelMatrix.columns.3 += modelMatrix.columns.0 * label.billboardOffset.x +
      modelMatrix.columns.1 * label.billboardOffset.y
    let labelHeight = label.height
    var labelSize = SIMD2<Float>(
      min(labelHeight * labelTexture.aspectRatio, 0.36),
      labelHeight
    )

    renderEncoder.setVertexBytes(
      &modelMatrix,
      length: MemoryLayout<simd_float4x4>.stride,
      index: 21
    )
    renderEncoder.setVertexBytes(
      &labelSize,
      length: MemoryLayout<SIMD2<Float>>.stride,
      index: 22
    )
    renderEncoder.setFragmentTexture(
      labelTexture.texture,
      index: TextureIndex.screenViewLabel.rawValue
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
  }

  private func screenViewVisualization() -> ScreenViewVisualization {
    let spatialViews = frameSnapshot.spatialViews
    let screenParticipants = spatialViews.participants.filter {
      $0.platform == .iOS || $0.platform == .macOS
    }
    guard !screenParticipants.isEmpty else { return ScreenViewVisualization() }

    var result = ScreenViewVisualization()
    if let state = spatialViews.sharedView {
      let sharedView = screenViewVisualizationMarkers(
        state: state,
        markerID: nil,
        name: String(localized: "Shared View"),
        color: ScreenViewPresentation.sharedColor,
        interactionActive: spatialViews.interactionActive
      )
      result.markers += sharedView.markers
      if spatialViews.namesVisible {
        result.labels.append(sharedView.label)
      }
    }

    let detachedParticipants = screenParticipants.filter {
      spatialViews.detachedViews[$0.id] != nil
    }
    for participant in detachedParticipants {
      guard let state = spatialViews.detachedViews[participant.id] else {
        continue
      }
      let detachedView = screenViewVisualizationMarkers(
        state: state,
        markerID: participant.id,
        name: participant.displayName,
        color: ScreenViewPresentation.detachedColor(for: participant.id),
        interactionActive: false
      )
      result.markers += detachedView.markers
      if spatialViews.namesVisible {
        result.labels.append(detachedView.label)
      }
    }
    return result
  }

  private func screenViewVisualizationMarkers(
    state: BorgVRScreenViewState,
    markerID: UUID?,
    name: String,
    color: SIMD4<Float>,
    interactionActive: Bool
  ) -> (markers: [VolumeMarker], label: ScreenViewLabelDescriptor) {
    func id(_ index: Int) -> UUID {
      guard let markerID else {
        return Self.screenViewVisualizationMarkerIDs[index]
      }
      var uuid = markerID.uuid
      withUnsafeMutableBytes(of: &uuid) { bytes in
        bytes[14] ^= UInt8(truncatingIfNeeded: index >> 8)
        bytes[15] ^= UInt8(truncatingIfNeeded: index)
      }
      return UUID(uuid: uuid)
    }

    let aspect = min(max(state.viewportAspectRatio, 0.25), 4)
    let fieldOfView = min(max(state.verticalFieldOfView, 0.2), 2.6)
    let nearDistance: Float = 0.12
    let farDistance: Float = 3.6
    let cameraDistance = BorgVRScreenViewState.cameraDistance

    let screenFromVolume =
      Transform(translation: SIMD3<Float>(state.pan.x, state.pan.y, 0)).matrix *
      simd_float4x4(state.orientation) *
      Transform(scale: SIMD3<Float>(repeating: state.scale)).matrix *
      volumeScale
    let volumeFromScreen = simd_inverse(screenFromVolume)

    func volumePoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
      let transformed = volumeFromScreen * SIMD4<Float>(point, 1)
      return SIMD3<Float>(transformed.x, transformed.y, transformed.z) / transformed.w +
        SIMD3<Float>(repeating: 0.5)
    }

    func planeCorners(distance: Float) -> [SIMD3<Float>] {
      let halfHeight = distance * tan(fieldOfView * 0.5)
      let halfWidth = halfHeight * aspect
      let z = cameraDistance - distance
      return [
        volumePoint(SIMD3<Float>(-halfWidth, -halfHeight, z)),
        volumePoint(SIMD3<Float>( halfWidth, -halfHeight, z)),
        volumePoint(SIMD3<Float>( halfWidth,  halfHeight, z)),
        volumePoint(SIMD3<Float>(-halfWidth,  halfHeight, z))
      ]
    }

    let nearHalfHeight = nearDistance * tan(fieldOfView * 0.5)
    let labelPosition = volumePoint(SIMD3<Float>(
      0,
      nearHalfHeight + 0.052,
      cameraDistance - nearDistance
    ))
    let label = ScreenViewLabelDescriptor(text: name, color: color, position: labelPosition)

    let lineRadius: Float = 0.002

    if !interactionActive {
      let screenCorners = planeCorners(distance: nearDistance)
      var result = (0..<4).map { index in
        VolumeMarker(
          id: id(index),
          name: name,
          color: color,
          geometry: .stroke([
            VolumeMarkerPoint(position: screenCorners[index], radius: 0.004),
            VolumeMarkerPoint(position: screenCorners[(index + 1) % 4], radius: 0.004)
          ])
        )
      }

      let eyeZ = cameraDistance + 0.035
      let eyeWidth: Float = 0.085
      let eyeHeight: Float = 0.038
      let upperEye = (0...8).map { index -> VolumeMarkerPoint in
        let t = Float(index) / 8
        return VolumeMarkerPoint(
          position: volumePoint(SIMD3<Float>(
            (t - 0.5) * eyeWidth,
            sin(t * .pi) * eyeHeight,
            eyeZ
          )),
          radius: 0.003
        )
      }
      let lowerEye = (0...8).map { index -> VolumeMarkerPoint in
        let t = Float(index) / 8
        return VolumeMarkerPoint(
          position: volumePoint(SIMD3<Float>(
            (t - 0.5) * eyeWidth,
            -sin(t * .pi) * eyeHeight,
            eyeZ
          )),
          radius: 0.003
        )
      }
      result.append(VolumeMarker(
        id: id(4),
        name: name,
        color: color,
        geometry: .stroke(upperEye)
      ))
      result.append(VolumeMarker(
        id: id(5),
        name: name,
        color: color,
        geometry: .stroke(lowerEye)
      ))
      result.append(VolumeMarker(
        id: id(6),
        name: name,
        color: color,
        geometry: .sphere(VolumeMarkerPoint(
          position: volumePoint(SIMD3<Float>(0, 0, eyeZ - 0.006)),
          radius: 0.012
        ))
      ))
      return (result, label)
    }

    let near = planeCorners(distance: nearDistance)
    let far = planeCorners(distance: farDistance)
    let edges = [
      (near[0], near[1]), (near[1], near[2]),
      (near[2], near[3]), (near[3], near[0]),
      (far[0], far[1]), (far[1], far[2]),
      (far[2], far[3]), (far[3], far[0]),
      (near[0], far[0]), (near[1], far[1]),
      (near[2], far[2]), (near[3], far[3])
    ]
    var result = edges.enumerated().map { index, edge in
      VolumeMarker(
        id: id(index),
        name: name,
        color: color,
        geometry: .stroke([
          VolumeMarkerPoint(position: edge.0, radius: lineRadius),
          VolumeMarkerPoint(position: edge.1, radius: lineRadius)
        ])
      )
    }
    result.append(VolumeMarker(
      id: id(12),
      name: name,
      color: color,
      geometry: .sphere(VolumeMarkerPoint(
        position: volumePoint(SIMD3<Float>(0, 0, cameraDistance)),
        radius: 0.018
      ))
    ))
    return (result, label)
  }

  private func renderOpaqueGeometry(commandBuffer: MTLCommandBuffer,
                                    drawable: LayerRenderer.Drawable,
                                    rasterizationRateMap: MTLRasterizationRateMap?) -> (
    color: MTLTexture,
    depth: MTLTexture,
    measurementLabels: [ScreenViewLabelDescriptor]
  ) {
    let targets = markerRenderTargets(drawable: drawable)
    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.colorAttachments[0].texture = targets.color
    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].storeAction = .store
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    renderPassDescriptor.depthAttachment.texture = targets.depth
    renderPassDescriptor.depthAttachment.loadAction = .clear
    renderPassDescriptor.depthAttachment.storeAction = .store
    renderPassDescriptor.depthAttachment.clearDepth = 0.0
    renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
    if layerRenderer.configuration.layout == .layered {
      renderPassDescriptor.renderTargetArrayLength = drawable.views.count
    }

    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      fatalError("Failed to create marker prepass encoder")
    }
    renderEncoder.label = "BorgVR Opaque Geometry Prepass"
    renderEncoder.pushDebugGroup("Opaque Geometry Prepass")

    let viewports = drawable.views.map { $0.textureMap.viewport }
    renderEncoder.setViewports(viewports)

    if drawable.views.count > 1 {
      var viewMappings = (0..<drawable.views.count).map {
        MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                          renderTargetArrayIndexOffset: UInt32($0))
      }
      renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
    }

    let measurementLabels = drawOpaqueGeometry(renderEncoder, drawable: drawable)

    renderEncoder.popDebugGroup()
    renderEncoder.endEncoding()

    return (targets.color, targets.depth, measurementLabels)
  }

  private func drawMeasurementLabelsOnScreen(
    _ labels: [ScreenViewLabelDescriptor],
    renderEncoder: MTLRenderCommandEncoder,
    drawable: LayerRenderer.Drawable
  ) {
    guard !labels.isEmpty, !drawable.views.isEmpty else { return }
    let mvp = drawable.views.indices.map { index in
      let view = drawable.views[index]
      let eyeMatrix = lastOriginFromDevice * view.transform
      return drawable.computeProjection(viewIndex: index) * eyeMatrix.inverse
    }
    mvp.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      renderEncoder.setVertexBytes(
        baseAddress,
        length: MemoryLayout<simd_float4x4>.stride * buffer.count,
        index: 20
      )
    }
    let sortedLabels = labels.sorted {
      simd_distance_squared(screenViewLabelWorldPosition($0), lastHeadPosition) >
        simd_distance_squared(screenViewLabelWorldPosition($1), lastHeadPosition)
    }
    drawScreenViewLabels(
      sortedLabels,
      renderEncoder: renderEncoder,
      depthStencilState: depthStateMarkerComposite,
      pipelineState: pipelineStateScreenViewOverlayLabel
    )
  }

  private func compositeOpaqueGeometry(_ renderEncoder: MTLRenderCommandEncoder,
                                       colorTexture: MTLTexture,
                                       depthTexture: MTLTexture) {
    renderEncoder.pushDebugGroup("Composite Opaque Geometry")
    renderEncoder.setRenderPipelineState(pipelineStateMarkerComposite)
    renderEncoder.setDepthStencilState(depthStateMarkerComposite)
    renderEncoder.setCullMode(.none)
    renderEncoder.setFragmentTexture(
      colorTexture,
      index: TextureIndex.markerColor.rawValue
    )
    renderEncoder.setFragmentTexture(
      depthTexture,
      index: TextureIndex.markerDepth.rawValue
    )
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    renderEncoder.popDebugGroup()
  }

  private func finishSpatialStylusStroke() {
    let completedStroke = activeSpatialStylusStrokeID != nil
    if let activeSpatialStylusStrokeID {
      immersiveInteraction.endStrokeProjectionFreeze(token: activeSpatialStylusStrokeID)
    }
    activeSpatialStylusStrokeID = nil
    spatialStylusTipFilterState = nil
    if completedStroke {
      sharedAppModel.synchronizeMarkers()
    }
  }

  private func filteredSpatialStylusTip(
    position: SIMD3<Float>,
    pressure: Float?
  ) -> (position: SIMD3<Float>, pressure: Float?) {
    guard let pressure else {
      spatialStylusTipFilterState = nil
      return (position, nil)
    }
    guard let previous = spatialStylusTipFilterState else {
      spatialStylusTipFilterState = (position, pressure)
      return (position, pressure)
    }

    let movement = simd_distance(position, previous.position)
    let positionBlend = min(0.7, max(0.18, movement / 0.003))
    let filteredPosition = previous.position +
      (position - previous.position) * positionBlend
    let pressureBlend: Float = 0.22
    let filteredPressure = previous.pressure +
      (pressure - previous.pressure) * pressureBlend
    spatialStylusTipFilterState = (filteredPosition, filteredPressure)
    return (filteredPosition, filteredPressure)
  }

  private func spatialToolPreviewPoint(
    worldPosition: SIMD3<Float>,
    radius: Float
  ) -> VolumeMarkerPoint? {
    let volumeFromOrigin = simd_inverse(lastUnscaledModelMatrix * volumeScale)
    let local = volumeFromOrigin * SIMD4<Float>(worldPosition, 1)
    guard abs(local.w) > 0.000_001 else { return nil }
    let position = SIMD3<Float>(local.x, local.y, local.z) / local.w +
      SIMD3<Float>(repeating: 0.5)
    let modelScale = simd_abs(frameState.transform.scale)
    let averageModelScale = max(
      (modelScale.x + modelScale.y + modelScale.z) / 3,
      0.000_001
    )
    return VolumeMarkerPoint(
      position: simd_clamp(
        position,
        SIMD3<Float>(repeating: -8),
        SIMD3<Float>(repeating: 8)
      ),
      // Preview points originate in world space. Compensate the model scale so
      // scaling the volume does not also resize the controller or stylus tip.
      radius: radius / averageModelScale
    )
  }

  private func spatialToolGlyphPosition(
    aimTransform: simd_float4x4,
    distanceBehindTip: Float
  ) -> SIMD3<Float> {
    let position = aimTransform * SIMD4<Float>(0, 0, distanceBehindTip, 1)
    return SIMD3<Float>(position.x, position.y, position.z)
  }

  private func spatialControllerGlyphPosition(
    aimTransform: simd_float4x4
  ) -> SIMD3<Float> {
    let bodyCenter = spatialToolGlyphPosition(
      aimTransform: aimTransform,
      distanceBehindTip: 0.055
    )
    let devicePosition = SIMD3<Float>(
      lastOriginFromDevice.columns.3.x,
      lastOriginFromDevice.columns.3.y,
      lastOriginFromDevice.columns.3.z
    )
    let towardDevice = devicePosition - bodyCenter
    guard simd_length_squared(towardDevice) > 0.000_001 else { return bodyCenter }
    return bodyCenter + simd_normalize(towardDevice) * 0.017
  }

  private func stylusMeasurementPreviewMarkers(
    worldPosition: SIMD3<Float>,
    kind: VolumeMeasurementKind,
    showsPlus: Bool,
    markerIDs: [UUID]
  ) -> [VolumeMarker] {
    let right = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.0.x,
      lastOriginFromDevice.columns.0.y,
      lastOriginFromDevice.columns.0.z
    ))
    let up = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.1.x,
      lastOriginFromDevice.columns.1.y,
      lastOriginFromDevice.columns.1.z
    ))
    let forward = -simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.2.x,
      lastOriginFromDevice.columns.2.y,
      lastOriginFromDevice.columns.2.z
    ))
    let size: Float = 0.011
    var worldVertices: [SIMD3<Float>]
    var paths: [[Int]]
    switch kind {
      case .length:
        worldVertices = [worldPosition - right * size, worldPosition + right * size]
        paths = [[0, 1]]
      case .area:
        worldVertices = [
          worldPosition + up * size,
          worldPosition - up * size * 0.7 - right * size,
          worldPosition - up * size * 0.7 + right * size
        ]
        paths = [[0, 1, 2, 0]]
      case .volume:
        worldVertices = [
          worldPosition + up * size,
          worldPosition - up * size * 0.65 - right * size,
          worldPosition - up * size * 0.65 + right * size,
          worldPosition - forward * size * 1.25
        ]
        paths = [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]]
    }
    if showsPlus {
      let center = worldPosition + right * size * 1.55 + up * size * 1.15
      let arm = size * 0.34
      let startIndex = worldVertices.count
      worldVertices.append(contentsOf: [
        center - right * arm,
        center + right * arm,
        center - up * arm,
        center + up * arm
      ])
      paths.append([startIndex, startIndex + 1])
      paths.append([startIndex + 2, startIndex + 3])
    }
    let points = worldVertices.compactMap {
      spatialToolPreviewPoint(worldPosition: $0, radius: 0.0018)
    }
    guard points.count == worldVertices.count else { return [] }
    let color = measurementColor(for: kind, selected: true)
    return paths.enumerated().map { index, path in
      VolumeMarker(
        id: markerIDs[index],
        name: "Stylus measurement preview",
        color: color,
        geometry: .stroke(path.map { points[$0] })
      )
    }
  }

  private func spatialControllerToolPreviewMarkers(
    sample: BorgSpatialInputSample,
    mode: SpatialToolMode
  ) -> [VolumeMarker] {
    let markerIDs = (0..<8).map {
      measurementVisualizationID(sample.id, 0x100 + $0)
    }
    if let kind = mode.measurementKind {
      return stylusMeasurementPreviewMarkers(
        worldPosition: spatialControllerGlyphPosition(
          aimTransform: sample.aimTransform
        ),
        kind: kind,
        showsPlus: immersiveInteraction.spatialControllerWillExtendMeasurement(
          sourceID: sample.id,
          kind: kind
        ),
        markerIDs: markerIDs
      )
    }

    let right = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.0.x,
      lastOriginFromDevice.columns.0.y,
      lastOriginFromDevice.columns.0.z
    ))
    let up = simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.1.x,
      lastOriginFromDevice.columns.1.y,
      lastOriginFromDevice.columns.1.z
    ))
    let forward = -simd_normalize(SIMD3<Float>(
      lastOriginFromDevice.columns.2.x,
      lastOriginFromDevice.columns.2.y,
      lastOriginFromDevice.columns.2.z
    ))
    let center = sample.source == .stylus
      ? spatialToolGlyphPosition(aimTransform: sample.aimTransform, distanceBehindTip: 0.05)
      : spatialControllerGlyphPosition(aimTransform: sample.aimTransform)
    let size: Float = 0.011
    let worldVertices: [SIMD3<Float>]
    let paths: [[Int]]
    let color: SIMD4<Float>
    switch mode {
      case .erase, .restore:
        let sign = center + right * size * 1.7 + up * size * 0.75
        let arm = size * 0.34
        worldVertices = [
          center - right * size * 0.9 - up * size * 0.25,
          center - right * size * 0.35 - up * size * 0.8,
          center + right * size * 0.2 - up * size * 0.8,
          center + right * size,
          center + right * size * 0.2 + up * size * 0.8,
          center - right * size * 0.35 + up * size * 0.15,
          center + right * size * 0.45 - up * size * 0.55,
          sign - right * arm, sign + right * arm,
          sign - up * arm, sign + up * arm
        ]
        paths = mode == .restore
          ? [[0, 1, 2, 3, 4, 0], [5, 6], [7, 8], [9, 10]]
          : [[0, 1, 2, 3, 4, 0], [5, 6], [7, 8]]
        color = mode == .erase ? SIMD4(1, 0.2, 0.2, 1) : SIMD4(0.2, 1, 0.5, 1)
      case .model:
        worldVertices = [
          center - right * size, center + right * size,
          center - up * size, center + up * size,
          center - forward * size, center + forward * size
        ]
        paths = [[0, 1], [2, 3], [4, 5]]
        color = SIMD4<Float>(0.15, 0.8, 1, 1)
      case .clipping:
        worldVertices = [
          center - right * size - up * size,
          center + right * size - up * size,
          center + right * size + up * size,
          center - right * size + up * size,
          center - right * size * 1.25,
          center + right * size * 1.25
        ]
        paths = [[0, 1, 2, 3, 0], [4, 5]]
        color = SIMD4<Float>(1, 0.55, 0.1, 1)
      case .marker:
        worldVertices = [
          center - right * size - up * size * 0.55,
          center - right * size * 0.25 + up * size * 0.4,
          center + right * size * 0.35 - up * size * 0.25,
          center + right * size + up * size * 0.65
        ]
        paths = [[0, 1, 2, 3]]
        color = sharedAppModel.defaultVolumeStrokeColor
      case .objectPlacement:
        return []
      case .screenView:
        worldVertices = [
          center - right * size * 1.25 - up * size * 0.75,
          center + right * size * 1.25 - up * size * 0.75,
          center + right * size * 1.25 + up * size * 0.75,
          center - right * size * 1.25 + up * size * 0.75
        ]
        paths = [[0, 1, 2, 3, 0]]
        color = SIMD4<Float>(0.2, 1, 0.55, 1)
      case .lengthMeasurement, .areaMeasurement, .volumeMeasurement:
        return []
    }
    let points = worldVertices.compactMap {
      spatialToolPreviewPoint(worldPosition: $0, radius: 0.0018)
    }
    guard points.count == worldVertices.count else { return [] }
    return paths.enumerated().map { index, path in
      VolumeMarker(
        id: markerIDs[index],
        name: "Controller tool preview",
        color: color,
        geometry: .stroke(path.map { points[$0] })
      )
    }
  }

  private func updateSpatialStylusStroke(
    sample: BorgSpatialStylusSample?
  ) {
    guard let sample else {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = nil
      spatialStylusRadiusAdjustmentStart = nil
      return
    }
    let filteredTip = filteredSpatialStylusTip(
      position: sample.tipPosition,
      pressure: sample.drawingPressure
    )
    guard let previewPoint = spatialToolPreviewPoint(
      worldPosition: filteredTip.position,
      radius: sharedAppModel.defaultVolumeStrokeRadius
    ) else {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = nil
      spatialStylusRadiusAdjustmentStart = nil
      return
    }
    let position = previewPoint.position

    if sample.isAdjustingRadius {
      finishSpatialStylusStroke()
      if spatialStylusRadiusAdjustmentStart == nil {
        let hsv = rgbToHSV(sharedAppModel.defaultVolumeStrokeColor)
        spatialStylusRadiusAdjustmentStart = (
          position: sample.tipPosition,
          radius: sharedAppModel.defaultVolumeStrokeRadius,
          hue: hsv.hue
        )
      }
      if let start = spatialStylusRadiusAdjustmentStart {
        let deviceUp = simd_normalize(SIMD3<Float>(
          lastOriginFromDevice.columns.1.x,
          lastOriginFromDevice.columns.1.y,
          lastOriginFromDevice.columns.1.z
        ))
        let deviceRight = simd_normalize(SIMD3<Float>(
          lastOriginFromDevice.columns.0.x,
          lastOriginFromDevice.columns.0.y,
          lastOriginFromDevice.columns.0.z
        ))
        let movement = sample.tipPosition - start.position
        let verticalMovement = simd_dot(movement, deviceUp)
        let horizontalMovement = simd_dot(movement, deviceRight)
        sharedAppModel.defaultVolumeStrokeRadius = VolumeMarkerRadius.clamp(
          start.radius * exp(verticalMovement * 8),
          for: .stroke
        )
        sharedAppModel.defaultVolumeStrokeColor = hsvToRGB(
          hue: start.hue + horizontalMovement * 3,
          saturation: 1,
          value: 1
        )
      }
      spatialStylusPreviewPoint = VolumeMarkerPoint(
        position: position,
        radius: sharedAppModel.defaultVolumeStrokeRadius
      )
      return
    }

    spatialStylusRadiusAdjustmentStart = nil
    guard sample.isDrawing else {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = VolumeMarkerPoint(
        position: position,
        radius: sharedAppModel.defaultVolumeStrokeRadius
      )
      return
    }

    spatialStylusPreviewPoint = nil
    let previousPosition = activeSpatialStylusStrokeID.flatMap { strokeID in
      sharedAppModel.volumeMarkers.first(where: { $0.id == strokeID })?.points.last?.position
    }
    let strokePosition = storedAppModel.projectObjectsOntoVolume
      ? immersiveInteraction.projectedVolumePosition(
          toward: filteredTip.position,
          smoothingDepthFrom: previousPosition
        ) ?? position
      : position
    let pointRadius = filteredTip.pressure.map {
      VolumeMarkerRadius.pressureAdjustedStrokeRadius(
        maximumRadius: sharedAppModel.defaultVolumeStrokeRadius,
        pressure: $0
      )
    } ?? sharedAppModel.defaultVolumeStrokeRadius
    let point = VolumeMarkerPoint(
      position: strokePosition,
      radius: pointRadius
    )

    if let activeSpatialStylusStrokeID,
       let markerIndex = sharedAppModel.volumeMarkers.firstIndex(where: {
         $0.id == activeSpatialStylusStrokeID
       }) {
      let modelScale = simd_abs(frameState.transform.scale)
      _ = sharedAppModel.volumeMarkers[markerIndex].appendStrokePoint(
        point,
        coordinateScale: SIMD3<Float>(
          volumeScale.columns.0.x,
          volumeScale.columns.1.y,
          volumeScale.columns.2.z
        ) * modelScale
      )
      return
    }

    let marker = VolumeMarker.stroke(
      name: sharedAppModel.nextVolumeMarkerName(for: .stroke),
      firstPoint: point,
      color: sharedAppModel.defaultVolumeStrokeColor
    )
    if storedAppModel.projectObjectsOntoVolume {
      immersiveInteraction.beginStrokeProjectionFreeze(token: marker.id)
    }
    sharedAppModel.volumeMarkers.append(marker)
    sharedAppModel.selectedVolumeMarkerID = marker.id
    activeSpatialStylusStrokeID = marker.id
    sharedAppModel.synchronizeMarkers()
  }

  private func updateSpatialAccessoryInteractions(drawable: LayerRenderer.Drawable) {
    let timestamp = LayerRenderer.Clock.Instant.epoch
      .duration(to: drawable.frameTiming.trackableAnchorTime)
      .timeInterval
    let samples = borgARProvider.getSpatialInputSamples(atTimestamp: timestamp)
    immersiveInteraction.volumeBrushContext.pruneDevicePreviews(activeIDs: Set(samples.map { $0.id.uuidString }))
    let inputContext = spatialInputContext.snapshot()
    immersiveInteraction.updateVolumeBrushSources(activeIDs: Set(samples.map { $0.id.uuidString }),
                                                  handMode: inputContext.mode)
    let placementConsumesAccessories = immersiveInteraction.handleArmedSceneObjectPlacement(
      samples: samples,
      datasetInfo: inputContext.datasetInfo
    )
    let stylusSample = placementConsumesAccessories ? nil : immersiveInteraction.spatialStylusSample(
      from: samples,
      datasetInfo: inputContext.datasetInfo,
      timestamp: timestamp
    )
    if !placementConsumesAccessories {
      immersiveInteraction.handleSpatialInputSamples(
        samples,
        datasetInfo: inputContext.datasetInfo,
        timestamp: timestamp
      )
    }
    spatialControllerSamples = samples.filter { $0.source == .controller }
    let selectedPrototype = sharedAppModel.validateSelectedSceneObjectPrototype()
    var objectPreviewInstances: [SceneMeshInstance] = []
    spatialControllerPreviewPoints = spatialControllerSamples.compactMap { sample in
      let tool = storedAppModel.controllerTool(for: sample.chirality)
      if tool == .erase || tool == .restore { return nil }
      guard storedAppModel.controllerTool(for: sample.chirality) == .objectPlacement else {
        return spatialToolPreviewPoint(
          worldPosition: sample.aimOrigin,
          radius: sharedAppModel.defaultVolumeStrokeRadius
        )
      }
      guard !sample.primaryPressed, let datasetInfo = inputContext.datasetInfo else {
        return nil
      }
      switch immersiveInteraction.sceneObjectPreview(
        prototype: selectedPrototype,
        worldTransform: sample.aimTransform,
        datasetInfo: datasetInfo,
        id: sample.id
      ) {
        case .sphere(let point):
          return point
        case .mesh(let instance):
          objectPreviewInstances.append(instance)
          return nil
        case nil:
          return nil
      }
    }
    spatialControllerModePreviewMarkers = spatialControllerSamples.flatMap { sample in
      spatialControllerToolPreviewMarkers(
        sample: sample,
        mode: storedAppModel.controllerTool(for: sample.chirality)
      )
    }
    if storedAppModel.stylusTool == .erase || storedAppModel.stylusTool == .restore {
      finishSpatialStylusStroke()
      spatialStylusPreviewPoint = nil
      spatialStylusMeasurementPreviewMarkers = samples.filter { $0.source == .stylus }.flatMap {
        spatialControllerToolPreviewMarkers(sample: $0, mode: storedAppModel.stylusTool)
      }
    } else if storedAppModel.stylusTool == .objectPlacement {
      finishSpatialStylusStroke()
      spatialStylusRadiusAdjustmentStart = nil
      spatialStylusMeasurementPreviewMarkers = []
      immersiveInteraction.handleSpatialStylusMeasurement(
        nil,
        datasetInfo: nil,
        kind: .length
      )
      spatialStylusPreviewPoint = nil
      if let sample = samples.first(where: { $0.source == .stylus }),
         !sample.primaryPressed,
         let datasetInfo = inputContext.datasetInfo {
        switch immersiveInteraction.sceneObjectPreview(
          prototype: selectedPrototype,
          worldTransform: sample.aimTransform,
          datasetInfo: datasetInfo,
          id: sample.id
        ) {
          case .sphere(let point):
            spatialStylusPreviewPoint = point
          case .mesh(let instance):
            objectPreviewInstances.append(instance)
          case nil:
            break
        }
      }
    } else if let stylusMeasurementKind = storedAppModel.stylusTool.measurementKind {
      finishSpatialStylusStroke()
      spatialStylusRadiusAdjustmentStart = nil
      immersiveInteraction.handleSpatialStylusMeasurement(
        stylusSample,
        datasetInfo: inputContext.datasetInfo,
        kind: stylusMeasurementKind
      )
      spatialStylusPreviewPoint = stylusSample.flatMap {
        spatialToolPreviewPoint(worldPosition: $0.tipPosition, radius: 0.008)
      }
      spatialStylusMeasurementPreviewMarkers = stylusSample.map {
        stylusMeasurementPreviewMarkers(
          worldPosition: spatialToolGlyphPosition(
            aimTransform: $0.aimTransform,
            distanceBehindTip: 0.05
          ),
          kind: stylusMeasurementKind,
          showsPlus: immersiveInteraction.spatialStylusWillExtendMeasurement,
          markerIDs: Self.stylusMeasurementPreviewMarkerIDs
        )
      } ?? []
    } else {
      spatialStylusMeasurementPreviewMarkers = []
      immersiveInteraction.handleSpatialStylusMeasurement(
        nil,
        datasetInfo: nil,
        kind: .length
      )
      updateSpatialStylusStroke(sample: stylusSample)
    }
    spatialSceneObjectPreviewInstances = objectPreviewInstances
    var previewPoints = spatialControllerPreviewPoints
    if let spatialStylusPreviewPoint {
      previewPoints.append(spatialStylusPreviewPoint)
    }
    synchronizeSpatialToolPreviewsIfNeeded(
      previewPoints,
      at: timestamp
    )
  }

  private func synchronizeSpatialToolPreviewsIfNeeded(
    _ points: [VolumeMarkerPoint],
    at timestamp: TimeInterval
  ) {
    let sharedPoints = storedAppModel.shareSpatialStylusPosition ? points : []
    if sharedPoints.isEmpty {
      guard spatialToolPreviewsWereShared else { return }
    } else {
      guard timestamp - lastSpatialToolPreviewShareTime >= 0.05 else { return }
    }
    lastSpatialToolPreviewShareTime = timestamp
    spatialToolPreviewsWereShared = !sharedPoints.isEmpty
    sharedAppModel.synchronizeSpatialToolPreviews(
      points: sharedPoints,
      color: sharedAppModel.defaultVolumeStrokeColor
    )
  }

  private func rgbToHSV(_ color: SIMD4<Float>) -> (
    hue: Float,
    saturation: Float,
    value: Float
  ) {
    let maximum = max(color.x, color.y, color.z)
    let minimum = min(color.x, color.y, color.z)
    let delta = maximum - minimum
    let saturation = maximum > 0 ? delta / maximum : 0
    guard delta > 0.000_001 else {
      return (0, saturation, maximum)
    }

    let hue: Float
    if maximum == color.x {
      hue = (color.y - color.z) / delta / 6
    } else if maximum == color.y {
      hue = ((color.z - color.x) / delta + 2) / 6
    } else {
      hue = ((color.x - color.y) / delta + 4) / 6
    }
    return (hue - floor(hue), saturation, maximum)
  }

  private func hsvToRGB(
    hue: Float,
    saturation: Float,
    value: Float
  ) -> SIMD4<Float> {
    let wrappedHue = hue - floor(hue)
    let sector = wrappedHue * 6
    let index = Int(floor(sector)) % 6
    let fraction = sector - floor(sector)
    let p = value * (1 - saturation)
    let q = value * (1 - saturation * fraction)
    let t = value * (1 - saturation * (1 - fraction))
    let rgb: SIMD3<Float>
    switch index {
      case 0: rgb = SIMD3<Float>(value, t, p)
      case 1: rgb = SIMD3<Float>(q, value, p)
      case 2: rgb = SIMD3<Float>(p, value, t)
      case 3: rgb = SIMD3<Float>(p, q, value)
      case 4: rgb = SIMD3<Float>(t, p, value)
      default: rgb = SIMD3<Float>(value, p, q)
    }
    return SIMD4<Float>(rgb, 1)
  }

  /**
   Renders a single frame. This function manages frame lifecycle, timing, command buffer setup,
   resource binding, and final drawing and presentation.
   */
  func renderFrame() -> Bool {
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }
    guard let frame = layerRenderer.queryNextFrame() else { return true }
    guard let timing = frame.predictTiming() else { return true }

    frame.startUpdate()
    updateDynamicBufferState()
    frameSnapshot = session.frameSnapshot()
    frameState = frameSnapshot.visualization
    do {
      let metadata = borgData.getMetadata()
      try renderTransferFunctions.synchronize(
        with: frameSnapshot.transferFunctions,
        minValue: metadata.minValue,
        maxValue: metadata.maxValue,
        rangeMax: metadata.rangeMax
      )
    } catch {
      logger?.error("Failed to update render transfer functions: \(error.localizedDescription)")
    }
    frame.endUpdate()

    LayerRenderer.Clock().wait(until: timing.optimalInputTime)

    // Closing an immersive space can happen while waiting for the predicted
    // input time. Do not submit that now-obsolete frame to the GPU.
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }

    var submissionEnded = false
    frame.startSubmission()
    defer {
      if !submissionEnded {
        frame.endSubmission()
      }
    }

    guard let drawable = frame.queryDrawables().first else { return true }
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }

    let desc = MTLCommandBufferDescriptor()
    desc.errorOptions = .encoderExecutionStatus
    guard let commandBuffer = commandQueue.makeCommandBuffer(descriptor: desc) else {
      logger?.error("Failed to create render command buffer.")
      return false
    }
    commandBuffer.label = "BorgVR Command Buffer"

    self.updateRenderState(drawable: drawable)
    self.updateSpatialAccessoryInteractions(drawable: drawable)
    volumeAtlas.prepareFrame(commandBuffer: commandBuffer)

    let rasterizationRateMap = drawable.rasterizationRateMaps.first
    let opaqueGeometryTargets = renderOpaqueGeometry(
      commandBuffer: commandBuffer,
      drawable: drawable,
      rasterizationRateMap: rasterizationRateMap
    )

    let renderPassDescriptor = MTLRenderPassDescriptor()
    let interactionDepthTexture = interactionDepthTexture(drawable: drawable)

    if rasterSampleCount > 1 {
      let renderTargets = memorylessRenderTargets(
        drawable: drawable,
        interactionDepthResolveTexture: interactionDepthTexture
      )
      renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
      renderPassDescriptor.colorAttachments[0].texture = renderTargets.color
      renderPassDescriptor.colorAttachments[1].resolveTexture = interactionDepthTexture
      renderPassDescriptor.colorAttachments[1].texture = renderTargets.interactionDepth
      renderPassDescriptor.depthAttachment.resolveTexture = drawable.depthTextures[0]
      renderPassDescriptor.depthAttachment.texture = renderTargets.depth
      renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
      renderPassDescriptor.colorAttachments[1].storeAction = .multisampleResolve
      renderPassDescriptor.depthAttachment.storeAction = .multisampleResolve
    } else {
      renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
      renderPassDescriptor.colorAttachments[1].texture = interactionDepthTexture
      renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
      renderPassDescriptor.colorAttachments[0].storeAction = .store
      renderPassDescriptor.colorAttachments[1].storeAction = .store
      renderPassDescriptor.depthAttachment.storeAction = .store
    }

    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    renderPassDescriptor.colorAttachments[1].loadAction = .clear
    renderPassDescriptor.colorAttachments[1].clearColor = MTLClearColorMake(-1, 0, 0, 0)
    renderPassDescriptor.depthAttachment.loadAction = .clear
    renderPassDescriptor.depthAttachment.clearDepth = 0.0
    renderPassDescriptor.rasterizationRateMap = rasterizationRateMap
    if layerRenderer.configuration.layout == .layered {
      renderPassDescriptor.renderTargetArrayLength = drawable.views.count
    }

    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      logger?.error("Failed to create render command encoder.")
      return false
    }

    renderEncoder.label = "BorgVR Render Encoder"
    renderEncoder.setCullMode(.front)
    renderEncoder.setFrontFacing(.counterClockwise)

    if frameState.brickVisualization {
      renderEncoder.setRenderPipelineState(pipelineStateBrickVis)
    } else {
      switch frameState.renderMode {
        case .isoValue:
          renderEncoder.setRenderPipelineState(pipelineStateIso)
        case .transferFunction1D:
          renderEncoder.setRenderPipelineState(pipelineStateTF)
        case .transferFunction1DLighting:
          renderEncoder.setRenderPipelineState(pipelineStateTFL)
      }
    }

    renderEncoder.setDepthStencilState(depthState)

    uniformBufferVertex.bindVertex(to: renderEncoder, index: VertexBufferIndex.uniforms.rawValue)
    uniformBufferFragment.bindFragment(to: renderEncoder, index: FragmentBufferIndex.uniforms.rawValue)
    bindRasterizationRateMap(rasterizationRateMap, to: renderEncoder)

    let viewports = drawable.views.map { $0.textureMap.viewport }
    renderEncoder.setViewports(viewports)

    if drawable.views.count > 1 {
      var viewMappings = (0..<drawable.views.count).map {
        MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                          renderTargetArrayIndexOffset: UInt32($0))
      }
      renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
    }

    renderEncoder.setVertexBuffer(cubeBuffer, offset: 0, index: VertexBufferIndex.meshPositions.rawValue)

    do {
      try renderTransferFunctions.bind(to: renderEncoder)
    } catch {
      logger?.error("Failed to bind transfer function texture: \(error)")
    }

    volumeAtlas.bind(to: renderEncoder,
                     atlasIndex: TextureIndex.volumeAtlas.rawValue,
                     metaIndex: FragmentBufferIndex.brickMeta.rawValue,
                     levelIndex: FragmentBufferIndex.levelTable.rawValue)

    hashTable.bind(to: renderEncoder, index: FragmentBufferIndex.hashTable.rawValue)
    renderEncoder.setFragmentTexture(
      opaqueGeometryTargets.depth,
      index: TextureIndex.markerDepth.rawValue
    )

    if volumeAtlas.isContentReady {
      renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.vertexCount)
    }

    renderEncoder.popDebugGroup()

    compositeOpaqueGeometry(
      renderEncoder,
      colorTexture: opaqueGeometryTargets.color,
      depthTexture: opaqueGeometryTargets.depth
    )
    drawMeasurementLabelsOnScreen(
      opaqueGeometryTargets.measurementLabels,
      renderEncoder: renderEncoder,
      drawable: drawable
    )

    if frameSnapshot.settings.transferFunctionDisplayMode !=
      TransferFunctionDisplayMode.windowOnly.rawValue {
      renderTransferfunction(renderEncoder, drawable: drawable)
    } else {
      transferFunctionPanelInteractionState.updatePanel(
        matrix: matrix_identity_float4x4,
        size: .zero,
        isVisible: false
      )
      transferFunctionPanelInteractionState.setFocused(false)
    }

    renderEncoder.endEncoding()

    // The immersive space can be suspended while this frame is being encoded.
    // Dropping an uncommitted command buffer is safe; submitting it after GPU
    // access has been revoked terminates the process on visionOS.
    guard !Task.isCancelled, layerRenderer.state == .running else { return true }

    let mcpScreenshotRequest = runtimeAppModel.mcpRenderBridge.takeScreenshotRequest()
    var mcpScreenshotReadback: MetalScreenshotReadback?
    var mcpScreenshotError: Error?
    if mcpScreenshotRequest != nil {
      do {
        mcpScreenshotReadback = try MetalScreenshotEncoder.encodeReadback(
          from: drawable.colorTextures[0],
          slice: 0,
          commandBuffer: commandBuffer
        )
      } catch {
        mcpScreenshotError = error
      }
    }

    drawable.encodePresent(commandBuffer: commandBuffer)

    commandBuffer.commit()
    frame.endSubmission()
    submissionEnded = true
    commandBuffer.waitUntilCompleted()

    if let error = commandBuffer.error as NSError? {
      mcpScreenshotRequest?.completion(.failure(error))
      let submissionWasNotPermitted = error.domain == MTLCommandBufferErrorDomain &&
        error.code == MTLCommandBufferError.notPermitted.rawValue
      if submissionWasNotPermitted || Task.isCancelled || layerRenderer.state != .running {
        logger?.info("Render submission stopped because the immersive scene was suspended.")
        immersiveInteraction.updateVolumeInteractionDepthSnapshot(nil)
        return true
      }
      logger?.error("Render command failed: \(error.localizedDescription)")
      if let info = error.userInfo[MTLCommandBufferEncoderInfoErrorKey] {
        logger?.error("Encoder info: \(String(describing: info))")
      }
      return false
    }

    timer.recordCompletedFrame(commandBuffer)

    let completedFrame = runtimeAppModel.mcpRenderBridge.recordFrame()
    if let request = mcpScreenshotRequest, let error = mcpScreenshotError {
      request.completion(.failure(error))
    } else if let request = mcpScreenshotRequest, let readback = mcpScreenshotReadback {
      do {
        request.completion(.success(BorgVRMCPImage(
          pngData: try MetalScreenshotEncoder.pngData(from: readback),
          width: readback.width,
          height: readback.height,
          renderedFrame: completedFrame
        )))
      } catch {
        request.completion(.failure(error))
      }
    }

    immersiveInteraction.updateVolumeInteractionDepthSnapshot(
      VolumeInteractionDepthSnapshot(
        texture: interactionDepthTexture,
        textureToClip: currentTextureToClipMatrices,
        worldToClip: currentWorldToClipMatrices,
        worldFromVolume: lastModelMatrix,
        headPosition: lastHeadPosition,
        rasterizationRateMap: rasterizationRateMap
      )
    )

    readBackHashTable(commandBuffer: commandBuffer)
    updatePerformanceCounters()

    return true
  }

  // MARK: Actual Loop

  /**
   The main render loop. Handles immersive space state transitions and repeatedly calls `renderFrame()`.
   */
  func renderLoop() async {
    while !Task.isCancelled {
      if layerRenderer.state == .invalidated {
        Task { @MainActor in
          runtimeAppModel.immersiveSpaceWasClosedBySystem()
        }
        return
      } else if layerRenderer.state == .paused {
        guard !Task.isCancelled else { return }
        Task { @MainActor in
          runtimeAppModel.immersiveSpaceState = .inTransition
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        continue
      } else {
        Task { @MainActor in
          if runtimeAppModel.immersiveSpaceState != .open {
            runtimeAppModel.markImmersiveSpaceOpened()
          }
        }
        var frameSucceeded = true
        autoreleasepool {
          frameSucceeded = self.renderFrame()
        }
        if !frameSucceeded {
          Task { @MainActor in
            runtimeAppModel.renderLoopFailed()
          }
          return
        }
      }
    }
  }
}



// MARK: - Render-loop startup

// MARK: - LayerRenderer.Clock.Instant.Duration Extension

/**
 An extension on `LayerRenderer.Clock.Instant.Duration` that provides a computed
 property to convert the duration into a `TimeInterval`.

 The conversion accounts for the attoseconds and seconds components of the
 duration.
 */
extension LayerRenderer.Clock.Instant.Duration {
  var timeInterval: TimeInterval {
    let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
    return TimeInterval(components.seconds) + (nanoseconds /
                                               TimeInterval(NSEC_PER_SEC))
  }
}

// MARK: - VisionVolumeRendererTaskExecutor

/**
 A task executor for rendering tasks that executes jobs on a dedicated serial
 dispatch queue.

 This executor conforms to the `TaskExecutor` protocol and is used to run
 rendering jobs on a high-priority, user-interactive queue.
 */
final class VisionVolumeRendererTaskExecutor: TaskExecutor {
  /// A serial dispatch queue dedicated to rendering tasks.
  private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

  /**
   Enqueues a job for execution on the render thread.

   - Parameter job: The unowned job to be executed.
   */
  func enqueue(_ job: UnownedJob) {
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  /**
   Converts the current executor into an unowned serial task executor.

   - Returns: An `UnownedTaskExecutor` that wraps this executor.
   */
  func asUnownedSerialExecutor() -> UnownedTaskExecutor {
    return UnownedTaskExecutor(ordinary: self)
  }

  /// A shared singleton instance of `VisionVolumeRendererTaskExecutor`.
  static var shared: VisionVolumeRendererTaskExecutor = VisionVolumeRendererTaskExecutor()
}

// MARK: - VisionVolumeRenderer Extension for AR Session and Render Loop

/**
 An extension on `VisionVolumeRenderer` that provides methods for starting the AR session and
 the render loop.
 */
extension VisionVolumeRenderer {
  /**
   Starts the render loop for the renderer.

   This method creates a rendering task using the shared
   `VisionVolumeRendererTaskExecutor`. It performs the following:
   - Instantiates a `VisionVolumeRenderer` with the provided parameters.
   - Initializes performance tracking.
   - Starts the AR session.
   - Begins the render loop.

   - Parameters:
   - layerRenderer: The layer renderer instance used for rendering.
   - runtimeAppModel: The shared application model.
   - appSetings: The application settings.
   - sharedAppModel: The parameters used for rendering.
   - timer: A GPU frame timer with a completion-time fallback.
   - dataset: The dataset to be rendered.
   */
  @MainActor
  static func startRenderLoop(_ layerRenderer: LayerRenderer,
                              session: VisionBorgVRSession,
                              timer: GPUFrameTimer,
                              dataset: BORGVRDatasetProtocol,
                              datasetID: String,
                              transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState,
                              immersiveInteraction: ImmersiveInteraction,
                              logger: LoggerBase? = nil) {
    let runtimeAppModel = session.runtimeState
    runtimeAppModel.renderTask?.cancel()
    runtimeAppModel.renderTask = Task(executorPreference: VisionVolumeRendererTaskExecutor.shared) {
      do {
        let renderer = try VisionVolumeRenderer(
          layerRenderer,
          session: session,
          timer: timer,
          dataset: dataset,
          transferFunctionPanelInteractionState: transferFunctionPanelInteractionState,
          immersiveInteraction: immersiveInteraction,
          logger: logger
        )

        await renderer.initRenderLoop()
        guard !Task.isCancelled else { return }
        await runtimeAppModel.markDatasetRendererReady(uniqueID: datasetID)
        await renderer.renderLoop()
      } catch {
        logger?.error("Failed to start render loop: \(error)")
      }
    }
  }
}


/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
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
