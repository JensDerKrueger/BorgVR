import Foundation
import Combine

struct VolumeEditOpeningRequest: Identifiable {
  let id = UUID()
  let datasetID: String
  let catalog: BorgVRVolumeEditCatalog
  let states: [BorgVRVolumeEditState]
  let preferredID: UUID?
}

/// Small lock-protected bridge used by compositor input and the UI alike.
final class VolumeBrushContext: @unchecked Sendable {
  struct State {
    var mode: BorgVRVolumeBrushMode = .erase
    var radius: Float = 0.03 // fraction of the largest physical dataset extent
    var projectsOntoVolume = true
  }
  private let lock = NSLock()
  private var state = State()
  private var dataset: BorgVRVolumeEditDataSource?
  private var previous: [String: (position: SIMD3<Double>, mode: BorgVRVolumeBrushMode)] = [:]
  private struct Preview { let id: UUID; let position: SIMD3<Float>; let mode: BorgVRVolumeBrushMode }
  private var previews: [String: Preview] = [:]
  private var remotePreviews: [UUID: (cursors: [BorgVRVolumeBrushCursor], received: TimeInterval)] = [:]
  typealias EditHandler = @Sendable (BorgVRVolumeBrushMode, [BorgVRVolumeBrushSample], BorgVRVolumeConversionCancellationToken, @escaping @Sendable (Error?) -> Void) -> Void
  private var editHandler: EditHandler?
  private var editingEnabled = true
  var radiusChanged: (@Sendable (Double) -> Void)?
  var didFail: (@Sendable (String) -> Void)?

  func setEditHandler(_ handler: EditHandler?) { lock.withLock { editHandler = handler } }
  func setEditingEnabled(_ enabled: Bool) {
    lock.withLock {
      editingEnabled = enabled
      if !enabled { previous.removeAll(); previews.removeAll() }
    }
  }
  func cursors() -> [BorgVRVolumeBrushCursor] {
    lock.withLock { previews.values.map { .init(id: $0.id, position: $0.position, radius: state.radius, mode: $0.mode) } }
  }
  func setRemoteCursors(_ cursors: [BorgVRVolumeBrushCursor], from participant: UUID) {
    lock.withLock { remotePreviews[participant] = (cursors, Date.timeIntervalSinceReferenceDate) }
  }
  func clearRemoteCursors() { lock.withLock { remotePreviews.removeAll() } }

  func settings() -> State { lock.withLock { state } }
  func hasPendingBrickUpdates() -> Bool {
    let current = lock.withLock { dataset }
    return current?.hasPendingBrickUpdates ?? false
  }
  func editingStatus() -> BorgVRVolumeEditStatus? {
    lock.withLock { dataset }?.editingStatus()
  }
  func applySamples(_ samples: [BorgVRVolumeBrushSample], mode: BorgVRVolumeBrushMode,
                    cancellationToken: BorgVRVolumeConversionCancellationToken,
                    completion: @escaping @Sendable (Error?) -> Void) {
    let (enabled, handler, current) = lock.withLock { (editingEnabled, editHandler, dataset) }
    guard enabled else { completion(BorgVRVolumeEditingCommandError.busy); return }
    if let handler { handler(mode, samples, cancellationToken, completion); return }
    guard let current else {
      completion(BorgVRVolumeEditingCommandError.unavailable); return
    }
    current.brush(samples, mode: mode, cancellationToken: cancellationToken, completion: completion)
  }
  func update(_ state: State) {
    lock.withLock {
      if state.mode != self.state.mode || state.projectsOntoVolume != self.state.projectsOntoVolume {
        previous.removeAll()
      }
      self.state = state
    }
  }
  func attach(_ dataset: BorgVRVolumeEditDataSource?) {
    lock.withLock {
      self.dataset = dataset; previous.removeAll(); previews.removeAll()
    }
  }
  func finish(source: String) { lock.withLock { previous[source] = nil; previews[source] = nil } }
  func previewPosition() -> SIMD3<Float>? { lock.withLock { previews["pointer"]?.position ?? previews["touch"]?.position } }
  func showPreview(at position: SIMD3<Float>, source: String = "pointer", mode: BorgVRVolumeBrushMode? = nil) {
    lock.withLock {
      previews[source] = Preview(id: previews[source]?.id ?? UUID(), position: position, mode: mode ?? state.mode)
    }
  }
  func scaleRadius(by factor: Double) {
    let limits = BorgVRVolumeBrushLimits.radiusFraction
    let radius = lock.withLock { min(limits.upperBound, max(limits.lowerBound, Double(state.radius) * factor)) }
    radiusChanged?(radius)
  }
  func pruneDevicePreviews(activeIDs: Set<String>) {
    lock.withLock {
      for key in Array(previews.keys) where UUID(uuidString: key) != nil && !activeIDs.contains(key) {
        previews[key] = nil; previous[key] = nil
      }
    }
  }

