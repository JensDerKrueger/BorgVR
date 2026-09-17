import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import simd

extension UTType {
  static let borgVRMarker = UTType(
    exportedAs: "de.uni-due.borgvr.marker",
    conformingTo: .data
  )
}

struct VolumeMarkerPoint: Equatable {
  var position: SIMD3<Float>
  var radius: Float
}

enum VolumeMarkerGeometry: Equatable {
  case sphere(VolumeMarkerPoint)
  case stroke([VolumeMarkerPoint])
}

enum VolumeMarkerKind: UInt8 {
  case sphere = 1
  case stroke = 2
}

struct VolumeMarker: Identifiable, Equatable {
  static let strokePointSpacingDiameterFactor: Float = 0.35
  static let maximumInteractiveStrokePointCount = 100_000

  var id: UUID
  var name: String
  var color: SIMD4<Float>
  var geometry: VolumeMarkerGeometry

  init(
    id: UUID,
    name: String,
    position: SIMD3<Float>,
    radius: Float,
    color: SIMD4<Float>
  ) {
    self.id = id
    self.name = name
    self.color = color
    geometry = .sphere(VolumeMarkerPoint(position: position, radius: radius))
  }

  init(
    id: UUID,
    name: String,
    color: SIMD4<Float>,
    geometry: VolumeMarkerGeometry
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.geometry = geometry
  }

  static func stroke(
    id: UUID = UUID(),
    name: String,
    firstPoint: VolumeMarkerPoint,
    color: SIMD4<Float>
  ) -> VolumeMarker {
    VolumeMarker(id: id, name: name, color: color, geometry: .stroke([firstPoint]))
  }

  var kind: VolumeMarkerKind {
    switch geometry {
      case .sphere: .sphere
      case .stroke: .stroke
    }
  }

  var points: [VolumeMarkerPoint] {
    switch geometry {
      case .sphere(let point): [point]
      case .stroke(let points): points
    }
  }

  var position: SIMD3<Float> {
    get {
      let markerPoints = points
      guard !markerPoints.isEmpty else { return SIMD3<Float>(repeating: 0.5) }
      return markerPoints.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(markerPoints.count)
    }
    set {
      translate(by: newValue - position)
    }
  }

  var radius: Float {
    get {
      let markerPoints = points
      guard !markerPoints.isEmpty else { return 0.08 }
      return markerPoints.reduce(0) { $0 + $1.radius } / Float(markerPoints.count)
    }
    set {
      let oldRadius = max(radius, 0.000_001)
      scaleRadii(by: newValue / oldRadius)
    }
  }

  mutating func translate(by offset: SIMD3<Float>) {
    geometry = geometry.mapPoints { point in
      VolumeMarkerPoint(position: point.position + offset, radius: point.radius)
    }
  }

  mutating func scaleRadii(by factor: Float) {
    geometry = geometry.mapPoints { point in
      VolumeMarkerPoint(position: point.position, radius: point.radius * factor)
    }
  }

  @discardableResult
  mutating func appendStrokePoint(
    _ point: VolumeMarkerPoint,
    spacingDiameterFactor: Float = VolumeMarker.strokePointSpacingDiameterFactor,
    coordinateScale: SIMD3<Float> = .one
  ) -> Bool {
    guard case .stroke(var points) = geometry,
          points.count < Self.maximumInteractiveStrokePointCount,
          let previousPoint = points.last else {
      return false
    }
    let diameter = max(previousPoint.radius, point.radius) * 2
    let minimumDistance = max(0, spacingDiameterFactor) * diameter
    let scaledOffset = (point.position - previousPoint.position) * coordinateScale
    guard simd_length(scaledOffset) >= minimumDistance else {
      return false
    }
    points.append(point)
    geometry = .stroke(points)
    return true
  }
}

private extension VolumeMarkerGeometry {
  func mapPoints(_ transform: (VolumeMarkerPoint) -> VolumeMarkerPoint) -> Self {
    switch self {
      case .sphere(let point): .sphere(transform(point))
      case .stroke(let points): .stroke(points.map(transform))
    }
  }
}

struct VolumeMarkerDocument: FileDocument {
  // Header: magic, UInt16 version, UInt16 flags, dataset UUID; marker payload follows.
  static let maximumFileByteCount = 64 * 1024 * 1024
  static let fileMagic = Data("BVRMARKR".utf8)
  static let fileVersion: UInt16 = 1
  static var readableContentTypes: [UTType] { [.borgVRMarker] }
  static var writableContentTypes: [UTType] { [.borgVRMarker] }

