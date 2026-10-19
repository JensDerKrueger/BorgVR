import Foundation
import SwiftUI
import UniformTypeIdentifiers
import simd

extension UTType {
  static let borgVRMeasurement = UTType(
    exportedAs: "de.uni-due.borgvr.measurement",
    conformingTo: .data
  )
}

struct VolumeMeasurementDocumentContents {
  let datasetID: String
  let measurements: [VolumeMeasurement]
}

struct VolumeMeasurementDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.borgVRMeasurement] }
  static var writableContentTypes: [UTType] { [.borgVRMeasurement] }

  let datasetID: String?
  let measurements: [VolumeMeasurement]

  init(datasetID: String?, measurements: [VolumeMeasurement]) {
    self.datasetID = datasetID
    self.measurements = measurements
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw VolumeMeasurementDocumentError.invalidFormat
    }
    let contents = try Self.decode(from: data)
    datasetID = contents.datasetID
    measurements = contents.measurements
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    .init(regularFileWithContents: try Self.encode(
      datasetID: datasetID,
      measurements: measurements
    ))
  }

  static func encode(
    datasetID: String?,
    measurements: [VolumeMeasurement]
  ) throws -> Data {
    let measurements = measurements.filter { !$0.points.isEmpty }
    guard let datasetID, let datasetUUID = UUID(uuidString: datasetID) else {
      throw VolumeMeasurementDocumentError.invalidFormat
    }
    guard measurements.count <= BorgVRMeasurementFormat.maximumMeasurementCount else {
      throw VolumeMeasurementDocumentError.tooManyMeasurements
    }
    let pointCount = measurements.reduce(0) { $0 + $1.points.count }
    guard pointCount <= BorgVRMeasurementFormat.maximumPointCount else {
      throw VolumeMeasurementDocumentError.tooManyPoints
    }

    var writer = MarkerDataWriter()
    writer.writeBytes(Data(BorgVRMeasurementFormat.magicBytes))
    writer.write(BorgVRMeasurementFormat.version)
    writer.write(UInt16(0))
    writer.writeUUID(datasetUUID)
    writer.write(UInt32(measurements.count))

    for measurement in measurements {
      guard let kind = encodedKind(measurement.kind) else {
        throw VolumeMeasurementDocumentError.invalidGeometry
      }
      writer.writeUUID(measurement.id)
      writer.write(kind)
      writer.write(UInt8(0))
      writer.write(UInt16(0))
      writer.writeString(
        measurement.name,
        maxCharacterCount: BorgVRMeasurementFormat.maximumNameCharacterCount
      )
      writer.write(UInt32(measurement.points.count))
      for point in measurement.points {
        guard isValid(position: point.position) else {
          throw VolumeMeasurementDocumentError.invalidGeometry
        }
        writer.writeUUID(point.id)
        writer.writeSIMD3(point.position)
      }
    }

    guard writer.data.count <= BorgVRMeasurementFormat.maximumFileByteCount else {
      throw VolumeMeasurementDocumentError.fileTooLarge
    }
    return writer.data
  }

  static func decode(from data: Data) throws -> VolumeMeasurementDocumentContents {
    guard data.count <= BorgVRMeasurementFormat.maximumFileByteCount else {
      throw VolumeMeasurementDocumentError.fileTooLarge
    }

    do {
      var reader = MarkerDataReader(data)
      let magic = Data(BorgVRMeasurementFormat.magicBytes)
      guard try reader.readBytes(count: magic.count) == magic else {
        throw VolumeMeasurementDocumentError.invalidFormat
      }
      let version: UInt16 = try reader.read()
      guard version == BorgVRMeasurementFormat.version else {
        throw VolumeMeasurementDocumentError.unsupportedVersion(Int(version))
      }
      _ = try reader.read() as UInt16
      let datasetID = try reader.readUUID().uuidString
      let measurementCount = Int(try reader.read() as UInt32)
      guard measurementCount <= BorgVRMeasurementFormat.maximumMeasurementCount else {
        throw VolumeMeasurementDocumentError.tooManyMeasurements
      }

      var measurements: [VolumeMeasurement] = []
      measurements.reserveCapacity(measurementCount)
      var measurementIDs = Set<UUID>()
      var pointIDs = Set<UUID>()
      var totalPointCount = 0

      for _ in 0..<measurementCount {
        let id = try reader.readUUID()
        guard measurementIDs.insert(id).inserted else {
          throw VolumeMeasurementDocumentError.invalidGeometry
        }
        let rawKind: UInt8 = try reader.read()
        _ = try reader.read() as UInt8
        _ = try reader.read() as UInt16
        guard let kind = decodedKind(rawKind) else {
          throw VolumeMeasurementDocumentError.invalidGeometry
        }
        let name = try reader.readString(
          maxByteCount: BorgVRMeasurementFormat.maximumNameByteCount
        )
        let pointCount = Int(try reader.read() as UInt32)
        guard pointCount <= BorgVRMeasurementFormat.maximumPointCount - totalPointCount else {
          throw VolumeMeasurementDocumentError.tooManyPoints
        }
        totalPointCount += pointCount

        var points: [VolumeMeasurementPoint] = []
        points.reserveCapacity(pointCount)
        for _ in 0..<pointCount {
          let pointID = try reader.readUUID()
          let position = try reader.readSIMD3()
          guard pointIDs.insert(pointID).inserted, isValid(position: position) else {
            throw VolumeMeasurementDocumentError.invalidGeometry
          }
          points.append(VolumeMeasurementPoint(id: pointID, position: position))
        }
        if !points.isEmpty {
          measurements.append(VolumeMeasurement(
            id: id,
            name: String(name.prefix(BorgVRMeasurementFormat.maximumNameCharacterCount)),
            kind: kind,
            points: points
          ))
        }
      }

      guard reader.isAtEnd else {
        throw VolumeMeasurementDocumentError.invalidFormat
      }
      return VolumeMeasurementDocumentContents(
        datasetID: datasetID,
        measurements: measurements
      )
    } catch let error as VolumeMeasurementDocumentError {
      throw error
    } catch {
      throw VolumeMeasurementDocumentError.invalidFormat
    }
  }

  static func encodedKind(_ kind: VolumeMeasurementKind) -> UInt8? {
    switch kind {
      case .length: 1
      case .area: 2
      case .volume: 3
    }
  }

  static func decodedKind(_ value: UInt8) -> VolumeMeasurementKind? {
    switch value {
      case 1: .length
      case 2: .area
      case 3: .volume
      default: nil
    }
  }

  static func isValid(position: SIMD3<Float>) -> Bool {
    position.x.isFinite && position.y.isFinite && position.z.isFinite &&
      BorgVRMeasurementFormat.positionRange.contains(position.x) &&
      BorgVRMeasurementFormat.positionRange.contains(position.y) &&
      BorgVRMeasurementFormat.positionRange.contains(position.z)
  }
}

