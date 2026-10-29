import Foundation

struct BorgVRVolumeEditWork: Codable, Sendable {
  let id: UUID
  let region: BorgVRVoxelRegion
  let revision: UInt64
}

/// Serializes durable edits, not renderer access. Workers retain immutable snapshots.
/// A torn trailing frame is discarded; corruption of a complete frame is reported.
final class BorgVRVolumeEditJournal {
  private struct Header: Decodable { let version: Int }
  private struct Checkpoint: Codable {
    let version: Int
    let datasetID: String
    let editStateID: UUID
    var revision: UInt64
    var mask: BorgVRVolumeEditMask
    var pending: [BorgVRVolumeEditWork]
    var operationIDs: Set<UUID>
    var brickRevisions: [Int: UInt64]?
  }

  struct Snapshot: Sendable {
    let editStateID: UUID
    let revision: UInt64
    let mask: BorgVRVolumeEditMask
    let pending: [BorgVRVolumeEditWork]
    let brickRevisions: [Int: UInt64]?
  }

  private let lock = NSLock()
  private let checkpointURL: URL
  private let journalURL: URL
  private var handle: FileHandle?
  private var state: Checkpoint
  private var failedWrite = false
  private var checkpointDirty = false
  private var journalDirty = false
  private static let maximumFrameBytes = 16 * 1024 * 1024
  private static let checkpointVersion = 3

  init(directory: URL, datasetID: String, size: SIMD3<Int>, spacing: SIMD3<Double>,
       componentCount: Int = 1,
       initialSnapshot: BorgVRVolumeEditSnapshot? = nil, persistOriginalSnapshot: Bool = false) throws {
    let mask = try BorgVRVolumeEditMask(size: size, spacing: spacing, componentCount: componentCount)
    checkpointURL = directory.appendingPathComponent("mask.checkpoint")
    journalURL = directory.appendingPathComponent("brush.journal")
    if let snapshot = initialSnapshot {
      guard snapshot.datasetID == datasetID, snapshot.mask.size == size, snapshot.mask.spacing == spacing,
            snapshot.mask.componentCount == componentCount else {
        throw BorgVRVolumeEditError.incompatibleDataset
      }
      try Self.validateNewDirectory(directory)
      state = try Self.checkpoint(from: snapshot)
      // Keep an untouched session's epoch and revision in memory. The first brush
      // persists them through openStorage(), just like an unused local state.
      guard !snapshot.mask.isOriginal || persistOriginalSnapshot else { return }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try writeCheckpoint()
    } else if FileManager.default.fileExists(atPath: checkpointURL.path) {
      let data = try Data(contentsOf: checkpointURL)
      do {
        let version = try PropertyListDecoder().decode(Header.self, from: data).version
        guard version == Self.checkpointVersion else {
          throw BorgVRVolumeEditError.unsupportedCheckpointVersion(version)
        }
        state = try PropertyListDecoder().decode(Checkpoint.self, from: data)
      } catch is DecodingError { throw BorgVRVolumeEditError.corruptJournal }
      guard state.datasetID == datasetID,
            state.mask.size == size, state.mask.spacing == spacing, state.mask.componentCount == componentCount else {
        throw BorgVRVolumeEditError.incompatibleDataset
      }
    } else {
      // A journal may have been truncated after checkpointing. Without its
      // checkpoint it cannot safely reconstruct the saved edits.
      guard !["brush.journal", "bricks.cache", "edit-state.plist"].contains(where: {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
      }) else { throw BorgVRVolumeEditError.corruptJournal }
      state = Checkpoint(version: Self.checkpointVersion, datasetID: datasetID, editStateID: UUID(), revision: 0,
                         mask: mask, pending: [], operationIDs: [], brickRevisions: [:])
    }
    guard FileManager.default.fileExists(atPath: checkpointURL.path) ||
          FileManager.default.fileExists(atPath: journalURL.path) else { return }
    if !FileManager.default.fileExists(atPath: checkpointURL.path) { try writeCheckpoint() }
    if !FileManager.default.fileExists(atPath: journalURL.path) {
      guard FileManager.default.createFile(atPath: journalURL.path, contents: nil) else {
        throw BorgVRVolumeEditError.corruptJournal
      }
    }
    let handle = try FileHandle(forUpdating: journalURL)
    self.handle = handle
    // Checkpoints can precede truncation of an older journal after a crash.
    let checkpointRevision = state.revision
    var validOffset: UInt64 = 0
    while true {
      let header = try handle.read(upToCount: 16) ?? Data()
      if header.isEmpty { break }
      if header.count < 16 { break }
      let length = Self.integer(header, offset: 0)
      let checksum = Self.integer(header, offset: 8)
      guard length > 0, length <= Self.maximumFrameBytes else {
        throw BorgVRVolumeEditError.corruptJournal
      }
      let payload = try handle.read(upToCount: Int(length)) ?? Data()
      if payload.count != Int(length) { break }
      guard Self.checksum(payload) == checksum else { throw BorgVRVolumeEditError.corruptJournal }
      let batch = try PropertyListDecoder().decode(BorgVRVolumeBrushBatch.self, from: payload)
      if batch.revision > checkpointRevision {
        try Self.apply(batch, to: &state)
        checkpointDirty = true
      }
      validOffset += 16 + length
    }
    if try handle.seekToEnd() != validOffset { try handle.truncate(atOffset: validOffset) }
    try handle.seek(toOffset: validOffset)
    journalDirty = validOffset > 0
  }

