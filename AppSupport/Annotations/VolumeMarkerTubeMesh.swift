import Metal
import simd

struct VolumeMarkerTubeMesh {
  var positions: [SIMD3<Float>]
  var normals: [SIMD3<Float>]
}

struct VolumeMarkerTubeGPUMesh {
  let positionBuffer: MTLBuffer
  let normalBuffer: MTLBuffer
  let vertexCount: Int
}

final class VolumeMarkerTubeMeshCache {
  private struct Entry {
    let geometryID: UUID
    let coordinateScale: SIMD3<Float>
    let mesh: VolumeMarkerTubeGPUMesh
  }

  private var entries: [UUID: Entry] = [:]

  func mesh(
    for marker: VolumeMarker,
    coordinateScale: SIMD3<Float>,
    device: MTLDevice
  ) -> VolumeMarkerTubeGPUMesh? {
    let points: [VolumeMarkerPoint]
    switch marker.geometry {
      case .sphere(let point):
        guard marker.showsDirection,
              let directionOrigin = marker.directionOrigin else {
          return nil
        }
        let scaledOffset = (directionOrigin - point.position) * coordinateScale
        guard simd_length_squared(scaledOffset) > 0.000_000_01 else {
          return nil
        }
        let directionRadius = point.radius * VolumeMarker.directionRadiusFactor
        points = [
          VolumeMarkerPoint(position: point.position, radius: directionRadius),
          VolumeMarkerPoint(position: directionOrigin, radius: directionRadius)
        ]
      case .stroke(let strokePoints):
        guard strokePoints.count >= 2 else { return nil }
        points = strokePoints
    }
    if let entry = entries[marker.id],
       entry.geometryID == marker.meshCacheID,
       entry.coordinateScale == coordinateScale {
      return entry.mesh
    }

    let tube = Self.generateTube(points: points, coordinateScale: coordinateScale)
    guard !tube.positions.isEmpty,
          tube.positions.count == tube.normals.count,
          let positionBuffer = device.makeBuffer(
            bytes: tube.positions,
            length: MemoryLayout<SIMD3<Float>>.stride * tube.positions.count,
            options: .storageModeShared
          ),
          let normalBuffer = device.makeBuffer(
            bytes: tube.normals,
            length: MemoryLayout<SIMD3<Float>>.stride * tube.normals.count,
            options: .storageModeShared
          ) else {
      return nil
    }
    positionBuffer.label = "Volume Marker Stroke Positions"
    normalBuffer.label = "Volume Marker Stroke Normals"
    let mesh = VolumeMarkerTubeGPUMesh(
      positionBuffer: positionBuffer,
      normalBuffer: normalBuffer,
      vertexCount: tube.positions.count
    )
    entries[marker.id] = Entry(
      geometryID: marker.meshCacheID,
      coordinateScale: coordinateScale,
      mesh: mesh
    )
    return mesh
  }

  func retainOnly(markerIDs: Set<UUID>) {
    entries = entries.filter { markerIDs.contains($0.key) }
  }

  func removeAll() {
    entries.removeAll()
  }

  private struct CurvePoint {
    var position: SIMD3<Float>
    var radius: Float
  }

  private static func generateTube(
    points: [VolumeMarkerPoint],
    coordinateScale: SIMD3<Float>,
    radialSegmentCount: Int = 12
  ) -> VolumeMarkerTubeMesh {
    let controlPoints = points.map {
      CurvePoint(
        position: ($0.position - SIMD3<Float>(repeating: 0.5)) * coordinateScale,
        radius: max($0.radius, 0.000_1)
      )
    }
    let curve = smoothCurve(controlPoints)
    guard curve.count >= 2 else {
      return VolumeMarkerTubeMesh(positions: [], normals: [])
    }

    var tangents = [SIMD3<Float>]()
    tangents.reserveCapacity(curve.count)
    for index in curve.indices {
      let previous = curve[max(index - 1, curve.startIndex)].position
      let next = curve[min(index + 1, curve.index(before: curve.endIndex))].position
      let delta = next - previous
      tangents.append(simd_length_squared(delta) > 0.000_000_01
        ? simd_normalize(delta)
        : (tangents.last ?? SIMD3<Float>(0, 0, 1)))
    }

    var ringNormals = [[SIMD3<Float>]]()
    ringNormals.reserveCapacity(curve.count)
    var frameNormal = initialNormal(for: tangents[0])
    var previousTangent = tangents[0]
    for tangent in tangents {
      frameNormal = transportedNormal(
        frameNormal,
        from: previousTangent,
        to: tangent
      )
      let frameBinormal = simd_normalize(simd_cross(tangent, frameNormal))
      frameNormal = simd_normalize(simd_cross(frameBinormal, tangent))
      var normals = [SIMD3<Float>]()
      normals.reserveCapacity(radialSegmentCount)
      for segment in 0..<radialSegmentCount {
        let angle = Float(segment) * 2 * .pi / Float(radialSegmentCount)
        normals.append(frameNormal * cos(angle) + frameBinormal * sin(angle))
      }
      ringNormals.append(normals)
      previousTangent = tangent
    }

    var positions = [SIMD3<Float>]()
    var normals = [SIMD3<Float>]()
    let triangleVertexCount = (curve.count - 1) * radialSegmentCount * 6
    positions.reserveCapacity(triangleVertexCount)
    normals.reserveCapacity(triangleVertexCount)

    func appendVertex(ring: Int, segment: Int) {
      let normal = ringNormals[ring][segment % radialSegmentCount]
      positions.append(curve[ring].position + normal * curve[ring].radius)
      normals.append(normal)
    }

    for ring in 0..<(curve.count - 1) {
      for segment in 0..<radialSegmentCount {
        let nextSegment = (segment + 1) % radialSegmentCount
        // Counter-clockwise winding as seen from outside the tube.
        appendVertex(ring: ring, segment: segment)
        appendVertex(ring: ring + 1, segment: nextSegment)
        appendVertex(ring: ring + 1, segment: segment)

        appendVertex(ring: ring, segment: segment)
        appendVertex(ring: ring, segment: nextSegment)
        appendVertex(ring: ring + 1, segment: nextSegment)
      }
    }
    return VolumeMarkerTubeMesh(positions: positions, normals: normals)
  }

