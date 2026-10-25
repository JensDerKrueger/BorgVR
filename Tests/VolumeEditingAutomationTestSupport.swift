import Foundation

// Only the preview DTOs are substituted; tests use the real edit model and I/O.
struct VolumeMarkerPoint {
  var position: SIMD3<Float>
  var radius: Float
}

struct VolumeMarker {
  enum Geometry { case stroke([VolumeMarkerPoint]) }
  let id: UUID
  let name: String
  let color: SIMD4<Float>
  let geometry: Geometry
}
