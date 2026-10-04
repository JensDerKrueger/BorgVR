import Foundation
import simd

enum VolumeMeasurementKind: String, CaseIterable, Identifiable {
  case length
  case area
  case volume

  var id: Self { self }

  var minimumPointCount: Int {
    switch self {
      case .length: 2
      case .area: 3
      case .volume: 4
    }
  }
}

enum VolumeMeasurementPresentation {
  static func color(for kind: VolumeMeasurementKind, selected: Bool) -> SIMD4<Float> {
    let base: SIMD3<Float>
    switch kind {
      case .length: base = SIMD3<Float>(1.0, 0.72, 0.12)
      case .area: base = SIMD3<Float>(0.10, 0.78, 0.92)
      case .volume: base = SIMD3<Float>(0.82, 0.30, 0.95)
    }
    let rgb = selected ? base + (SIMD3<Float>(repeating: 1) - base) * 0.22 : base
    return SIMD4<Float>(rgb, 1)
  }

  static func visualizationID(_ base: UUID, index: Int) -> UUID {
    var uuid = base.uuid
    withUnsafeMutableBytes(of: &uuid) { bytes in
      bytes[12] ^= 0x4D
      bytes[13] ^= UInt8(truncatingIfNeeded: index >> 16)
      bytes[14] ^= UInt8(truncatingIfNeeded: index >> 8)
      bytes[15] ^= UInt8(truncatingIfNeeded: index)
    }
    return UUID(uuid: uuid)
  }
}

/// GPU instance shared by the screen and immersive measurement-point shaders.
/// The radius is expressed in pixels so control points remain compact at every distance.
struct MeasurementPointRenderInstance {
  var centerAndRadius: SIMD4<Float>
  var color: SIMD4<Float>
}

struct VolumeMeasurementPoint: Identifiable, Equatable {
  let id: UUID
  var position: SIMD3<Float>

  init(id: UUID = UUID(), position: SIMD3<Float>) {
    self.id = id
    self.position = position
  }
}

struct VolumeMeasurementGeometry {
  struct Edge {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
  }

  var points: [VolumeMeasurementPoint]
  var edges: [Edge]
  var triangleVertices: [SIMD3<Float>]
  var labelPosition: SIMD3<Float>?
  var value: Double?
}

struct VolumeMeasurement: Identifiable {
  let id: UUID
  var name: String
  let kind: VolumeMeasurementKind
  private(set) var points: [VolumeMeasurementPoint]
  private(set) var geometry: VolumeMeasurementGeometry
  private(set) var geometryRevision: UUID
  private var physicalExtent: SIMD3<Float>?

  init(
    id: UUID = UUID(),
    name: String,
    kind: VolumeMeasurementKind,
    points: [VolumeMeasurementPoint] = [],
    physicalExtent: SIMD3<Float>? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.points = points
    self.geometry = VolumeMeasurementGeometry(
      points: points,
      edges: [],
      triangleVertices: [],
      labelPosition: points.first?.position,
      value: nil
    )
    self.geometryRevision = UUID()
    self.physicalExtent = nil
    if let physicalExtent {
      updateGeometry(physicalExtent: physicalExtent)
    }
  }

  @discardableResult
  mutating func addPoint(
    at position: SIMD3<Float>,
    physicalExtent: SIMD3<Float>
  ) -> UUID? {
    guard Self.isFinite(position), Self.isFinite(physicalExtent) else { return nil }
    let point = VolumeMeasurementPoint(
      position: projectedPositionIfNeeded(position, physicalExtent: physicalExtent)
    )
    points.append(point)
    updateGeometry(physicalExtent: physicalExtent)
    return point.id
  }

  mutating func setPoint(
    id pointID: UUID,
    position: SIMD3<Float>,
    physicalExtent: SIMD3<Float>
  ) {
    guard Self.isFinite(position), Self.isFinite(physicalExtent) else { return }
    guard let index = points.firstIndex(where: { $0.id == pointID }) else { return }
    points[index].position = index >= 3 && kind == .area
      ? projectedPositionIfNeeded(position, physicalExtent: physicalExtent)
      : position
    updateGeometry(physicalExtent: physicalExtent)
  }

  @discardableResult
  mutating func removePoint(id pointID: UUID) -> Bool {
    let previousCount = points.count
    points.removeAll { $0.id == pointID }
    guard points.count != previousCount else { return false }
    if let physicalExtent {
      updateGeometry(physicalExtent: physicalExtent)
    } else {
      geometry = VolumeMeasurementGeometry(
        points: points,
        edges: [],
        triangleVertices: [],
        labelPosition: points.first?.position,
        value: nil
      )
      geometryRevision = UUID()
    }
    return true
  }

