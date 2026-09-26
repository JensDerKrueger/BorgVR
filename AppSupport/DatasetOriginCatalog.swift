import Foundation

struct DatasetOrigin: Codable, Hashable, Sendable {
  let address: String
  let port: Int
  let password: String

  var identityKey: String {
    "\(address.lowercased())\u{0}\(port)\u{0}\(password)"
  }
}

enum SharePlayWaitingReason {
  case hostDataset
  case datasetSource
}

struct DatasetOriginSnapshot: Codable, Sendable {
  struct Entry: Codable, Sendable {
    let origin: DatasetOrigin
    let datasetIDs: [String]
  }

  let entries: [Entry]

  static let empty = DatasetOriginSnapshot(entries: [])

  func originsByDatasetID() -> [String: [DatasetOrigin]] {
    var result: [String: [DatasetOrigin]] = [:]
    for entry in entries {
      for datasetID in entry.datasetIDs where !datasetID.isEmpty {
        result[datasetID, default: []].append(entry.origin)
      }
    }
    return result.mapValues(DatasetOriginCatalog.deduplicated)
  }
}

struct DatasetOriginAdvertisement: Codable, Sendable {
  let datasetID: String
  let origins: [DatasetOrigin]
}

enum DatasetOriginSharePlayCodec {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
  }
}

final class DatasetOriginCatalog: @unchecked Sendable {
  static let shared = DatasetOriginCatalog()

  private struct Record: Codable {
    let origin: DatasetOrigin
    let sequence: UInt64
    let allowsSharing: Bool
  }

  private struct Storage: Codable {
    var nextSequence: UInt64 = 1
    var recordsByDatasetID: [String: [Record]] = [:]
  }

