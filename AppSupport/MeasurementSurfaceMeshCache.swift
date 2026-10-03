import Metal
import simd

struct MeasurementSurfaceGPUMesh {
  let positionBuffer: MTLBuffer
  let normalBuffer: MTLBuffer
  let vertexCount: Int
}

final class MeasurementSurfaceMeshCache {
  private struct Entry {
    let revision: UUID
    let coordinateScale: SIMD3<Float>
    let mesh: MeasurementSurfaceGPUMesh
  }

  private var entries: [UUID: Entry] = [:]

  func mesh(
    for measurement: VolumeMeasurement,
    coordinateScale: SIMD3<Float>,
    device: MTLDevice
  ) -> MeasurementSurfaceGPUMesh? {
    guard Self.isFinite(coordinateScale) else {
      entries.removeValue(forKey: measurement.id)
      return nil
    }
    if let entry = entries[measurement.id],
       entry.revision == measurement.geometryRevision,
       entry.coordinateScale == coordinateScale {
      return entry.mesh
    }

    let triangleVertices = measurement.geometry.triangleVertices
    guard triangleVertices.count >= 3 else {
      entries.removeValue(forKey: measurement.id)
      return nil
    }

    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    positions.reserveCapacity(triangleVertices.count)
    normals.reserveCapacity(triangleVertices.count)
    for offset in stride(from: 0, to: triangleVertices.count - 2, by: 3) {
      guard Self.isFinite(triangleVertices[offset]),
            Self.isFinite(triangleVertices[offset + 1]),
            Self.isFinite(triangleVertices[offset + 2]) else { continue }
      let a = (triangleVertices[offset] - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      let b = (triangleVertices[offset + 1] - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      let c = (triangleVertices[offset + 2] - SIMD3<Float>(repeating: 0.5)) * coordinateScale
      guard Self.isFinite(a), Self.isFinite(b), Self.isFinite(c) else { continue }
      let cross = simd_cross(b - a, c - a)
      let lengthSquared = simd_length_squared(cross)
      guard lengthSquared.isFinite, lengthSquared > 1e-16 else { continue }
      let normal = cross / sqrt(lengthSquared)
      guard Self.isFinite(normal) else { continue }
      positions += [a, b, c]
      normals += [normal, normal, normal]
    }
    guard !positions.isEmpty,
          let positionBuffer = device.makeBuffer(
            bytes: positions,
            length: MemoryLayout<SIMD3<Float>>.stride * positions.count,
            options: .storageModeShared
          ),
          let normalBuffer = device.makeBuffer(
            bytes: normals,
            length: MemoryLayout<SIMD3<Float>>.stride * normals.count,
            options: .storageModeShared
          ) else { return nil }
    positionBuffer.label = "Measurement Surface Positions"
    normalBuffer.label = "Measurement Surface Normals"
    let mesh = MeasurementSurfaceGPUMesh(
      positionBuffer: positionBuffer,
      normalBuffer: normalBuffer,
      vertexCount: positions.count
    )
    entries[measurement.id] = Entry(
      revision: measurement.geometryRevision,
      coordinateScale: coordinateScale,
      mesh: mesh
    )
    return mesh
  }

  func retainOnly(measurementIDs: Set<UUID>) {
    entries = entries.filter { measurementIDs.contains($0.key) }
  }

  private static func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
  }
}
