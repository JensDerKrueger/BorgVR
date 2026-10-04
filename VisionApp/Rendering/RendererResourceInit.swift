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
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

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
