import Foundation
import simd

final class TransferFunctionPanelInteractionState {
  private struct State {
    var panelWorldMatrix = matrix_identity_float4x4
    var panelSize = SIMD2<Float>(repeating: 0)
    var bottomDepthOffset: Float = 0.1
    var isVisible = false
    var isFocused = false
    var hitUV: SIMD2<Float>?
    var hitOpacity: Float = 1
    var channelMask: UInt32 = 0
  }

  private let lock = NSLock()
  private var state = State()

  func updatePanel(
    matrix: simd_float4x4,
    size: SIMD2<Float>,
    bottomDepthOffset: Float = 0.1,
    isVisible: Bool
  ) {
    lock.lock()
    state.panelWorldMatrix = matrix
    state.panelSize = size
    state.bottomDepthOffset = bottomDepthOffset
    state.isVisible = isVisible
    lock.unlock()
  }

  func setFocused(_ isFocused: Bool) {
    lock.lock()
    state.isFocused = isFocused
    lock.unlock()
  }

  func updateHitUV(_ hitUV: SIMD2<Float>?, opacity: Float = 1) {
    lock.lock()
    state.hitUV = hitUV
    state.hitOpacity = opacity
    lock.unlock()
  }

  func updateChannelMask(_ channelMask: UInt32) {
    lock.lock()
    state.channelMask = channelMask
    lock.unlock()
  }

  func shaderState() -> (isFocused: Bool, hitUV: SIMD2<Float>?, hitOpacity: Float, channelMask: UInt32) {
    lock.lock()
    let value = (state.isFocused, state.hitUV, state.hitOpacity, state.channelMask)
    lock.unlock()
    return value
  }

  func localPoint(forWorldPosition worldPosition: SIMD3<Float>) -> (point: SIMD3<Float>, size: SIMD2<Float>)? {
    lock.lock()
    let snapshot = state
    lock.unlock()

    guard snapshot.isVisible,
          snapshot.panelSize.x > 0,
          snapshot.panelSize.y > 0 else {
      return nil
    }

    let localFromWorld = snapshot.panelWorldMatrix.inverse
    let localPosition4 = localFromWorld * SIMD4<Float>(worldPosition, 1)
    return (
      SIMD3<Float>(localPosition4.x, localPosition4.y, localPosition4.z),
      snapshot.panelSize
    )
  }

  func hitTest(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD2<Float>? {
    lock.lock()
    let snapshot = state
    lock.unlock()

    guard snapshot.isVisible,
          snapshot.panelSize.x > 0,
          snapshot.panelSize.y > 0 else {
      return nil
    }

    let localFromWorld = snapshot.panelWorldMatrix.inverse
    let localOrigin4 = localFromWorld * SIMD4<Float>(origin, 1)
    let localDirection4 = localFromWorld * SIMD4<Float>(simd_normalize(direction), 0)
    let localOrigin = SIMD3<Float>(localOrigin4.x, localOrigin4.y, localOrigin4.z)
    let localDirection = SIMD3<Float>(localDirection4.x, localDirection4.y, localDirection4.z)

    let slope = -snapshot.bottomDepthOffset / snapshot.panelSize.y
    let planeNormal = simd_normalize(SIMD3<Float>(0, -slope, 1))
    let pointOnPlane = SIMD3<Float>(0, snapshot.panelSize.y * 0.5, 0)
    let denominator = simd_dot(planeNormal, localDirection)

    guard abs(denominator) > 0.0001 else {
      return nil
    }

    let t = simd_dot(planeNormal, pointOnPlane - localOrigin) / denominator
    guard t >= 0 else {
      return nil
    }

    let hit = localOrigin + localDirection * t
    let halfSize = snapshot.panelSize * 0.5
    guard hit.x >= -halfSize.x,
          hit.x <= halfSize.x,
          hit.y >= -halfSize.y,
          hit.y <= halfSize.y else {
      return nil
    }

    let u = (hit.x / snapshot.panelSize.x) + 0.5
    let v = (hit.y / snapshot.panelSize.y) + 0.5
    return SIMD2<Float>(u, v)
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
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
