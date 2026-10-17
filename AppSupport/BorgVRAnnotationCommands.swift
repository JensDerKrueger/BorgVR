import Foundation
import simd

struct BorgVRMarkerPointCommandState: Codable, Equatable, Sendable {
  var position: SIMD3<Float>
  var radius: Float

  init(position: SIMD3<Float>, radius: Float) {
    self.position = position
    self.radius = radius
  }

  init(_ point: VolumeMarkerPoint) {
    position = point.position
    radius = point.radius
  }

  var markerPoint: VolumeMarkerPoint {
    VolumeMarkerPoint(position: position, radius: radius)
  }
}

struct BorgVRMarkerCommandState: Codable, Equatable, Sendable, Identifiable {
  enum Kind: String, Codable, Sendable {
    case sphere
    case stroke
  }

  var id: UUID
  var name: String
  var kind: Kind
  var color: SIMD4<Float>
  var points: [BorgVRMarkerPointCommandState]
  var directionOrigin: SIMD3<Float>?
  var showsDirection: Bool

  init(
    id: UUID,
    name: String,
    kind: Kind,
    color: SIMD4<Float>,
    points: [BorgVRMarkerPointCommandState],
    directionOrigin: SIMD3<Float>?,
    showsDirection: Bool
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.color = color
    self.points = points
    self.directionOrigin = directionOrigin
    self.showsDirection = showsDirection
  }

  init(_ marker: VolumeMarker) {
    id = marker.id
    name = marker.name
    kind = marker.kind == .sphere ? .sphere : .stroke
    color = marker.color
    points = marker.points.map(BorgVRMarkerPointCommandState.init)
    directionOrigin = marker.directionOrigin
    showsDirection = marker.showsDirection
  }

  func marker() throws -> VolumeMarker {
    guard color.isFinite,
          color.x >= 0, color.x <= 1,
          color.y >= 0, color.y <= 1,
          color.z >= 0, color.z <= 1,
          color.w >= 0, color.w <= 1,
          !points.isEmpty,
          points.allSatisfy({ $0.position.isFinite && $0.radius.isFinite }) else {
      throw BorgVRSessionCommandError.invalidAnnotation
    }
    switch kind {
      case .sphere:
        guard points.count == 1,
              VolumeMarkerRadius.sphereRange.contains(points[0].radius) else {
          throw BorgVRSessionCommandError.invalidAnnotation
        }
        let origin = directionOrigin ?? points[0].position
        guard origin.isFinite else { throw BorgVRSessionCommandError.invalidAnnotation }
        return VolumeMarker(
          id: id,
          name: name,
          position: points[0].position,
          radius: points[0].radius,
          color: color,
          directionOrigin: origin,
          showsDirection: showsDirection && directionOrigin != nil
        )
      case .stroke:
        guard points.count <= VolumeMarker.maximumInteractiveStrokePointCount,
              points.allSatisfy({ VolumeMarkerRadius.strokeRange.contains($0.radius) }) else {
          throw BorgVRSessionCommandError.invalidAnnotation
        }
        return VolumeMarker(
          id: id,
          name: name,
          color: color,
          geometry: .stroke(points.map(\.markerPoint))
        )
    }
  }
}

struct BorgVRMeshInstanceCommandState: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var assetID: UUID
  var name: String
  var translationMeters: SIMD3<Float>
  var rotation: SIMD4<Float>
  var scale: SIMD3<Float>
  var isVisible: Bool

  init(
    id: UUID,
    assetID: UUID,
    name: String,
    translationMeters: SIMD3<Float>,
    rotation: SIMD4<Float>,
    scale: SIMD3<Float>,
    isVisible: Bool
  ) {
    self.id = id
    self.assetID = assetID
    self.name = name
    self.translationMeters = translationMeters
    self.rotation = rotation
    self.scale = scale
    self.isVisible = isVisible
  }

  init(_ instance: SceneMeshInstance) {
    id = instance.id
    assetID = instance.asset.assetID
    name = instance.name
    translationMeters = instance.translationMeters
    rotation = instance.rotation.vector
    scale = instance.scale
    isVisible = instance.isVisible
  }

  func instance(asset: SceneMeshAsset) throws -> SceneMeshInstance {
    guard asset.id == assetID,
          translationMeters.isFinite,
          rotation.isFinite,
          simd_length_squared(rotation) > 0.000_001,
          scale.isFinite,
          scale.x > 0, scale.y > 0, scale.z > 0 else {
      throw BorgVRSessionCommandError.invalidAnnotation
    }
    return SceneMeshInstance(
      id: id,
      name: name,
      asset: asset.reference,
      translationMeters: translationMeters,
      rotation: simd_normalize(simd_quatf(vector: rotation)),
      scale: scale,
      isVisible: isVisible
    )
  }
}

enum BorgVRObjectCommandState: Encodable, Equatable, Sendable, Identifiable {
  case marker(BorgVRMarkerCommandState)
  case mesh(BorgVRMeshInstanceCommandState)

  private enum CodingKeys: String, CodingKey {
    case type
    case marker
    case mesh
  }

  private enum ObjectType: String, Encodable {
    case marker
    case mesh
  }

  var id: UUID {
    switch self {
      case .marker(let marker): marker.id
      case .mesh(let mesh): mesh.id
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
      case .marker(let marker):
        try container.encode(ObjectType.marker, forKey: .type)
        try container.encode(marker, forKey: .marker)
      case .mesh(let mesh):
        try container.encode(ObjectType.mesh, forKey: .type)
        try container.encode(mesh, forKey: .mesh)
    }
  }
}

