import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import Observation
import RealityKit

extension Renderer {

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
  (MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState) {
    // Build a render state pipeline object.
    guard let shaderPath = Bundle.main.path(forResource: "Shaders", ofType: "metal") else {
      fatalError("Failed to find Shaders.metal file")
    }
    let shaderSource = try String(contentsOfFile: shaderPath, encoding: .utf8)

    let screenSpaceError = StoredAppModel.float("screenSpaceError")
    let atlasSizeMB = StoredAppModel.int("atlasSizeMB")
    let maxProbingAttempts = StoredAppModel.int("maxProbingAttempts")
    let requestLowResLOD = StoredAppModel.bool("requestLowResLOD") ? 1 : 0
    let stopOnMiss = StoredAppModel.bool("stopOnMiss") ? 1 : 0

    let width : Float = 1888.0

    let lodFactor = 2.0 * tan(1.663 / 2.0) * screenSpaceError / width
    let levelZeroWorldSpaceError = max(
      borgVRMetaData.aspectX / Float(borgVRMetaData.width),
      borgVRMetaData.aspectY / Float(borgVRMetaData.height),
      borgVRMetaData.aspectZ / Float(borgVRMetaData.depth)
    )

    let (atlasWidth, atlasHeight, atlasDepth, _) = VolumeAtlas.computeAtlasSize(
      maxMemory: atlasSizeMB * 1024 * 1024,
      maxBrickCount: borgVRMetaData.brickMetadata.count,
      brickSize: borgVRMetaData.brickSize,
      bytesPerComponent: borgVRMetaData.bytesPerComponent,
      componentCount: borgVRMetaData.componentCount
    )

    func maxCellsIntersected(in grid: Vec3<Int>) -> Int {
      return grid.x-1 + grid.y-1 + grid.z-1 + 1
    }

    let overlapStepX = Float(borgVRMetaData.overlap) / Float(atlasWidth)
    let overlapStepY = Float(borgVRMetaData.overlap) / Float(atlasHeight)
    let overlapStepZ = Float(borgVRMetaData.overlap) / Float(atlasDepth)
    let maxIterations = maxCellsIntersected(
      in: borgVRMetaData.levelMetadata[0].totalBricks
    )

    let compileOptions = MTLCompileOptions()
    compileOptions.preprocessorMacros = [
      "OVERRIDE_DUMMY" : NSNumber(value: 1),
      "LEVEL_COUNT": NSNumber(value: borgVRMetaData.levelMetadata.count),
      "BRICK_SIZE": NSNumber(value: borgVRMetaData.brickSize),
      "BRICK_INNER_SIZE": NSNumber(value: borgVRMetaData.brickSize - borgVRMetaData.overlap * 2),
      "OVERLAP_STEP": NSString(string: "float3(\(overlapStepX),\(overlapStepY),\(overlapStepZ))"),
      "LEVEL_ZERO_WORLD_SPACE_ERROR" : NSNumber(value: levelZeroWorldSpaceError),
      "LOD_FACTOR" : NSNumber(value: lodFactor),
      "POOL_SIZE" : NSString(string: "float3(\(atlasWidth),\(atlasHeight),\(atlasDepth))"),
      "VOLUME_SIZE" : NSString(string: "float3(\(borgVRMetaData.width),\(borgVRMetaData.height),\(borgVRMetaData.depth))"),
      "POOL_CAPACITY" : NSString(string: "uint3(\(atlasWidth / borgVRMetaData.brickSize),\(atlasHeight / borgVRMetaData.brickSize),\(atlasDepth / borgVRMetaData.brickSize))"),
      "HASHTABLE_SIZE" : NSNumber(value: hasTable.size),
      "MAX_PROBING_ATTEMPTS" : NSNumber(value: maxProbingAttempts),
      "MAX_ITERATIONS" : NSNumber(value: maxIterations),
      "REQUEST_LOWRES_LOD": NSNumber(value: requestLowResLOD),
      "STOP_ON_MISS": NSNumber(value: stopOnMiss)
    ]
    compileOptions.mathMode = .fast

    let library = try device.makeLibrary(source: shaderSource, options: compileOptions)
    let vertexFunction = library.makeFunction(name: "vertexShader")

    let pipelineDescriptorTF = MTLRenderPipelineDescriptor()
    pipelineDescriptorTF.label = "Render Pipeline for 1D TF"
    pipelineDescriptorTF.vertexFunction = vertexFunction
    pipelineDescriptorTF.fragmentFunction = library.makeFunction(name: "fragmentShaderTF")
    pipelineDescriptorTF.rasterSampleCount = rasterSampleCount
    pipelineDescriptorTF.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorTF.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorTF.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorTFL = MTLRenderPipelineDescriptor()
    pipelineDescriptorTFL.label = "Render Pipeline for 1D TF with Lighting"
    pipelineDescriptorTFL.vertexFunction = vertexFunction
    pipelineDescriptorTFL.fragmentFunction = library.makeFunction(name: "fragmentShaderTFLighting")
    pipelineDescriptorTFL.rasterSampleCount = rasterSampleCount
    pipelineDescriptorTFL.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorTFL.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorTFL.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorIso = MTLRenderPipelineDescriptor()
    pipelineDescriptorIso.label = "Render Pipeline for Lit Isosurfaces"
    pipelineDescriptorIso.vertexFunction = vertexFunction
    pipelineDescriptorIso.fragmentFunction = library.makeFunction(name: "fragmentShaderIso")
    pipelineDescriptorIso.rasterSampleCount = rasterSampleCount
    pipelineDescriptorIso.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorIso.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorIso.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    let pipelineDescriptorBrickVis = MTLRenderPipelineDescriptor()
    pipelineDescriptorBrickVis.label = "Render Pipeline visualizing the brick structure"
    pipelineDescriptorBrickVis.vertexFunction = vertexFunction
    pipelineDescriptorBrickVis.fragmentFunction = library.makeFunction(name: "fragmentShaderBrickVis")
    pipelineDescriptorBrickVis.rasterSampleCount = rasterSampleCount
    pipelineDescriptorBrickVis.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
    pipelineDescriptorBrickVis.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
    pipelineDescriptorBrickVis.maxVertexAmplificationCount = layerRenderer.properties.viewCount

    return (try device.makeRenderPipelineState(descriptor: pipelineDescriptorTF),
            try device.makeRenderPipelineState(descriptor: pipelineDescriptorTFL),
            try device.makeRenderPipelineState(descriptor: pipelineDescriptorIso),
            try device.makeRenderPipelineState(descriptor: pipelineDescriptorBrickVis))
  }

  func initRenderLoop() async {
    initPerformanceTracking()
    await borgARProvider.startARSession()
  }

  /**
   Initializes performance tracking for dynamic oversampling.

   This method sets up the CPU frame timer's thresholds and callback closures so that the renderer
   can dynamically adjust the oversampling factor based on current performance (FPS).
   */
  func initPerformanceTracking() {
    guard self.dynamicOverSampling else { return }

    timer.dropThreshold = Double(self.dropFPS)
    timer.recoveryThreshold = Double(self.recoveryFPS)
    timer.minimumDropDuration = 0.5

    timer.onPerformanceTooSlow = { [weak self] fps, percentMissed in
      guard let self = self else { return }
      if self.activeOversampling < 0.5 {
        return
      }
      self.activeOversampling -= 0.1
    }

    timer.onPerformanceRecovered = { [weak self] fps, percentAbove in
      guard let self = self else { return false }
      if self.activeOversampling >= self.initialOversampling {
        activeOversampling = initialOversampling
        return false
      }
      self.activeOversampling += 0.1
      return true
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
 FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
