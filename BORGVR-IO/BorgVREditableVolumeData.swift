import Foundation
import Compression

enum BorgVRVolumeEditStorage {
  static func removeDataset(at datasetURL: URL) throws {
    guard datasetURL.isFileURL, datasetURL.pathExtension.lowercased() == "data" else {
      throw BorgVRVolumeEditError.invalidGeometry
    }
    for url in [datasetURL, datasetURL.appendingPathExtension("edits")] {
      do { try FileManager.default.removeItem(at: url) }
      catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }
  }

  static func directory(datasetURL: URL?, datasetID: String, applicationSupportURL: URL) throws -> URL {
    guard let id = UUID(uuidString: datasetID)?.uuidString else { throw BorgVRVolumeEditError.incompatibleDataset }
    let builtin = applicationSupportURL.appendingPathComponent("BorgVR/VolumeEdits", isDirectory: true)
      .appendingPathComponent(id, isDirectory: true)
    guard let datasetURL else { return builtin }
    guard datasetURL.isFileURL else { throw BorgVRVolumeEditError.invalidGeometry }
    return datasetURL.appendingPathExtension("edits").appendingPathComponent(id, isDirectory: true)
  }

  static func removeEmptyParent(of directory: URL) throws {
    let parent = directory.deletingLastPathComponent()
    if UUID(uuidString: parent.lastPathComponent) != nil,
       parent.deletingLastPathComponent().pathExtension == "edits" ||
       (UUID(uuidString: parent.lastPathComponent) != nil && parent.deletingLastPathComponent().lastPathComponent == "VolumeEdits") {
      if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
        if parent.path.withCString({ rmdir($0) }) == 0 {
          try removeEmptyParent(of: parent)
        }
      }
      return
    }
    guard parent.pathExtension == "edits" else { return }
    let contents = try FileManager.default.contentsOfDirectory(at: parent,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    for entry in contents {
      guard entry.lastPathComponent == ".DS_Store" else { return }
      let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
    }
    for entry in contents {
      let result = entry.path.withCString { unlink($0) }
      let code = errno
      if result != 0, code != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
    // Unlike recursive removal, rmdir preserves any concurrently created edits.
    let result = parent.path.withCString { rmdir($0) }
    let code = errno
    if result != 0, code != ENOENT, code != ENOTEMPTY, code != EEXIST {
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }
}

/// Retains a bounded set of immutable source bricks, preferring current atlas residents.
/// Editing a streamed resident brick must not download its original values again.
final class VolumeEditSourceCache: BORGVRDatasetProtocol {
  private let source: BORGVRDatasetProtocol
  private let lock = NSLock()
  private var bricks: [Int: [UInt8]] = [:]
  private var nonresidentBricks: Set<Int> = []
  private var residents: Set<Int> = []
  private var byteCount = 0
  private let brickBytes: Int
  private let budget: Int

  init(_ source: BORGVRDatasetProtocol, budget: Int = 32 * 1024 * 1024) {
    self.source = source
    self.budget = budget
    let m = source.getMetadata()
    brickBytes = m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent
  }

  func newRequest() { source.newRequest() }
  func getMetadata() -> BORGVRMetaData { source.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { source.allocateBrickBuffer() }
  func updateResidentBrickIDs(_ ids: Set<Int>) {
    lock.withLock {
      guard residents != ids else { return }
      residents = ids
      nonresidentBricks = Set(bricks.keys).subtracting(ids)
    }
  }
  func cachedBrick(index: Int) -> [UInt8]? { lock.withLock { bricks[index] } }

  func getRawBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws -> Int? {
    do { return try source.getRawBrick(index: index, outputBuffer: outputBuffer) }
    catch {
      // A streamed original may only remain in the decoded RAM cache after a
      // disconnect. Re-encoding those bytes is preferable to failing the export.
      if cachedBrick(index: index) != nil { return nil }
      throw error
    }
  }

  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    if let cached = lock.withLock({ bricks[index] }) {
      _ = cached.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, cached.count) }
      return
    }
    try source.getBrick(index: index, outputBuffer: outputBuffer)
    retain(index, buffer: outputBuffer)
  }

  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    try source.getFirstBrick(outputBuffer: outputBuffer)
    retain(getMetadata().brickMetadata.count - 1, buffer: outputBuffer)
  }

  private func retain(_ index: Int, buffer: UnsafeMutablePointer<UInt8>) {
    lock.withLock {
      guard bricks[index] == nil, brickBytes <= budget else { return }
      while byteCount + brickBytes > budget {
        // Prefer resident originals. Skip an uncached nonresident request when
        // the budget is already occupied entirely by atlas residents.
        guard let evicted = nonresidentBricks.first ?? (residents.contains(index) ? bricks.keys.first : nil) else { return }
        nonresidentBricks.remove(evicted)
        if let old = bricks.removeValue(forKey: evicted) { byteCount -= old.count }
      }
      bricks[index] = Array(UnsafeBufferPointer(start: buffer, count: brickBytes))
      if !residents.contains(index) { nonresidentBricks.insert(index) }
      byteCount += brickBytes
    }
  }
}

private struct VolumeEditExportPayload {
  let bytes: Data
  let ranges: [BORGVRComponentRange]
}

/// Bounds output buffering and reuses LZ4 workspace for newly computed bricks.
private final class VolumeEditExportWriter {
  let metadata: BORGVRMetaData
  let fullBrickBytes: Int
  private let file: FileHandle
  private var chunk = Data()
  private let chunkLimit = 8 * 1024 * 1024
  private var offset = 8
  private var minima: [Int]
  private var maxima: [Int]
  private var compressed: [UInt8] = []
  private var scratch: [UInt8] = []

