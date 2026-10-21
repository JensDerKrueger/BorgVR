import Foundation

struct BorgVRRigidTransform: Sendable {
  let xAxis: Vec3<Float>
  let yAxis: Vec3<Float>
  let zAxis: Vec3<Float>
  let translation: Vec3<Float>

  static let identity = BorgVRRigidTransform(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1),
    translation: .zero
  )

  /// Maps a point from reference patient space back into moving patient space.
  func inverseApplying(to point: Vec3<Float>) -> Vec3<Float> {
    let translated = point - translation
    return Vec3<Float>(
      x: translated.dot(xAxis),
      y: translated.dot(yAxis),
      z: translated.dot(zAxis)
    )
  }
}

enum BorgVRDICOMRigidRegistration {
  static func register(
    reference: BorgVRUnbrickedVolume,
    moving: BorgVRUnbrickedVolume,
    logger: LoggerBase?
  ) throws -> BorgVRRigidTransform {
    guard reference.source.componentCount == 1,
          moving.source.componentCount == 1,
          reference.source.bytesPerComponent == moving.source.bytesPerComponent else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    logger?.info("Initializing rigid DICOM registration from patient-space geometry.")

    // The optimizer will refine this transform later. Both DICOM geometries already
    // use the same patient coordinate system, so identity is the correct initial value.
    return .identity
  }
}
