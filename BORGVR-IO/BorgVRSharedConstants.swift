import Foundation
import simd

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
  static let renderStateVersion: UInt16 = 5
  static let markerVersion: UInt16 = 3

  enum PacketKind: UInt8 {
    case commonRenderState = 1
    case screenTransform = 2
    case visionTransform = 3
    case volumeMarkers = 4
    case spatialStylusPreview = 5
  }
}

struct BorgVRLightingState: Equatable, Sendable {
  static let defaultDirection = SIMD3<Float>(0, 0, 1)
  static let defaultAmbientColor = SIMD3<Float>(repeating: 0.1)
  static let defaultDiffuseColor = SIMD3<Float>(repeating: 0.5)
  static let defaultSpecularColor = SIMD3<Float>(repeating: 0.8)

  var direction: SIMD3<Float>
  var ambientColor: SIMD3<Float>
  var diffuseColor: SIMD3<Float>
  var specularColor: SIMD3<Float>

  static let `default` = BorgVRLightingState(
    direction: defaultDirection,
    ambientColor: defaultAmbientColor,
    diffuseColor: defaultDiffuseColor,
    specularColor: defaultSpecularColor
  )

  var sanitized: BorgVRLightingState {
    let safeDirection: SIMD3<Float>
    if direction.x.isFinite,
       direction.y.isFinite,
       direction.z.isFinite,
       simd_length_squared(direction) > 0.000_001 {
      safeDirection = simd_normalize(direction)
    } else {
      safeDirection = Self.defaultDirection
    }

    return BorgVRLightingState(
      direction: safeDirection,
      ambientColor: Self.sanitizeColor(ambientColor, fallback: Self.defaultAmbientColor),
      diffuseColor: Self.sanitizeColor(diffuseColor, fallback: Self.defaultDiffuseColor),
      specularColor: Self.sanitizeColor(specularColor, fallback: Self.defaultSpecularColor)
    )
  }

  private static func sanitizeColor(
    _ color: SIMD3<Float>,
    fallback: SIMD3<Float>
  ) -> SIMD3<Float> {
    guard color.x.isFinite, color.y.isFinite, color.z.isFinite else {
      return fallback
    }
    return simd_clamp(color, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
  }
}

enum BorgVRSharePlayPlatform: UInt8, Codable {
  case iOS = 1
  case macOS = 2
  case visionOS = 3

  var systemImage: String {
    switch self {
      case .iOS: return "iphone"
      case .macOS: return "desktopcomputer"
      case .visionOS: return "visionpro"
    }
  }
}

struct BorgVRSharePlayParticipantInfo: Codable, Equatable, Sendable {
  static let maximumDisplayNameLength = 80

  let platform: BorgVRSharePlayPlatform
  let displayName: String
  let sharesScreenView: Bool

  init(
    platform: BorgVRSharePlayPlatform,
    displayName: String,
    sharesScreenView: Bool = false
  ) {
    self.platform = platform
    self.displayName = String(
      displayName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(Self.maximumDisplayNameLength)
    )
    self.sharesScreenView = sharesScreenView
  }
}

struct BorgVRSharePlayParticipant: Identifiable, Equatable, Sendable {
  let id: UUID
  let info: BorgVRSharePlayParticipantInfo

  var displayName: String { info.displayName }
  var platform: BorgVRSharePlayPlatform { info.platform }
}

enum BorgVRSharePlayParticipantInfoCodec {
  static func encode(_ info: BorgVRSharePlayParticipantInfo) throws -> Data {
    try JSONEncoder().encode(info)
  }

  static func decode(_ data: Data) throws -> BorgVRSharePlayParticipantInfo {
    guard data.count <= 1_024 else {
      throw BorgVRSharePlayProtocolError.invalidParticipantInfo
    }
    let info = try JSONDecoder().decode(BorgVRSharePlayParticipantInfo.self, from: data)
    guard !info.displayName.isEmpty else {
      throw BorgVRSharePlayProtocolError.invalidParticipantInfo
    }
    return info
  }
}

struct BorgVRSharePlayHostClaim: Codable, Equatable, Sendable {
  let term: UInt64
  let candidateID: UUID
}

struct BorgVRSharePlayHostState: Codable, Equatable, Sendable {
  let term: UInt64
  let hostID: UUID
}

enum BorgVRSharePlayHostCodec {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    guard data.count <= 1_024 else {
      throw BorgVRSharePlayProtocolError.invalidParticipantInfo
    }
    return try JSONDecoder().decode(type, from: data)
  }
}

struct BorgVRScreenViewState: Equatable, Sendable {
  static let cameraDistance: Float = 2.4
  static let defaultVerticalFieldOfView: Float = .pi / 4

  var orientation: simd_quatf
  var scale: Float
  var pan: SIMD2<Float>
  var viewportAspectRatio: Float
  var verticalFieldOfView: Float