  func exportDefaults() -> (name: String, description: String)? {
    let current = lock.withLock { dataset }
    guard let metadata = current?.getMetadata() else { return nil }
    return (metadata.datasetDescription, metadata.metaDescription)
  }

  func export(to url: URL, name: String, description: String,
              cancellationToken: BorgVRVolumeConversionCancellationToken,
              progress: @escaping @Sendable (Double) -> Void,
              completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
    guard let dataset = lock.withLock({ dataset }) else {
      completion(.failure(BorgVRVolumeEditError.incompatibleDataset)); return
    }
    dataset.export(to: url, name: name, description: description,
      cancellationToken: cancellationToken, progress: progress, completion: completion)
  }

  func discardAllEdits(completion: @escaping @Sendable (Error?) -> Void) {
    let current = lock.withLock { () -> BorgVRVolumeEditDataSource? in
      previous.removeAll(); previews.removeAll()
      return dataset
    }
    guard let current else { completion(BorgVRVolumeEditError.incompatibleDataset); return }
    current.discardAllEdits(completion: completion)
  }

  func apply(at position: SIMD3<Float>, source: String, mode: BorgVRVolumeBrushMode? = nil) {
    let input = lock.withLock { () -> (BorgVRVolumeEditDataSource, State, [BorgVRVolumeBrushSample])? in
      guard editingEnabled, let dataset, position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
      let extent = dataset.getMetadata().physicalExtentMeters
      let radius = Double(state.radius * max(extent.x, extent.y, extent.z))
      let center = SIMD3<Double>(position * extent)
      let brushMode = mode ?? state.mode
      // A temporary mode change starts a new segment, never interpolating the
      // opposite operation back across the previous segment.
      let last = previous[source].flatMap { $0.mode == brushMode ? $0.position : nil }
      let distance = last.map { p in
        let d = center - p
        return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
      } ?? 0
      previews[source] = Preview(id: previews[source]?.id ?? UUID(), position: position, mode: mode ?? state.mode)
      guard last == nil || distance >= radius * 0.15 else { return nil }
      let steps = min(256, max(1, Int(ceil(min(distance / max(radius * 0.4, Double.leastNormalMagnitude), 256)))))
      let samples = (1...steps).map { step in
        BorgVRVolumeBrushSample(center: last.map { $0 + (center - $0) * (Double(step) / Double(steps)) } ?? center,
                                radius: radius)
      }
      previous[source] = (center, brushMode)
      return (dataset, state, samples)
    }
    if let (_, settings, samples) = input {
      applySamples(samples, mode: mode ?? settings.mode, cancellationToken: .init()) { [weak self] error in
        guard let error else { return }
        if error is CancellationError { return }
        if case BorgVRVolumeEditError.editingBlocked = error { return }
        if case BorgVRVolumeEditingCommandError.busy = error { return }
        self?.didFail?(error.localizedDescription)
      }
    }
  }

  func previewMarkers() -> [VolumeMarker] {
    lock.withLock {
      let local = previews.values.map { preview in
        VolumeMarker(id: preview.id, name: "",
          color: preview.mode == .erase ? SIMD4(1, 0.2, 0.2, 1) : SIMD4(0.2, 1, 0.5, 1),
          geometry: .stroke([VolumeMarkerPoint(position: preview.position, radius: state.radius)]))
      }
      let remote = remotePreviews.values.filter { Date.timeIntervalSinceReferenceDate - $0.received < 0.75 }
        .flatMap(\.cursors).map { cursor in
          VolumeMarker(id: cursor.id, name: "", color: cursor.mode == .erase ? SIMD4(1, 0.2, 0.2, 1) : SIMD4(0.2, 1, 0.5, 1),
            geometry: .stroke([VolumeMarkerPoint(position: cursor.position, radius: cursor.radius)]))
        }
      return local + remote
    }
  }
}

@MainActor
final class VolumeBrushModel: ObservableObject, BorgVRVolumeEditingCommands {
  enum ExportPhase: Equatable { case options, exporting, cancelling, ready, cancelled }