  func formattedValue(locale: Locale = .current) -> String? {
    guard let value = geometry.value, value.isFinite else { return nil }
    switch kind {
      case .length:
        return PhysicalSizeFormatter.length(meters: value, locale: locale)
      case .area:
        return PhysicalSizeFormatter.area(squareMeters: value, locale: locale)
      case .volume:
        return PhysicalSizeFormatter.volume(cubicMeters: value, locale: locale)
    }
  }

  mutating func updatePhysicalExtent(_ physicalExtent: SIMD3<Float>) {
    updateGeometry(physicalExtent: physicalExtent)
  }

  private mutating func updateGeometry(physicalExtent: SIMD3<Float>) {
    guard Self.isUsableExtent(physicalExtent),
          points.allSatisfy({ Self.isFinite($0.position) }) else {
      self.physicalExtent = nil
      geometry = VolumeMeasurementGeometry(
        points: points.filter { Self.isFinite($0.position) },
        edges: [],
        triangleVertices: [],
        labelPosition: nil,
        value: nil
      )
      geometryRevision = UUID()
      return
    }
    let physicalExtent = safeExtent(physicalExtent)
    self.physicalExtent = physicalExtent
    switch kind {
      case .length:
        geometry = lengthGeometry(physicalExtent: physicalExtent)
      case .area:
        geometry = areaGeometry(physicalExtent: physicalExtent)
      case .volume:
        geometry = volumeGeometry(physicalExtent: physicalExtent)
    }
    geometryRevision = UUID()
  }

  private func projectedPositionIfNeeded(
    _ position: SIMD3<Float>,
    physicalExtent: SIMD3<Float>
  ) -> SIMD3<Float> {
    guard kind == .area, points.count >= 3,
          let plane = areaPlane(physicalExtent: physicalExtent) else {
      return position
    }
    let physical = position * physicalExtent
    let projected = physical - plane.normal * simd_dot(physical - plane.origin, plane.normal)
    return projected / safeExtent(physicalExtent)
  }

  private func lengthGeometry(physicalExtent: SIMD3<Float>) -> VolumeMeasurementGeometry {
    guard points.count >= 2 else {
      return VolumeMeasurementGeometry(
        points: points,
        edges: [],
        triangleVertices: [],
        labelPosition: points.first?.position,
        value: nil
      )
    }
    let edges = (1..<points.count).map {
      VolumeMeasurementGeometry.Edge(
        start: points[$0 - 1].position,
        end: points[$0].position
      )
    }
    let segmentLengths = edges.map { edge -> Double in
      let delta = (edge.end - edge.start) * physicalExtent
      guard Self.isFinite(delta) else { return .infinity }
      return sqrt(
        Double(delta.x) * Double(delta.x) +
        Double(delta.y) * Double(delta.y) +
        Double(delta.z) * Double(delta.z)
      )
    }
    let length = segmentLengths.reduce(0, +)
    let labelPosition: SIMD3<Float>?
    if length.isFinite, length > 0 {
      let midpoint = length * 0.5
      var accumulated = 0.0
      var result = points.first?.position
      for (index, segmentLength) in segmentLengths.enumerated() {
        let next = accumulated + segmentLength
        if midpoint <= next, segmentLength > 0 {
          let fraction = Float((midpoint - accumulated) / segmentLength)
          result = edges[index].start + (edges[index].end - edges[index].start) * fraction
          break
        }
        accumulated = next
      }
      labelPosition = result
    } else {
      labelPosition = Self.averagePosition(points.map(\.position))
    }
    return VolumeMeasurementGeometry(
      points: points,
      edges: edges,
      triangleVertices: [],
      labelPosition: labelPosition,
      value: length.isFinite ? length : nil
    )
  }

  private struct AreaPlane {
    let origin: SIMD3<Float>
    let normal: SIMD3<Float>
    let u: SIMD3<Float>
    let v: SIMD3<Float>
  }