  deinit { try? handle?.close() }

  private func openStorage() throws -> FileHandle {
    if let handle { return handle }
    try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try writeCheckpoint()
    checkpointDirty = false
    guard FileManager.default.createFile(atPath: journalURL.path, contents: nil) else {
      throw BorgVRVolumeEditError.corruptJournal
    }
    let handle = try FileHandle(forUpdating: journalURL)
    self.handle = handle
    journalDirty = false
    return handle
  }

  private func writeCheckpoint() throws {
    try Self.encode(state).write(to: checkpointURL, options: .atomic)
    let checkpointFile = try FileHandle(forWritingTo: checkpointURL)
    defer { try? checkpointFile.close() }
    try checkpointFile.synchronize()
  }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(editStateID: state.editStateID, revision: state.revision,
               mask: state.mask, pending: state.pending, brickRevisions: state.brickRevisions)
    }
  }

  func transferableSnapshot(datasetID: String) -> BorgVRVolumeEditSnapshot {
    lock.withLock { .init(datasetID: datasetID, stateID: state.editStateID,
      revision: state.revision, mask: state.mask, operationIDs: state.operationIDs) }
  }

  static func install(_ snapshot: BorgVRVolumeEditSnapshot, in directory: URL) throws {
    let checkpoint = try checkpoint(from: snapshot)
    try validateNewDirectory(directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encode(checkpoint).write(to: directory.appendingPathComponent("mask.checkpoint"), options: .atomic)
  }

  private static func checkpoint(from snapshot: BorgVRVolumeEditSnapshot) throws -> Checkpoint {
    guard UUID(uuidString: snapshot.datasetID) != nil else { throw BorgVRVolumeEditError.incompatibleDataset }
    return Checkpoint(version: checkpointVersion, datasetID: snapshot.datasetID, editStateID: snapshot.stateID,
      revision: snapshot.revision, mask: snapshot.mask, pending: [], operationIDs: snapshot.operationIDs,
      brickRevisions: snapshot.mask.isOriginal ? [:] : nil)
  }

  private static func validateNewDirectory(_ directory: URL) throws {
    // Install only into a new state directory, never on top of an open journal/cache.
    for file in ["mask.checkpoint", "brush.journal", "bricks.cache"] {
      guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
        throw BorgVRVolumeEditError.invalidRevision
      }
    }
  }

  func closeStorage() throws {
    try checkpoint()
    try lock.withLock { try handle?.close(); handle = nil }
  }

  /// Transferred snapshots contain the mask, not local cache revisions. Seed these
  /// once; subsequent operations update them durably in the journal.
  func initializeBrickRevisions(_ revisions: [Int: UInt64]) {
    lock.withLock {
      if state.brickRevisions == nil {
        state.brickRevisions = revisions
        checkpointDirty = true
      }
    }
  }

  /// The caller (the SharePlay host in a group session) assigns the next revision.
  /// Duplicate delivery is harmless; revision gaps are rejected before persistence.
  func append(_ batch: BorgVRVolumeBrushBatch,
              onRecorded: ((BorgVRVolumeBrushBatch) -> Void)? = nil) throws {
    try lock.withLock {
      guard !failedWrite else { throw BorgVRVolumeEditError.corruptJournal }
      if state.operationIDs.contains(batch.id) { return }
      try Self.validate(batch, for: state)
      let payload = try Self.encode(batch)
      guard payload.count <= Self.maximumFrameBytes else { throw BorgVRVolumeEditError.invalidBrush }
      var frame = Data()
      Self.appendInteger(UInt64(payload.count), to: &frame)
      Self.appendInteger(Self.checksum(payload), to: &frame)
      frame.append(payload)
      let handle = try openStorage()
      do {
        try handle.write(contentsOf: frame)
        try handle.synchronize()
      } catch {
        // Never append behind a partially written frame in this process.
        failedWrite = true
        throw error
      }
      // The GPU can respond as soon as the operation is durable. Building the
      // canonical mask may take longer, but never blocks the render thread.
      onRecorded?(batch)
      try Self.apply(batch, to: &state)
      checkpointDirty = true
      journalDirty = true
    }
  }

  /// A newer overlapping edit replaces the work ID, so an old worker cannot clear it.
  /// Completion becomes durable at the next checkpoint. Repeating work after a crash is safe.
  func complete(_ work: BorgVRVolumeEditWork) {
    lock.withLock {
      let previous = state.pending.count
      state.pending.removeAll { $0.id == work.id }
      if previous != state.pending.count { checkpointDirty = true }
    }
  }

  func checkpoint() throws {
    try lock.withLock {
      guard !failedWrite else { throw BorgVRVolumeEditError.corruptJournal }
      guard let handle else { return }
      if checkpointDirty { try writeCheckpoint() }
      do {
        if journalDirty {
          try handle.truncate(atOffset: 0)
          try handle.seek(toOffset: 0)
          try handle.synchronize()
        }
        checkpointDirty = false
        journalDirty = false
      } catch { failedWrite = true; throw error }
    }
  }

  func discardAllEdits() throws {
    let snapshot = snapshot()
    let extent = SIMD3<Double>(snapshot.mask.size) * snapshot.mask.spacing
    // Record a full restore first. A crash before checkpointing still replays it,
    // and the monotonic revision prevents old in-flight brick versions from winning.
    try append(BorgVRVolumeBrushBatch(id: UUID(), revision: snapshot.revision + 1, mode: .restore,
      samples: [.init(center: extent * 0.5, radius: max(extent.x, extent.y, extent.z) * 2)], affectedBrickIDs: []))
    lock.withLock {
      state.pending.removeAll()
      state.operationIDs.removeAll()
      state.brickRevisions = [:]
    }
    try checkpoint()
  }

  func closeForRemoval() throws {
    try lock.withLock {
      guard state.mask.isOriginal, state.pending.isEmpty else {
        throw BorgVRVolumeEditError.invalidRevision
      }
      try handle?.close()
      handle = nil
      failedWrite = false
      checkpointDirty = false
      journalDirty = false
    }
  }

  private static func validate(_ batch: BorgVRVolumeBrushBatch, for state: Checkpoint) throws {
    guard state.revision < UInt64.max, batch.revision == state.revision + 1,
          !batch.samples.isEmpty, batch.samples.count <= BorgVRVolumeBrushLimits.maximumSampleCount,
          !state.operationIDs.contains(batch.id) else { throw BorgVRVolumeEditError.invalidRevision }
    for sample in batch.samples { try sample.validate() }
    _ = try batch.channels.validated(componentCount: state.mask.componentCount)
    guard batch.affectedBrickIDs?.allSatisfy({ $0 >= 0 }) != false else {
      throw BorgVRVolumeEditError.invalidBrick
    }
  }

  private static func apply(_ batch: BorgVRVolumeBrushBatch, to state: inout Checkpoint) throws {
    try validate(batch, for: state)
    if let ids = batch.affectedBrickIDs, state.brickRevisions != nil {
      for id in ids { state.brickRevisions?[id] = batch.revision }
    } else {
      state.brickRevisions = nil
    }
    for sample in batch.samples {
      try state.mask.apply(sample, mode: batch.mode, channels: batch.channels)
      var low = SIMD3<Int>.zero
      var high = SIMD3<Int>.zero
      for axis in 0..<3 {
        let a = (sample.center[axis] - sample.radius) / state.mask.spacing[axis] - 0.5
        let b = (sample.center[axis] + sample.radius) / state.mask.spacing[axis] + 0.5
        // Clamp in floating point before converting even very distant brush positions.
        low[axis] = Int(max(0, min(Double(state.mask.size[axis]), floor(a))))
        high[axis] = Int(max(0, min(Double(state.mask.size[axis]), ceil(b))))
      }
      var region = BorgVRVoxelRegion(lower: low, upper: high)
      guard !region.isEmpty else { continue }
      // Merge overlapping footprints transitively. The list remains compact for strokes.
      var index = 0
      while index < state.pending.count {
        let previous = state.pending[index].region
        if region.intersects(previous) {
          region = BorgVRVoxelRegion(
            lower: SIMD3(min(region.lower.x, previous.lower.x), min(region.lower.y, previous.lower.y),
                         min(region.lower.z, previous.lower.z)),
            upper: SIMD3(max(region.upper.x, previous.upper.x), max(region.upper.y, previous.upper.y),
                         max(region.upper.z, previous.upper.z))
          )
          state.pending.remove(at: index)
          index = 0
        } else { index += 1 }
      }
      state.pending.append(BorgVRVolumeEditWork(id: UUID(), region: region, revision: batch.revision))
    }
    // Retain work even after full restore: resident edited atlas bricks still need replacement.
    state.revision = batch.revision
    state.operationIDs.insert(batch.id)
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(value)
  }

  private static func appendInteger(_ value: UInt64, to data: inout Data) {
    for byte in 0..<8 { data.append(UInt8(truncatingIfNeeded: value >> (8 * byte))) }
  }

  private static func integer(_ data: Data, offset: Int) -> UInt64 {
    (0..<8).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
  }

  private static func checksum(_ data: Data) -> UInt64 {
    data.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
  }
}