enum DatasetStateStorage {
  static let measurementDirectoryName = "Measurements"

  static func objectFileURL(datasetID: String, logger: LoggerBase? = nil) -> URL? {
    guard let directory = VolumeMarkerCatalog.storageDirectoryURL(logger: logger) else {
      return nil
    }
    return directory
      .appendingPathComponent(sanitizedFilename(datasetID, fallback: "objects"))
      .appendingPathExtension(BorgVRMarkerFormat.fileExtension)
  }

  static func measurementFileURL(datasetID: String, logger: LoggerBase? = nil) -> URL? {
    guard let directory = measurementDirectoryURL(logger: logger) else { return nil }
    return directory
      .appendingPathComponent(sanitizedFilename(datasetID, fallback: "measurements"))
      .appendingPathExtension(BorgVRMeasurementFormat.fileExtension)
  }

  static func measurementDirectoryURL(logger: LoggerBase? = nil) -> URL? {
    guard let documentsURL = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    ).first else { return nil }
    let directoryURL = documentsURL.appendingPathComponent(
      measurementDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      return directoryURL
    } catch {
      logger?.warning("Measurement directory unavailable: \(error.localizedDescription)")
      return nil
    }
  }

  static func saveObjects(
    datasetID: String,
    markers: [VolumeMarker],
    meshInstances: [SceneMeshInstance],
    to url: URL
  ) throws {
    let data = try VolumeMarkerDocument.encode(
      datasetID: datasetID,
      markers: markers,
      meshInstances: meshInstances
    )
    try data.write(to: url, options: .atomic)
    NotificationCenter.default.post(
      name: VolumeMarkerCatalog.didChangeNotification,
      object: nil
    )
  }

  static func saveMeasurements(
    datasetID: String,
    measurements: [VolumeMeasurement],
    to url: URL
  ) throws {
    let data = try VolumeMeasurementDocument.encode(
      datasetID: datasetID,
      measurements: measurements
    )
    try data.write(to: url, options: .atomic)
  }

  static func loadObjects(datasetID: String, from url: URL) throws -> VolumeMarkerDocumentContents {
    let contents = try VolumeMarkerDocument.decode(
      from: Data(contentsOf: url, options: .mappedIfSafe)
    )
    guard contents.datasetID.caseInsensitiveCompare(datasetID) == .orderedSame else {
      throw DatasetStateStorageError.datasetMismatch
    }
    return contents
  }

  static func loadMeasurements(
    datasetID: String,
    physicalExtent: SIMD3<Float>,
    from url: URL
  ) throws -> [VolumeMeasurement] {
    let contents = try VolumeMeasurementDocument.decode(
      from: Data(contentsOf: url, options: .mappedIfSafe)
    )
    guard contents.datasetID.caseInsensitiveCompare(datasetID) == .orderedSame else {
      throw DatasetStateStorageError.datasetMismatch
    }
    return contents.measurements.map { measurement in
      VolumeMeasurement(
        id: measurement.id,
        name: measurement.name,
        kind: measurement.kind,
        points: measurement.points,
        physicalExtent: physicalExtent
      )
    }
  }

  static func removeFileIfPresent(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private static func sanitizedFilename(_ value: String, fallback: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let scalars = value.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return result.isEmpty ? fallback : result
  }
}