  private func areaPlane(physicalExtent: SIMD3<Float>) -> AreaPlane? {
    guard points.count >= 3 else { return nil }
    let physical = points.prefix(3).map { $0.position * physicalExtent }
    guard physical.allSatisfy({ Self.isFinite($0) }) else { return nil }
    let scale = characteristicScale(physicalExtent)
    let firstEdge = (physical[1] - physical[0]) / scale
    let secondEdge = (physical[2] - physical[0]) / scale
    let normalVector = simd_cross(firstEdge, secondEdge)
    let firstEdgeLengthSquared = simd_length_squared(firstEdge)
    let normalLengthSquared = simd_length_squared(normalVector)
    guard firstEdgeLengthSquared.isFinite, normalLengthSquared.isFinite,
          firstEdgeLengthSquared > 1e-12,
          normalLengthSquared > 1e-12 else { return nil }
    let normal = normalVector / sqrt(normalLengthSquared)
    let u = firstEdge / sqrt(firstEdgeLengthSquared)
    let vVector = simd_cross(normal, u)
    let vLengthSquared = simd_length_squared(vVector)
    guard Self.isFinite(normal), Self.isFinite(u), vLengthSquared.isFinite,
          vLengthSquared > 1e-12 else { return nil }
    return AreaPlane(
      origin: physical[0],
      normal: normal,
      u: u,
      v: vVector / sqrt(vLengthSquared)
    )
  }

  private func areaGeometry(physicalExtent: SIMD3<Float>) -> VolumeMeasurementGeometry {
    guard let plane = areaPlane(physicalExtent: physicalExtent) else {
      let edges = points.count == 2
        ? [VolumeMeasurementGeometry.Edge(start: points[0].position, end: points[1].position)]
        : []
      return VolumeMeasurementGeometry(
        points: points,
        edges: edges,
        triangleVertices: [],
        labelPosition: points.first?.position,
        value: nil
      )
    }

    let extent = safeExtent(physicalExtent)
    let projectedPhysical = points.map { point -> SIMD3<Float> in
      let physical = point.position * physicalExtent
      return physical - plane.normal * simd_dot(physical - plane.origin, plane.normal)
    }
    guard projectedPhysical.allSatisfy({ Self.isFinite($0) }) else {
      return VolumeMeasurementGeometry(
        points: points,
        edges: [],
        triangleVertices: [],
        labelPosition: nil,
        value: nil
      )
    }
    let projected2D = projectedPhysical.map {
      SIMD2<Float>(simd_dot($0 - plane.origin, plane.u), simd_dot($0 - plane.origin, plane.v))
    }
    let scale = characteristicScale(physicalExtent)
    let hull = Self.convexHull2D(projected2D.map { $0 / scale })
    let displayPoints = zip(points, projectedPhysical).map {
      VolumeMeasurementPoint(id: $0.0.id, position: $0.1 / extent)
    }
    guard hull.count >= 3 else {
      return VolumeMeasurementGeometry(
        points: displayPoints,
        edges: [],
        triangleVertices: [],
        labelPosition: displayPoints.first?.position,
        value: nil
      )
    }

    let edges = hull.indices.map { index in
      VolumeMeasurementGeometry.Edge(
        start: displayPoints[hull[index]].position,
        end: displayPoints[hull[(index + 1) % hull.count]].position
      )
    }
    var triangles: [SIMD3<Float>] = []
    for index in 1..<(hull.count - 1) {
      triangles += [
        displayPoints[hull[0]].position,
        displayPoints[hull[index]].position,
        displayPoints[hull[index + 1]].position
      ]
    }
    var signedArea = 0.0
    for index in hull.indices {
      let a = projected2D[hull[index]]
      let b = projected2D[hull[(index + 1) % hull.count]]
      signedArea += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
    }
    let labelPosition = Self.averagePosition(hull.map { displayPoints[$0].position })
    return VolumeMeasurementGeometry(
      points: displayPoints,
      edges: edges,
      triangleVertices: triangles,
      labelPosition: labelPosition,
      value: signedArea.isFinite ? abs(signedArea) * 0.5 : nil
    )
  }

  private struct Face: Hashable {
    var a: Int
    var b: Int
    var c: Int
  }

  private struct EdgeKey: Hashable {
    let low: Int
    let high: Int

    init(_ a: Int, _ b: Int) {
      low = min(a, b)
      high = max(a, b)
    }
  }

