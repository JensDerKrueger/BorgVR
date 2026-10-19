import Foundation

struct SpatialToolPreview: Sendable {}

enum SpatialToolPreviewSharePlayCodec {
  static func decodeIfPresent(_ data: Data) throws -> [SpatialToolPreview]? { nil }
}

struct VolumeMarkerSharePlayContents: Sendable {}

enum VolumeMarkerSharePlayCodec {
  static func decodeIfPresent(_ data: Data) throws -> VolumeMarkerSharePlayContents? { nil }
}

struct VolumeMeasurement: Sendable {}

enum VolumeMeasurementSharePlayCodec {
  static func decodeIfPresent(_ data: Data) throws -> [VolumeMeasurement]? { nil }
}