enum DatasetStateStorageError: LocalizedError {
  case datasetMismatch

  var errorDescription: String? {
    switch self {
      case .datasetMismatch:
        String(localized: "The saved data belongs to a different dataset.")
    }
  }
}

struct DatasetStateSavePlan {
  let transferFunctionURL: URL?
  let viewStateURL: URL?
  let objectURL: URL?
  let measurementURL: URL?

  var fileURLs: [URL] {
    [transferFunctionURL, viewStateURL, objectURL, measurementURL].compactMap { $0 }
  }

  var isEmpty: Bool { fileURLs.isEmpty }

  var hasExistingFiles: Bool {
    fileURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
  }
}

enum VolumeMeasurementExportRecovery {
  static func finish(
    _ result: Result<URL, Error>,
    datasetID: String?,
    measurements: [VolumeMeasurement]
  ) throws {
    guard case let .failure(error) = result else { return }
    guard isDuplicateFileError(error),
          let destinationURL = destinationFileURL(from: error) else {
      throw error
    }

    let data = try VolumeMeasurementDocument.encode(
      datasetID: datasetID,
      measurements: measurements
    )
    let accessed = destinationURL.startAccessingSecurityScopedResource()
    defer {
      if accessed { destinationURL.stopAccessingSecurityScopedResource() }
    }

    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: destinationURL,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedURL in
      do {
        try data.write(to: coordinatedURL, options: .atomic)
      } catch {
        writeError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let writeError { throw writeError }
  }

  private static func isDuplicateFileError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSOSStatusErrorDomain, nsError.code == -48 { return true }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return isDuplicateFileError(underlying)
    }
    return false
  }

  private static func destinationFileURL(from error: Error) -> URL? {
    let nsError = error as NSError
    for key in ["NSFileNewItemLocationKey", "NSDestinationURL"] {
      if let url = nsError.userInfo[key] as? URL { return url }
      if let path = nsError.userInfo[key] as? String {
        return URL(fileURLWithPath: path)
      }
    }
    if let path = nsError.userInfo["NSDestinationFilePath"] as? String {
      return URL(fileURLWithPath: path)
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return destinationFileURL(from: underlying)
    }
    return nil
  }
}