  private let lock = NSLock()
  private let defaults: UserDefaults
  private let storageKey = "borgvr.dataset-origin-catalog.v1"
  private var storage: Storage

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: storageKey),
       let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
      storage = decoded
    } else {
      storage = Storage()
    }
  }

  func origins(for datasetID: String) -> [DatasetOrigin] {
    lock.withLock {
      orderedOrigins(storage.recordsByDatasetID[datasetID] ?? [])
    }
  }

  func shareableOrigins(for datasetID: String) -> [DatasetOrigin] {
    lock.withLock {
      orderedOrigins((storage.recordsByDatasetID[datasetID] ?? []).filter(\.allowsSharing))
    }
  }

  func shareableSnapshot() -> DatasetOriginSnapshot {
    lock.withLock {
      var datasetIDsByOrigin: [DatasetOrigin: Set<String>] = [:]
      for (datasetID, records) in storage.recordsByDatasetID {
        for record in records where record.allowsSharing {
          datasetIDsByOrigin[record.origin, default: []].insert(datasetID)
        }
      }
      let entries = datasetIDsByOrigin.map { origin, datasetIDs in
        DatasetOriginSnapshot.Entry(origin: origin, datasetIDs: datasetIDs.sorted())
      }.sorted { lhs, rhs in
        lhs.origin.identityKey < rhs.origin.identityKey
      }
      return DatasetOriginSnapshot(entries: entries)
    }
  }

  /// Makes remotely received sources locally usable without allowing them to leak into later sessions.
  func mergeRemoteSnapshot(_ snapshot: DatasetOriginSnapshot) {
    lock.withLock {
      for entry in snapshot.entries {
        guard !entry.origin.address.isEmpty, (1...65535).contains(entry.origin.port) else {
          continue
        }
        for datasetID in Set(entry.datasetIDs) where !datasetID.isEmpty {
          var records = storage.recordsByDatasetID[datasetID] ?? []
          let allowsSharing = records.first {
            $0.origin.identityKey == entry.origin.identityKey
          }?.allowsSharing ?? false
          records.removeAll { $0.origin.identityKey == entry.origin.identityKey }
          records.append(
            Record(origin: entry.origin, sequence: takeSequence(), allowsSharing: allowsSharing)
          )
          storage.recordsByDatasetID[datasetID] = records
        }
      }
      persist()
    }
  }

  func sharingAllowed(for origin: DatasetOrigin) -> Bool {
    lock.withLock {
      storage.recordsByDatasetID.values
        .joined()
        .contains { $0.origin.identityKey == origin.identityKey && $0.allowsSharing }
    }
  }

  /// Replaces everything previously learned from this endpoint with its current dataset list.
  func recordServerSnapshot(
    origin: DatasetOrigin,
    datasetIDs: some Sequence<String>,
    allowsSharing: Bool
  ) {
    let ids = Set(datasetIDs.filter { !$0.isEmpty })
    lock.withLock {
      removeOrigin(origin.identityKey)
      for datasetID in ids {
        storage.recordsByDatasetID[datasetID, default: []].append(
          Record(origin: origin, sequence: takeSequence(), allowsSharing: allowsSharing)
        )
      }
      removeEmptyDatasets()
      persist()
    }
  }

  func record(origin: DatasetOrigin, for datasetID: String, allowsSharing: Bool) {
    guard !datasetID.isEmpty else { return }
    lock.withLock {
      var records = storage.recordsByDatasetID[datasetID] ?? []
      records.removeAll { $0.origin.identityKey == origin.identityKey }
      records.append(
        Record(origin: origin, sequence: takeSequence(), allowsSharing: allowsSharing)
      )
      storage.recordsByDatasetID[datasetID] = records
      persist()
    }
  }

  /// Stores SharePlay origins in their advertised order and makes them newer than cached entries.
  /// Received credentials remain private to this device and are not forwarded in future sessions.
  func prioritize(_ origins: [DatasetOrigin], for datasetID: String) {
    guard !datasetID.isEmpty else { return }
    let uniqueOrigins = Self.deduplicated(origins)
    lock.withLock {
      var records = storage.recordsByDatasetID[datasetID] ?? []
      let identities = Set(uniqueOrigins.map(\.identityKey))
      let sharingByIdentity = records.reduce(into: [String: Bool]()) { result, record in
        result[record.origin.identityKey, default: false] =
          result[record.origin.identityKey, default: false] || record.allowsSharing
      }
      records.removeAll { identities.contains($0.origin.identityKey) }
      for origin in uniqueOrigins.reversed() {
        records.append(
          Record(
            origin: origin,
            sequence: takeSequence(),
            allowsSharing: sharingByIdentity[origin.identityKey] ?? false
          )
        )
      }
      storage.recordsByDatasetID[datasetID] = records
      persist()
    }
  }

  func clear() {
    lock.withLock {
      storage = Storage()
      defaults.removeObject(forKey: storageKey)
    }
  }

  func setSharingAllowed(_ allowed: Bool, for origin: DatasetOrigin) {
    lock.withLock {
      for datasetID in Array(storage.recordsByDatasetID.keys) {
        storage.recordsByDatasetID[datasetID] = storage.recordsByDatasetID[datasetID]?.map { record in
          guard record.origin.identityKey == origin.identityKey else { return record }
          return Record(origin: record.origin, sequence: record.sequence, allowsSharing: allowed)
        }
      }
      persist()
    }
  }

  static func deduplicated(_ origins: [DatasetOrigin]) -> [DatasetOrigin] {
    var seen = Set<String>()
    return origins.filter { origin in
      guard !origin.address.isEmpty, (1...65535).contains(origin.port) else { return false }
      return seen.insert(origin.identityKey).inserted
    }
  }

  private func orderedOrigins(_ records: [Record]) -> [DatasetOrigin] {
    var seen = Set<String>()
    return records
      .sorted { $0.sequence > $1.sequence }
      .compactMap { record in
        seen.insert(record.origin.identityKey).inserted ? record.origin : nil
      }
  }

  private func removeOrigin(_ identityKey: String) {
    for datasetID in Array(storage.recordsByDatasetID.keys) {
      storage.recordsByDatasetID[datasetID]?.removeAll {
        $0.origin.identityKey == identityKey
      }
    }
  }

  private func removeEmptyDatasets() {
    storage.recordsByDatasetID = storage.recordsByDatasetID.filter { !$0.value.isEmpty }
  }

  private func takeSequence() -> UInt64 {
    let sequence = storage.nextSequence
    storage.nextSequence = storage.nextSequence == .max ? 1 : storage.nextSequence + 1
    return sequence
  }

  private func persist() {
    guard let data = try? JSONEncoder().encode(storage) else { return }
    defaults.set(data, forKey: storageKey)
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
