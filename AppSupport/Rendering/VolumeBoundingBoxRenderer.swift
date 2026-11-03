import Metal
import simd

/// A cached frame in normalized volume-model coordinates, separate from annotations.
final class VolumeBoundingBoxRenderer {
  private var cachedExtent: SIMD3<Float>?
  private var positions: MTLBuffer?
  private var normals: MTLBuffer?
  private var vertexCount = 0

  static func geometry(extent: SIMD3<Float>) -> Tesselation {
    guard extent.x.isFinite, extent.y.isFinite, extent.z.isFinite,
          extent.x > 0, extent.y > 0, extent.z > 0 else { return Tesselation() }
    var result = Tesselation()
    let thickness = min(0.0015, min(extent.x, extent.y, extent.z) * 0.25)
    for axis in 0..<3 {
      let a = (axis + 1) % 3
      let b = (axis + 2) % 3
      for sideA: Float in [-0.5, 0.5] {
        for sideB: Float in [-0.5, 0.5] {
          var center = SIMD3<Float>.zero
          center[a] = (extent[a] - thickness) * sideA
          center[b] = (extent[b] - thickness) * sideB
          var size = SIMD3<Float>(repeating: thickness)
          size[axis] = extent[axis]
          let edge = Tesselation.genBrick(center: center, size: size,
            texScale: SIMD3<Float>(repeating: 1)).unpack()
          result.vertices.append(contentsOf: edge.vertices)
          result.normals.append(contentsOf: edge.normals)
        }
      }
    }
    return result
  }

  func render(
    device: MTLDevice,
    encoder: MTLRenderCommandEncoder,
    extent: SIMD3<Float>,
    modelMatrix: simd_float4x4
  ) {
    if cachedExtent != extent {
      let mesh = Self.geometry(extent: extent)
      guard !mesh.vertices.isEmpty,
            let positions = device.makeBuffer(bytes: mesh.vertices,
              length: mesh.vertices.count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared),
            let normals = device.makeBuffer(bytes: mesh.normals,
              length: mesh.normals.count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
      else { return }
      positions.label = "Dataset Bounding Box Positions"
      normals.label = "Dataset Bounding Box Normals"
      self.positions = positions
      self.normals = normals
      vertexCount = mesh.vertices.count
      cachedExtent = extent
    }
    guard let positions, let normals else { return }
    var modelMatrix = modelMatrix
    var color = SIMD4<Float>(1, 1, 1, 1)
    encoder.pushDebugGroup("Dataset Bounding Box")
    encoder.setVertexBuffer(positions, offset: 0, index: VertexBufferIndex.meshPositions.rawValue)
    encoder.setVertexBuffer(normals, offset: 0, index: 24)
    encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<simd_float4x4>.stride, index: 21)
    encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 23)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    encoder.popDebugGroup()
  }
}
