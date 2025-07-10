import CompositorServices
import SwiftUI

class ImmersiveInteraction {
  var renderingParamaters: RenderingParamaters

  private var startTranslation: SIMD3<Float> = .zero
  private var startRotation: simd_quatf = .init(.identity)
  private var tmpDistance: Double = 0.0

  private var startTranslationTF: SIMD3<Float> = .zero
  private var translationTF: SIMD3<Float> = .zero
  private var lastTranslationTF: SIMD3<Float> = SIMD3<Float>(0.5,0.5,0.5)

  private var startTranslationClipping: SIMD3<Float> = .zero
  private var translationClipping: SIMD3<Float> = .zero
  private var lastTranslationClipping: SIMD3<Float> = .zero

  private var doubleEventIsRunning = false

  init(renderingParamaters: RenderingParamaters) {
    self.renderingParamaters = renderingParamaters
  }

  func distanceBetweenVectors(v1: SIMD3<Double>, v2: SIMD3<Double>) -> Double {
    let deltaX = v2.x - v1.x
    let deltaY = v2.y - v1.y
    let deltaZ = v2.z - v1.z
    return sqrt(deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ)
  }

  private func handleScaling(_ events: SpatialEventCollection) {
    doubleEventIsRunning = true
    var v1: SIMD3<Double>?
    var v2: SIMD3<Double>?
    for event in events {
      switch event.phase {
      case .active:
        if v1 == nil {
          v1 = event.inputDevicePose!.pose3D.position.vector
        } else {
          v2 = event.inputDevicePose!.pose3D.position.vector
        }

      case .cancelled, .ended:
        renderingParamaters.lastTransform.scale = renderingParamaters.transform.scale
        tmpDistance = 0
      default:
        break
      }
    }
    if (v1 != nil && v2 != nil) {
      let distance = distanceBetweenVectors(v1: v1!, v2: v2!)
      if tmpDistance == 0.0 {
        tmpDistance = distance
      }
      renderingParamaters.transform.scale = SIMD3(repeating: renderingParamaters.lastTransform.scale.x * (Float(distance - tmpDistance) + 1))
    }
  }

  private func handleTranslationAndRotation(_ event: SpatialEventCollection.Event) {
    switch event.phase {
    case .active:
      // One hand from the scaling movement is still active
      if doubleEventIsRunning {
        return
      }
      if let pose = event.inputDevicePose {
        if startTranslation == .zero {
          startTranslation = SIMD3<Float>(pose.pose3D.position.vector)
          startRotation = simd_quatf(pose.pose3D.rotation)
        }

        renderingParamaters.transform.rotation =  simd_quatf(pose.pose3D.rotation) * startRotation.inverse * renderingParamaters.lastTransform.rotation
        let translate = (SIMD3<Float>(pose.pose3D.position.vector) - startTranslation)
        renderingParamaters.transform.translation = renderingParamaters.lastTransform.translation + translate
      }
    case .cancelled, .ended:
      renderingParamaters.lastTransform.translation = renderingParamaters.transform.translation
      renderingParamaters.lastTransform.rotation = renderingParamaters.transform.rotation
      startTranslation = .zero
      startRotation = .init(.identity)
      doubleEventIsRunning = false
    default:
      break
    }
  }

  private func handleClippingTranslationAndRotation(_ event: SpatialEventCollection.Event) {
    switch event.phase {
      case .active:
        // One hand from the scaling movement is still active
        if doubleEventIsRunning {
          return
        }
        if let pose = event.inputDevicePose {

          if startTranslationClipping == .zero {
            startTranslationClipping = SIMD3<Float>(pose.pose3D.position.vector)
          }

          var translate = (SIMD3<Float>(pose.pose3D.position.vector) - startTranslationClipping)

          translate = simd_float3x3(
            renderingParamaters.transform.rotation
          ).inverse * translate

          translationClipping = lastTranslationClipping + translate

          if translationClipping.x > 0.99 {translationClipping.x = 0.99}
          if translationClipping.y > 0.99 {translationClipping.y = 0.99}
          if translationClipping.z > 0.99 {translationClipping.z = 0.99}
          if translationClipping.x < -0.99 {translationClipping.x = -0.99}
          if translationClipping.y < -0.99 {translationClipping.y = -0.99}
          if translationClipping.z < -0.99 {translationClipping.z = -0.99}

          if translationClipping.x >= 0 {
            renderingParamaters.clipMax.x = 1
            renderingParamaters.clipMin.x = translationClipping.x
          } else {
            renderingParamaters.clipMin.x = 0
            renderingParamaters.clipMax.x = 1+translationClipping.x
          }

          if translationClipping.y >= 0 {
            renderingParamaters.clipMax.y = 1
            renderingParamaters.clipMin.y = translationClipping.y
          } else {
            renderingParamaters.clipMin.y = 0
            renderingParamaters.clipMax.y = 1+translationClipping.y
          }

          if translationClipping.z >= 0 {
            renderingParamaters.clipMax.z = 1
            renderingParamaters.clipMin.z = translationClipping.z
          } else {
            renderingParamaters.clipMin.z = 0
            renderingParamaters.clipMax.z = 1+translationClipping.z
          }

        }
      case .cancelled, .ended:
        lastTranslationClipping = translationClipping
        startTranslationClipping = .zero
        doubleEventIsRunning = false
      default:
        break
    }
  }

  private func handleTFTranslationAndRotation(_ event: SpatialEventCollection.Event) {
    switch event.phase {
    case .active:
      // One hand from the scaling movement is still active
      if doubleEventIsRunning {
        return
      }
      if let pose = event.inputDevicePose {

        if startTranslationTF == .zero {
          startTranslationTF = SIMD3<Float>(pose.pose3D.position.vector)
        }

        let translate = (SIMD3<Float>(pose.pose3D.position.vector) - startTranslationTF)

        var channels : [Int] = []
        if renderingParamaters.transferEditing.red { channels.append(0) }
        if renderingParamaters.transferEditing.green { channels.append(1) }
        if renderingParamaters.transferEditing.blue { channels.append(2) }
        if renderingParamaters.transferEditing.opacity { channels.append(3) }

        translationTF = lastTranslationTF + translate

        renderingParamaters.transferFunction
          .smoothStep(start: translationTF.x, shift: translationTF.y, channels: channels)
      }
    case .cancelled, .ended:
      lastTranslationTF = translationTF
      startTranslationTF = .zero
      doubleEventIsRunning = false
    default:
      break
    }
  }

  func handleSpatialEvents(_ events: SpatialEventCollection,
                           _ interactionMode: AppModel.InteractionMode) {
    switch interactionMode {
      case .transferEditing:
        switch events.count {
        case 1:
          handleTFTranslationAndRotation(events.first!)
        case 2:
          return
        default:
          return
        }
      case .model:
        switch events.count {
        case 1:
          handleTranslationAndRotation(events.first!)
        case 2:
          handleScaling(events)
        default:
          return
        }
      case .clipping:
        switch events.count {
          case 1:
            handleClippingTranslationAndRotation(events.first!)
          case 2:
            return
          default:
            return
        }
    }
  }
}
