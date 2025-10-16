import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import Observation
import RealityKit

extension Renderer {

  // MARK: Pre-Frame Setup

  /**
   Updates the render state with view-projection uniforms and clip parameters per view.

   - Parameters:
   - drawable: The drawable from the current frame.
   - deviceAnchor: The device anchor containing the transform of the Vision Pro.
   */
  private func updateRenderState(drawable: LayerRenderer.Drawable) {
    if sharedAppModel.purgeAtlas {
      volumeAtlas.purge()
      sharedAppModel.purgeAtlas = false
    }

    let anchors = borgARProvider.getAnchors(for: drawable)
    let originFromDevice = anchors.originFromDevice ?? matrix_identity_float4x4
    let originFromWorldAnchor = anchors.originFromWorldAnchor ?? matrix_identity_float4x4

    sharedAppModel.originFromWorldAnchorMatrix = originFromWorldAnchor

    let modelMatrix : simd_float4x4
    if autoRotationAngle > 0 {
      let autoRotationMatrix = rotationYMatrix(degrees: autoRotationAngle)

      let rot = sharedAppModel.modelTransform.rotation
      let trans = sharedAppModel.modelTransform.translation
      let scale = sharedAppModel.modelTransform.scale

      let model = Transform(
        scale: scale,
        rotation: simd_quatf(autoRotationMatrix)*rot,
        translation: trans
      ).matrix

      modelMatrix = originFromWorldAnchor * model * volumeScale
    } else {
      modelMatrix = originFromWorldAnchor * sharedAppModel.modelTransform.matrix * volumeScale
    }

    func uniforms(forViewIndex viewIndex: Int) -> (VertexUniforms, FragmentUniforms) {
      let view = drawable.views[viewIndex]
      let viewMatrix = (originFromDevice * view.transform).inverse
      let projection = drawable.computeProjection(viewIndex: viewIndex)

      let viewToTexture = Transform(translation: SIMD3<Float>(0.5, 0.5, 0.5)).matrix * simd_inverse(viewMatrix * modelMatrix)
      let viewToTextureVoxelScaled = Transform(translation: SIMD3<Float>(0.5, 0.5, 0.5)).matrix * simd_inverse(viewMatrix * originFromWorldAnchor * sharedAppModel.modelTransform.matrix)

      let metadata = borgData.getMetadata()
      let borderSize = Float(metadata.overlap + 1) / SIMD3<Float>(Float(metadata.width), Float(metadata.height), Float(metadata.depth))
      let clipMin = sharedAppModel.clipMin + borderSize
      let clipMax = sharedAppModel.clipMax - borderSize

      let clipScale = (clipMax - clipMin)
      let clipMatrix = Transform(
        scale: clipScale,
        translation: 0.5 * (clipMax + clipMin - 1)
      ).matrix

      return (
        VertexUniforms(modelViewProjectionMatrix: projection * viewMatrix * modelMatrix * clipMatrix,
                       clipMatrix: clipMatrix),
        FragmentUniforms(
          isoValue: sharedAppModel.isoValue,
          oversampling: activeOversampling,
          transferBias: sharedAppModel.transferFunction.textureBias,
          cameraPosInTextureSpace: simd_make_float3(viewToTexture * simd_float4(0, 0, 0, 1)),
          cameraPosInTextureSpaceVoxelScaled: simd_make_float3(viewToTextureVoxelScaled * simd_float4(0, 0, 0, 1)),
          cubeBounds: (clipMin, clipMax),
          modelView: viewMatrix * modelMatrix,
          modelViewIT: simd_transpose(simd_inverse(viewMatrix * modelMatrix))
        )
      )
    }

    (uniformBufferVertex.current.uniforms.0, uniformBufferFragment.current.uniforms.0) = uniforms(forViewIndex: 0)
    if drawable.views.count > 1 {
      (uniformBufferVertex.current.uniforms.1, uniformBufferFragment.current.uniforms.1) = uniforms(forViewIndex: 1)
    }

    switch sharedAppModel.renderMode {
      case .transferFunction1D, .transferFunction1DLighting:
        volumeAtlas.updateEmptiness(transferFunction: sharedAppModel.transferFunction)
      case .isoValue:
        volumeAtlas.updateEmptiness(isoValue: sharedAppModel.isoValue)
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
  private func memorylessRenderTargets(drawable: LayerRenderer.Drawable) -> (color: MTLTexture, depth: MTLTexture) {

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
    let newTargets = (renderTarget(resolveTexture: drawable.colorTextures[0], cachedTexture: cachedTargets?.color),
                      renderTarget(resolveTexture: drawable.depthTextures[0], cachedTexture: cachedTargets?.depth))

    memorylessTargets[currentRenderTargetIndex] = newTargets

    return newTargets
  }

  /**
   Reads back the GPU hash table and pages in missing bricks.

   - Parameter commandBuffer: The command buffer from the current frame.
   */
  func readBackHashTable(commandBuffer: MTLCommandBuffer) {
    let missingBricks = hashTable.getValues(from: commandBuffer)

    if !missingBricks.isEmpty {
      let intArray = missingBricks.map { Int($0) }.sorted(by: >)
      let metadata = borgData.getMetadata()

      for entry in intArray {
        for level in (1..<metadata.levelMetadata.count).reversed() {
          if entry > metadata.levelMetadata[level].prevBricks {
            break
          }
        }
      }

      try? volumeAtlas.pageIn(IDs: intArray)
    }
  }


  /**
   Updates performance counters and appends results to the performance model history.
   */
  func updatePerformanceCounters() {
    timer.frameRendered()

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

    DispatchQueue.main.async {
      self.runtimeAppModel.performanceModel.history.recoveryThreshold = Double(self.recoveryFPS)
      self.runtimeAppModel.performanceModel.history.dropThreshold = Double(self.dropFPS)
      self.runtimeAppModel.performanceModel.history.add(last: last,
                                                 avg: avg,
                                                 smoothed: smoothed)

      if self.runtimeAppModel.startRotationCapture {
        self.logger?.info("Start Rotation")
        self.autoRotationAngle = 1
        self.runtimeAppModel.startRotationCapture = false
      }

      if self.runtimeAppModel.logPerformance {
        struct State {
          static var lastTime = CACurrentMediaTime()
        }

        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - State.lastTime

        if elapsed >= 2.0 {
          self.logger?
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
  
  /**
   Renders a single frame. This function manages frame lifecycle, timing, command buffer setup,
   resource binding, and final drawing and presentation.
   */
  func renderFrame() {
    guard let frame = layerRenderer.queryNextFrame() else { return }

    frame.startUpdate()
    frame.endUpdate()

    guard let timing = frame.predictTiming() else { return }
    LayerRenderer.Clock().wait(until: timing.optimalInputTime)

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      fatalError("Failed to create command buffer")
    }
    commandBuffer.label = "BorgVR Command Buffer"

    guard let drawable = frame.queryDrawables().first else { return }

    frame.startSubmission()
    self.updateDynamicBufferState()

    self.updateRenderState(drawable: drawable)

    let renderPassDescriptor = MTLRenderPassDescriptor()

    if rasterSampleCount > 1 {
      let renderTargets = memorylessRenderTargets(drawable: drawable)
      renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
      renderPassDescriptor.colorAttachments[0].texture = renderTargets.color
      renderPassDescriptor.depthAttachment.resolveTexture = drawable.depthTextures[0]
      renderPassDescriptor.depthAttachment.texture = renderTargets.depth
      renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
      renderPassDescriptor.depthAttachment.storeAction = .multisampleResolve
    } else {
      renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
      renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]
      renderPassDescriptor.colorAttachments[0].storeAction = .store
      renderPassDescriptor.depthAttachment.storeAction = .store
    }

    renderPassDescriptor.colorAttachments[0].loadAction = .clear
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
    renderPassDescriptor.depthAttachment.loadAction = .clear
    renderPassDescriptor.depthAttachment.clearDepth = 0.0
    renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
    if layerRenderer.configuration.layout == .layered {
      renderPassDescriptor.renderTargetArrayLength = drawable.views.count
    }

    guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
      fatalError("Failed to create render encoder")
    }

    renderEncoder.label = "Primary Render Encoder"
    renderEncoder.pushDebugGroup("Draw Box")
    renderEncoder.setCullMode(.front)
    renderEncoder.setFrontFacing(.counterClockwise)

    if sharedAppModel.brickVis {
      renderEncoder.setRenderPipelineState(pipelineStateBrickVis)
    } else {
      switch sharedAppModel.renderMode {
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
      try sharedAppModel.transferFunction.bind(to: renderEncoder, index: TextureIndex.transferFunction.rawValue)
    } catch {
      logger?.error("Failed to bind transfer function texture: \(error)")
    }

    volumeAtlas.bind(to: renderEncoder,
                     atlasIndex: TextureIndex.volumeAtlas.rawValue,
                     metaIndex: FragmentBufferIndex.brickMeta.rawValue,
                     levelIndex: FragmentBufferIndex.levelTable.rawValue)

    hashTable.bind(to: renderEncoder, index: FragmentBufferIndex.hashTable.rawValue)

    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.vertexCount)

    renderEncoder.popDebugGroup()
    renderEncoder.endEncoding()

    drawable.encodePresent(commandBuffer: commandBuffer)
    commandBuffer.commit()
    readBackHashTable(commandBuffer: commandBuffer)
    updatePerformanceCounters()
    frame.endSubmission()
  }

  // MARK: Actual Loop

  /**
   The main render loop. Handles immersive space state transitions and repeatedly calls `renderFrame()`.
   */
  func renderLoop() {
    while true {
      if layerRenderer.state == .invalidated {
        Task { @MainActor in
          runtimeAppModel.immersiveSpaceState = .closed
        }
        return
      } else if layerRenderer.state == .paused {
        Task { @MainActor in
          runtimeAppModel.immersiveSpaceState = .inTransition
        }
        layerRenderer.waitUntilRunning()
        continue
      } else {
        Task { @MainActor in
          if runtimeAppModel.immersiveSpaceState != .open {
            runtimeAppModel.immersiveSpaceState = .open
          }
        }
        autoreleasepool {
          self.renderFrame()
        }
      }
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use, copy,
 modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
 to permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