  private func volumeGeometry(physicalExtent: SIMD3<Float>) -> VolumeMeasurementGeometry {
    let physicalPoints = points.map { $0.position * physicalExtent }
    guard physicalPoints.allSatisfy({ Self.isFinite($0) }) else {
      return VolumeMeasurementGeometry(
        points: points,
        edges: [],
        triangleVertices: [],
        labelPosition: nil,
        value: nil
      )
    }
    let scale = characteristicScale(physicalExtent)
    let hullPoints = physicalPoints.map { $0 / scale }
    guard let faces = Self.convexHull3D(hullPoints) else {
      var edges: [VolumeMeasurementGeometry.Edge] = []
      if points.count >= 2 {
        edges = (1..<points.count).map {
          .init(start: points[$0 - 1].position, end: points[$0].position)
        }
        if points.count >= 3, let lastPoint = points.last, let firstPoint = points.first {
          edges.append(.init(start: lastPoint.position, end: firstPoint.position))
        }
      }
      return VolumeMeasurementGeometry(
        points: points,
        edges: edges,
        triangleVertices: [],
        labelPosition: Self.averagePosition(points.map(\.position)),
        value: nil
      )
    }

    var edgeKeys = Set<EdgeKey>()
    var edges: [VolumeMeasurementGeometry.Edge] = []
    var triangles: [SIMD3<Float>] = []
    var signedVolume = 0.0
    for face in faces {
      let indices = [face.a, face.b, face.c]
      triangles += indices.map { points[$0].position }
      let a = physicalPoints[face.a]
      let b = physicalPoints[face.b]
      let c = physicalPoints[face.c]
      let ad = SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z))
      let bd = SIMD3<Double>(Double(b.x), Double(b.y), Double(b.z))
      let cd = SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
      signedVolume += simd_dot(ad, simd_cross(bd, cd)) / 6
      for edge in [(face.a, face.b), (face.b, face.c), (face.c, face.a)] {
        let key = EdgeKey(edge.0, edge.1)
        if edgeKeys.insert(key).inserted {
          edges.append(.init(start: points[key.low].position, end: points[key.high].position))
        }
      }
    }
    let hullIndices = Set(faces.flatMap { [$0.a, $0.b, $0.c] })
    guard !hullIndices.isEmpty, signedVolume.isFinite else {
      return VolumeMeasurementGeometry(
        points: points,
        edges: [],
        triangleVertices: [],
        labelPosition: nil,
        value: nil
      )
    }
    let labelPosition = Self.averagePosition(hullIndices.map { points[$0].position })
    return VolumeMeasurementGeometry(
      points: points,
      edges: edges,
      triangleVertices: triangles,
      labelPosition: labelPosition,
      value: abs(signedVolume)
    )
  }

  private static func convexHull2D(_ points: [SIMD2<Float>]) -> [Int] {
    guard points.count >= 3, points.allSatisfy({ isFinite($0) }) else {
      return []
    }
    let sorted = points.indices.sorted {
      points[$0].x == points[$1].x
        ? points[$0].y < points[$1].y
        : points[$0].x < points[$1].x
    }
    func cross(_ o: Int, _ a: Int, _ b: Int) -> Double {
      let oa = points[a] - points[o]
      let ob = points[b] - points[o]
      return Double(oa.x) * Double(ob.y) - Double(oa.y) * Double(ob.x)
    }
    var lower: [Int] = []
    for index in sorted {
      while lower.count >= 2,
            let last = lower.last,
            cross(lower[lower.count - 2], last, index) <= 1e-10 {
        lower.removeLast()
      }
      lower.append(index)
    }
    var upper: [Int] = []
    for index in sorted.reversed() {
      while upper.count >= 2,
            let last = upper.last,
            cross(upper[upper.count - 2], last, index) <= 1e-10 {
        upper.removeLast()
      }
      upper.append(index)
    }
    lower.removeLast()
    upper.removeLast()
    return lower + upper
  }

  private static func convexHull3D(_ points: [SIMD3<Float>]) -> [Face]? {
    guard points.count >= 4, points.allSatisfy({ isFinite($0) }) else { return nil }
    let bounds = points.reduce(
      (minimum: SIMD3<Float>(repeating: .greatestFiniteMagnitude),
       maximum: SIMD3<Float>(repeating: -.greatestFiniteMagnitude))
    ) { result, point in
      (simd_min(result.minimum, point), simd_max(result.maximum, point))
    }
    let diagonal = simd_length(bounds.maximum - bounds.minimum)
    guard diagonal.isFinite, diagonal > Float.leastNormalMagnitude,
          let first = points.indices.min(by: { points[$0].x < points[$1].x }),
          let second = points.indices.max(by: {
      simd_length_squared(points[$0] - points[first]) <
        simd_length_squared(points[$1] - points[first])
          }), first != second else { return nil }
    let epsilon = max(diagonal * 1e-6, 1e-7)
    let baseline = points[second] - points[first]
    let baselineLength = simd_length(baseline)
    guard baselineLength.isFinite, baselineLength > epsilon else { return nil }
    let third = points.indices
      .filter { $0 != first && $0 != second }
      .max {
        simd_length_squared(simd_cross(baseline, points[$0] - points[first])) <
          simd_length_squared(simd_cross(baseline, points[$1] - points[first]))
      }
    guard let third else { return nil }
    let initialNormal = simd_cross(points[second] - points[first], points[third] - points[first])
    let initialNormalLength = simd_length(initialNormal)
    guard initialNormalLength.isFinite,
          initialNormalLength / baselineLength > epsilon else { return nil }
    let fourth = points.indices
      .filter { $0 != first && $0 != second && $0 != third }
      .max {
        abs(simd_dot(initialNormal, points[$0] - points[first])) <
          abs(simd_dot(initialNormal, points[$1] - points[first]))
      }
    guard let fourth else { return nil }
    let planeDistance = abs(
      simd_dot(initialNormal / initialNormalLength, points[fourth] - points[first])
    )
    guard planeDistance.isFinite, planeDistance > epsilon else {
      return nil
    }

    let interior = (points[first] + points[second] + points[third] + points[fourth]) * 0.25
    func oriented(_ a: Int, _ b: Int, _ c: Int) -> Face {
      let normal = simd_cross(points[b] - points[a], points[c] - points[a])
      return simd_dot(normal, interior - points[a]) > 0
        ? Face(a: a, b: c, c: b)
        : Face(a: a, b: b, c: c)
    }
    var faces = [
      oriented(first, second, third),
      oriented(first, fourth, second),
      oriented(second, fourth, third),
      oriented(third, fourth, first)
    ]
    let initial = Set([first, second, third, fourth])
    for pointIndex in points.indices where !initial.contains(pointIndex) {
      let visible = faces.indices.filter { faceIndex in
        let face = faces[faceIndex]
        let normal = simd_cross(
          points[face.b] - points[face.a],
          points[face.c] - points[face.a]
        )
        let normalLengthSquared = simd_length_squared(normal)
        guard normalLengthSquared.isFinite,
              normalLengthSquared > epsilon * epsilon else { return false }
        let signedDistance = simd_dot(
          normal,
          points[pointIndex] - points[face.a]
        ) / sqrt(normalLengthSquared)
        return signedDistance.isFinite && signedDistance > epsilon
      }
      guard !visible.isEmpty else { continue }
      var boundary: [EdgeKey: (Int, Int, Int)] = [:]
      for faceIndex in visible {
        let face = faces[faceIndex]
        for edge in [(face.a, face.b), (face.b, face.c), (face.c, face.a)] {
          let key = EdgeKey(edge.0, edge.1)
          if let existing = boundary[key] {
            boundary[key] = (existing.0, existing.1, existing.2 + 1)
          } else {
            boundary[key] = (edge.0, edge.1, 1)
          }
        }
      }
      let visibleSet = Set(visible)
      faces = faces.indices.compactMap { visibleSet.contains($0) ? nil : faces[$0] }
      for edge in boundary.values where edge.2 == 1 {
        faces.append(oriented(edge.0, edge.1, pointIndex))
      }
    }
    let validFaces = faces.filter { face in
      let normal = simd_cross(
        points[face.b] - points[face.a],
        points[face.c] - points[face.a]
      )
      let lengthSquared = simd_length_squared(normal)
      return lengthSquared.isFinite && lengthSquared > epsilon * epsilon
    }
    return validFaces.isEmpty ? nil : validFaces
  }

  private func characteristicScale(_ extent: SIMD3<Float>) -> Float {
    let scale = max(max(abs(extent.x), abs(extent.y)), abs(extent.z))
    return scale.isFinite ? max(scale, 1e-12) : 1
  }

  private func safeExtent(_ extent: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
      max(abs(extent.x), 1e-12),
      max(abs(extent.y), 1e-12),
      max(abs(extent.z), 1e-12)
    )
  }

  private static func isFinite(_ value: SIMD2<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite
  }

  private static func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
  }

  private static func isUsableExtent(_ value: SIMD3<Float>) -> Bool {
    isFinite(value) && value.x > 0 && value.y > 0 && value.z > 0
  }

  private static func averagePosition(_ positions: [SIMD3<Float>]) -> SIMD3<Float>? {
    guard !positions.isEmpty, positions.allSatisfy({ isFinite($0) }) else { return nil }
    let sum = positions.reduce(SIMD3<Double>.zero) { partial, position in
      partial + SIMD3<Double>(
        Double(position.x),
        Double(position.y),
        Double(position.z)
      )
    }
    let average = sum / Double(positions.count)
    guard average.x.isFinite, average.y.isFinite, average.z.isFinite,
          abs(average.x) <= Double(Float.greatestFiniteMagnitude),
          abs(average.y) <= Double(Float.greatestFiniteMagnitude),
          abs(average.z) <= Double(Float.greatestFiniteMagnitude) else { return nil }
    return SIMD3<Float>(Float(average.x), Float(average.y), Float(average.z))
  }
}