struct BorgVRMeasurementPointCommandState: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var position: SIMD3<Float>

  init(id: UUID, position: SIMD3<Float>) {
    self.id = id
    self.position = position
  }

  init(_ point: VolumeMeasurementPoint) {
    id = point.id
    position = point.position
  }
}

struct BorgVRMeasurementCommandState: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var name: String
  var kind: VolumeMeasurementKind
  var points: [BorgVRMeasurementPointCommandState]

  init(
    id: UUID,
    name: String,
    kind: VolumeMeasurementKind,
    points: [BorgVRMeasurementPointCommandState]
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.points = points
  }

  init(_ measurement: VolumeMeasurement) {
    id = measurement.id
    name = measurement.name
    kind = measurement.kind
    points = measurement.points.map(BorgVRMeasurementPointCommandState.init)
  }

  func measurement(physicalExtent: SIMD3<Float>?) throws -> VolumeMeasurement {
    guard points.count <= BorgVRMeasurementFormat.maximumPointCount,
          points.allSatisfy({ $0.position.isFinite }) else {
      throw BorgVRSessionCommandError.invalidAnnotation
    }
    return VolumeMeasurement(
      id: id,
      name: name,
      kind: kind,
      points: points.map { VolumeMeasurementPoint(id: $0.id, position: $0.position) },
      physicalExtent: physicalExtent
    )
  }
}

struct BorgVRAnnotationSnapshot: Equatable, Sendable {
  var objects: [BorgVRObjectCommandState]
  var measurements: [BorgVRMeasurementCommandState]

  static let empty = BorgVRAnnotationSnapshot(objects: [], measurements: [])

  init(
    markers: [VolumeMarker],
    meshInstances: [SceneMeshInstance],
    measurements: [VolumeMeasurement]
  ) {
    objects = markers.map { .marker(BorgVRMarkerCommandState($0)) }
      + meshInstances.map { .mesh(BorgVRMeshInstanceCommandState($0)) }
    self.measurements = measurements.map(BorgVRMeasurementCommandState.init)
  }

  init(
    objects: [BorgVRObjectCommandState],
    measurements: [BorgVRMeasurementCommandState]
  ) {
    self.objects = objects
    self.measurements = measurements
  }
}

struct BorgVRMeshAssetCommandState: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var name: String
  var description: String
  var boundsMinimum: SIMD3<Float>
  var boundsMaximum: SIMD3<Float>

  init(_ asset: SceneMeshAsset) {
    id = asset.id
    name = asset.name
    description = asset.assetDescription
    boundsMinimum = asset.boundsMinimum
    boundsMaximum = asset.boundsMaximum
  }
}

extension BorgVRObjectCommandState {
  var gscStatement: String {
    switch self {
      case .marker(let marker):
        let color = marker.color
        switch marker.kind {
          case .sphere:
            let point = marker.points[0]
            let origin = marker.directionOrigin ?? point.position
            return [
              "setspheremarker",
              gscQuote(marker.id.uuidString),
              gscQuote(marker.name),
              gscFloat(point.position.x), gscFloat(point.position.y), gscFloat(point.position.z),
              gscFloat(point.radius),
              gscFloat(color.x), gscFloat(color.y), gscFloat(color.z), gscFloat(color.w),
              marker.showsDirection && marker.directionOrigin != nil ? "true" : "false",
              gscFloat(origin.x), gscFloat(origin.y), gscFloat(origin.z)
            ].joined(separator: " ")
          case .stroke:
            let points = marker.points.flatMap { point in
              [
                gscFloat(point.position.x), gscFloat(point.position.y),
                gscFloat(point.position.z), gscFloat(point.radius)
              ]
            }
            return ([
              "setstrokemarker",
              gscQuote(marker.id.uuidString),
              gscQuote(marker.name),
              gscFloat(color.x), gscFloat(color.y), gscFloat(color.z), gscFloat(color.w)
            ] + points).joined(separator: " ")
        }
      case .mesh(let mesh):
        return [
          "setmeshinstance",
          gscQuote(mesh.id.uuidString),
          gscQuote(mesh.assetID.uuidString),
          gscQuote(mesh.name),
          gscFloat(mesh.translationMeters.x), gscFloat(mesh.translationMeters.y),
          gscFloat(mesh.translationMeters.z),
          gscFloat(mesh.rotation.x), gscFloat(mesh.rotation.y),
          gscFloat(mesh.rotation.z), gscFloat(mesh.rotation.w),
          gscFloat(mesh.scale.x), gscFloat(mesh.scale.y), gscFloat(mesh.scale.z),
          mesh.isVisible ? "true" : "false"
        ].joined(separator: " ")
    }
  }
}

extension BorgVRMeasurementCommandState {
  var gscStatement: String {
    let encodedPoints = points.flatMap { point in
      [
        gscQuote(point.id.uuidString),
        gscFloat(point.position.x), gscFloat(point.position.y), gscFloat(point.position.z)
      ]
    }
    return ([
      "setmeasurement",
      gscQuote(id.uuidString),
      kind.rawValue,
      gscQuote(name)
    ] + encodedPoints).joined(separator: " ")
  }
}

func gscQuote(_ value: String) -> String {
  let escaped = value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  return "\"\(escaped)\""
}

func gscFloat(_ value: Float) -> String {
  String(value)
}

private extension SIMD3 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension SIMD4 where Scalar == Float {
  var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
