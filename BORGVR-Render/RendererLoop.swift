import CompositorServices
import Metal
import MetalKit
import simd
import Spatial
import Observation
import RealityKit

extension Renderer {

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
    let f = (fLen > 1e-5) ? (forward / fLen) : SIMD3<Float>(0, 0, 1)

    let r = simd_normalize(simd_cross(up, f))
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
    if sharedAppModel.purgeAtlas {
      volumeAtlas.purge()
      sharedAppModel.purgeAtlas = false
    }

    let anchors = borgARProvider.getAnchors(for: drawable)
    let originFromDevice = anchors.originFromDevice ?? matrix_identity_float4x4
    let originFromWorldAnchor = anchors.originFromWorldAnchor ?? matrix_identity_float4x4

    self.lastOriginFromDevice = originFromDevice

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

      self.lastOriginFromDevice = originFromDevice
      self.lastModelMatrix = modelMatrix
      self.lastClipMatrix = clipMatrix

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

  

  private func renderTransferfunction(_ renderEncoder: MTLRenderCommandEncoder,
                                      drawable: LayerRenderer.Drawable) {
    renderEncoder.pushDebugGroup("Transfer Function Panel (3D)")

    renderEncoder.setRenderPipelineState(pipelineStateTFHUD)   // keep your name or rename
    renderEncoder.setCullMode(.none)
    renderEncoder.setDepthStencilState(depthStateHUD)
    do {
      try sharedAppModel.transferFunction.bind(to: renderEncoder, index: 0)
    } catch {
      logger?.error("Failed to bind TF texture for panel: \(error)")
    }

    let viewCount = drawable.views.count
    var mvp = [simd_float4x4](repeating: matrix_identity_float4x4, count: viewCount)

    var panelSize : SIMD2<Float>
    if storedAppModel.tfMode == TransferFunctionDisplayMode.HUD.rawValue {
      for i in 0..<viewCount {
        let view = drawable.views[i]
        let viewMatrix = (lastOriginFromDevice * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: i)
        mvp[i] = projection * viewMatrix * tfPanelWorldMatrix
      }
      panelSize = tfPanelSizeMeters
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
      let margin: Float = 0.02
      let bottomCenter = volCenter - worldUp * (0.5 * volHeight)
      let panelPos = bottomCenter - worldUp * (margin + 0.5 * panelHeight)

      // Billboard: face viewer; use cylindrical=true for yaw-only (stays upright)
      let (billboard, forward) = makeBillboardMatrix(position: panelPos,
                                                     camera: lastHeadPosition,
                                                     up: worldUp,
                                                     cylindrical: true)

      // Optional: push slightly toward the camera to avoid depth fighting with the volume
      let pushTowardCamera: Float = 0.005
      var panelWorld = billboard
      panelWorld.columns.3.x += forward.x * pushTowardCamera
      panelWorld.columns.3.y += forward.y * pushTowardCamera
      panelWorld.columns.3.z += forward.z * pushTowardCamera

      for i in 0..<viewCount {
        let view = drawable.views[i]
        let viewMatrix = (lastOriginFromDevice * view.transform).inverse
        let projection = drawable.computeProjection(viewIndex: i)
        mvp[i] = projection * viewMatrix * panelWorld
      }
    }

    // buffer(20): mvp array
    mvp.withUnsafeBytes { bytes in
      renderEncoder.setVertexBytes(bytes.baseAddress!,
                                   length: bytes.count,
                                   index: 20)
    }

    renderEncoder.setVertexBytes(&panelSize,
                                 length: MemoryLayout<SIMD2<Float>>.stride,
                                 index: 21)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    renderEncoder.popDebugGroup()
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

    let desc = MTLCommandBufferDescriptor()
    desc.errorOptions = .encoderExecutionStatus
    guard let commandBuffer = commandQueue.makeCommandBuffer(descriptor: desc) else {
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

    renderEncoder.label = "BorgVR Render Encoder"
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

    if storedAppModel.tfMode != TransferFunctionDisplayMode.windowOnly.rawValue {
      renderTransferfunction(renderEncoder, drawable: drawable)
    }

    renderEncoder.endEncoding()

    drawable.encodePresent(commandBuffer: commandBuffer)

    commandBuffer.addCompletedHandler { cb in
      if let err = cb.error as NSError? {
        self.logger?.error("Render Error: \(String(describing: err))")
        if let info = err.userInfo[MTLCommandBufferEncoderInfoErrorKey] {
          self.logger?.error("Encoder info: \(String(describing: info))")
        }
      }
    }

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

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
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
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