  private static func smoothCurve(_ points: [CurvePoint]) -> [CurvePoint] {
    guard points.count >= 2 else { return points }
    var result = [CurvePoint]()
    result.reserveCapacity(points.count * 3)

    for index in 0..<(points.count - 1) {
      let p1 = points[index]
      let p2 = points[index + 1]
      let p0 = index > 0
        ? points[index - 1]
        : CurvePoint(position: p1.position * 2 - p2.position, radius: p1.radius)
      let p3 = index + 2 < points.count
        ? points[index + 2]
        : CurvePoint(position: p2.position * 2 - p1.position, radius: p2.radius)
      let segmentLength = simd_length(p2.position - p1.position)
      let averageRadius = max((p1.radius + p2.radius) * 0.5, 0.000_1)
      let subdivisions = min(8, max(2, Int(ceil(segmentLength / (averageRadius * 0.4)))))

      for step in 0..<subdivisions {
        let t = Float(step) / Float(subdivisions)
        result.append(
          CurvePoint(
            position: centripetalCatmullRom(
              p0.position,
              p1.position,
              p2.position,
              p3.position,
              t
            ),
            radius: p1.radius + (p2.radius - p1.radius) * t
          )
        )
      }
    }
    result.append(points.last!)
    return result
  }

  private static func centripetalCatmullRom(
    _ p0: SIMD3<Float>,
    _ p1: SIMD3<Float>,
    _ p2: SIMD3<Float>,
    _ p3: SIMD3<Float>,
    _ t: Float
  ) -> SIMD3<Float> {
    let segmentLength = simd_length(p2 - p1)
    guard segmentLength > 0.000_001 else { return p1 }

    func nextKnot(_ knot: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
      knot + sqrt(max(simd_length(b - a), 0.000_001))
    }

    func interpolate(
      _ a: SIMD3<Float>,
      _ b: SIMD3<Float>,
      from start: Float,
      to end: Float,
      at value: Float
    ) -> SIMD3<Float> {
      let span = max(end - start, 0.000_001)
      return a * ((end - value) / span) + b * ((value - start) / span)
    }

    let t0: Float = 0
    let t1 = nextKnot(t0, p0, p1)
    let t2 = nextKnot(t1, p1, p2)
    let t3 = nextKnot(t2, p2, p3)
    let value = t1 + (t2 - t1) * t
    let a1 = interpolate(p0, p1, from: t0, to: t1, at: value)
    let a2 = interpolate(p1, p2, from: t1, to: t2, at: value)
    let a3 = interpolate(p2, p3, from: t2, to: t3, at: value)
    let b1 = interpolate(a1, a2, from: t0, to: t2, at: value)
    let b2 = interpolate(a2, a3, from: t1, to: t3, at: value)
    return interpolate(b1, b2, from: t1, to: t2, at: value)
  }

  private static func initialNormal(for tangent: SIMD3<Float>) -> SIMD3<Float> {
    let reference: SIMD3<Float> = abs(tangent.y) < 0.9
      ? SIMD3<Float>(0, 1, 0)
      : SIMD3<Float>(1, 0, 0)
    return simd_normalize(simd_cross(reference, tangent))
  }

  private static func transportedNormal(
    _ normal: SIMD3<Float>,
    from oldTangent: SIMD3<Float>,
    to newTangent: SIMD3<Float>
  ) -> SIMD3<Float> {
    let rotationAxis = simd_cross(oldTangent, newTangent)
    let axisLength = simd_length(rotationAxis)
    guard axisLength > 0.000_01 else {
      return simd_normalize(normal - newTangent * simd_dot(normal, newTangent))
    }
    let angle = atan2(axisLength, simd_dot(oldTangent, newTangent))
    return simd_quatf(angle: angle, axis: rotationAxis / axisLength).act(normal)
  }
}
