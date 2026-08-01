import simd

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
  let z = farZ / (nearZ - farZ)
  return simd_float4x4(
    SIMD4<Float>(x, 0, 0, 0),
    SIMD4<Float>(0, y, 0, 0),
    SIMD4<Float>(0, 0, z, -1),
    SIMD4<Float>(0, 0, z * nearZ, 0)
  )
}