  let datasetID: String?
  let markers: [VolumeMarker]

  init(datasetID: String?, markers: [VolumeMarker]) {
    self.datasetID = datasetID
    self.markers = markers
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let contents = try Self.decode(from: data)
    datasetID = contents.datasetID
    markers = contents.markers
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    guard let datasetID, let datasetUUID = UUID(uuidString: datasetID) else {
      throw VolumeMarkerDocumentError.invalidFormat
    }
    var writer = MarkerDataWriter()
    writer.writeBytes(Self.fileMagic)
    writer.write(Self.fileVersion)
    writer.write(UInt16(0))
    writer.writeUUID(datasetUUID)
    try VolumeMarkerBinaryCodec.encode(markers, to: &writer)
    guard writer.data.count <= Self.maximumFileByteCount else {
      throw VolumeMarkerDocumentError.fileTooLarge
    }
    return .init(regularFileWithContents: writer.data)
  }

  static func decode(from data: Data) throws -> VolumeMarkerDocumentContents {
    guard data.count <= maximumFileByteCount else {
      throw VolumeMarkerDocumentError.fileTooLarge
    }
    var reader = MarkerDataReader(data)
    guard try reader.readBytes(count: fileMagic.count) == fileMagic else {
      throw VolumeMarkerDocumentError.invalidFormat
    }
    let version: UInt16 = try reader.read()
    guard version == fileVersion else {
      throw VolumeMarkerDocumentError.unsupportedVersion(Int(version))
    }
    _ = try reader.read() as UInt16
    let datasetID = try reader.readUUID().uuidString
    let markers = try VolumeMarkerBinaryCodec.decode(from: &reader)
    guard reader.isAtEnd else {
      throw VolumeMarkerDocumentError.invalidFormat
    }
    return VolumeMarkerDocumentContents(
      datasetID: datasetID,
      markers: markers
    )
  }

  static func decodeMarkers(from data: Data) throws -> [VolumeMarker] {
    try decode(from: data).markers
  }
}

struct VolumeMarkerDocumentContents {
  let datasetID: String
  let markers: [VolumeMarker]
}

enum VolumeMarkerDocumentError: LocalizedError {
  case invalidFormat
  case unsupportedVersion(Int)
  case fileTooLarge
  case tooManyMarkers
  case tooManyPoints
  case invalidGeometry

  var errorDescription: String? {
    switch self {
      case .invalidFormat:
        return NSLocalizedString(
          "The selected file is not a BorgVR marker file.",
          comment: "Marker file validation error"
        )
      case .unsupportedVersion(let version):
        return String(
          format: NSLocalizedString(
            "Unsupported marker file version %d.",
            comment: "Marker file validation error with the unsupported version number"
          ),
          version
        )
      case .fileTooLarge:
        return NSLocalizedString(
          "The marker file exceeds the maximum supported size.",
          comment: "Marker file validation error"
        )
      case .tooManyMarkers:
        return NSLocalizedString(
          "The marker file contains too many markers.",
          comment: "Marker file validation error"
        )
      case .tooManyPoints:
        return NSLocalizedString(
          "The marker file contains too many geometry points.",
          comment: "Marker file validation error"
        )
      case .invalidGeometry:
        return NSLocalizedString(
          "The marker file contains invalid marker geometry.",
          comment: "Marker file validation error"
        )
    }
  }
}

struct VolumeMarkerCatalogEntry: Identifiable, Equatable {
  enum Source: Equatable {
    case cached
    case local
  }

  let id: String
  let datasetID: String
  let description: String
  let url: URL
  let source: Source

  var displayName: String {
    let value = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? url.deletingPathExtension().lastPathComponent : value
  }

  func matches(datasetID: String?) -> Bool {
    guard let datasetID else { return false }
    return self.datasetID.caseInsensitiveCompare(datasetID) == .orderedSame
  }
}

enum VolumeMarkerCatalog {
  static let didChangeNotification = Notification.Name("VolumeMarkerCatalogDidChange")
  static let storageDirectoryName = "Markers"
  static let remoteMarkerByteLimit = 64 * 1024 * 1024

  static func storageDirectoryURL(logger: LoggerBase? = nil) -> URL? {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else { return nil }
    let directoryURL = documentsURL.appendingPathComponent(storageDirectoryName, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      return directoryURL
    } catch {
      logger?.warning("Marker directory unavailable: \(error.localizedDescription)")
      return nil
    }
  }