  let context = VolumeBrushContext()
  @Published var mode: BorgVRVolumeBrushMode = .erase { didSet { synchronize() } }
  @Published var radius: Double = 0.03 { didSet { synchronize() } }
  @Published var projectsOntoVolume = true { didSet { synchronize() } }
  @Published private(set) var error: String?
  @Published private(set) var physicalMaximum: Float = 1
  @Published private(set) var exportPhase = ExportPhase.options
  @Published private(set) var exportProgress = 0.0
  @Published private(set) var exportJob: BorgVRVolumeExportJob?
  @Published var exportName = ""
  @Published var exportDescription = ""
  @Published private(set) var isDiscardingEdits = false { didSet { updateEditingAvailability() } }
  @Published private(set) var isUpdatingBricks = false
  @Published var exportedURL: URL?
  @Published private(set) var states: [BorgVRVolumeEditState] = []
  @Published private(set) var activeState: BorgVRVolumeEditState?
  @Published private(set) var isOpeningState = false { didSet { updateEditingAvailability() } }
  @Published private(set) var isInSharePlay = false
  @Published private(set) var isWaitingForSharedState = false { didSet { updateEditingAvailability() } }
  @Published private(set) var isRestoringPersonalState = false { didSet { updateEditingAvailability() } }
  @Published private(set) var isExporting = false { didSet { updateEditingAvailability() } }
  @Published var isSharePlayHost = false {
    didSet {
      if isInSharePlay, !isSharePlayHost, let request = openingRequest {
        cancelOpeningSelection(id: request.id)
      }
    }
  }
  @Published var openingRequest: VolumeEditOpeningRequest?
  @Published private(set) var preparationID: UUID?
  @Published private(set) var preparationProgress = 0.0
  private var preparationCancellation: BorgVRVolumeConversionCancellationToken?
  private var openingContinuation: CheckedContinuation<UUID?, Error>?
  private var preparedChoice: (datasetID: String, stateID: UUID?)?
  private var dataSource: BorgVRVolumeEditDataSource?
  private var openingTask: Task<Void, Never>?
  private var closingTask: Task<Void, Never>?
  private var workingState: BorgVRVolumeEditState?
  private var sessionStateID: UUID?
  private var stateTransitionID = UUID()
  var didBecomeReady: (() -> Void)?
  var sharedDiscard: (() async throws -> Void)?
  private var datasetGeneration = UUID()
  private var exportCancellation: BorgVRVolumeConversionCancellationToken?
  private var temporaryExportDirectory: URL?
  private var exportWaiters: [UUID: CheckedContinuation<BorgVRVolumeExportJob, Error>] = [:]
  private var exclusiveExport: (id: UUID, source: BorgVRVolumeEditDataSource, cancel: () -> Void)?
  private var exportEndWaiters: [CheckedContinuation<Void, Never>] = []
  private var restorePersonalStateTask: Task<Void, Never>?

  var canExport: Bool {
    !isInSharePlay && !isExporting && !isOpeningState && !isDiscardingEdits && !isRestoringPersonalState &&
      dataSource?.editingStatus() != nil
  }

  init(projectsOntoVolume: Bool = true) {
    self.projectsOntoVolume = projectsOntoVolume
    synchronize()
    context.radiusChanged = { [weak self] value in Task { @MainActor in self?.radius = value } }
    context.didFail = { [weak self] message in Task { @MainActor in self?.error = message } }
  }

  private func synchronize() {
    context.update(.init(mode: mode, radius: Float(radius), projectsOntoVolume: projectsOntoVolume))
  }

  private func updateEditingAvailability() {
    let enabled = !isExporting && !isOpeningState && !isWaitingForSharedState && !isDiscardingEdits && !isRestoringPersonalState
    context.setEditingEnabled(enabled)
    dataSource?.setEditsBlocked(!enabled)
  }

  /// Both dataset and isosurface exports hold this admission lock until their
  /// worker actually returns, including cancellation and dataset closure.
  func beginReadOnlyExport(cancel: @escaping () -> Void) throws -> UUID {
    guard !isInSharePlay else { throw BorgVRVolumeEditingCommandError.exportUnavailableDuringSharePlay }
    guard let source = dataSource, source.editingStatus() != nil else { throw BorgVRVolumeEditingCommandError.unavailable }
    guard canExport else { throw BorgVRVolumeEditingCommandError.busy }
    let id = UUID()
    exclusiveExport = (id, source, cancel)
    isExporting = true
    return id
  }

  func prepareReadOnlyExport(id: UUID) async throws {
    guard let operation = exclusiveExport, operation.id == id else { throw CancellationError() }
    // Snapshot capture is queued behind accepted brush input; its mask is not
    // copied or retained here. Admission stays closed throughout the export.
    _ = try await withCheckedThrowingContinuation { continuation in
      operation.source.snapshot { continuation.resume(with: $0) }
    }
    try Task.checkCancellation()
    guard exclusiveExport?.id == id, !isInSharePlay else { throw CancellationError() }
  }

