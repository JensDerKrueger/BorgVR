import simd

struct ScreenProjection {
  static let defaultFieldOfView: Float = 45
  static let fieldOfViewRange: ClosedRange<Float> = 10...120
  static let cameraDistance: Float = 2.4
  static let nearZ: Float = 0.05
  static let farZ: Float = 100

  let fieldOfView: Float
  let parallel: Bool

  init(fieldOfView: Float, parallel: Bool) {
    self.fieldOfView = fieldOfView.isFinite
      ? min(Self.fieldOfViewRange.upperBound, max(Self.fieldOfViewRange.lowerBound, fieldOfView))
      : Self.defaultFieldOfView
    self.parallel = parallel
  }

  var radians: Float { fieldOfView * .pi / 180 }
  var visibleHeight: Float { 2 * tan(radians * 0.5) * Self.cameraDistance }

  func matrix(aspect: Float) -> simd_float4x4 {
    guard parallel else {
      return matrixPerspective(fovyRadians: radians, aspect: aspect, nearZ: Self.nearZ, farZ: Self.farZ)
    }
    let height = visibleHeight
    return simd_float4x4(
      SIMD4<Float>(2 / (height * aspect), 0, 0, 0),
      SIMD4<Float>(0, 2 / height, 0, 0),
      SIMD4<Float>(0, 0, 1 / (Self.farZ - Self.nearZ), 0),
      SIMD4<Float>(0, 0, Self.farZ / (Self.farZ - Self.nearZ), 1)
    )
  }
}

func matrixTranslation(_ translation: SIMD3<Float>) -> simd_float4x4 {
  simd_float4x4(
    SIMD4<Float>(1, 0, 0, 0),
    SIMD4<Float>(0, 1, 0, 0),
    SIMD4<Float>(0, 0, 1, 0),
    SIMD4<Float>(translation.x, translation.y, translation.z, 1)
  )
}

func matrixScale(_ scale: SIMD3<Float>) -> simd_float4x4 {
  simd_float4x4(
    SIMD4<Float>(scale.x, 0, 0, 0),
    SIMD4<Float>(0, scale.y, 0, 0),
    SIMD4<Float>(0, 0, scale.z, 0),
    SIMD4<Float>(0, 0, 0, 1)
  )
}

func matrixRotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
  simd_float4x4(simd_quatf(angle: radians, axis: normalize(axis)))
}

func matrixPerspective(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
  let y = 1 / tan(fovyRadians * 0.5)
  let x = y / aspect
  let z = nearZ / (farZ - nearZ)
  return simd_float4x4(
    SIMD4<Float>(x, 0, 0, 0),
    SIMD4<Float>(0, y, 0, 0),
    SIMD4<Float>(0, 0, z, -1),
    SIMD4<Float>(0, 0, z * farZ, 0)
  )
}
