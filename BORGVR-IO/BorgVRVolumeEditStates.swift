import Foundation

struct BorgVRVolumeEditState: Codable, Identifiable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable { case local, copy, sharePlay }
  let id: UUID
  let datasetID: String
  var name: String
  let kind: Kind
  let createdAt: Date
  var modifiedAt: Date
}

struct BorgVRVolumeEditSnapshot: Codable, Sendable {
  let datasetID: String
  let stateID: UUID
  let revision: UInt64
  let mask: BorgVRVolumeEditMask
  var operationIDs: Set<UUID> = []
}

/// Each state owns its journal and disposable brick cache, never the original data.
final class BorgVRVolumeEditCatalog: @unchecked Sendable {
  let root: URL
  let datasetID: String
  private let lock = NSRecursiveLock()
  private static let metadataFilename = "edit-state.plist"
  private static let stateFiles = [metadataFilename, "mask.checkpoint", "brush.journal", "bricks.cache"]

  static func removeStateStorage(at directory: URL) throws {
    for file in stateFiles {
      let url = directory.appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    let result = directory.path.withCString { rmdir($0) }
    if result != 0, errno != ENOENT, errno != ENOTEMPTY { throw POSIXError(.EIO) }
    try BorgVRVolumeEditStorage.removeEmptyParent(of: directory)
  }

  init(root: URL, datasetID: String) throws {
    guard let id = UUID(uuidString: datasetID)?.uuidString else { throw BorgVRVolumeEditError.incompatibleDataset }
    self.root = root
    self.datasetID = id
  }

  func states() throws -> [BorgVRVolumeEditState] {
    try lock.withLock {
      var directories: [URL] = []
      if FileManager.default.fileExists(atPath: root.path) {
        directories += try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
          .filter { UUID(uuidString: $0.lastPathComponent) != nil &&
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
      }
      return directories.compactMap { directory in
        guard var state = try? PropertyListDecoder().decode(BorgVRVolumeEditState.self,
          from: Data(contentsOf: directory.appendingPathComponent(Self.metadataFilename))),
          state.datasetID == datasetID,
          UUID(uuidString: directory.lastPathComponent) == state.id else { return nil }
        // An unused Original working directory must not create a saved variant.
        let dates = ["mask.checkpoint", "brush.journal"].compactMap { file in
          try? directory.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard !dates.isEmpty else { return nil }
        state.modifiedAt = max(state.modifiedAt, dates.max() ?? state.modifiedAt)
        return state
      }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
  }

  func directory(for id: UUID) throws -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }

  func save(_ state: BorgVRVolumeEditState) throws {
    guard state.datasetID == datasetID else { throw BorgVRVolumeEditError.incompatibleDataset }
    try lock.withLock { try write(state, to: directory(for: state.id)) }
  }

  func rename(_ id: UUID, to name: String) throws {
    try lock.withLock {
      guard var state = try states().first(where: { $0.id == id }) else { throw BorgVRVolumeEditError.invalidRevision }
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, name.count <= 200 else { throw BorgVRVolumeEditError.invalidGeometry }
      state.name = name
      try save(state)
    }
  }

  /// Caller must first stop all users of this state. Other variants remain untouched.
  func delete(_ id: UUID) throws {
    try lock.withLock {
      guard try states().contains(where: { $0.id == id }) else { throw BorgVRVolumeEditError.invalidRevision }
      let directory = try directory(for: id)
      try FileManager.default.removeItem(at: directory)
      try BorgVRVolumeEditStorage.removeEmptyParent(of: directory)
    }
  }

  private func write(_ state: BorgVRVolumeEditState, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(state).write(to: directory.appendingPathComponent(Self.metadataFilename), options: .atomic)
  }
}