  func finishReadOnlyExport(id: UUID) {
    guard let operation = exclusiveExport, operation.id == id else { return }
    operation.source.setEditsBlocked(false)
    exclusiveExport = nil
    isExporting = false
    let waiters = exportEndWaiters
    exportEndWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForExportEnd() async {
    guard isExporting else { return }
    await withCheckedContinuation { exportEndWaiters.append($0) }
  }

  func open(_ source: BORGVRDatasetProtocol, datasetURL: URL? = nil, logger: LoggerBase? = nil) -> BORGVRDatasetProtocol {
    close()
    let generation = datasetGeneration
    isWaitingForSharedState = isInSharePlay
    do {
      let metadata = source.getMetadata()
      let catalog = try Self.catalog(datasetID: metadata.uniqueID, datasetURL: datasetURL)
      states = try catalog.states()
      let choice = preparedChoice?.datasetID == metadata.uniqueID ? preparedChoice?.stateID : lastSelectedID(catalog: catalog)
      let selected = isInSharePlay && !isSharePlayHost ? nil : states.first { $0.id == choice }
      let state = selected ?? makeState(datasetID: catalog.datasetID, kind: .local)
      workingState = state
      activeState = selected
      preparedChoice = nil
      let edited = BorgVRVolumeEditDataSource(original: source, catalog: catalog, logger: logger,
        backgroundWorkChanged: { [weak self] _ in
          Task { @MainActor in
            guard let self, self.datasetGeneration == generation else { return }
            let active = self.context.hasPendingBrickUpdates()
            if self.isUpdatingBricks != active { self.isUpdatingBricks = active }
          }
        })
      dataSource = edited
      edited.setPreparationReady(false)
      edited.setSharedReady(!isInSharePlay)
      edited.didRecord = { [weak self, weak edited] in
        Task { @MainActor in
          guard let self, self.datasetGeneration == generation, self.dataSource === edited else { return }
          guard self.activeState?.id != self.workingState?.id ||
            !self.states.contains(where: { $0.id == self.workingState?.id }) else { return }
          self.activeState = self.workingState
          if !self.isInSharePlay, let state = self.workingState {
            UserDefaults.standard.set(state.id.uuidString, forKey: "volumeEditState.\(catalog.root.path)")
          }
          self.refreshStates()
        }
      }
      context.attach(edited)
      isOpeningState = true
      let previousClose = closingTask
      openingTask = Task { [weak self] in
        await previousClose?.value
        guard !Task.isCancelled, let self, self.datasetGeneration == generation else { return }
        do { try await self.activate(state, snapshot: nil, displayAsOriginal: selected == nil) }
        catch { if self.datasetGeneration == generation { self.error = error.localizedDescription; self.isOpeningState = false } }
      }
      physicalMaximum = max(metadata.physicalExtentMeters.x, metadata.physicalExtentMeters.y,
                            metadata.physicalExtentMeters.z)
      error = nil
      return edited
    } catch {
      self.error = error.localizedDescription
      context.attach(nil)
      return source
    }
  }

  func close() {
    restorePersonalStateTask?.cancel()
    restorePersonalStateTask = nil
    isRestoringPersonalState = false
    exclusiveExport?.cancel()
    preparationCancellation?.cancel()
    preparationCancellation = nil
    preparationID = nil
    openingTask?.cancel()
    openingTask = nil
    if let source = dataSource {
      let previous = closingTask
      closingTask = Task {
        await previous?.value
        await waitForExportEnd()
        await withCheckedContinuation { continuation in source.shutdown { _ in continuation.resume() } }
      }
    }
    dataSource = nil
    activeState = nil
    workingState = nil
    sessionStateID = nil
    states = []
    isOpeningState = false
    if let exportCancellation { exportCancellation.cancel() }
    else { removeTemporaryExport() }
    exportCancellation = nil
    if var job = exportJob, job.isActive {
      job.status = .cancelled
      exportJob = job
      finishExportWaiters(job)
    }
    temporaryExportDirectory = nil
    exportedURL = nil
    exportPhase = .options
    exportProgress = 0
    datasetGeneration = UUID()
    context.attach(nil)
    isUpdatingBricks = false
    isDiscardingEdits = false
  }

  static func catalog(datasetID: String, datasetURL: URL?) throws -> BorgVRVolumeEditCatalog {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try .init(root: BorgVRVolumeEditStorage.directory(datasetURL: datasetURL, datasetID: datasetID,
      applicationSupportURL: support), datasetID: datasetID)
  }

  func prepareOpening(datasetID: String, datasetURL: URL?, interactive: Bool = true) async throws {
    await closingTask?.value
    guard !isInSharePlay || isSharePlayHost else { return }
    let catalog = try Self.catalog(datasetID: datasetID, datasetURL: datasetURL)
    let states = try catalog.states()
    var choice = lastSelectedID(catalog: catalog)
    if interactive, !states.isEmpty {
      guard openingContinuation == nil else { throw BorgVRVolumeEditingCommandError.busy }
      let request = VolumeEditOpeningRequest(datasetID: datasetID, catalog: catalog, states: states, preferredID: choice)
      choice = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          openingContinuation = continuation
          openingRequest = request
        }
      } onCancel: {
        Task { @MainActor [weak self] in self?.cancelOpeningSelection(id: request.id) }
      }
    }
    try Task.checkCancellation()
    preparedChoice = (datasetID, states.contains { $0.id == choice } ? choice : nil)
  }

  func completeOpeningSelection(id: UUID, stateID: UUID?) {
    guard openingRequest?.id == id else { return }
    let continuation = openingContinuation
    openingContinuation = nil; openingRequest = nil
    continuation?.resume(returning: stateID)
  }

  func cancelOpeningSelection(id: UUID) {
    guard openingRequest?.id == id else { return }
    let continuation = openingContinuation
    openingContinuation = nil; openingRequest = nil
    continuation?.resume(throwing: CancellationError())
  }

  func canDeleteOpeningState(_ id: UUID, requestID: UUID) -> Bool {
    (!isInSharePlay || isSharePlayHost) && !isExporting && !isRestoringPersonalState &&
      !isDiscardingEdits && openingRequest?.id == requestID && activeState?.id != id && workingState?.id != id
  }

  func deleteOpeningState(_ id: UUID, requestID: UUID) throws {
    guard canDeleteOpeningState(id, requestID: requestID), let request = openingRequest else {
      throw BorgVRVolumeEditingCommandError.busy
    }
    try request.catalog.delete(id)
  }

  func refreshStates() { states = (try? dataSource?.catalog.states()) ?? [] }

  func reportError(_ error: Error) { self.error = error.localizedDescription }

  private func makeState(datasetID: String, kind: BorgVRVolumeEditState.Kind, name: String = "") -> BorgVRVolumeEditState {
    .init(id: UUID(), datasetID: datasetID, name: name, kind: kind, createdAt: Date(), modifiedAt: Date())
  }

  private func lastSelectedID(catalog: BorgVRVolumeEditCatalog) -> UUID? {
    UserDefaults.standard.string(forKey: "volumeEditState.\(catalog.root.path)").flatMap(UUID.init(uuidString:))
  }

  func waitForStateReady() async throws {
    let generation = datasetGeneration
    while isOpeningState {
      try await Task.sleep(for: .milliseconds(10))
      guard generation == datasetGeneration else { throw CancellationError() }
    }
    guard dataSource?.editingStatus() != nil else { throw BorgVRVolumeEditingCommandError.unavailable }
  }

  private func activate(_ state: BorgVRVolumeEditState, snapshot: BorgVRVolumeEditSnapshot?, displayAsOriginal: Bool = false,
                        preserveAppearance: Bool = false) async throws {
    guard let source = dataSource, !isExporting, !isDiscardingEdits else { throw BorgVRVolumeEditingCommandError.busy }
    let generation = datasetGeneration
    let transition = UUID()
    stateTransitionID = transition
    isOpeningState = true
    source.setPreparationReady(false)
    defer {
      source.setPreparationReady(true)
      if datasetGeneration == generation && stateTransitionID == transition { isOpeningState = false }
    }
    context.finish(source: "pointer"); context.finish(source: "touch")
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      source.activate(state, snapshot: snapshot, preserveAppearance: preserveAppearance) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    guard generation == datasetGeneration, stateTransitionID == transition else { throw CancellationError() }
    workingState = state
    activeState = displayAsOriginal ? nil : state
    if source.hasPendingBrickUpdates {
      let token = BorgVRVolumeConversionCancellationToken()
      preparationCancellation = token
      preparationProgress = 0
      if !isInSharePlay { preparationID = UUID() }
      defer {
        if preparationCancellation === token { preparationCancellation = nil; preparationID = nil }
      }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        source.preparePendingEdits(cancellationToken: token, progress: { [weak self] value in
          Task { @MainActor in
            guard let self, self.preparationCancellation === token else { return }
            self.preparationProgress = max(self.preparationProgress, value)
          }
        }) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    }
    source.setPreparationReady(true)
    guard generation == datasetGeneration, stateTransitionID == transition else { throw CancellationError() }
    isOpeningState = false
    isUpdatingBricks = source.hasPendingBrickUpdates
    refreshStates()
    if !isInSharePlay {
      UserDefaults.standard.set(displayAsOriginal ? nil : state.id.uuidString, forKey: "volumeEditState.\(source.catalog.root.path)")
    }
    didBecomeReady?()
  }

  func selectState(_ id: UUID?) async throws {
    guard !isInSharePlay, !isExporting, !isRestoringPersonalState else { throw BorgVRVolumeEditingCommandError.busy }
    try await waitForStateReady()
    guard !isInSharePlay, !isExporting, !isRestoringPersonalState else { throw BorgVRVolumeEditingCommandError.busy }
    try await activatePersonalState(id)
  }

  private func activatePersonalState(_ id: UUID?) async throws {
    guard let source = dataSource else { throw BorgVRVolumeEditingCommandError.unavailable }
    let state: BorgVRVolumeEditState
    if let id {
      guard let saved = try source.catalog.states().first(where: { $0.id == id }) else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Unknown edit state ID.")
      }
      state = saved
    } else { state = makeState(datasetID: source.catalog.datasetID, kind: .local) }
    try await activate(state, snapshot: nil, displayAsOriginal: id == nil)
  }

  func duplicateState(name: String = "", empty: Bool = false) async throws {
    guard !isInSharePlay, !isExporting, !isRestoringPersonalState, let source = dataSource else { throw BorgVRVolumeEditingCommandError.busy }
    let previous = try await stateSnapshot()
    guard !isInSharePlay, !isExporting, !isRestoringPersonalState, dataSource === source else { throw BorgVRVolumeEditingCommandError.busy }
    let state = makeState(datasetID: source.catalog.datasetID, kind: empty ? .local : .copy, name: name)
    let mask = empty ? try BorgVRVolumeEditMask(size: previous.mask.size, spacing: previous.mask.spacing) : previous.mask
    try await activate(state, snapshot: .init(datasetID: state.datasetID, stateID: state.id, revision: 0, mask: mask))
  }

  func renameState(_ id: UUID, name: String) throws {
    guard !isInSharePlay, !isExporting, !isRestoringPersonalState, let source = dataSource else { throw BorgVRVolumeEditingCommandError.busy }
    try source.catalog.rename(id, to: name)
    refreshStates()
    if activeState?.id == id { activeState = states.first { $0.id == id }; workingState = activeState }
  }

  func deleteState(_ id: UUID) throws {
    guard !isInSharePlay, !isOpeningState, !isExporting, !isRestoringPersonalState, activeState?.id != id,
      let source = dataSource else { throw BorgVRVolumeEditingCommandError.busy }
    try source.catalog.delete(id)
    refreshStates()
  }

  func stateSnapshot() async throws -> BorgVRVolumeEditSnapshot {
    try await waitForStateReady()
    guard let source = dataSource else { throw BorgVRVolumeEditingCommandError.unavailable }
    return try await withCheckedThrowingContinuation { continuation in source.snapshot { continuation.resume(with: $0) } }
  }

  func installSessionSnapshot(_ snapshot: BorgVRVolumeEditSnapshot, preserveAppearance: Bool = false) async throws {
    let generation = datasetGeneration
    await waitForExportEnd()
    guard isInSharePlay, datasetGeneration == generation else { throw CancellationError() }
    try await waitForStateReady()
    let oldID = sessionStateID
    let state = makeState(datasetID: snapshot.datasetID, kind: .sharePlay)
    try await activate(state, snapshot: snapshot, preserveAppearance: preserveAppearance)
    guard isInSharePlay else { throw CancellationError() }
    sessionStateID = state.id
    dataSource?.setSharedReady(true)
    isWaitingForSharedState = false
    error = nil
    if let oldID, states.contains(where: { $0.id == oldID }) {
      try dataSource?.catalog.delete(oldID)
      refreshStates()
    }
  }

  func setSharePlayActive(_ active: Bool) {
    guard isInSharePlay != active else { return }
    restorePersonalStateTask?.cancel()
    restorePersonalStateTask = nil
    if active {
      isWaitingForSharedState = true
      isRestoringPersonalState = false
    } else {
      isRestoringPersonalState = dataSource != nil
      isWaitingForSharedState = false
    }
    isInSharePlay = active
    if active {
      cancelExport()
      exclusiveExport?.cancel()
      sessionStateID = nil
      if let request = openingRequest { cancelOpeningSelection(id: request.id) }
    }
    dataSource?.setSharedReady(!active)
    if !active {
      isSharePlayHost = false
      sessionStateID = nil
      context.setEditHandler(nil)
      context.clearRemoteCursors()
      sharedDiscard = nil
      if let catalog = dataSource?.catalog {
        let id = lastSelectedID(catalog: catalog)
        let generation = datasetGeneration
        isRestoringPersonalState = true
        restorePersonalStateTask = Task { [weak self] in
          guard let self else { return }
          defer {
            if !Task.isCancelled, self.datasetGeneration == generation { self.isRestoringPersonalState = false }
          }
          await self.waitForExportEnd()
          do {
            try Task.checkCancellation()
            try await self.waitForStateReady()
            guard !self.isInSharePlay, self.datasetGeneration == generation else { throw CancellationError() }
            try await self.activatePersonalState(id)
          } catch is CancellationError {}
          catch { self.error = error.localizedDescription }
        }
      }
    }
  }

  func beginSharedStateSynchronization() {
    isWaitingForSharedState = true
    dataSource?.setSharedReady(false)
  }

  func predictSharedBrush(id: UUID, mode: BorgVRVolumeBrushMode, samples: [BorgVRVolumeBrushSample]) {
    dataSource?.predict(id: id, mode: mode, samples: samples)
  }

  func cancelSharedPredictions() { dataSource?.cancelPredictions() }

  func applyConfirmed(_ batch: BorgVRVolumeBrushBatch) async throws {
    guard let source = dataSource else { throw BorgVRVolumeEditingCommandError.unavailable }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      source.brush(batch.samples, mode: batch.mode, operationID: batch.id, expectedRevision: batch.revision) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  func discardAllEdits() {
    Task {
      do { try await discardVolumeEdits() }
      catch is CancellationError {}
      catch { self.error = error.localizedDescription }
    }
  }

  func exportMoveCompleted(_ result: Result<URL, Error>) -> Bool {
    switch result {
      case .success:
        removeTemporaryExport()
        exportedURL = nil
        exportPhase = .options
        return true
      case .failure(let error):
        if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription }
        return false
    }
  }

  func prepareExport() {
    guard canExport else { return }
    removeTemporaryExport()
    let defaults = context.exportDefaults()
    let sourceName = defaults?.name ?? ""
    exportName = sourceName.isEmpty ? String(localized: "Edited Volume") : sourceName
    exportDescription = defaults?.description ?? ""
    exportProgress = 0
    exportPhase = .options
    exportedURL = nil
    error = nil
  }

  func cancelExport() {
    guard exportPhase == .exporting || exportPhase == .cancelling else { return }
    exportPhase = .cancelling
    exportJob?.status = .cancelling
    exportCancellation?.cancel()
  }

  func dismissExportDialog() {
    if isExporting { cancelExport() }
    else {
      removeTemporaryExport()
      exportedURL = nil
      exportPhase = .options
    }
  }

  private func removeTemporaryExport() {
    // Only remove the directory we allocated, never a user-selected destination.
    if let temporaryExportDirectory { try? FileManager.default.removeItem(at: temporaryExportDirectory) }
    temporaryExportDirectory = nil
  }

  func export() {
    guard !isExporting else { return }
    let name = exportName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let filename = name.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters))
        .joined(separator: "_")
      do {
        _ = try beginExport(to: directory.appendingPathComponent(filename).appendingPathExtension("data"),
          name: name, description: exportDescription, ownedDirectory: directory)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  func volumeEditingState() -> BorgVRVolumeEditingState {
    let status = context.editingStatus()
    return BorgVRVolumeEditingState(available: status != nil, datasetID: status?.datasetID,
      hasEdits: status?.hasEdits ?? false, isUpdatingBricks: status?.isUpdatingBricks ?? false,
      pendingBrickCount: status?.pendingBrickCount ?? 0, mode: mode, radiusFraction: radius,
      radiusMeters: radius * Double(physicalMaximum), projectsOntoVolume: projectsOntoVolume, export: exportJob,
      activeStateID: activeState?.id, savedStates: states, shared: isInSharePlay, waitingForSharedState: isWaitingForSharedState)
  }

  func configureVolumeBrush(mode: BorgVRVolumeBrushMode?, radiusFraction: Double?, projectsOntoVolume: Bool?) throws {
    if let radiusFraction {
      guard radiusFraction.isFinite, BorgVRVolumeBrushLimits.radiusFraction.contains(radiusFraction) else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Brush radius fraction must be between 0.002 and 0.15.")
      }
    }
    if let mode { self.mode = mode }
    if let radiusFraction { radius = radiusFraction }
    if let projectsOntoVolume { self.projectsOntoVolume = projectsOntoVolume }
  }

  func editVolume(mode: BorgVRVolumeBrushMode, samples: [BorgVRVolumeBrushSample]) async throws {
    try await waitForStateReady()
    guard context.editingStatus() != nil else { throw BorgVRVolumeEditingCommandError.unavailable }
    guard !isDiscardingEdits, !isExporting, !isRestoringPersonalState else { throw BorgVRVolumeEditingCommandError.busy }
    guard !samples.isEmpty, samples.count <= BorgVRVolumeBrushLimits.maximumSampleCount else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Provide between 1 and 65536 brush samples.")
    }
    for sample in samples { try sample.validate() }
    let generation = datasetGeneration
    let token = BorgVRVolumeConversionCancellationToken()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        context.applySamples(samples, mode: mode, cancellationToken: token) { error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume() }
        }
      }
    } onCancel: { token.cancel() }
    try Task.checkCancellation()
    guard generation == datasetGeneration else { throw CancellationError() }
  }

  func discardVolumeEdits() async throws {
    guard !isExporting, !isRestoringPersonalState else { throw BorgVRVolumeEditingCommandError.busy }
    if isInSharePlay, let sharedDiscard { try await sharedDiscard(); return }
    guard context.editingStatus() != nil else { throw BorgVRVolumeEditingCommandError.unavailable }
    guard !isDiscardingEdits, !isExporting else { throw BorgVRVolumeEditingCommandError.busy }
    try Task.checkCancellation()
    let generation = datasetGeneration
    isDiscardingEdits = true
    defer { if generation == datasetGeneration { isDiscardingEdits = false } }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      context.discardAllEdits { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    guard generation == datasetGeneration else { throw CancellationError() }
    exportedURL = nil
    error = nil
    if let source = dataSource {
      isDiscardingEdits = false
      try await activate(makeState(datasetID: source.catalog.datasetID, kind: .local), snapshot: nil, displayAsOriginal: true)
    }
  }

  func prepareVolumeEdits() async throws {
    try await waitForStateReady()
    guard let source = dataSource, !isExporting, !isDiscardingEdits else { throw BorgVRVolumeEditingCommandError.busy }
    let generation = datasetGeneration
    let token = BorgVRVolumeConversionCancellationToken()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        source.preparePendingEdits(cancellationToken: token, progress: { _ in }) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    } onCancel: { token.cancel() }
    try Task.checkCancellation()
    guard generation == datasetGeneration else { throw CancellationError() }
  }

  func waitForVolumeEdits(timeout: TimeInterval) async throws {
    guard timeout.isFinite, timeout > 0, timeout <= 86400 else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Timeout must be between 0 (exclusive) and 86400 seconds.")
    }
    let generation = datasetGeneration
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while true {
      try Task.checkCancellation()
      guard generation == datasetGeneration else { throw CancellationError() }
      guard let status = context.editingStatus() else { throw BorgVRVolumeEditingCommandError.unavailable }
      if !status.isUpdatingBricks, !isDiscardingEdits { return }
      guard ContinuousClock.now < deadline else { throw BorgVRVolumeEditingCommandError.timeout }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  func startVolumeExport(to url: URL, name: String?, description: String?) throws -> BorgVRVolumeExportJob {
    let defaults = context.exportDefaults()
    return try beginExport(to: url, name: name ?? defaults?.name ?? "Edited Volume",
      description: description ?? defaults?.description ?? "", ownedDirectory: nil)
  }

  func waitForVolumeExport(id: UUID) async throws -> BorgVRVolumeExportJob {
    let waiter = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          try? cancelVolumeExport(id: id)
          continuation.resume(throwing: CancellationError())
          return
        }
        guard let job = exportJob, job.id == id else {
          continuation.resume(throwing: BorgVRVolumeEditingCommandError.unknownExport)
          return
        }
        if job.isActive { exportWaiters[waiter] = continuation }
        else { continuation.resume(with: exportResult(job)) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, let continuation = self.exportWaiters.removeValue(forKey: waiter) else { return }
        try? self.cancelVolumeExport(id: id)
        continuation.resume(throwing: CancellationError())
      }
    }
  }

  private func exportResult(_ job: BorgVRVolumeExportJob) -> Result<BorgVRVolumeExportJob, Error> {
    switch job.status {
      case .completed: .success(job)
      case .cancelled: .failure(CancellationError())
      default: .failure(BorgVRVolumeEditingCommandError.exportFailed(job.error ?? "Volume export failed."))
    }
  }

  private func finishExportWaiters(_ job: BorgVRVolumeExportJob) {
    let waiters = Array(exportWaiters.values)
    exportWaiters.removeAll()
    for continuation in waiters { continuation.resume(with: exportResult(job)) }
  }

  func cancelVolumeExport(id: UUID) throws {
    guard exportJob?.id == id else { throw BorgVRVolumeEditingCommandError.unknownExport }
    cancelExport()
  }

  private func beginExport(to url: URL, name: String, description: String,
                           ownedDirectory: URL?) throws -> BorgVRVolumeExportJob {
    guard context.editingStatus() != nil else { throw BorgVRVolumeEditingCommandError.unavailable }
    guard !isInSharePlay else { throw BorgVRVolumeEditingCommandError.exportUnavailableDuringSharePlay }
    guard canExport else { throw BorgVRVolumeEditingCommandError.busy }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, url.isFileURL, url.pathExtension.lowercased() == "data" else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Export needs a name and a .data file destination.")
    }
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("The export destination already exists; choose a new file.")
    }
    removeTemporaryExport()
    temporaryExportDirectory = ownedDirectory
    exportedURL = nil
    exportName = name
    exportDescription = description
    exportPhase = .exporting
    exportProgress = 0
    error = nil
    let job = BorgVRVolumeExportJob(id: UUID(), outputPath: url.path, status: .running, progress: 0)
    exportJob = job
    let token = BorgVRVolumeConversionCancellationToken()
    let exportID = try beginReadOnlyExport { token.cancel() }
    exportCancellation = token
    let generation = datasetGeneration
    let parent = url.deletingLastPathComponent()
    let access = parent.startAccessingSecurityScopedResource()
    context.export(to: url, name: name, description: description, cancellationToken: token,
        progress: { [weak self] progress in
          Task { @MainActor in
            guard let self, self.datasetGeneration == generation, self.exportCancellation === token else { return }
            if progress > self.exportProgress {
              self.exportProgress = progress
              self.exportJob?.progress = progress
            }
          }
        }) { [weak self] result in
        if access { parent.stopAccessingSecurityScopedResource() }
        Task { @MainActor in
          self?.finishReadOnlyExport(id: exportID)
          guard let self, self.datasetGeneration == generation, self.exportCancellation === token else {
            if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
            return
          }
          self.exportCancellation = nil
          switch result {
            case .success(let url):
              self.exportProgress = 1
              self.exportJob?.progress = 1
              self.exportJob?.status = .completed
              self.exportedURL = ownedDirectory == nil ? nil : url
              self.exportPhase = .ready
            case .failure(let error):
              self.removeTemporaryExport()
              if error is CancellationError {
                self.exportJob?.status = .cancelled
                self.exportPhase = .cancelled
              } else {
                self.exportJob?.status = .failed
                self.exportJob?.error = error.localizedDescription
                self.error = error.localizedDescription
                self.exportPhase = .options
              }
          }
          if let job = self.exportJob { self.finishExportWaiters(job) }
        }
      }
    return job
  }
}
