import Foundation

enum BorgVRTransferFunctionFormat {
  static let magicBytes = [UInt8]("BTF1".utf8)
  static let version: UInt32 = 2
  static let extendedHeaderByteCount = 16
  static let bytesPerEntry = 4
  static let maximumEntryCount = 1 << 16
  static let maximumDescriptionByteCount = 64 * 1024
  static let maximumFileByteCount =
    extendedHeaderByteCount + maximumDescriptionByteCount + maximumEntryCount * bytesPerEntry
}

enum BorgVRMarkerFormat {
  static let fileExtension = "marker"
  static let defaultFilename = "BorgVR Markers.marker"
  static let magicBytes = [UInt8]("BVRMARKR".utf8)
  static let version: UInt16 = 2
  static let headerByteCount = 32
  static let maximumFileByteCount = 64 * 1024 * 1024
  static let maximumMarkerCount = 100_000
  static let maximumPointCount = 1_000_000
  static let maximumNameCharacterCount = 80
  static let maximumNameByteCount = 512
  static let positionFallback: Float = 0.5
  static let positionRange: ClosedRange<Float> = -8...8
}

enum BorgVRSharePlayProtocol {
  static let magic: UInt32 = 0x4256_5350 // "BVSP"
  static let renderStateVersion: UInt16 = 2
  static let markerVersion: UInt16 = 3

  enum PacketKind: UInt8 {
    case commonRenderState = 1
    case screenTransform = 2
    case visionTransform = 3
    case volumeMarkers = 4
    case spatialStylusPreview = 5
  }
}

enum BorgVRServerProtocol {
  static let authenticationMinimumVersionName = "3"
  static let currentVersionName = "4"
  static let markerFilesMinimumVersion = 4
}

enum BorgVRSharedDefaults {
  static let brickSize = 64
  static let brickOverlap = 2
  static let compressionEnabled = true
  static let borderMode = "zeroes"
  static let datasetServerPort = 12_345
  static let sharePlayServerPort = 12_346
  static let webServerPort = 443
  static let sharePlayWebServerPort = 444
  static let maximumBricksPerRequest = 20
}