  init(metadata: BORGVRMetaData, url: URL) throws {
    self.metadata = metadata
    fullBrickBytes = metadata.brickSize * metadata.brickSize * metadata.brickSize *
      metadata.componentCount * metadata.bytesPerComponent
    minima = Array(repeating: Int.max, count: metadata.componentCount)
    maxima = Array(repeating: 0, count: metadata.componentCount)
    guard FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 8)) else {
      throw BorgVRVolumeEditError.invalidGeometry
    }
    file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    chunk.reserveCapacity(chunkLimit)
  }

  deinit { try? file.close() }

  func encode(_ brick: BorgVRMaterializedEditBrick) throws -> VolumeEditExportPayload {
    guard brick.bytes.count == fullBrickBytes else { throw BorgVRVolumeEditError.invalidBufferSize }
    if metadata.compression {
      if compressed.isEmpty {
        compressed = Array(repeating: 0, count: fullBrickBytes)
        scratch = Array(repeating: 0, count: compression_encode_scratch_buffer_size(COMPRESSION_LZ4))
      }
      let count = brick.bytes.withUnsafeBufferPointer { input in
        compressed.withUnsafeMutableBufferPointer { output in
          scratch.withUnsafeMutableBytes { work in
            compression_encode_buffer(output.baseAddress!, output.count, input.baseAddress!, input.count,
              work.baseAddress, COMPRESSION_LZ4)
          }
        }
      }
      if count > 0, count < brick.bytes.count {
        return VolumeEditExportPayload(bytes: Data(compressed.prefix(count)), ranges: brick.componentRanges)
      }
    }
    return VolumeEditExportPayload(bytes: Data(brick.bytes), ranges: brick.componentRanges)
  }

  func append(_ payload: VolumeEditExportPayload) throws {
    guard !payload.bytes.isEmpty, payload.bytes.count <= fullBrickBytes,
          metadata.compression || payload.bytes.count == fullBrickBytes,
          payload.ranges.count == metadata.componentCount else {
      throw BorgVRVolumeEditError.invalidBufferSize
    }
    if chunk.count + payload.bytes.count > chunkLimit { try flush() }
    if payload.bytes.count >= chunkLimit { try file.write(contentsOf: payload.bytes) }
    else { chunk.append(payload.bytes) }
    metadata.append(offset: offset, size: payload.bytes.count,
      minValue: payload.ranges.map(\.minValue).min() ?? 0,
      maxValue: payload.ranges.map(\.maxValue).max() ?? 0, componentRanges: payload.ranges)
    offset += payload.bytes.count
    for c in minima.indices {
      minima[c] = min(minima[c], payload.ranges[c].minValue)
      maxima[c] = max(maxima[c], payload.ranges[c].maxValue)
    }
  }

  private func flush() throws {
    guard !chunk.isEmpty else { return }
    try file.write(contentsOf: chunk)
    chunk.removeAll(keepingCapacity: true)
  }

  func finish() throws {
    try flush()
    metadata.updateComponentRanges(minima.indices.map {
      BORGVRComponentRange(minValue: minima[$0], maxValue: maxima[$0])
    })
    try file.write(contentsOf: metadata.toData())
    try file.seek(toOffset: 0)
    try file.write(contentsOf: Data(from: UInt64(offset)))
    try file.synchronize()
    try file.close()
  }
}

/// Owns one edit journal/cache. Original dataset metadata and network payloads stay immutable.
final class BorgVREditableVolumeData: BORGVRDatasetProtocol, BorgVRVolumeGPUBrushSource, @unchecked Sendable {
  private let source: VolumeEditSourceCache
  private let executor: BorgVRVolumeEditExecutor
  private let materializer: BorgVRVolumeEditMaterializer?
  let journal: BorgVRVolumeEditJournal
  private let cache: BorgVRVolumeEditBrickCache
  private let directory: URL
  private let worker = DispatchQueue(label: "BorgVR.VolumeEditing", qos: .userInitiated)
  private let backgroundWorker = DispatchQueue(label: "BorgVR.VolumeEditHierarchy", qos: .utility)
  private let demandWorker = DispatchQueue(label: "BorgVR.VolumeEditDemand", qos: .userInitiated)
  private let coarseDemandWorker = DispatchQueue(label: "BorgVR.VolumeEditCoarseDemand", qos: .userInitiated)
  private let persistenceWorker = DispatchQueue(label: "BorgVR.VolumeEditPersistence", qos: .utility)
  private let originalWorker = DispatchQueue(label: "BorgVR.VolumeEditOriginals", qos: .userInitiated)
  private let lock = NSLock()
  private var desired: [Int: UInt64] = [:]
  private var ranges: [Int: BrickMetadata] = [:]
  private var pendingEraseRanges: [Int: BrickMetadata] = [:]
  private var dirtyIDs: Set<Int> = []
  private var queued: Set<Int> = []
  private var residentIDs: Set<Int> = []
  private var readyBricks: [Int: BorgVRMaterializedEditBrick] = [:]
  private var readyOrder: [Int] = []
  private var readyBytes = 0
  private var persistencePending: [Int: BorgVRMaterializedEditBrick] = [:]
  private var persistenceRunning = false
  private var persistenceActive: BorgVRMaterializedEditBrick?
  private var persistenceFailures: [Int: (revision: UInt64, error: Error)] = [:]
  private static let readyBudget = 32 * 1024 * 1024
  private var changes: [(UInt64, [Int])] = []
  private var revision: UInt64 = 0
  private var backgroundIDs: [Int] = []
  private var backgroundRunning = false
  private var stopped = false
  private var foregroundJobs = 0
  private var gpuBrushRendererCount = 0
  private var recordedRevision: UInt64 = 0
  private var brushHistory: [BorgVRVolumeBrushBatch] = []
  private var originalRequests: Set<Int> = []
  private var resetting = false
  private var maskHasEdits = false
  private var editGeneration: UInt64 = 0
  private let materializations = DispatchGroup()
  private let persistenceJobs = DispatchGroup()
  private let persistenceSpace = DispatchSemaphore(value: 0)
  private let logger: LoggerBase?
  private let backgroundWorkChanged: (@Sendable (Bool) -> Void)?
  private let statusDelivery = DispatchQueue(label: "BorgVR.VolumeEditStatus")
  private var lastBackgroundWorkStatus = false

