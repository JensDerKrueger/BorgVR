import Foundation

/// A stable renderer-facing source. State changes replace only the editing layer.
final class BorgVRVolumeEditDataSource: BORGVRDatasetProtocol, BorgVRVolumeGPUBrushSource, @unchecked Sendable {
  let original: BORGVRDatasetProtocol
  let catalog: BorgVRVolumeEditCatalog
  private let logger: LoggerBase?
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "BorgVR.EditStateTransitions", qos: .userInitiated)
  private var current: BorgVREditableVolumeData?
  private var state: BorgVRVolumeEditState?
  private var transitioning = true
  private var pendingTransitions = 0
  private var stopped = false
  private var baseRevision: UInt64 = 1
  private var generation: UInt64 = 0
  private var storageGeneration: UInt64 = 0
  private var switchRevision: UInt64 = 1
  private var renderers = 0
  private var residents: Set<Int> = []
  private var manifestRegistered = false
  private var sharedReady = true
  private var initialLowReady = false
  private var preparationReady = true
  private var editsBlocked = false
  private var predictions: [(id: UUID, mode: BorgVRVolumeBrushMode, samples: [BorgVRVolumeBrushSample], channels: BorgVRVolumeEditChannels)] = []
  var didRecord: (@Sendable () -> Void)?
  private let backgroundWorkChanged: @Sendable (Bool) -> Void

  init(original: BORGVRDatasetProtocol, catalog: BorgVRVolumeEditCatalog, logger: LoggerBase?,
       backgroundWorkChanged: @escaping @Sendable (Bool) -> Void) {
    self.original = original; self.catalog = catalog; self.logger = logger
    self.backgroundWorkChanged = backgroundWorkChanged
  }

  func activate(_ state: BorgVRVolumeEditState, snapshot: BorgVRVolumeEditSnapshot? = nil, preserveAppearance: Bool = false,
                completion: @escaping @Sendable (Error?) -> Void) {
    lock.withLock { pendingTransitions += 1; transitioning = true }
    queue.async { [self] in
      var activationError: Error?
      let previous = lock.withLock { (current, self.state) }
      var previousClosed = false
      var candidate: BorgVREditableVolumeData?
      do {
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        if previous.1?.id == state.id {
          guard snapshot == nil else { throw BorgVRVolumeEditError.invalidRevision }
        } else {
          let directory = try catalog.directory(for: state.id)
          let next = try BorgVREditableVolumeData(source: original, directory: directory, logger: logger,
            backgroundWorkChanged: backgroundWorkChanged, initialSnapshot: snapshot,
            persistOriginalSnapshot: state.kind != .sharePlay)
          candidate = next
          if let snapshot, !snapshot.mask.isOriginal || state.kind != .sharePlay { try catalog.save(state) }
          if let old = previous.0 {
            previousClosed = true
            let closed = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var closeError: Error?
            old.shutdown { error in closeError = error; closed.signal() }
            closed.wait()
            if let closeError { throw closeError }
          }
          guard !lock.withLock({ stopped }) else { throw CancellationError() }
          install(next, state: state, preserveAppearance: preserveAppearance)
          candidate = nil
        }
      } catch {
        activationError = error
        if let candidate {
          let closed = DispatchSemaphore(value: 0)
          candidate.shutdown { _ in closed.signal() }
          closed.wait()
        }
        if previousClosed, !lock.withLock({ stopped }), let state = previous.1 {
          do {
            let restored = try BorgVREditableVolumeData(source: original,
              directory: catalog.directory(for: state.id), logger: logger, backgroundWorkChanged: backgroundWorkChanged)
            install(restored, state: state, preserveAppearance: false)
          } catch {
            lock.withLock { current = nil; self.state = nil }
            activationError = error
          }
        }
      }
      lock.withLock { pendingTransitions -= 1; transitioning = pendingTransitions > 0 || stopped }
      completion(activationError)
    }
  }

  private func install(_ next: BorgVREditableVolumeData, state: BorgVRVolumeEditState, preserveAppearance: Bool) {
    manifestRegistered = (try? catalog.directory(for: state.id))
      .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("edit-state.plist").path) } ?? false
    lock.withLock {
      baseRevision += (current?.contentRevision ?? 0) + 1
      switchRevision = baseRevision
      generation &+= 1; storageGeneration &+= 1
      current = next; self.state = state
      initialLowReady = preserveAppearance
      predictions.removeAll()
      for _ in 0..<renderers { next.attachGPUBrushRenderer() }
      next.updateResidentBrickIDs(residents)
    }
    next.prepareForRendering()
  }

  func shutdown(completion: @escaping @Sendable (Error?) -> Void) {
    lock.withLock { stopped = true; transitioning = true }
    queue.async { [self] in
      if let current = lock.withLock({ current }) { current.shutdown(completion: completion) }
      else { completion(nil) }
    }
  }

  func stop() { shutdown { _ in } }
  func preparePendingEdits(cancellationToken: BorgVRVolumeConversionCancellationToken,
                           progress: @escaping @Sendable (Double) -> Void,
                           completion: @escaping @Sendable (Error?) -> Void) {
    queue.async { [self] in
      guard let current = lock.withLock({ transitioning || stopped ? nil : current }) else {
        completion(CancellationError()); return
      }
      current.preparePendingEdits(cancellationToken: cancellationToken, progress: progress, completion: completion)
    }
  }
  func setSharedReady(_ ready: Bool) { lock.withLock { sharedReady = ready } }
  func setPreparationReady(_ ready: Bool) { lock.withLock { preparationReady = ready } }
  func setEditsBlocked(_ blocked: Bool) { lock.withLock { editsBlocked = blocked } }
  var isContentReady: Bool {
    lock.withLock {
      guard !transitioning, sharedReady, preparationReady, let current else { return false }
      if !initialLowReady, current.gpuReadableRevision(index: getMetadata().brickMetadata.count - 1) != nil { initialLowReady = true }
      return initialLowReady
    }
  }
  func getMetadata() -> BORGVRMetaData { original.getMetadata() }
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { original.allocateBrickBuffer() }
  func editingStatus() -> BorgVRVolumeEditStatus? {
    lock.withLock { transitioning || stopped ? nil : current?.editingStatus() }
  }
  var hasPendingBrickUpdates: Bool { editingStatus()?.isUpdatingBricks ?? false }
  var contentRevision: UInt64 { lock.withLock { baseRevision + (current?.contentRevision ?? 0) } }
  var gpuBrushGeneration: UInt64 { lock.withLock { generation } }
  func changedBrickIDs(since revision: UInt64) -> [Int] {
    lock.withLock {
      if revision < switchRevision { return Array(getMetadata().brickMetadata.indices) }
      return current?.changedBrickIDs(since: revision >= baseRevision ? revision - baseRevision : 0) ?? []
    }
  }
  func visibilityMetadata(index: Int) -> BrickMetadata? {
    lock.withLock { transitioning ? nil : current?.visibilityMetadata(index: index) }
  }
  func updateResidentBrickIDs(_ ids: Set<Int>) {
    lock.withLock { residents = ids; current?.updateResidentBrickIDs(ids) }
  }
  func newRequest() { lock.withLock { transitioning ? nil : current }?.newRequest() }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let (source, epoch) = lock.withLock { (transitioning ? nil : current, generation) }
    guard let source else { throw BORGVRDataError.brickNotYetAvailable(index: index) }
    try source.getBrick(index: index, outputBuffer: outputBuffer)
    guard lock.withLock({ epoch == generation && !transitioning }) else {
      throw BORGVRDataError.brickNotYetAvailable(index: index)
    }
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    if let current = lock.withLock({ transitioning ? nil : current }) {
      try current.getFirstBrick(outputBuffer: outputBuffer)
    } else {
      try original.getFirstBrick(outputBuffer: outputBuffer)
    }
  }
  func attachGPUBrushRenderer() { lock.withLock { renderers += 1; current?.attachGPUBrushRenderer() } }
  func detachGPUBrushRenderer() { lock.withLock { renderers = max(0, renderers - 1); current?.detachGPUBrushRenderer() } }
  func gpuBrushHistory() -> [BorgVRVolumeBrushBatch] {
    lock.withLock {
      guard !transitioning, let current else { return [] }
      let revision = current.recordedBrushRevision
      guard revision < UInt64.max - UInt64(predictions.count) else { return current.gpuBrushHistory() }
      return current.gpuBrushHistory() + predictions.enumerated().map { index, prediction in
        .init(id: prediction.id, revision: revision + UInt64(index) + 1, mode: prediction.mode,
          samples: prediction.samples, channels: prediction.channels)
      }
    }
  }

  func predict(id: UUID, mode: BorgVRVolumeBrushMode, samples: [BorgVRVolumeBrushSample],
               channels: BorgVRVolumeEditChannels = .all) {
    lock.withLock {
      guard !editsBlocked, !transitioning, predictions.count < 4096, !predictions.contains(where: { $0.id == id }) else { return }
      guard let channels = try? channels.validated(componentCount: getMetadata().componentCount) else { return }
      predictions.append((id, mode, samples, channels))
    }
  }

  func cancelPredictions() {
    lock.withLock {
      guard !predictions.isEmpty else { return }
      predictions.removeAll()
      invalidatePredictedAtlas()
    }
  }

  private func invalidatePredictedAtlas() {
    generation &+= 1
    baseRevision += 1
    switchRevision = baseRevision + (current?.contentRevision ?? 0)
  }

  private func confirmed(_ batch: BorgVRVolumeBrushBatch) {
    lock.withLock {
      guard !predictions.isEmpty else { return }
      if predictions.first?.id == batch.id { predictions.removeFirst() }
      else {
        predictions.removeAll { $0.id == batch.id }
        // Foreign operations can arrive ahead of a local prediction. Re-upload
        // canonical voxels, then replay only the still-unconfirmed local input.
        invalidatePredictedAtlas()
      }
    }
  }
  func gpuReadableRevision(index: Int) -> UInt64? { lock.withLock { transitioning ? nil : current?.gpuReadableRevision(index: index) } }
  func cachedOriginalBrick(index: Int) -> [UInt8]? { lock.withLock { current }?.cachedOriginalBrick(index: index) }

  func snapshot(completion: @escaping @Sendable (Result<BorgVRVolumeEditSnapshot, Error>) -> Void) {
    queue.async { [self] in
      guard let current = lock.withLock({ transitioning ? nil : current }) else {
        completion(.failure(BorgVRVolumeEditError.invalidRevision)); return
      }
      current.captureSnapshot { completion(.success($0)) }
    }
  }

  func brush(_ samples: [BorgVRVolumeBrushSample], mode: BorgVRVolumeBrushMode,
             channels: BorgVRVolumeEditChannels = .all,
             cancellationToken: BorgVRVolumeConversionCancellationToken? = nil,
             operationID: UUID = UUID(), expectedRevision: UInt64? = nil,
             completion: (@Sendable (Error?) -> Void)? = nil) {
    // Admission and enqueueing share the lock, so a later export barrier cannot
    // overtake a brush that was already accepted before editing was blocked.
    let accepted = lock.withLock { () -> Bool in
      guard !editsBlocked, !stopped, !transitioning else { return false }
      let epoch = storageGeneration
      queue.async { [self] in
        guard let current = lock.withLock({ !transitioning && !stopped && storageGeneration == epoch ? current : nil }),
              let state = lock.withLock({ state }) else { completion?(CancellationError()); return }
        do {
          try cancellationToken?.checkCancellation()
          if !manifestRegistered { try catalog.save(state); manifestRegistered = true }
          current.recordBrush(samples, mode: mode, channels: channels, cancellationToken: cancellationToken,
            operationID: operationID, expectedRevision: expectedRevision, onRecorded: { [weak self] in self?.confirmed($0) }) { [weak self] error in
            if error == nil { self?.didRecord?() }
            completion?(error)
          }
        } catch { completion?(error) }
      }
      return true
    }
    if !accepted { completion?(BorgVRVolumeEditError.editingBlocked) }
  }

  func discardAllEdits(completion: @escaping @Sendable (Error?) -> Void) {
    queue.async { [self] in
      guard let current = lock.withLock({ transitioning ? nil : current }) else {
        completion(BorgVRVolumeEditError.invalidRevision); return
      }
      current.discardAllEdits { [self] error in
        queue.async { [self] in manifestRegistered = false; completion(error) }
      }
    }
  }

  func export(to url: URL, name: String, description: String,
              cancellationToken: BorgVRVolumeConversionCancellationToken,
              progress: @escaping @Sendable (Double) -> Void,
              completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
    queue.async { [self] in
      guard let current = lock.withLock({ transitioning ? nil : current }) else {
        completion(.failure(BorgVRVolumeEditError.invalidRevision)); return
      }
      current.export(to: url, name: name, description: description,
        cancellationToken: cancellationToken, progress: progress, completion: completion)
    }
  }
}
