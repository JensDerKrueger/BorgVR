import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import simd

extension UTType {
  static let borgVRMarker = UTType(
    exportedAs: "de.uni-due.borgvr.marker",
    conformingTo: .json
  )
}

struct VolumeMarker: Identifiable, Equatable {
  var id: UUID
  var name: String
  var position: SIMD3<Float>
  var radius: Float
  var color: SIMD4<Float>
}

struct VolumeMarkerDocument: FileDocument {
  static let maximumFileByteCount = 64 * 1024 * 1024
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
    guard let datasetID, UUID(uuidString: datasetID) != nil else {
      throw VolumeMarkerDocumentError.invalidFormat
    }
    let payload = VolumeMarkerFile(
      version: 1,
      datasetID: datasetID,
      markers: markers.map(StoredVolumeMarker.init(marker:))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return .init(regularFileWithContents: try encoder.encode(payload))
  }

  static func decode(from data: Data) throws -> VolumeMarkerDocumentContents {
    guard data.count <= maximumFileByteCount else {
      throw VolumeMarkerDocumentError.fileTooLarge
    }
    let payload = try JSONDecoder().decode(VolumeMarkerFile.self, from: data)
    guard payload.format == "BorgVRVolumeMarkers" else {
      throw VolumeMarkerDocumentError.invalidFormat
    }
    guard payload.version == 1 else {
      throw VolumeMarkerDocumentError.unsupportedVersion(payload.version)
    }
    guard UUID(uuidString: payload.datasetID) != nil else {
      throw VolumeMarkerDocumentError.invalidFormat
    }
    guard payload.markers.count <= 100_000 else {
      throw VolumeMarkerDocumentError.tooManyMarkers
    }
    return VolumeMarkerDocumentContents(
      datasetID: payload.datasetID,
      markers: payload.markers.enumerated().map { index, stored in
        stored.marker(fallbackName: "Marker \(index + 1)")
      }
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
    }
  }
}

private struct VolumeMarkerFile: Codable {
  var format: String = "BorgVRVolumeMarkers"
  var version: Int = 1
  var datasetID: String
  var markers: [StoredVolumeMarker]
}

private struct StoredVolumeMarker: Codable {
  var id: UUID
  var name: String
  var position: [Float]
  var radius: Float
  var color: [Float]

  init(marker: VolumeMarker) {
    id = marker.id
    name = marker.name
    position = [marker.position.x, marker.position.y, marker.position.z]
    radius = marker.radius
    color = [marker.color.x, marker.color.y, marker.color.z, marker.color.w]
  }

  func marker(fallbackName: String) -> VolumeMarker {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return VolumeMarker(
      id: id,
      name: String((cleanName.isEmpty ? fallbackName : cleanName).prefix(80)),
      position: SIMD3<Float>(
        finite(position[safe: 0], fallback: 0.5, range: -8...8),
        finite(position[safe: 1], fallback: 0.5, range: -8...8),
        finite(position[safe: 2], fallback: 0.5, range: -8...8)
      ),
      radius: finite(radius, fallback: 0.08, range: 0.005...1),
      color: SIMD4<Float>(
        finite(color[safe: 0], fallback: 1, range: 0...1),
        finite(color[safe: 1], fallback: 0, range: 0...1),
        finite(color[safe: 2], fallback: 0, range: 0...1),
        finite(color[safe: 3], fallback: 1, range: 0...1)
      )
    )
  }

  private func finite(_ value: Float?, fallback: Float, range: ClosedRange<Float>) -> Float {
    guard let value, value.isFinite else { return fallback }
    return min(range.upperBound, max(range.lowerBound, value))
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
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
  private static let sharePlayVersion: UInt16 = 1
  private static let packetKind: UInt8 = 4
  private static let maximumMarkerCount = Int(UInt16.max)

  static func encode(_ markers: [VolumeMarker]) -> Data {
    var writer = MarkerDataWriter()
    writer.write(sharePlayMagic)
    writer.write(sharePlayVersion)
    writer.write(packetKind)
    writer.write(UInt8(0))

    let markerCount = min(markers.count, maximumMarkerCount)
    writer.write(UInt16(markerCount))
    for marker in markers.prefix(markerCount) {
      writer.writeUUID(marker.id)
      writer.writeString(marker.name, maxCharacterCount: 80)
      writer.writeSIMD3(marker.position)
      writer.write(marker.radius)
      writer.writeSIMD4(marker.color)
    }
    return writer.data
  }

  /// Returns `nil` when the data is a different SharePlay packet kind.
  static func decodeIfPresent(_ data: Data) throws -> [VolumeMarker]? {
    var reader = MarkerDataReader(data)
    let magic: UInt32 = try reader.read()
    guard magic == sharePlayMagic else { return nil }
    let version: UInt16 = try reader.read()
    guard version == sharePlayVersion else {
      throw VolumeMarkerCodecError.unsupportedVersion(version)
    }
    let packet: UInt8 = try reader.read()
    _ = try reader.read() as UInt8
    guard packet == packetKind else { return nil }

    let markerCount: UInt16 = try reader.read()
    var markers: [VolumeMarker] = []
    markers.reserveCapacity(Int(markerCount))
    for index in 0..<Int(markerCount) {
      let id = try reader.readUUID()
      let rawName = try reader.readString(maxByteCount: 512)
      let position = try reader.readSIMD3()
      let radius: Float = try reader.read()
      let color = try reader.readSIMD4()
      let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      markers.append(
        VolumeMarker(
          id: id,
          name: String((trimmedName.isEmpty ? "Marker \(index + 1)" : trimmedName).prefix(80)),
          position: SIMD3<Float>(
            min(max(position.x, -8), 8),
            min(max(position.y, -8), 8),
            min(max(position.z, -8), 8)
          ),
          radius: min(max(radius, 0.005), 1),
          color: SIMD4<Float>(
            min(max(color.x, 0), 1),
            min(max(color.y, 0), 1),
            min(max(color.z, 0), 1),
            min(max(color.w, 0), 1)
          )
        )
      )
    }

    guard reader.isAtEnd else {
      throw VolumeMarkerCodecError.trailingBytes(reader.remainingCount())
    }
    return markers
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

private struct MarkerDataWriter {
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

private struct MarkerDataReader {
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