  init(
    orientation: simd_quatf,
    scale: Float,
    pan: SIMD2<Float>,
    viewportAspectRatio: Float,
    verticalFieldOfView: Float = defaultVerticalFieldOfView
  ) {
    self.orientation = orientation
    self.scale = scale
    self.pan = pan
    self.viewportAspectRatio = viewportAspectRatio
    self.verticalFieldOfView = verticalFieldOfView
  }
}

struct BorgVRScreenViewUpdate: Equatable, Sendable {
  let state: BorgVRScreenViewState
  let isShared: Bool
}

enum BorgVRScreenViewStateCodec {
  private static let sharedViewFlag: UInt8 = 1 << 0

  static func encode(_ state: BorgVRScreenViewState, isShared: Bool = true) -> Data {
    var writer = BorgVRSharePlayDataWriter()
    writer.write(BorgVRSharePlayProtocol.magic)
    writer.write(BorgVRSharePlayProtocol.renderStateVersion)
    writer.write(BorgVRSharePlayProtocol.PacketKind.screenTransform.rawValue)
    writer.write(isShared ? sharedViewFlag : UInt8(0))
    writer.write(state.orientation.vector.x)
    writer.write(state.orientation.vector.y)
    writer.write(state.orientation.vector.z)
    writer.write(state.orientation.vector.w)
    writer.write(state.scale)
    writer.write(state.pan.x)
    writer.write(state.pan.y)
    writer.write(state.viewportAspectRatio)
    writer.write(state.verticalFieldOfView)
    return writer.data
  }

  static func decodeUpdateIfPresent(_ data: Data) throws -> BorgVRScreenViewUpdate? {
    var reader = BorgVRSharePlayDataReader(data)
    let magic: UInt32 = try reader.read()
    guard magic == BorgVRSharePlayProtocol.magic else { return nil }
    let version: UInt16 = try reader.read()
    guard version == BorgVRSharePlayProtocol.renderStateVersion else {
      throw BorgVRSharePlayProtocolError.unsupportedVersion(version)
    }
    let packetKind: UInt8 = try reader.read()
    guard packetKind == BorgVRSharePlayProtocol.PacketKind.screenTransform.rawValue else {
      return nil
    }
    let flags: UInt8 = try reader.read()
    let orientation = simd_quatf(vector: SIMD4<Float>(
      try reader.read(),
      try reader.read(),
      try reader.read(),
      try reader.read()
    ))
    let state = BorgVRScreenViewState(
      orientation: simd_normalize(orientation),
      scale: try reader.read(),
      pan: SIMD2<Float>(try reader.read(), try reader.read()),
      viewportAspectRatio: try reader.read(),
      verticalFieldOfView: try reader.read()
    )
    guard reader.isAtEnd,
          state.orientation.vector.x.isFinite,
          state.orientation.vector.y.isFinite,
          state.orientation.vector.z.isFinite,
          state.orientation.vector.w.isFinite,
          state.scale.isFinite,
          state.scale > 0,
          state.pan.x.isFinite,
          state.pan.y.isFinite,
          state.viewportAspectRatio.isFinite,
          state.viewportAspectRatio > 0,
          state.verticalFieldOfView.isFinite,
          state.verticalFieldOfView > 0,
          state.verticalFieldOfView < .pi else {
      throw BorgVRSharePlayProtocolError.invalidScreenViewState
    }
    return BorgVRScreenViewUpdate(
      state: state,
      isShared: (flags & sharedViewFlag) != 0
    )
  }

  static func decodeIfPresent(_ data: Data) throws -> BorgVRScreenViewState? {
    try decodeUpdateIfPresent(data)?.state
  }
}

enum BorgVRSharePlayProtocolError: Error {
  case unexpectedEnd
  case unsupportedVersion(UInt16)
  case invalidParticipantInfo
  case invalidScreenViewState
}

private struct BorgVRSharePlayDataWriter {
  private(set) var data = Data()

  mutating func write<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func write(_ value: Float) {
    write(value.bitPattern)
  }
}

private struct BorgVRSharePlayDataReader {
  private let data: Data
  private var offset = 0

  init(_ data: Data) {
    self.data = data
  }

  var isAtEnd: Bool { offset == data.count }

  mutating func read<T: FixedWidthInteger>() throws -> T {
    let size = MemoryLayout<T>.size
    guard offset + size <= data.count else {
      throw BorgVRSharePlayProtocolError.unexpectedEnd
    }
    var value: T = 0
    _ = withUnsafeMutableBytes(of: &value) { destination in
      data.copyBytes(to: destination, from: offset..<(offset + size))
    }
    offset += size
    return T(littleEndian: value)
  }

  mutating func read() throws -> Float {
    Float(bitPattern: try read())
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