  init(source: BORGVRDatasetProtocol, directory: URL, logger: LoggerBase?,
       executor: BorgVRVolumeEditExecutor? = nil,
       backgroundWorkChanged: (@Sendable (Bool) -> Void)? = nil,
       initialSnapshot: BorgVRVolumeEditSnapshot? = nil, persistOriginalSnapshot: Bool = false) throws {
    let cachedSource = VolumeEditSourceCache(source)
    self.source = cachedSource
    self.directory = directory
    self.logger = logger
    self.backgroundWorkChanged = backgroundWorkChanged
    let m = source.getMetadata()
    journal = try BorgVRVolumeEditJournal(directory: directory, datasetID: m.uniqueID,
      size: SIMD3(m.width, m.height, m.depth),
      spacing: SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ)),
      componentCount: m.componentCount,
      initialSnapshot: initialSnapshot, persistOriginalSnapshot: persistOriginalSnapshot)
    cache = try BorgVRVolumeEditBrickCache(url: directory.appendingPathComponent("bricks.cache"),
                                          editStateID: journal.snapshot().editStateID)
    // The dataset format does not record its padding mode. Preserve original padding
    // where possible; new boundaries use clamping consistently on every platform.
    let materializer = executor == nil ? try BorgVRVolumeEditMaterializer(source: cachedSource) : nil
    self.materializer = materializer
    self.executor = try executor ?? materializer ?? BorgVRCPUVolumeEditExecutor(source: cachedSource, border: .clamp)
    let snapshot = journal.snapshot()
    maskHasEdits = !snapshot.mask.isOriginal
    recordedRevision = snapshot.revision
    var recoveredRevisions: [Int: UInt64] = [:]
    if !snapshot.mask.isOriginal {
      if snapshot.brickRevisions == nil {
        for (level, layout) in m.levelMetadata.enumerated() {
          let count = layout.totalBricks.x * layout.totalBricks.y * layout.totalBricks.z
          for id in layout.prevBricks..<(layout.prevBricks + count) {
            if snapshot.mask.coverage(in: Self.brickFootprint(index: id, level: level, metadata: m)) != .original {
              recoveredRevisions[id] = snapshot.revision
            }
          }
        }
      }
      for (id, target) in snapshot.brickRevisions ?? recoveredRevisions {
        guard m.brickMetadata.indices.contains(id) else { throw BorgVRVolumeEditError.corruptJournal }
        if let saved = cache.summary(index: id, revision: target), saved.matchesOriginal ||
          (saved.metadata.size == m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent &&
           saved.metadata.componentRanges.count == m.componentCount) {
          guard !saved.matchesOriginal else { continue }
          desired[id] = target
          ranges[id] = saved.metadata
        } else {
          let level = m.levelMetadata.lastIndex { $0.prevBricks <= id }!
          guard snapshot.mask.coverage(in: Self.brickFootprint(index: id, level: level, metadata: m)) != .original else { continue }
          desired[id] = target
          pendingEraseRanges[id] = Self.eraseBounds(source.visibilityMetadata(index: id))
          dirtyIDs.insert(id)
          backgroundIDs.append(id)
        }
      }
      backgroundIDs.sort(by: >)
      if !desired.isEmpty { publish(Array(desired.keys)) }
    }
    if snapshot.brickRevisions == nil {
      journal.initializeBrickRevisions(recoveredRevisions)
      try journal.checkpoint()
    }
    updateBackgroundWorkStatus()
  }

  var hasPendingBrickUpdates: Bool { lock.withLock { pendingBrickUpdates } }

  func editingStatus() -> BorgVRVolumeEditStatus? {
    lock.withLock {
      guard !stopped else { return nil }
      return BorgVRVolumeEditStatus(datasetID: getMetadata().uniqueID, hasEdits: maskHasEdits,
        isUpdatingBricks: pendingBrickUpdates, pendingBrickCount: dirtyIDs.union(persistenceFailures.keys).count)
    }
  }

  private var pendingBrickUpdates: Bool {
    !stopped && (resetting || !dirtyIDs.isEmpty || !queued.isEmpty ||
      !persistencePending.isEmpty || persistenceActive != nil || !persistenceFailures.isEmpty)
  }

  /// Call with the dataset lock held (or before publishing the initialized object).
  private func updateBackgroundWorkStatus() {
    let active = pendingBrickUpdates
    guard active != lastBackgroundWorkStatus else { return }
    lastBackgroundWorkStatus = active
    if let backgroundWorkChanged {
      // Preserve event order without running UI callbacks under the dataset lock.
      statusDelivery.async { backgroundWorkChanged(active) }
    }
  }

  var contentRevision: UInt64 { lock.withLock { revision } }
  func attachGPUBrushRenderer() { lock.withLock { gpuBrushRendererCount += 1 } }
  func detachGPUBrushRenderer() { lock.withLock { gpuBrushRendererCount = max(0, gpuBrushRendererCount - 1) } }
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] { lock.withLock { brushHistory } }
  var recordedBrushRevision: UInt64 { lock.withLock { recordedRevision } }
  func gpuReadableRevision(index: Int) -> UInt64? {
    lock.withLock { dirtyIDs.contains(index) ? nil : recordedRevision }
  }
  func cachedOriginalBrick(index: Int) -> [UInt8]? {
    if let bytes = source.cachedBrick(index: index) { return bytes }
    if lock.withLock({ !stopped && !resetting && originalRequests.insert(index).inserted }) {
      originalWorker.async { [self] in
        defer { _ = lock.withLock { originalRequests.remove(index) } }
        let buffer = source.allocateBrickBuffer()
        defer { buffer.deallocate() }
        try? source.getBrick(index: index, outputBuffer: buffer)
      }
    }
    return nil
  }
  func getMetadata() -> BORGVRMetaData { source.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { source.allocateBrickBuffer() }
  func updateResidentBrickIDs(_ ids: Set<Int>) {
    lock.withLock { residentIDs = ids }
    source.updateResidentBrickIDs(ids)
  }
  func prepareForRendering() {
    let overview = getMetadata().brickMetadata.count - 1
    // Rendering is gated on this brick, so GPU feedback cannot request it yet.
    // Use the demand lane rather than waiting behind the fine-brick backlog.
    if lock.withLock({ dirtyIDs.contains(overview) }) { enqueue(overview) }
    scheduleBackgroundWork()
  }
  func newRequest() {
    if lock.withLock({ queued.isEmpty && foregroundJobs == 0 }) { source.newRequest() }
    scheduleBackgroundWork()
  }

  deinit { try? journal.checkpoint() }

  func stop() {
    lock.withLock { stopped = true; backgroundIDs.removeAll(); updateBackgroundWorkStatus() }
    worker.async { [self] in
      try? journal.checkpoint()
      persistenceWorker.async { [self] in try? cache.compactIfNeeded() }
    }
  }

  /// Close admission, cancel workers, then close files before another state reuses them.
  func shutdown(completion: @escaping @Sendable (Error?) -> Void) {
    lock.withLock {
      stopped = true; editGeneration &+= 1; backgroundIDs.removeAll(); persistencePending.removeAll()
    }
    worker.async { [self] in
      backgroundWorker.sync {}
      demandWorker.sync {}
      coarseDemandWorker.sync {}
      originalWorker.sync {}
      materializations.wait()
      do {
        try persistenceWorker.sync { try cache.closeStorage() }
        try journal.closeStorage()
        completion(nil)
      } catch { completion(error) }
    }
  }

  func captureSnapshot(completion: @escaping @Sendable (BorgVRVolumeEditSnapshot) -> Void) {
    worker.async { [self] in completion(journal.transferableSnapshot(datasetID: getMetadata().uniqueID)) }
  }

  func visibilityMetadata(index: Int) -> BrickMetadata? {
    lock.withLock {
      desired[index] == nil ? source.visibilityMetadata(index: index) : ranges[index] ?? pendingEraseRanges[index]
    }
  }

  private static func eraseBounds(_ previous: BrickMetadata?, channels: BorgVRVolumeEditChannels = .all) -> BrickMetadata? {
    guard let previous else { return nil }
    if previous.componentRanges.allSatisfy({ $0.minValue == 0 }) { return previous }
    // Erase can only lower values. Include zero and intermediate values from
    // filtering/LOD averaging, but never expand the previous upper bounds.
    let ranges = previous.componentRanges.enumerated().map { channel, range in
      channels.contains(channel) ? BORGVRComponentRange(minValue: 0, maxValue: range.maxValue) : range
    }
    return BrickMetadata(offset: previous.offset, size: previous.size,
      minValue: ranges.map(\.minValue).min() ?? 0, maxValue: previous.maxValue, componentRanges: ranges)
  }

  func changedBrickIDs(since oldRevision: UInt64) -> [Int] {
    lock.withLock {
      if let first = changes.first, oldRevision + 1 < first.0 {
        return Array(getMetadata().brickMetadata.indices)
      }
      return Array(Set(changes.filter { $0.0 > oldRevision }.flatMap(\.1)))
    }
  }

  private func publish(_ ids: [Int]) {
    revision += 1
    changes.append((revision, ids))
    if changes.count > 128 { changes.removeFirst() }
  }

  private func materialize(index: Int, mask: BorgVRVolumeEditMask, revision: UInt64,
                           revisions: [Int: UInt64]? = nil, foreground: Bool = false,
                           isCancelled: @escaping () -> Bool = { false }) throws -> BorgVRMaterializedEditBrick {
    let generation = try lock.withLock {
      guard !stopped, !resetting else { throw CancellationError() }
      materializations.enter()
      return editGeneration
    }
    defer { materializations.leave() }
    let cancelled = { [self] in
      isCancelled() || lock.withLock { stopped || resetting || editGeneration != generation || (!foreground && foregroundJobs > 0) }
    }
    if let materializer {
      return try materializer.materialize(index: index, mask: mask, revision: revision, revisions: revisions,
        useGPU: foreground, cached: { [self] id, target in try cachedMaterializedBrick(index: id, revision: target) },
        store: { [self] result in
          guard lock.withLock({ shouldCommit(result) }) else { return }
          while lock.withLock({ persistencePending.values.reduce(0) { $0 + $1.bytes.count } > Self.readyBudget }) {
            if cancelled() { throw CancellationError() }
            _ = persistenceSpace.wait(timeout: .now() + 0.05)
          }
          commit(result)
        }, isCancelled: cancelled)
    }
    let result = try executor.materialize(index: index, mask: mask, revision: revision, isCancelled: cancelled)
    commit(result)
    return result
  }

  private func cachedMaterializedBrick(index: Int, revision: UInt64) throws -> BorgVRMaterializedEditBrick? {
    if let ready = lock.withLock({
      [readyBricks[index], persistencePending[index], persistenceActive?.index == index ? persistenceActive : nil]
        .compactMap { $0 }.first { $0.revision == revision }
    }) { return ready }
    let m = getMetadata()
    guard let result = try? cache.brick(index: index, revision: revision),
      result.bytes.count == m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent,
      result.componentRanges.count == m.componentCount else { return nil }
    return result
  }

  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let (target, ready) = lock.withLock { () -> (UInt64?, BorgVRMaterializedEditBrick?) in
      let target = desired[index]
      let ready = readyBricks[index] ?? persistencePending[index] ??
        (persistenceActive?.index == index ? persistenceActive : nil)
      let available = ready.map { $0.revision == target || (target == nil && $0.matchesOriginal) } ?? false
      return (target, available ? ready : nil)
    }
    if let ready {
      _ = ready.bytes.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, ready.bytes.count) }
      return
    }
    guard let target else { try source.getBrick(index: index, outputBuffer: outputBuffer); return }
    if lock.withLock({ dirtyIDs.contains(index) }) {
      enqueue(index)
      throw BORGVRDataError.brickNotYetAvailable(index: index)
    }
    let m = getMetadata()
    if let summary = try? cache.readBrick(index: index, revision: target, into: outputBuffer,
      byteCount: m.brickSize * m.brickSize * m.brickSize * m.componentCount * m.bytesPerComponent) {
      lock.withLock {
        if ranges[index] == nil, desired[index] == target {
          ranges[index] = summary.metadata
          publish([index])
        }
      }
      return
    }
    // A discarded or corrupt disposable cache must not leave metadata claiming
    // that this brick is ready; otherwise the worker would skip its reconstruction.
    lock.withLock {
      if desired[index] == target {
        ranges[index] = nil; dirtyIDs.insert(index); updateBackgroundWorkStatus()
      }
    }
    enqueue(index)
    throw BORGVRDataError.brickNotYetAvailable(index: index)
  }

  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let index = getMetadata().brickMetadata.count - 1
    guard let target = lock.withLock({ desired[index] }) else {
      try source.getFirstBrick(outputBuffer: outputBuffer)
      return
    }
    if !lock.withLock({ dirtyIDs.contains(index) }),
       let _ = try? getBrick(index: index, outputBuffer: outputBuffer) { return }
    let snapshot = journal.snapshot()
    let result: BorgVRMaterializedEditBrick
    do {
      result = try materialize(index: index, mask: snapshot.mask, revision: target, revisions: snapshot.brickRevisions)
    } catch BORGVRDataError.brickNotYetAvailable {
      try source.getFirstBrick(outputBuffer: outputBuffer)
      enqueue(index)
      return
    }
    _ = result.bytes.withUnsafeBytes { memcpy(outputBuffer, $0.baseAddress!, result.bytes.count) }
  }

  func brush(_ samples: [BorgVRVolumeBrushSample], mode: BorgVRVolumeBrushMode,
             channels: BorgVRVolumeEditChannels = .all,
             cancellationToken: BorgVRVolumeConversionCancellationToken? = nil,
             operationID: UUID = UUID(), expectedRevision: UInt64? = nil,
             completion: (@Sendable (Error?) -> Void)? = nil) {
    recordBrush(samples, mode: mode, channels: channels, cancellationToken: cancellationToken, operationID: operationID,
      expectedRevision: expectedRevision, onRecorded: nil, completion: completion)
  }

  func recordBrush(_ samples: [BorgVRVolumeBrushSample], mode: BorgVRVolumeBrushMode,
             channels: BorgVRVolumeEditChannels = .all,
             cancellationToken: BorgVRVolumeConversionCancellationToken? = nil,
             operationID: UUID = UUID(), expectedRevision: UInt64? = nil,
             onRecorded: (@Sendable (BorgVRVolumeBrushBatch) -> Void)? = nil,
             completion: (@Sendable (Error?) -> Void)? = nil) {
    guard !lock.withLock({ stopped || resetting }) else { completion?(CancellationError()); return }
    worker.async { [self] in
      guard !lock.withLock({ stopped || resetting }) else { completion?(CancellationError()); return }
      do {
        try cancellationToken?.checkCancellation()
        guard !samples.isEmpty, samples.count <= BorgVRVolumeBrushLimits.maximumSampleCount else {
          throw BorgVRVolumeEditError.invalidRevision
        }
        for sample in samples { try sample.validate() }
        let channels = try channels.validated(componentCount: getMetadata().componentCount)
        let snapshot = journal.snapshot()
        guard snapshot.revision < UInt64.max else { throw BorgVRVolumeEditError.invalidRevision }
        let ids = affectedBrickIDs(samples, restoring: mode == .restore ? snapshot.mask : nil, channels: channels)
        guard !ids.isEmpty || expectedRevision != nil else { completion?(nil); return }
        if let expectedRevision, expectedRevision != snapshot.revision + 1 {
          throw BorgVRVolumeEditError.invalidRevision
        }
        let batch = BorgVRVolumeBrushBatch(id: operationID, revision: snapshot.revision + 1,
          mode: mode, samples: samples, channels: channels, affectedBrickIDs: ids)
        try journal.append(batch) { [self] recorded in
          lock.withLock {
            recordedRevision = recorded.revision
            brushHistory.append(recorded)
            // A lagging atlas falls back to the canonical CPU result on a history gap.
            if brushHistory.count > 256 { brushHistory.removeFirst() }
            for id in ids {
              let previous = desired[id] == nil ? source.visibilityMetadata(index: id)
                : ranges[id] ?? pendingEraseRanges[id]
              pendingEraseRanges[id] = mode == .erase ? Self.eraseBounds(previous, channels: channels) : nil
              desired[id] = recorded.revision
              persistenceFailures[id] = nil
              ranges[id] = nil
              dirtyIDs.insert(id)
            }
            publish(ids)
            updateBackgroundWorkStatus()
          }
          onRecorded?(recorded)
        }
        let updated = journal.snapshot()
        lock.withLock { maskHasEdits = !updated.mask.isOriginal }
        if !lock.withLock({ gpuBrushRendererCount > 0 }) {
          // CPU fallback prioritizes the finest resident bricks. The GPU path
          // previews all resident LODs without waiting for materialization.
          let residents = lock.withLock { residentIDs.intersection(ids) }
          let levels = getMetadata().levelMetadata
          let finestLevel = residents.compactMap { id in levels.lastIndex { $0.prevBricks <= id } }.min()
          let visible = residents.filter { id in levels.lastIndex { $0.prevBricks <= id } == finestLevel }.sorted()
          for id in visible {
            do {
              _ = try materialize(index: id, mask: updated.mask, revision: updated.revision, revisions: updated.brickRevisions)
            } catch BORGVRDataError.brickNotYetAvailable {
              // Retain the previous atlas page while missing source data is fetched.
            }
          }
        }
        if updated.revision % 64 == 0 { try journal.checkpoint() }
        lock.withLock { backgroundIDs = Array(Set(backgroundIDs + ids)).sorted(by: >) }
        scheduleBackgroundWork()
        // Rendering requests take priority. Remaining persistent work is resumed lazily.
        completion?(nil)
      } catch is CancellationError { completion?(CancellationError()) }
      catch { logger?.error("Volume brush failed: \(error.localizedDescription)"); completion?(error) }
    }
  }

  func discardAllEdits(completion: @escaping @Sendable (Error?) -> Void) {
    let accepted = lock.withLock { () -> Bool in
      guard !stopped, !resetting, foregroundJobs == 0 else { return false }
      resetting = true
      editGeneration &+= 1
      backgroundIDs.removeAll()
      backgroundRunning = false
      persistencePending.removeAll()
      updateBackgroundWorkStatus()
      return true
    }
    guard accepted else { completion(BorgVRVolumeEditError.invalidRevision); return }
    worker.async { [self] in
      var failure: Error?
      defer { lock.withLock { resetting = false; updateBackgroundWorkStatus() }; completion(failure) }
      do {
        // Admission is closed and active CPU jobs see cancellation. Drain all
        // editing queues before closing or removing any of their files.
        backgroundWorker.sync {}
        demandWorker.sync {}
        coarseDemandWorker.sync {}
        originalWorker.sync {}
        materializations.wait()
        try journal.discardAllEdits()
        let revision = journal.snapshot().revision
        lock.withLock {
          desired.removeAll(); ranges.removeAll(); pendingEraseRanges.removeAll(); dirtyIDs.removeAll()
          maskHasEdits = false
          readyBricks.removeAll(); readyOrder.removeAll(); readyBytes = 0
          backgroundIDs.removeAll(); persistencePending.removeAll()
          persistenceFailures.removeAll()
          brushHistory.removeAll(); recordedRevision = revision
          publish(Array(getMetadata().brickMetadata.indices))
        }
        // Drain old IO before unlinking files. Closed stores stay in memory until
        // another brush operation recreates them; idle checkpoints are no-ops.
        try persistenceWorker.sync { try cache.closeForRemoval() }
        try journal.closeForRemoval()
        try BorgVRVolumeEditCatalog.removeStateStorage(at: directory)
      } catch { failure = error }
    }
  }

  private func enqueue(_ index: Int, background: Bool = false,
                       completion: (@Sendable (Bool) -> Void)? = nil) {
    guard lock.withLock({
      guard !stopped, !resetting, queued.insert(index).inserted else { return false }
      updateBackgroundWorkStatus()
      return true
    }) else {
      completion?(false); return
    }
    // A newly exposed brick must not wait behind an expensive hierarchy rebuild.
    // Neither CPU lane is allowed to block recording the next brush operation.
    let fineCount = getMetadata().levelMetadata.dropFirst().first?.prevBricks ?? getMetadata().brickMetadata.count
    let queue = background ? backgroundWorker : (index < fineCount ? demandWorker : coarseDemandWorker)
    queue.async { [self] in
      var needsRetry = false
      defer {
        lock.withLock {
          queued.remove(index)
          if needsRetry, !stopped, !resetting, !backgroundIDs.contains(index) { backgroundIDs.insert(index, at: 0) }
          updateBackgroundWorkStatus()
        }
        completion?(needsRetry)
        if needsRetry { scheduleBackgroundWork() }
      }
      guard !lock.withLock({ stopped || resetting }) else { return }
      do {
        let snapshot = journal.snapshot()
        guard let target = lock.withLock({ desired[index] }) else { return }
        guard target <= snapshot.revision else { needsRetry = true; return }
        if lock.withLock({ ranges[index] != nil }) { return }
        _ = try materialize(index: index, mask: snapshot.mask, revision: target, revisions: snapshot.brickRevisions)
        needsRetry = lock.withLock { desired[index].map { $0 != target } ?? false }
      } catch is CancellationError {
        // Foreground work may temporarily preempt demand/background jobs.
        // Discard/close must not requeue the cancelled generation.
        needsRetry = lock.withLock { !stopped && !resetting }
      } catch BORGVRDataError.brickNotYetAvailable {
        needsRetry = true
        // The next render request retries after network bricks become available.
      } catch { logger?.warning("Volume edit brick is waiting: \(error.localizedDescription)") }
    }
  }

  private func scheduleBackgroundWork() {
    guard let generation = lock.withLock({ () -> UInt64? in
      guard !backgroundRunning, !stopped, !resetting, foregroundJobs == 0, !backgroundIDs.isEmpty else { return nil }
      backgroundRunning = true
      return editGeneration
    }) else { return }
    worker.async { [self] in backgroundStep(generation: generation) }
  }

  private func backgroundStep(generation: UInt64) {
    guard lock.withLock({ !stopped && !resetting && editGeneration == generation }) else { return }
    if lock.withLock({ foregroundJobs > 0 }) {
      lock.withLock { backgroundRunning = false }
      return
    }
    let waitingForPersistence = lock.withLock {
      !stopped && persistencePending.values.reduce(0) { $0 + $1.bytes.count } > Self.readyBudget
    }
    if waitingForPersistence {
      worker.asyncAfter(deadline: .now() + 0.02) { [self] in backgroundStep(generation: generation) }
      return
    }
    let (next, waiting) = lock.withLock { () -> (Int?, Bool) in
      guard !stopped else {
        backgroundRunning = false
        return (nil, false)
      }
      if let id = backgroundIDs.popLast() { return (id, false) }
      if !queued.isEmpty { return (nil, true) }
      backgroundRunning = false
      return (nil, false)
    }
    if waiting {
      worker.asyncAfter(deadline: .now() + 0.02) { [self] in backgroundStep(generation: generation) }
      return
    }
    guard let next else {
      if lock.withLock({ desired.allSatisfy { ranges[$0.key] != nil } }) {
        for work in journal.snapshot().pending { journal.complete(work) }
        try? journal.checkpoint()
        persistenceWorker.async { [self] in try? cache.compactIfNeeded() }
      }
      return
    }
    // Keep only one lazy brick in flight. Continue immediately on success instead
    // of imposing a 50-bricks/second limit or queuing work ahead of render requests.
    enqueue(next, background: true) { [self] retry in
      if retry {
        worker.asyncAfter(deadline: .now() + 0.02) { [self] in backgroundStep(generation: generation) }
      } else {
        worker.async { [self] in backgroundStep(generation: generation) }
      }
    }
  }

  /// Bakes a stable mask revision, independent of unfinished cached brick jobs.
  func preparePendingEdits(cancellationToken: BorgVRVolumeConversionCancellationToken,
                           progress: @escaping @Sendable (Double) -> Void,
                           completion: @escaping @Sendable (Error?) -> Void) {
    let accepted = lock.withLock { () -> Bool in
      guard !stopped, !resetting else { return false }
      foregroundJobs += 1
      return true
    }
    guard accepted else { completion(CancellationError()); return }
    worker.async { [self] in
      let snapshot = journal.snapshot()
      let pending = lock.withLock { Array(dirtyIDs.union(persistenceFailures.keys)).sorted() }
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        var failure: Error?
        do {
          progress(0)
          for (offset, id) in pending.enumerated() {
            let target = snapshot.brickRevisions?[id] ?? snapshot.revision
            let deadline = Date().addingTimeInterval(60)
            while true {
              try cancellationToken.checkCancellation()
              do {
                _ = try materialize(index: id, mask: snapshot.mask, revision: target,
                  revisions: snapshot.brickRevisions, foreground: true, isCancelled: { cancellationToken.isCancelled })
                break
              } catch BORGVRDataError.brickNotYetAvailable where Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            }
            progress(Double(offset + 1) / Double(max(1, pending.count)))
          }
          try flushPreparedEdits(cancellationToken: cancellationToken)
          progress(1)
        } catch { failure = error }
        finishForegroundWork()
        completion(failure)
      }
    }
  }

  private func flushPreparedEdits(cancellationToken: BorgVRVolumeConversionCancellationToken?) throws {
    try waitForPersistence(cancellationToken: cancellationToken)
    let failures = lock.withLock { persistenceFailures.map { ($0.key, $0.value.revision) } }
    if !failures.isEmpty {
      let snapshot = journal.snapshot()
      for (index, revision) in failures {
        try cancellationToken?.checkCancellation()
        _ = try materialize(index: index, mask: snapshot.mask, revision: revision,
          revisions: snapshot.brickRevisions, foreground: true,
          isCancelled: { cancellationToken?.isCancelled == true })
      }
      try waitForPersistence(cancellationToken: cancellationToken)
    }
    if let error = lock.withLock({ persistenceFailures.values.first?.error }) { throw error }
    if lock.withLock({ stopped || resetting }) { throw CancellationError() }
    try cache.synchronize()
    try worker.sync {
      if lock.withLock({ desired.allSatisfy { ranges[$0.key] != nil } }) {
        for work in journal.snapshot().pending { journal.complete(work) }
        try journal.checkpoint()
      }
    }
  }

  private func waitForPersistence(cancellationToken: BorgVRVolumeConversionCancellationToken?) throws {
    while persistenceJobs.wait(timeout: .now() + 0.05) == .timedOut {
      try cancellationToken?.checkCancellation()
      if lock.withLock({ stopped || resetting }) { throw CancellationError() }
    }
    try cancellationToken?.checkCancellation()
  }

  private func finishForegroundWork() {
    lock.withLock {
      foregroundJobs -= 1
      backgroundIDs = Array(Set(backgroundIDs).union(dirtyIDs)).sorted(by: >)
      updateBackgroundWorkStatus()
    }
    scheduleBackgroundWork()
  }

  func export(to url: URL, name: String? = nil, description: String? = nil,
              cancellationToken: BorgVRVolumeConversionCancellationToken? = nil,
              progress: @escaping @Sendable (Double) -> Void = { _ in },
              completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
    let accepted = lock.withLock {
      guard !stopped, !resetting else { return false }
      foregroundJobs += 1
      return true
    }
    guard accepted else { completion(.failure(BorgVRVolumeEditError.invalidRevision)); return }
    // Capture after earlier brush input, but before later input on the same queue.
    // Waiting for a mask snapshot must not block the UI thread.
    worker.async { [self] in
      let snapshot = journal.snapshot()
      DispatchQueue.global(qos: .userInitiated).async { [self] in
        let result = Result<URL, Error> {
          func checkCancellation() throws {
            try cancellationToken?.checkCancellation()
            if lock.withLock({ stopped }) { throw CancellationError() }
          }
          try checkCancellation()
          progress(0)
          let metadata = getMetadata().editExportMetadata()
          if let name { metadata.datasetDescription = name }
          if let description { metadata.metaDescription = description }
          let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID()).data")
          defer { try? FileManager.default.removeItem(at: temporary) }
          let writer = try VolumeEditExportWriter(metadata: metadata, url: temporary)
          let rawBuffer = source.allocateBrickBuffer()
          defer { rawBuffer.deallocate() }
          let brickCount = getMetadata().brickMetadata.count
          var reportedPercent = 0
          for index in getMetadata().brickMetadata.indices {
            let deadline = Date().addingTimeInterval(60)
            let payload: VolumeEditExportPayload
            while true {
              try checkCancellation()
              do {
                payload = try exportPayload(index: index, snapshot: snapshot, rawBuffer: rawBuffer, writer: writer) { [self] in
                  cancellationToken?.isCancelled == true || lock.withLock { stopped }
                }
                break
              } catch BORGVRDataError.brickNotYetAvailable where Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
              }
            }
            try checkCancellation()
            try writer.append(payload)
            let percent = (index + 1) * 99 / max(1, brickCount)
            if percent > reportedPercent {
              reportedPercent = percent
              progress(Double(percent) / 100)
            }
          }
          try checkCancellation()
          try writer.finish()
          try flushPreparedEdits(cancellationToken: cancellationToken)
          try checkCancellation()
          try FileManager.default.moveItem(at: temporary, to: url)
          progress(1)
          return url
        }
        finishForegroundWork()
        completion(result)
      }
    }
  }

  private func exportPayload(index: Int, snapshot: BorgVRVolumeEditJournal.Snapshot,
                             rawBuffer: UnsafeMutablePointer<UInt8>, writer: VolumeEditExportWriter,
                             isCancelled: @escaping () -> Bool) throws -> VolumeEditExportPayload {
    let metadata = getMetadata()
    let original = metadata.brickMetadata[index]
    func originalPayload() throws -> VolumeEditExportPayload {
      if let count = try source.getRawBrick(index: index, outputBuffer: rawBuffer) {
        guard count == original.size, count > 0, count <= writer.fullBrickBytes else {
          throw BorgVRVolumeEditError.invalidBufferSize
        }
        return VolumeEditExportPayload(bytes: Data(bytes: rawBuffer, count: count), ranges: original.componentRanges)
      }
      try source.getBrick(index: index, outputBuffer: rawBuffer)
      return try writer.encode(BorgVRMaterializedEditBrick(index: index, revision: 0,
        bytes: Array(UnsafeBufferPointer(start: rawBuffer, count: writer.fullBrickBytes)),
        componentRanges: original.componentRanges, matchesOriginal: true))
    }
    // The per-brick map avoids walking the mask for the usually large untouched part.
    if snapshot.mask.isOriginal || (snapshot.brickRevisions != nil && snapshot.brickRevisions?[index] == nil) {
      return try originalPayload()
    }
    let level = metadata.levelMetadata.lastIndex { $0.prevBricks <= index }!
    if snapshot.mask.coverage(in: Self.brickFootprint(index: index, level: level, metadata: metadata)) == .original {
      return try originalPayload()
    }
    let target = snapshot.brickRevisions?[index] ?? snapshot.revision
    if let saved = try? cache.storedBrick(index: index, revision: target) {
      if saved.original { return try originalPayload() }
      if saved.rawByteCount == writer.fullBrickBytes, saved.componentRanges.count == metadata.componentCount {
        // The destination uses the same raw-or-LZ4 per-brick convention as the cache.
        if metadata.compression || !saved.compressed {
          return VolumeEditExportPayload(bytes: saved.payload, ranges: saved.componentRanges)
        }
        if let decoded = try? saved.materializedBrick() { return try writer.encode(decoded) }
      }
    }
    let ready = lock.withLock { () -> BorgVRMaterializedEditBrick? in
      [readyBricks[index], persistencePending[index], persistenceActive?.index == index ? persistenceActive : nil]
        .compactMap { $0 }.first { $0.revision == target }
    }
    if let ready {
      if ready.matchesOriginal { return try originalPayload() }
      return try writer.encode(ready)
    }
    let computed = try materialize(index: index, mask: snapshot.mask, revision: target,
      revisions: snapshot.brickRevisions, foreground: true, isCancelled: isCancelled)
    return try writer.encode(computed)
  }

  private func shouldCommit(_ result: BorgVRMaterializedEditBrick) -> Bool {
    let retry = persistenceFailures[result.index]?.revision == result.revision
    let current =
      desired[result.index] == result.revision
      || (retry && desired[result.index] == nil && result.matchesOriginal)
    let alreadyPersisting =
      persistencePending[result.index]?.revision == result.revision
      || (persistenceActive?.index == result.index
        && persistenceActive?.revision == result.revision)
    return current && (dirtyIDs.contains(result.index) || (retry && !alreadyPersisting))
  }

  private func commit(_ result: BorgVRMaterializedEditBrick) {
    let startPersistence = lock.withLock { () -> Bool in
      guard !stopped, !resetting else { return false }
      guard shouldCommit(result) else { return false }
      if dirtyIDs.contains(result.index) {
        if let previous = readyBricks.removeValue(forKey: result.index) {
          readyBytes -= previous.bytes.count
        }
        readyOrder.removeAll { $0 == result.index }
        dirtyIDs.remove(result.index)
        pendingEraseRanges[result.index] = nil
        readyBricks[result.index] = result
        readyOrder.append(result.index)
        readyBytes += result.bytes.count
        while readyBytes > Self.readyBudget, readyOrder.count > 1 {
          let evicted = readyOrder.removeFirst()
          if let brick = readyBricks.removeValue(forKey: evicted) {
            readyBytes -= brick.bytes.count
          }
        }
        if result.matchesOriginal {
          desired[result.index] = nil
          ranges[result.index] = nil
        } else {
          ranges[result.index] = BrickMetadata(
            offset: 0, size: result.bytes.count,
            minValue: result.componentRanges.map(\.minValue).min() ?? 0,
            maxValue: result.componentRanges.map(\.maxValue).max() ?? 0,
            componentRanges: result.componentRanges)
        }
        publish([result.index])
      }
      persistencePending[result.index] = result
      updateBackgroundWorkStatus()
      guard !persistenceRunning else { return false }
      persistenceRunning = true
      persistenceJobs.enter()
      return true
    }
    if startPersistence { persistenceWorker.async { [self] in persistNextBrick() } }
  }

  private func persistNextBrick() {
    let next = lock.withLock { () -> BorgVRMaterializedEditBrick? in
      guard let index = persistencePending.keys.first else {
        persistenceRunning = false
        persistenceJobs.leave()
        updateBackgroundWorkStatus()
        return nil
      }
      let next = persistencePending.removeValue(forKey: index)
      persistenceActive = next
      updateBackgroundWorkStatus()
      return next
    }
    guard let next else { return }
    do {
      try cache.store(next, synchronize: lock.withLock { foregroundJobs == 0 })
      lock.withLock {
        if let failure = persistenceFailures[next.index], failure.revision <= next.revision {
          persistenceFailures[next.index] = nil
        }
      }
    }
    catch {
      lock.withLock {
        if desired[next.index] == next.revision || (desired[next.index] == nil && next.matchesOriginal) {
          persistenceFailures[next.index] = (next.revision, error)
        }
      }
      logger?.warning("Could not persist an edited brick: \(error.localizedDescription)")
    }
    lock.withLock { persistenceActive = nil; updateBackgroundWorkStatus() }
    persistenceSpace.signal()
    // Yield between bricks so stop/compaction requests can interleave.
    persistenceWorker.async { [self] in persistNextBrick() }
  }

  private func affectedBrickIDs(_ samples: [BorgVRVolumeBrushSample],
                                restoring mask: BorgVRVolumeEditMask? = nil,
                                channels: BorgVRVolumeEditChannels = .all) -> [Int] {
    if mask?.isOriginal == true { return [] }
    let m = getMetadata()
    let stride = m.brickSize - 2 * m.overlap
    let spacing = SIMD3(Double(m.voxelSpacingX), Double(m.voxelSpacingY), Double(m.voxelSpacingZ))
    var ids: Set<Int> = []
    for (level, layout) in m.levelMetadata.enumerated() {
      let factor = Double(1 << level)
      for sample in samples {
        var low = SIMD3<Int>.zero, high = SIMD3<Int>.zero
        let counts = SIMD3(layout.totalBricks.x, layout.totalBricks.y, layout.totalBricks.z)
        for axis in 0..<3 {
          let a = (sample.center[axis] - sample.radius) / (spacing[axis] * factor)
          let b = (sample.center[axis] + sample.radius) / (spacing[axis] * factor)
          low[axis] = Int(max(0, min(Double(counts[axis]), floor((a - Double(m.overlap)) / Double(stride)))))
          high[axis] = Int(max(0, min(Double(counts[axis]), ceil((b + Double(m.overlap)) / Double(stride)))))
        }
        for z in low.z..<high.z { for y in low.y..<high.y { for x in low.x..<high.x {
          let id = layout.prevBricks + (z * layout.totalBricks.y + y) * layout.totalBricks.x + x
          guard !ids.contains(id) else { continue }
          // Include halos and every fine voxel contributing to a coarse LOD.
          // Pending CPU results do not matter: the current mask is authoritative.
          if let mask, mask.coverage(in: Self.brickFootprint(index: id, level: level, metadata: m), channels: channels) == .original {
            continue
          }
          ids.insert(id)
        } } }
      }
    }
    return Array(ids)
  }

  /// Include overlap and all finest-level children contributing to a coarse brick.
  /// Clamp padding just as the CPU executor does, including odd dataset dimensions.
  private static func brickFootprint(index: Int, level: Int, metadata m: BORGVRMetaData) -> BorgVRVoxelRegion {
    let layout = m.levelMetadata[level]
    let local = index - layout.prevBricks
    let coordinate = SIMD3(local % layout.totalBricks.x,
      (local / layout.totalBricks.x) % layout.totalBricks.y,
      local / (layout.totalBricks.x * layout.totalBricks.y))
    let origin = coordinate &* (m.brickSize - 2 * m.overlap) &- SIMD3(repeating: m.overlap)
    let levelSize = SIMD3(layout.size.x, layout.size.y, layout.size.z)
    let fullSize = SIMD3(m.width, m.height, m.depth)
    let factor = 1 << level
    var low = SIMD3<Int>.zero, high = SIMD3<Int>.zero
    for axis in 0..<3 {
      low[axis] = max(0, min(levelSize[axis] - 1, origin[axis])) * factor
      high[axis] = min(fullSize[axis], min(levelSize[axis], origin[axis] + m.brickSize) * factor)
    }
    return BorgVRVoxelRegion(lower: low, upper: high)
  }
}
