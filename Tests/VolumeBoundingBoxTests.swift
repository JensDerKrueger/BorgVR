import Foundation
import simd

@main
private enum VolumeBoundingBoxTests {
  static func main() {
    for extent in [SIMD3<Float>(1, 1, 1), SIMD3(0.25, 0.5, 1), SIMD3(1, 0.001, 0.4)] {
      let box = VolumeBoundingBoxRenderer.geometry(extent: extent)
      precondition(box.vertices.count == 12 * 36 && box.normals.count == box.vertices.count,
        "The box must contain exactly twelve closed edge beams")
      var minimum = SIMD3<Float>(repeating: .infinity)
      var maximum = SIMD3<Float>(repeating: -.infinity)
      for i in box.vertices.indices {
        let point = box.vertices[i]
        precondition(point.x.isFinite && point.y.isFinite && point.z.isFinite)
        precondition(abs(simd_length(box.normals[i]) - 1) < 0.00001)
        minimum = simd_min(minimum, point)
        maximum = simd_max(maximum, point)
        // Every vertex belongs to an edge, never to a filled box face/interior.
        let edgeAxes = (0..<3).filter { abs(abs(point[$0]) - extent[$0] * 0.5) <= 0.00151 }
        precondition(edgeAxes.count >= 2, "Bounding box contains non-edge geometry")
      }
      precondition(simd_length(minimum + extent * 0.5) < 0.00001,
        "Beam thickness must not extend below the dataset bounds")
      precondition(simd_length(maximum - extent * 0.5) < 0.00001,
        "Beam thickness must not extend above the dataset bounds")
      for i in stride(from: 0, to: box.vertices.count, by: 3) {
        let face = simd_cross(box.vertices[i + 1] - box.vertices[i], box.vertices[i + 2] - box.vertices[i])
        precondition(simd_dot(face, box.normals[i]) > 0, "Incorrect bounding box winding")
      }
    }
    for extent in [SIMD3<Float>(0, 1, 1), SIMD3(-1, 1, 1), SIMD3(.nan, 1, 1)] {
      precondition(VolumeBoundingBoxRenderer.geometry(extent: extent).vertices.isEmpty)
    }
    print("Bounding box tests passed: twelve edges, anisotropic extents, finite normals, winding, invalid extents")
  }
}