  static func entries(
    additionalDirectoryURLs: [URL] = [],
    currentDatasetID: String?,
    logger: LoggerBase? = nil
  ) -> [VolumeMarkerCatalogEntry] {
    var directories = additionalDirectoryURLs
    if let storageURL = storageDirectoryURL(logger: logger) {
      directories.insert(storageURL, at: 0)
    }
    var seenURLs = Set<String>()
    var seenIDs = Set<String>()
    var result: [VolumeMarkerCatalogEntry] = []
    for (index, directory) in directories.enumerated() {
      guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      ) else { continue }
      for url in urls where url.pathExtension.lowercased() == "marker" {
        let path = url.standardizedFileURL.path
        guard seenURLs.insert(path).inserted else { continue }
        do {
          let data = try Data(contentsOf: url, options: .mappedIfSafe)
          let contents = try VolumeMarkerDocument.decode(from: data)
          let id = identifier(for: data)
          guard seenIDs.insert(id).inserted else { continue }
          result.append(
            VolumeMarkerCatalogEntry(
              id: id,
              datasetID: contents.datasetID,
              description: url.deletingPathExtension().lastPathComponent,
              url: url,
              source: index == 0 ? .cached : .local
            )
          )
        } catch {
          logger?.warning("Ignoring marker file \(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
    }
    return result.sorted { lhs, rhs in
      let lhsMatches = lhs.matches(datasetID: currentDatasetID)
      let rhsMatches = rhs.matches(datasetID: currentDatasetID)
      if lhsMatches != rhsMatches { return lhsMatches }
      return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
  }

  static func storeRemoteMarkerFiles(
    from manager: BORGVRRemoteDataManager,
    byteLimit: Int = remoteMarkerByteLimit,
    logger: LoggerBase? = nil
  ) throws -> Int {
    guard manager.supportsMarkerFiles,
          byteLimit > 0,
          let directoryURL = storageDirectoryURL(logger: logger) else { return 0 }
    let remoteFiles = try manager.requestMarkerFileList()
    var existingIDs = Set(entries(currentDatasetID: nil, logger: logger).map(\.id))
    var transferredBytes = 0
    var storedCount = 0
    for remoteFile in remoteFiles where !existingIDs.contains(remoteFile.id) {
      guard remoteFile.byteCount <= remoteMarkerByteLimit,
            transferredBytes + remoteFile.byteCount <= byteLimit else {
        logger?.warning("Marker sync limit reached before \(remoteFile.id).")
        break
      }
      let data = try manager.requestMarkerFile(id: remoteFile.id)
      guard identifier(for: data) == remoteFile.id else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Marker file ID mismatch for \(remoteFile.id).")
      }
      let contents = try VolumeMarkerDocument.decode(from: data)
      guard contents.datasetID.caseInsensitiveCompare(remoteFile.datasetID) == .orderedSame else {
        throw BORGVRRemoteDataManagerError.invalidResponse(reason: "Marker dataset ID mismatch for \(remoteFile.id).")
      }
      let filename = sanitizedFilename(remoteFile.description, fallback: remoteFile.id)
      var targetURL = directoryURL.appendingPathComponent(filename).appendingPathExtension("marker")
      if FileManager.default.fileExists(atPath: targetURL.path) {
        targetURL = directoryURL
          .appendingPathComponent("\(filename)-\(remoteFile.id)")
          .appendingPathExtension("marker")
      }
      try data.write(to: targetURL, options: .atomic)
      transferredBytes += data.count
      storedCount += 1
      existingIDs.insert(remoteFile.id)
    }
    if storedCount > 0 {
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
    return storedCount
  }

  static func identifier(for data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func sanitizedFilename(_ value: String, fallback: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
    let components = value.components(separatedBy: invalid)
    let cleaned = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    return String((cleaned.isEmpty ? fallback : cleaned).prefix(120))
  }
}

enum VolumeMarkerSharePlayCodec {
  private static let sharePlayMagic: UInt32 = 0x4256_5350 // "BVSP"
  private static let sharePlayVersion: UInt16 = 2
  private static let packetKind: UInt8 = 4

  static func encode(_ markers: [VolumeMarker]) -> Data {
    var writer = MarkerDataWriter()
    writer.write(sharePlayMagic)
    writer.write(sharePlayVersion)
    writer.write(packetKind)
    writer.write(UInt8(0))
    do {
      try VolumeMarkerBinaryCodec.encode(markers, to: &writer)
    } catch {
      assertionFailure("Unable to encode volume markers: \(error.localizedDescription)")
      writer.write(UInt32(0))
    }
    return writer.data
  }

  /// Returns `nil` when the data is a different SharePlay packet kind.
  static func decodeIfPresent(_ data: Data) throws -> [VolumeMarker]? {
    var reader = MarkerDataReader(data)
    let magic: UInt32 = try reader.read()
    guard magic == sharePlayMagic else { return nil }
    let version: UInt16 = try reader.read()
    let packet: UInt8 = try reader.read()
    _ = try reader.read() as UInt8
    guard packet == packetKind else { return nil }
    guard version == sharePlayVersion else {
      throw VolumeMarkerCodecError.unsupportedVersion(version)
    }

    let markers = try VolumeMarkerBinaryCodec.decode(from: &reader)

    guard reader.isAtEnd else {
      throw VolumeMarkerCodecError.trailingBytes(reader.remainingCount())
    }
    return markers
  }
}

enum VolumeMarkerBinaryCodec {
  // Each marker stores kind, UUID, name, RGBA, point count, then xyz/radius points.
  static let maximumMarkerCount = 100_000
  static let maximumPointCount = 1_000_000
  private static let maximumNameByteCount = 512

  static func encode(_ markers: [VolumeMarker], to writer: inout MarkerDataWriter) throws {
    guard markers.count <= maximumMarkerCount else {
      throw VolumeMarkerDocumentError.tooManyMarkers
    }
    let pointCount = markers.reduce(0) { $0 + $1.points.count }
    guard pointCount <= maximumPointCount else {
      throw VolumeMarkerDocumentError.tooManyPoints
    }
    guard markers.allSatisfy({ marker in
      let points = marker.points
      return !points.isEmpty && (marker.kind != .sphere || points.count == 1)
    }) else {
      throw VolumeMarkerDocumentError.invalidGeometry
    }

    writer.write(UInt32(markers.count))
    for marker in markers {
      let points = marker.points
      writer.write(marker.kind.rawValue)
      writer.write(UInt8(0))
      writer.write(UInt16(0))
      writer.writeUUID(marker.id)
      writer.writeString(marker.name, maxCharacterCount: 80)
      writer.writeSIMD4(sanitizedColor(marker.color))
      writer.write(UInt32(points.count))
      for point in points {
        writer.writeSIMD3(sanitizedPosition(point.position))
        writer.write(sanitizedRadius(point.radius))
      }
    }
  }

  static func decode(from reader: inout MarkerDataReader) throws -> [VolumeMarker] {
    let markerCount = Int(try reader.read() as UInt32)
    guard markerCount <= maximumMarkerCount else {
      throw VolumeMarkerDocumentError.tooManyMarkers
    }

    var markers: [VolumeMarker] = []
    markers.reserveCapacity(markerCount)
    var totalPointCount = 0
    for index in 0..<markerCount {
      let rawKind: UInt8 = try reader.read()
      _ = try reader.read() as UInt8
      _ = try reader.read() as UInt16
      guard let kind = VolumeMarkerKind(rawValue: rawKind) else {
        throw VolumeMarkerDocumentError.invalidGeometry
      }
      let id = try reader.readUUID()
      let rawName = try reader.readString(maxByteCount: maximumNameByteCount)
      let color = sanitizedColor(try reader.readSIMD4())
      let pointCount = Int(try reader.read() as UInt32)
      guard pointCount > 0,
            kind != .sphere || pointCount == 1,
            pointCount <= maximumPointCount - totalPointCount else {
        throw VolumeMarkerDocumentError.invalidGeometry
      }
      totalPointCount += pointCount
      var points: [VolumeMarkerPoint] = []
      points.reserveCapacity(pointCount)
      for _ in 0..<pointCount {
        points.append(
          VolumeMarkerPoint(
            position: sanitizedPosition(try reader.readSIMD3()),
            radius: sanitizedRadius(try reader.read())
          )
        )
      }
      let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      markers.append(
        VolumeMarker(
          id: id,
          name: String((trimmedName.isEmpty ? "Marker \(index + 1)" : trimmedName).prefix(80)),
          color: color,
          geometry: kind == .sphere ? .sphere(points[0]) : .stroke(points)
        )
      )
    }
    return markers
  }

  private static func sanitizedPosition(_ value: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
      finite(value.x, fallback: 0.5, range: -8...8),
      finite(value.y, fallback: 0.5, range: -8...8),
      finite(value.z, fallback: 0.5, range: -8...8)
    )
  }

  private static func sanitizedRadius(_ value: Float) -> Float {
    finite(value, fallback: 0.08, range: 0.005...1)
  }

  private static func sanitizedColor(_ value: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4<Float>(
      finite(value.x, fallback: 1, range: 0...1),
      finite(value.y, fallback: 0, range: 0...1),
      finite(value.z, fallback: 0, range: 0...1),
      finite(value.w, fallback: 1, range: 0...1)
    )
  }

  private static func finite(
    _ value: Float,
    fallback: Float,
    range: ClosedRange<Float>
  ) -> Float {
    guard value.isFinite else { return fallback }
    return min(range.upperBound, max(range.lowerBound, value))
  }
}

enum VolumeMarkerCodecError: LocalizedError {
  case unsupportedVersion(UInt16)
  case outOfBounds
  case invalidString
  case trailingBytes(Int)

  var errorDescription: String? {
    switch self {
      case .unsupportedVersion(let version):
        return "Unsupported marker update version \(version)."
      case .outOfBounds:
        return "Unexpected end of marker update."
      case .invalidString:
        return "Marker update contains invalid text."
      case .trailingBytes(let count):
        return "Marker update has \(count) trailing bytes."
    }
  }
}

struct MarkerDataWriter {
  private(set) var data = Data()

  mutating func write<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func write(_ value: Float) {
    write(value.bitPattern)
  }

  mutating func writeUUID(_ value: UUID) {
    var uuid = value.uuid
    withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
  }

  mutating func writeBytes(_ value: Data) {
    data.append(value)
  }

  mutating func writeString(_ value: String, maxCharacterCount: Int) {
    let string = String(value.prefix(maxCharacterCount))
    let utf8 = Data(string.utf8)
    write(UInt16(clamping: utf8.count))
    data.append(utf8.prefix(Int(UInt16.max)))
  }

  mutating func writeSIMD3(_ value: SIMD3<Float>) {
    write(value.x)
    write(value.y)
    write(value.z)
  }

  mutating func writeSIMD4(_ value: SIMD4<Float>) {
    write(value.x)
    write(value.y)
    write(value.z)
    write(value.w)
  }
}

struct MarkerDataReader {
  private let data: Data
  private var offset = 0

  init(_ data: Data) {
    self.data = data
  }

  var isAtEnd: Bool { offset == data.count }
  func remainingCount() -> Int { data.count - offset }

  mutating func read<T: FixedWidthInteger>() throws -> T {
    let byteCount = MemoryLayout<T>.size
    guard offset + byteCount <= data.count else { throw VolumeMarkerCodecError.outOfBounds }
    let value = data.withUnsafeBytes { raw in
      raw.loadUnaligned(fromByteOffset: offset, as: T.self)
    }
    offset += byteCount
    return T(littleEndian: value)
  }

  mutating func read() throws -> Float {
    Float(bitPattern: try read() as UInt32)
  }

  mutating func readUUID() throws -> UUID {
    let byteCount = MemoryLayout<uuid_t>.size
    guard offset + byteCount <= data.count else { throw VolumeMarkerCodecError.outOfBounds }
    let uuid = data.withUnsafeBytes { raw in
      raw.loadUnaligned(fromByteOffset: offset, as: uuid_t.self)
    }
    offset += byteCount
    return UUID(uuid: uuid)
  }

  mutating func readBytes(count: Int) throws -> Data {
    guard count >= 0, offset + count <= data.count else {
      throw VolumeMarkerCodecError.outOfBounds
    }
    let bytes = data[offset..<(offset + count)]
    offset += count
    return Data(bytes)
  }

  mutating func readString(maxByteCount: Int) throws -> String {
    let byteCount = Int(try read() as UInt16)
    guard byteCount <= maxByteCount, offset + byteCount <= data.count else {
      throw VolumeMarkerCodecError.outOfBounds
    }
    let bytes = data[offset..<(offset + byteCount)]
    offset += byteCount
    guard let string = String(data: bytes, encoding: .utf8) else {
      throw VolumeMarkerCodecError.invalidString
    }
    return string
  }

  mutating func readSIMD3() throws -> SIMD3<Float> {
    SIMD3<Float>(try read(), try read(), try read())
  }

  mutating func readSIMD4() throws -> SIMD4<Float> {
    SIMD4<Float>(try read(), try read(), try read(), try read())
  }
}