enum VolumeMeasurementSharePlayCodec {
  static func encode(_ measurements: [VolumeMeasurement]) -> Data {
    let measurements = measurements.filter { !$0.points.isEmpty }
    var writer = MarkerDataWriter()
    writer.write(BorgVRSharePlayProtocol.magic)
    writer.write(BorgVRSharePlayProtocol.PacketKind.volumeMeasurements.rawValue)
    writer.write(UInt8(0))
    writer.write(UInt32(measurements.count))
    for measurement in measurements {
      writer.writeUUID(measurement.id)
      writer.write(VolumeMeasurementDocument.encodedKind(measurement.kind) ?? 0)
      writer.write(UInt8(0))
      writer.write(UInt16(0))
      writer.writeString(
        measurement.name,
        maxCharacterCount: BorgVRMeasurementFormat.maximumNameCharacterCount
      )
      writer.write(UInt32(measurement.points.count))
      for point in measurement.points {
        writer.writeUUID(point.id)
        writer.writeSIMD3(point.position)
      }
    }
    return writer.data
  }

  static func decodeIfPresent(_ data: Data) throws -> [VolumeMeasurement]? {
    var reader = MarkerDataReader(data)
    let magic: UInt32 = try reader.read()
    guard magic == BorgVRSharePlayProtocol.magic else { return nil }
    let packet: UInt8 = try reader.read()
    _ = try reader.read() as UInt8
    guard packet == BorgVRSharePlayProtocol.PacketKind.volumeMeasurements.rawValue else {
      return nil
    }
    let count = Int(try reader.read() as UInt32)
    guard count <= BorgVRMeasurementFormat.maximumMeasurementCount else {
      throw VolumeMeasurementDocumentError.tooManyMeasurements
    }
    var result: [VolumeMeasurement] = []
    var totalPointCount = 0
    var measurementIDs = Set<UUID>()
    var pointIDs = Set<UUID>()
    result.reserveCapacity(count)
    for _ in 0..<count {
      let id = try reader.readUUID()
      let rawKind: UInt8 = try reader.read()
      _ = try reader.read() as UInt8
      _ = try reader.read() as UInt16
      guard measurementIDs.insert(id).inserted,
            let kind = VolumeMeasurementDocument.decodedKind(rawKind) else {
        throw VolumeMeasurementDocumentError.invalidGeometry
      }
      let name = try reader.readString(
        maxByteCount: BorgVRMeasurementFormat.maximumNameByteCount
      )
      let pointCount = Int(try reader.read() as UInt32)
      guard pointCount <= BorgVRMeasurementFormat.maximumPointCount - totalPointCount else {
        throw VolumeMeasurementDocumentError.tooManyPoints
      }
      totalPointCount += pointCount
      var points: [VolumeMeasurementPoint] = []
      points.reserveCapacity(pointCount)
      for _ in 0..<pointCount {
        let pointID = try reader.readUUID()
        let position = try reader.readSIMD3()
        guard pointIDs.insert(pointID).inserted,
              VolumeMeasurementDocument.isValid(position: position) else {
          throw VolumeMeasurementDocumentError.invalidGeometry
        }
        points.append(VolumeMeasurementPoint(id: pointID, position: position))
      }
      if !points.isEmpty {
        result.append(VolumeMeasurement(
          id: id,
          name: String(name.prefix(BorgVRMeasurementFormat.maximumNameCharacterCount)),
          kind: kind,
          points: points
        ))
      }
    }
    guard reader.isAtEnd else {
      throw VolumeMeasurementDocumentError.invalidFormat
    }
    return result
  }
}

enum VolumeMeasurementDocumentError: LocalizedError {
  case invalidFormat
  case unsupportedVersion(Int)
  case fileTooLarge
  case tooManyMeasurements
  case tooManyPoints
  case invalidGeometry
  case missingDatasetGeometry

  var errorDescription: String? {
    switch self {
      case .invalidFormat:
        String(localized: "measurement_file_error_invalid")
      case .unsupportedVersion(let version):
        String(
          format: String(localized: "measurement_file_error_version_format"),
          version
        )
      case .fileTooLarge:
        String(localized: "measurement_file_error_too_large")
      case .tooManyMeasurements:
        String(localized: "measurement_file_error_too_many_measurements")
      case .tooManyPoints:
        String(localized: "measurement_file_error_too_many_points")
      case .invalidGeometry:
        String(localized: "measurement_file_error_invalid_geometry")
      case .missingDatasetGeometry:
        String(localized: "measurement_file_error_missing_dataset")
    }
  }
}
