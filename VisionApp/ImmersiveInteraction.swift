import CompositorServices
import SwiftUI

class ImmersiveInteraction {
  var sharedAppModel: SharedAppModel

  private var startTranslation: SIMD3<Float> = .zero
  private var startRotation: simd_quatf = .init(.identity)
  private var tmpDistance: Double = 0.0

  private var startTranslationClipping: SIMD3<Float> = .zero
  private var translationClipping: SIMD3<Float> = .zero

  private var doubleEventIsRunning = false

  init(sharedAppModel: SharedAppModel) {
    self.sharedAppModel = sharedAppModel
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
          sharedAppModel.lastModelTransform.scale = sharedAppModel.modelTransform.scale
          sharedAppModel.synchronize(kind: .transformOnly)
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
      sharedAppModel.modelTransform.scale = SIMD3(repeating: sharedAppModel.lastModelTransform.scale.x * (Float(distance - tmpDistance) + 1))
      sharedAppModel.synchronize(kind: .transformOnly)
    }
  }

  private func handleTranslationAndRotation(_ event: SpatialEventCollection.Event) {

    let inverseWorld = sharedAppModel.originFromWorldAnchorMatrix.inverse

    switch event.phase {
    case .active:
      // One hand from the scaling movement is still active
      if doubleEventIsRunning {
        return
      }
      if let pose = event.inputDevicePose {
        if startTranslation == .zero {
          startTranslation = SIMD3<Float>(pose.pose3D.position.vector)
          startRotation = simd_quatf(pose.pose3D.rotation.transformed(
            by: inverseWorld,
            order: .pre
          ))
        }

        let poseRotation = simd_quatf(pose.pose3D.rotation.transformed(
          by: inverseWorld,
          order: .pre
        ))

        sharedAppModel.modelTransform.rotation =  poseRotation * startRotation.inverse * sharedAppModel.lastModelTransform.rotation

        let translate = inverseWorld.transformDirection(SIMD3<Float>(pose.pose3D.position.vector) - startTranslation)

        sharedAppModel.modelTransform.translation = sharedAppModel.lastModelTransform.translation + translate
        sharedAppModel.synchronize(kind: .transformOnly)
      }
    case .cancelled, .ended:
      sharedAppModel.lastModelTransform.translation = sharedAppModel.modelTransform.translation
      sharedAppModel.lastModelTransform.rotation = sharedAppModel.modelTransform.rotation
      startTranslation = .zero
      startRotation = .init(.identity)
      doubleEventIsRunning = false
    default:
      break
    }
  }

  private func handleClippingTranslationAndRotation(_ event: SpatialEventCollection.Event) {
    let inverseWorld = sharedAppModel.originFromWorldAnchorMatrix.inverse

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

          var translate = inverseWorld.transformDirection(SIMD3<Float>(pose.pose3D.position.vector) - startTranslationClipping)

          translate = simd_float3x3(
            sharedAppModel.modelTransform.rotation
          ).inverse * translate

          translationClipping = sharedAppModel.lastTranslationClipping + translate

          if translationClipping.x > 0.99 {translationClipping.x = 0.99}
          if translationClipping.y > 0.99 {translationClipping.y = 0.99}
          if translationClipping.z > 0.99 {translationClipping.z = 0.99}
          if translationClipping.x < -0.99 {translationClipping.x = -0.99}
          if translationClipping.y < -0.99 {translationClipping.y = -0.99}
          if translationClipping.z < -0.99 {translationClipping.z = -0.99}

          if translationClipping.x >= 0 {
            sharedAppModel.clipMax.x = 1
            sharedAppModel.clipMin.x = translationClipping.x
          } else {
            sharedAppModel.clipMin.x = 0
            sharedAppModel.clipMax.x = 1+translationClipping.x
          }

          if translationClipping.y >= 0 {
            sharedAppModel.clipMax.y = 1
            sharedAppModel.clipMin.y = translationClipping.y
          } else {
            sharedAppModel.clipMin.y = 0
            sharedAppModel.clipMax.y = 1+translationClipping.y
          }

          if translationClipping.z >= 0 {
            sharedAppModel.clipMax.z = 1
            sharedAppModel.clipMin.z = translationClipping.z
          } else {
            sharedAppModel.clipMin.z = 0
            sharedAppModel.clipMax.z = 1+translationClipping.z
          }
          
          sharedAppModel.synchronize(kind: .stateOnly)
        }
      case .cancelled, .ended:
        sharedAppModel.lastTranslationClipping = translationClipping
        startTranslationClipping = .zero
        doubleEventIsRunning = false
      default:
        break
    }
  }


  func handleSpatialEvents(_ events: SpatialEventCollection,
                           _ interactionMode: RuntimeAppModel.InteractionMode,
                           _ transferEditState: RuntimeAppModel.TransferEditState) {
    switch interactionMode {
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

public enum RotationComposeOrder { case pre, post }

public extension Rotation3D {
  /// Returns `self` composed with the rotation contained in `matrix`.
  /// - Parameters:
  ///   - matrix: A 4×4 transform; only its rotational component is used.
  ///   - order: `.pre` means `matrix` is applied before `self` (M ∘ R). `.post` applies after (R ∘ M).
  ///   - orthonormalize: If true, removes any scale/shear before extracting rotation.
  func transformed(
    by matrix: simd_float4x4,
    order: RotationComposeOrder = .pre,
    orthonormalize: Bool = true
  ) -> Rotation3D {
    let qM = matrix.rotationQuaternion(orthonormalize: orthonormalize)
    let qSelfF = simd_quatf(self)
    let qOut: simd_quatf = (order == .pre) ? (qM * qSelfF) : (qSelfF * qM)
    return Rotation3D.init(qOut)
  }
}

private extension simd_float4x4 {
  /// Extracts a unit-rotation quaternion from the matrix.
  func rotationQuaternion(orthonormalize: Bool) -> simd_quatf {
    if !orthonormalize {
      return simd_quatf(self)           // assumes no shear / uniform scale
    }

    var c0 = simd_float3(columns.0.x,columns.0.y,columns.0.z)
    var c1 = simd_float3(columns.1.x,columns.1.y,columns.1.z)
    c0 = simd_normalize(c0)
    c1 = simd_normalize(c1 - simd_dot(c1, c0) * c0)
    let c2 = simd_cross(c0, c1)
    return simd_quatf(simd_float3x3(c0, c1, c2))
  }

  func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
    let v = self * SIMD4<Float>(d, 0)
    return SIMD3<Float>(v.x, v.y, v.z)
  }
}
