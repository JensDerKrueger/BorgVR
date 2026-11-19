import Foundation
import Combine
import Observation
import simd
import SwiftUI

@MainActor
protocol BorgVRCommandExecuting: BorgVRActionExecuting {
  var commandEvents: AnyPublisher<BorgVRCommandEvent, Never> { get }
  func perform(_ command: BorgVRCommand, source: BorgVRCommandSource) throws
  var isCommandRecording: Bool { get }
  func startCommandRecording()
  func waitForRecordingPreparation() async throws
  func finishCommandRecording() async throws
  func recordedGSCScript() throws -> String
  func mutateSettings<Result>(source: BorgVRCommandSource, _ mutation: () throws -> Result) rethrows -> Result
}

enum BorgVRStateResetScope: String, Codable, Sendable {
  case all
  case transform
  case clipping
  case transferFunction
  case lighting
}

enum BorgVRMutationDomain: String, Codable, Hashable, Sendable {
  case visualization
  case transferFunction
  case objects
  case measurements
  case interaction
}

struct BorgVRTransformSnapshot: Codable, Equatable, Sendable {
  var rotation: SIMD4<Float>
  var translation: SIMD3<Float>
  var scale: SIMD3<Float>
}

struct BorgVRLightingSnapshot: Codable, Equatable, Sendable {
  var direction: SIMD3<Float>
  var ambient: SIMD3<Float>
  var diffuse: SIMD3<Float>
  var specular: SIMD3<Float>
}

struct BorgVRTransferFunctionSnapshot: Codable, Equatable, Sendable {
  let channel: Int
  let samples: [SIMD4<UInt8>]
  let revision: UInt64

  init(channel: Int, samples: [SIMD4<UInt8>], revision: UInt64 = 0) {
    self.channel = channel
    self.samples = samples
    self.revision = revision
  }

  var base64EncodedSamples: String {
    var bytes = Data(capacity: samples.count * 4)
    for sample in samples {
      bytes.append(contentsOf: [sample.x, sample.y, sample.z, sample.w])
    }
    return bytes.base64EncodedString()
  }
}

struct BorgVRVisualizationSnapshot: Equatable, Sendable {
  var transform: BorgVRTransformSnapshot
  var clipMinimum: SIMD3<Float>
  var clipMaximum: SIMD3<Float>
  var normalizedIsoValue: Float
  var isoValue: Float
  var renderMode: RenderMode
  var brickVisualization: Bool
  var brickVisualizationMask: UInt32 = 7
  var transferBiases: SIMD4<Float>
  var lighting: BorgVRLightingSnapshot
  var objectsVisible: Bool
  var measurementsVisible: Bool
  var objectCount: Int
  var measurementCount: Int
  var transferFunctionRevisions: [UInt64]
}

struct BorgVRRenderAnnotationsSnapshot: Sendable {
  let markers: [VolumeMarker]
  let meshAssets: [UUID: SceneMeshAsset]
  let meshInstances: [SceneMeshInstance]
  let measurements: [VolumeMeasurement]
  let remoteToolPreviews: [SpatialToolPreview]
  let selectedMarkerIDs: Set<UUID>
  let selectedMeasurementID: UUID?
  let selectedMeasurementPointID: UUID?
  let datasetMaximumExtentMeters: Float
  let localToolColor: SIMD4<Float>

  static let empty = BorgVRRenderAnnotationsSnapshot(
    markers: [],
    meshAssets: [:],
    meshInstances: [],
    measurements: [],
    remoteToolPreviews: [],
    selectedMarkerIDs: [],
    selectedMeasurementID: nil,
    selectedMeasurementPointID: nil,
    datasetMaximumExtentMeters: 1,
    localToolColor: SIMD4<Float>(1, 0, 0, 1)
  )
}

struct BorgVRSpatialViewsSnapshot: Sendable {
  let participants: [BorgVRSharePlayParticipant]
  let sharedView: BorgVRScreenViewState?
  let detachedViews: [UUID: BorgVRScreenViewState]
  let namesVisible: Bool
  let interactionActive: Bool

  static let empty = BorgVRSpatialViewsSnapshot(
    participants: [],
    sharedView: nil,
    detachedViews: [:],
    namesVisible: true,
    interactionActive: false
  )
}

struct BorgVRRenderSettingsSnapshot: Sendable {
  let sampleJitter: Bool
  let alphaEpsilon: Float
  let subbrickSkipping: Bool
  let opacityAdaptiveSampling: Bool
  let transferFunctionDisplayMode: Int
  let purgeAtlas: Bool
  let rotationCaptureRequestID: UInt64
  var screenFieldOfView: Float = 45
  var parallelProjection: Bool = false
  var showDatasetBoundingBox: Bool = false
  var background: BorgVRMCPBackgroundState? = nil
  var foveationSamplingStrength: Float = 1

  static let `default` = BorgVRRenderSettingsSnapshot(
    sampleJitter: false,
    alphaEpsilon: 0,
    subbrickSkipping: true,
    opacityAdaptiveSampling: true,
    transferFunctionDisplayMode: 0,
    purgeAtlas: false,
    rotationCaptureRequestID: 0
  )
}

struct BorgVRFrameSnapshot: Sendable {
  let visualization: BorgVRVisualizationSnapshot
  let transferFunctions: [BorgVRTransferFunctionSnapshot]
  let annotations: BorgVRRenderAnnotationsSnapshot
  let spatialViews: BorgVRSpatialViewsSnapshot
  let settings: BorgVRRenderSettingsSnapshot
}

/// Publishes immutable render state without making the renderer cross an actor boundary.
/// Snapshot construction happens on MainActor; a frame only retains the latest finished value.
private final class BorgVRRenderSnapshotStore: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshot: BorgVRFrameSnapshot

  init(_ snapshot: BorgVRFrameSnapshot) {
    self.snapshot = snapshot
  }

  func load() -> BorgVRFrameSnapshot {
    lock.withLock { snapshot }
  }

  func publish(_ snapshot: BorgVRFrameSnapshot) {
    lock.withLock { self.snapshot = snapshot }
  }
}

private final class BorgVRExternalMutationMailbox: @unchecked Sendable {
  struct Pending {
    let source: BorgVRCommandSource
    let domains: Set<BorgVRMutationDomain>
  }

  private let lock = NSLock()
  private var source: BorgVRCommandSource = .userInterface
  private var domains: Set<BorgVRMutationDomain> = []
  private var deliveryScheduled = false

  func enqueue(source: BorgVRCommandSource, domain: BorgVRMutationDomain) -> Bool {
    lock.withLock {
      self.source = source
      domains.insert(domain)
      guard !deliveryScheduled else { return false }
      deliveryScheduled = true
      return true
    }
  }

  func takePending() -> Pending? {
    lock.withLock {
      guard deliveryScheduled else { return nil }
      let pending = Pending(source: source, domains: domains)
      domains.removeAll(keepingCapacity: true)
      deliveryScheduled = false
      return pending
    }
  }
}

enum BorgVRCommand: Codable, Sendable {
  case setRenderMode(RenderMode)
  case setBrickVisualization(enabled: Bool? = nil, resident: Bool? = nil, empty: Bool? = nil, missing: Bool? = nil)
  case setRenderOptimizations(subbrickSkipping: Bool? = nil, opacityAdaptiveSampling: Bool? = nil, alphaEpsilon: Float? = nil)
  case setScreenProjection(fieldOfView: Float? = nil, parallel: Bool? = nil)
  case setBoundingBox(Bool)
  case setTransform(BorgVRTransformSnapshot)
  case rotate(axis: SIMD3<Float>, degrees: Float)
  case setNormalizedIsoValue(Float)
  case setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>)
  case setTransferFunction(BorgVRTransferFunctionSnapshot)
  case setBackground(BorgVRMCPBackgroundState)
  case restoreDatasetViewState(Data)
  case setLighting(
    direction: SIMD3<Float>?,
    ambient: SIMD3<Float>?,
    diffuse: SIMD3<Float>?,
    specular: SIMD3<Float>?
  )
  case setAnnotationVisibility(objects: Bool?, measurements: Bool?)
  case upsertObject(BorgVRObjectCommandState)
  case removeObject(UUID)
  case clearObjects
  case upsertMeasurement(BorgVRMeasurementCommandState)
  case removeMeasurement(UUID)
  case clearMeasurements
  case reset(BorgVRStateResetScope)
  case setSettings(Data)
  case setInteractionMode(String)
  case selectTransferFunctionChannel(Int)
  case setTransferEditing(red: Bool, green: Bool, blue: Bool, opacity: Bool)
  case action(BorgVRRecordedAction)
  /// A semantic boundary for state that does not yet have a lossless GSC representation.
  case mutation(BorgVRMutationDomain)
}

enum BorgVRRecordingError: LocalizedError {
  case unrepresentedMutation(BorgVRMutationDomain)
  case invalidCommand
  case recordingLimitExceeded

  var errorDescription: String? {
    switch self {
      case .unrepresentedMutation(let domain):
        "The recording contains an unsupported change in \(domain.rawValue). It cannot be exported losslessly."
      case .invalidCommand: "Invalid recorded command."
      case .recordingLimitExceeded: "Recording exceeds supported limits (64 MiB, 100000 commands, 32 MiB per command)."
    }
  }
}

extension BorgVRCommand {
  private struct Document: Codable {
    var version = 1
    let command: BorgVRCommand
  }

  func encodedGSCStatement() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(Document(command: self)).base64EncodedString()
    guard payload.utf8.count <= 32 * 1024 * 1024 else { throw BorgVRRecordingError.recordingLimitExceeded }
    return "sessioncommand \(gscQuote(payload))"
  }

  static func decodeGSCCommand(_ payload: String) throws -> Self {
    guard payload.utf8.count <= 32 * 1024 * 1024,
          let data = Data(base64Encoded: payload) else { throw BorgVRRecordingError.invalidCommand }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.version == 1 else { throw BorgVRRecordingError.invalidCommand }
    return document.command
  }
}

/// The recorder's linear GSC subset is intentionally separate from the full macOS DSL.
/// Parse the complete document before executing any operation.
enum BorgVRRecordedGSC {
  static let maximumFileBytes = 64 * 1024 * 1024
  static let maximumCommands = 100_000

  static func commands(in data: Data) throws -> [BorgVRCommand] {
    guard data.count <= maximumFileBytes, let script = String(data: data, encoding: .utf8) else {
      throw BorgVRRecordingError.invalidCommand
    }
    var commands: [BorgVRCommand] = []
    for line in script.split(whereSeparator: \.isNewline) {
      let line = line.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let prefix = "sessioncommand \""
      guard commands.count < maximumCommands, line.hasPrefix(prefix), line.hasSuffix("\"") else {
        throw BorgVRMCPCommandError.unsupported("Native replay accepts BorgVR 3.9 command recordings only. Use the macOS interpreter for general GSC scripts.")
      }
      commands.append(try BorgVRCommand.decodeGSCCommand(String(line.dropFirst(prefix.count).dropLast())))
    }
    guard !commands.isEmpty else { throw BorgVRRecordingError.invalidCommand }
    return commands
  }
}

struct BorgVRCommandEvent: Sendable {
  enum Phase: Sendable, Equatable { case began, committed, failed }
  let id: UUID
  let command: BorgVRCommand
  let source: BorgVRCommandSource
  let timestamp: Date
  let phase: Phase

  init(id: UUID = UUID(), command: BorgVRCommand, source: BorgVRCommandSource, timestamp: Date,
       phase: Phase = .committed) {
    self.id = id
    self.command = command
    self.source = source
    self.timestamp = timestamp
    self.phase = phase
  }
}

enum BorgVRSessionError: Error {
  case commandHandlerUnavailable
  case snapshotProviderUnavailable
}

enum BorgVRSessionCommandError: Error, LocalizedError {
  case invalidRotation
  case invalidScale
  case invalidIsoValue
  case invalidClipping
  case invalidLightDirection
  case invalidLightColor
  case invalidTransferFunction
  case emptyAnnotationVisibility
  case invalidRenderingOptions
  case invalidAnnotation
  case annotationNotFound
  case meshAssetNotFound(UUID)

  var errorDescription: String? {
    switch self {
      case .invalidRotation: "Rotation must not be zero."
      case .invalidScale: "Scale must be positive."
      case .invalidIsoValue: "Normalized isovalue must be between zero and one."
      case .invalidClipping: "Clipping bounds must be ordered and contained in zero to one."
      case .invalidLightDirection: "Light direction must not be zero."
      case .invalidLightColor: "Light colors must be between zero and one."
      case .invalidTransferFunction: "The transfer function data is invalid."
      case .emptyAnnotationVisibility: "At least one annotation visibility value is required."
      case .invalidRenderingOptions: "Provide at least one rendering option; alpha epsilon must be finite and between zero and one."
      case .invalidAnnotation: "The annotation data is invalid."
      case .annotationNotFound: "The requested annotation was not found."
      case .meshAssetNotFound(let id): "No mesh asset with ID \(id.uuidString) was found."
    }
  }
}

/// Owns the state domains of one BorgVR application session without merging their responsibilities.
/// Every external controller can use the same semantic command path, while renderers consume one
/// coherent value snapshot at the beginning of a frame.
@MainActor
final class BorgVRSession<VisualizationState: AnyObject, RuntimeState: AnyObject, SettingsState: AnyObject>: ObservableObject, BorgVRCommandExecuting, @unchecked Sendable {
  typealias CommandHandler = (BorgVRCommand, BorgVRCommandSource) throws -> Void
  typealias SnapshotProvider = () -> BorgVRFrameSnapshot
  typealias AnnotationSnapshotProvider = () -> BorgVRAnnotationSnapshot
  typealias TransferFunctionSnapshotProvider = () -> [BorgVRTransferFunctionSnapshot]

  nonisolated(unsafe) let visualizationState: VisualizationState
  nonisolated(unsafe) let runtimeState: RuntimeState
  nonisolated(unsafe) let settingsState: SettingsState

  private let lock = NSRecursiveLock()
  private let commandHandler: CommandHandler
  private let snapshotProvider: SnapshotProvider
  private let annotationSnapshotProvider: AnnotationSnapshotProvider
  private let transferFunctionSnapshotProvider: TransferFunctionSnapshotProvider
  nonisolated private let renderSnapshotStore: BorgVRRenderSnapshotStore
  nonisolated private let externalMutationMailbox = BorgVRExternalMutationMailbox()
  private var cachedAnnotationSnapshot: BorgVRAnnotationSnapshot
  private var snapshotObservationCancellables: Set<AnyCancellable> = []
  private var snapshotRefreshScheduled = false
  private var tracksObservationSnapshotChanges = false
  private var recordedEvents: [BorgVRCommandEvent] = []
  private let commandEventSubject = PassthroughSubject<BorgVRCommandEvent, Never>()
  var commandEvents: AnyPublisher<BorgVRCommandEvent, Never> { commandEventSubject.eraseToAnyPublisher() }
  private var lastObservedFrame: BorgVRFrameSnapshot
  private var suppressCommandEvents = false
  private var recordsCommands = false
  @Published private(set) var isCommandRecording = false
  @Published private(set) var commandRecordingError: String?
  private var commandDepth = 0
  private var settingsSnapshotProvider: (() throws -> Data)?
  private var lastRecordedSettings: Data?
  private var interfaceSnapshotProvider: (() -> [BorgVRCommand])?
  private var lastRecordedInterface: Data?
  private var recordingID = UUID()
  private var pendingRecordedActions = 0
  private var lastRecordedFrame: BorgVRFrameSnapshot?
  private var lastRecordedAnnotations: BorgVRAnnotationSnapshot = .empty
  private var recordingPreparation: (() -> Void)?
  private var recordingBaselineProvider: (() async throws -> [BorgVRRecordedAction])?
  private var recordingPreparationFinished: (() -> Void)?
  private var recordingBaselineTask: Task<Void, Never>?
  private var recordingContextProvider: (() -> [BorgVRRecordedAction])?

  init(
    visualizationState: VisualizationState,
    runtimeState: RuntimeState,
    settingsState: SettingsState,
    commandHandler: @escaping CommandHandler,
    snapshotProvider: @escaping SnapshotProvider,
    annotationSnapshotProvider: @escaping AnnotationSnapshotProvider = { .empty },
    transferFunctionSnapshotProvider: @escaping TransferFunctionSnapshotProvider = { [] }
  ) {
    self.visualizationState = visualizationState
    self.runtimeState = runtimeState
    self.settingsState = settingsState
    self.commandHandler = commandHandler
    self.snapshotProvider = snapshotProvider
    self.annotationSnapshotProvider = annotationSnapshotProvider
    self.transferFunctionSnapshotProvider = transferFunctionSnapshotProvider
    let initialFrame = snapshotProvider()
    self.renderSnapshotStore = BorgVRRenderSnapshotStore(initialFrame)
    self.lastObservedFrame = initialFrame
    self.cachedAnnotationSnapshot = annotationSnapshotProvider()
  }

  func perform(_ command: BorgVRCommand, source: BorgVRCommandSource) throws {
    lock.lock()
    defer { lock.unlock() }
    captureUncommittedChanges()
    commandDepth += 1
    defer { commandDepth -= 1 }
    try BorgVRCommandExecutionContext.$executingAction.withValue(true) {
      try BorgVRCommandExecutionContext.$source.withValue(source) { try commandHandler(command, source) }
    }
    publishRenderSnapshot()
    refreshAnnotationSnapshot(for: command)
    if case .reset(.transferFunction) = command {
      for snapshot in transferFunctionSnapshotProvider() { emit(.setTransferFunction(snapshot), source: source) }
    } else {
      emit(command, source: source)
    }
    captureSettingsChanges(source: source)
    updateRecordingBaseline()
  }

  func performAction<Result>(_ action: BorgVRRecordedAction, source: BorgVRCommandSource,
                            operation: () throws -> Result) rethrows -> Result {
    if BorgVRCommandExecutionContext.executingAction { return try operation() }
    captureUncommittedChanges()
    let value = try BorgVRCommandExecutionContext.$executingAction.withValue(true) {
      try BorgVRCommandExecutionContext.$source.withValue(source, operation: operation)
    }
    emit(.action(action), source: source)
    updateRecordingBaseline()
    return value
  }

  func trackActionCompletion(_ operation: @escaping @MainActor () async throws -> Void) {
    guard recordsCommands else { return }
    let id = recordingID
    pendingRecordedActions += 1
    Task { @MainActor in
      defer { if self.recordingID == id { self.pendingRecordedActions -= 1 } }
      do { try await operation() }
      catch { if self.recordingID == id { self.commandRecordingError = error.localizedDescription } }
    }
  }

  func performAction<Result>(_ action: BorgVRRecordedAction, source: BorgVRCommandSource,
                            operation: () async throws -> Result) async rethrows -> Result {
    if BorgVRCommandExecutionContext.executingAction { return try await operation() }
    captureUncommittedChanges()
    let id = recordingID
    let isRecorded = recordsCommands && source != .sharePlay
    if isRecorded { pendingRecordedActions += 1; emit(.action(action), source: source, committed: false) }
    let activityID = UUID()
    publishCommandEvent(.action(action), source: source, id: activityID, phase: .began)
    defer { if isRecorded, id == recordingID { pendingRecordedActions -= 1 } }
    do {
      let result = try await BorgVRCommandExecutionContext.$executingAction.withValue(true) {
        try await BorgVRCommandExecutionContext.$source.withValue(source, operation: operation)
      }
      publishCommandEvent(.action(action), source: source, id: activityID)
      return result
    } catch {
      publishCommandEvent(.action(action), source: source, id: activityID, phase: .failed)
      if isRecorded, id == recordingID { commandRecordingError = "A recorded action failed: \(error.localizedDescription)" }
      throw error
    }
  }

  func configureSettingsRecording(_ provider: @escaping () throws -> Data) {
    settingsSnapshotProvider = provider
  }

  func configureInterfaceRecording(_ provider: @escaping () -> [BorgVRCommand]) {
    interfaceSnapshotProvider = provider
  }

  func configureRecordingContext(_ provider: @escaping () -> [BorgVRRecordedAction]) {
    recordingContextProvider = provider
  }

  private func captureInterfaceChanges(source: BorgVRCommandSource = .userInterface) {
    guard recordsCommands, let interfaceSnapshotProvider else { return }
    do {
      let commands = interfaceSnapshotProvider()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(commands)
      guard data != lastRecordedInterface else { return }
      lastRecordedInterface = data
      for command in commands { emit(command, source: source) }
    } catch { commandRecordingError = error.localizedDescription }
  }

  func configureActionRecording(prepare: @escaping () -> Void,
    baseline: @escaping () async throws -> [BorgVRRecordedAction], finish: @escaping () -> Void) {
    recordingPreparation = prepare
    recordingBaselineProvider = baseline
    recordingPreparationFinished = finish
  }

  func performResolvedAction(_ action: BorgVRRecordedAction, source: BorgVRCommandSource,
                            operation: () async throws -> BorgVRRecordedAction) async throws {
    if BorgVRCommandExecutionContext.executingAction { _ = try await operation(); return }
    captureUncommittedChanges()
    let id = recordingID
    let eventID = emit(.action(action), source: source, committed: false)
    let activityID = UUID()
    publishCommandEvent(.action(action), source: source, id: activityID, phase: .began)
    if eventID != nil { pendingRecordedActions += 1 }
    defer { if eventID != nil, id == recordingID { pendingRecordedActions -= 1 } }
    do {
      let result = try await BorgVRCommandExecutionContext.$executingAction.withValue(true) {
        try await BorgVRCommandExecutionContext.$source.withValue(source, operation: operation)
      }
      publishCommandEvent(.action(result), source: source, id: activityID)
      if id == recordingID, let eventID,
        let index = recordedEvents.firstIndex(where: { $0.id == eventID }) {
        recordedEvents[index] = .init(command: .action(result), source: source, timestamp: recordedEvents[index].timestamp)
      }
    } catch {
      publishCommandEvent(.action(action), source: source, id: activityID, phase: .failed)
      if eventID != nil, id == recordingID { commandRecordingError = error.localizedDescription }
      throw error
    }
  }

  func finishCommandRecording() async throws {
    let deadline = ContinuousClock.now + .seconds(300)
    while pendingRecordedActions > 0 {
      guard ContinuousClock.now < deadline else { throw BorgVRMCPCommandError.timeout }
      try await Task.sleep(for: .milliseconds(20))
    }
    _ = stopCommandRecording()
  }

  func waitForRecordingPreparation() async throws {
    await recordingBaselineTask?.value
    if let commandRecordingError { throw BorgVRMCPCommandError.unsupported(commandRecordingError) }
  }

  @discardableResult
  func mutateSettings<Result>(source: BorgVRCommandSource = .userInterface,
                              _ mutation: () throws -> Result) rethrows -> Result {
    let value = try mutation()
    publishRenderSnapshot()
    captureSettingsChanges(source: source)
    return value
  }

  func settingsBinding<Value>(_ binding: Binding<Value>) -> Binding<Value> {
    Binding(get: { binding.wrappedValue }, set: { value in
      self.mutateSettings { binding.wrappedValue = value }
    })
  }

  func binding<Value>(_ binding: Binding<Value>, domain: BorgVRMutationDomain = .visualization) -> Binding<Value> {
    Binding(get: { binding.wrappedValue }, set: { value in
      self.mutate(source: .userInterface, domain: domain) { binding.wrappedValue = value }
    })
  }

  /// File dialogs are presentation; only the committed files belong to a recording.
  func performFileAction(outputs: [URL], operation: () throws -> Void) throws {
    if !recordsCommands || BorgVRCommandExecutionContext.executingAction { try operation(); return }
    captureUncommittedChanges()
    do {
      let files = try BorgVRCommandExecutionContext.$executingAction.withValue(true) {
        try operation()
        return try outputs.map { url in
          BorgVRRecordedFile(path: url.path, data: try Data(contentsOf: url))
        }
      }
      emit(.action(.writeFiles(files)), source: .userInterface)
      updateRecordingBaseline()
    } catch {
      if recordsCommands { commandRecordingError = error.localizedDescription }
      throw error
    }
  }

  func captureFileExport(_ result: Result<URL, Error>) throws {
    guard recordsCommands else { return }
    do { try performFileAction(outputs: [result.get()]) {} }
    catch { commandRecordingError = error.localizedDescription; throw error }
  }

  private func captureSettingsChanges(source: BorgVRCommandSource = .userInterface) {
    guard recordsCommands, source != .sharePlay, let settingsSnapshotProvider else { return }
    do {
      let data = try settingsSnapshotProvider()
      guard data != lastRecordedSettings else { return }
      lastRecordedSettings = data
      emit(.setSettings(data), source: source)
    } catch { commandRecordingError = error.localizedDescription }
  }

  /// Commits a mutation made by a latency-sensitive input handler and derives the semantic
  /// commands represented by the resulting snapshot. The mutation itself remains on MainActor.
  @discardableResult
  func mutate<Result>(
    source: BorgVRCommandSource,
    domain: BorgVRMutationDomain,
    _ mutation: () throws -> Result
  ) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    captureUncommittedChanges()
    let before = frameSnapshot()
    let annotationsBefore = cachedAnnotationSnapshot
    let result = try mutation()
    let after = snapshotProvider()
    renderSnapshotStore.publish(after)
    let commands = inferredCommands(from: before.visualization, to: after.visualization, fallback: domain)
      + inferredSettingsCommands(from: before.settings, to: after.settings)
    let annotationCommands = inferredAnnotationCommands(
      from: annotationsBefore,
      to: refreshAnnotationSnapshot(for: domain),
      domain: domain
    )
    for command in commands + annotationCommands {
      emit(command, source: source)
    }
    updateRecordingBaseline()
    return result
  }

  /// Use when legacy interaction code has already performed its mutation. New code should use
  /// `mutate(source:domain:_:)` so the write and its publication form one session operation.
  func commitExternalMutation(
    source: BorgVRCommandSource,
    domain: BorgVRMutationDomain
  ) {
    lock.lock()
    defer { lock.unlock() }
    captureUncommittedChanges(source: source)
    let before = frameSnapshot()
    let annotationsBefore = cachedAnnotationSnapshot
    let after = snapshotProvider()
    renderSnapshotStore.publish(after)
    let commands = inferredCommands(from: before.visualization, to: after.visualization, fallback: domain)
      + inferredSettingsCommands(from: before.settings, to: after.settings)
    let annotationCommands = inferredAnnotationCommands(
      from: annotationsBefore,
      to: refreshAnnotationSnapshot(for: domain),
      domain: domain
    )
    for command in commands + annotationCommands {
      emit(command, source: source)
    }
    updateRecordingBaseline()
  }

  /// Bridges render-actor and device callbacks to the MainActor-owned session without blocking
  /// their input loop. Consecutive high-frequency updates may intentionally coalesce.
  nonisolated func submitExternalMutation(
    source: BorgVRCommandSource,
    domain: BorgVRMutationDomain
  ) {
    guard externalMutationMailbox.enqueue(source: source, domain: domain) else { return }
    Task { @MainActor [weak self] in
      self?.commitPendingExternalMutations()
    }
  }

  private func commitPendingExternalMutations() {
    guard let pending = externalMutationMailbox.takePending() else { return }
    lock.lock()
    defer { lock.unlock() }
    captureUncommittedChanges(source: pending.source)
    let before = frameSnapshot()
    let annotationsBefore = cachedAnnotationSnapshot
    let after = snapshotProvider()
    renderSnapshotStore.publish(after)

    let fallback = pending.domains.sorted { $0.rawValue < $1.rawValue }.first ?? .interaction
    var commands = inferredCommands(
      from: before.visualization,
      to: after.visualization,
      fallback: fallback
    ) + inferredSettingsCommands(from: before.settings, to: after.settings)
    let annotationAfter = annotationSnapshotProvider()
    if pending.domains.contains(.objects) {
      commands += inferredAnnotationCommands(
        from: annotationsBefore,
        to: annotationAfter,
        domain: .objects
      )
    }
    if pending.domains.contains(.measurements) {
      commands += inferredAnnotationCommands(
        from: annotationsBefore,
        to: annotationAfter,
        domain: .measurements
      )
    }
    if pending.domains.contains(.objects) || pending.domains.contains(.measurements) {
      cachedAnnotationSnapshot = annotationAfter
    }
    for command in commands {
      emit(command, source: pending.source)
    }
    updateRecordingBaseline()
  }

  nonisolated func renderSnapshot() -> BorgVRVisualizationSnapshot {
    renderSnapshotStore.load().visualization
  }

  nonisolated func frameSnapshot() -> BorgVRFrameSnapshot {
    renderSnapshotStore.load()
  }

  func currentSnapshot() -> BorgVRVisualizationSnapshot {
    currentFrameSnapshot().visualization
  }

  /// Startup must not wait for the coalesced UI observation to publish a new dataset.
  func currentFrameSnapshot() -> BorgVRFrameSnapshot {
    let snapshot = snapshotProvider()
    renderSnapshotStore.publish(snapshot)
    return snapshot
  }

  func publishRenderSnapshot() {
    let snapshot = snapshotProvider()
    renderSnapshotStore.publish(snapshot)
    if commandDepth == 0 { captureUncommittedChanges(observedFrame: snapshot) }
  }

  private func updateRecordingBaseline() {
    guard recordsCommands else { return }
    captureInterfaceChanges()
    lastRecordedFrame = snapshotProvider()
    lastRecordedAnnotations = annotationSnapshotProvider()
  }

  /// Safety net for legacy input and platform observation. Renderer snapshot refreshes
  /// must not consume a change before the recorder has derived its semantic commands.
  private func captureUncommittedChanges(source: BorgVRCommandSource = .userInterface,
                                         observedFrame: BorgVRFrameSnapshot? = nil) {
    if !recordsCommands, commandDepth == 0 {
      let after = observedFrame ?? snapshotProvider()
      let changes = inferredCommands(from: lastObservedFrame.visualization, to: after.visualization, fallback: .visualization)
        + inferredSettingsCommands(from: lastObservedFrame.settings, to: after.settings)
      for command in changes { publishCommandEvent(command, source: source) }
      lastObservedFrame = after
      return
    }
    guard recordsCommands, commandDepth == 0, let before = lastRecordedFrame else { return }
    let after = snapshotProvider()
    let annotations = annotationSnapshotProvider()
    let changes = inferredCommands(from: before.visualization, to: after.visualization, fallback: .visualization)
      + inferredSettingsCommands(from: before.settings, to: after.settings)
      + inferredAnnotationCommands(from: lastRecordedAnnotations, to: annotations, domain: .objects)
      + inferredAnnotationCommands(from: lastRecordedAnnotations, to: annotations, domain: .measurements)
    for command in changes { emit(command, source: source) }
    lastObservedFrame = after
    lastRecordedFrame = after
    lastRecordedAnnotations = annotations
    cachedAnnotationSnapshot = annotations
    captureSettingsChanges(source: source)
    captureInterfaceChanges(source: source)
  }

  /// Tracks ObservableObject changes without rebuilding state in every screen-rendering frame.
  /// ObservableObject emits before mutation, so publication is coalesced onto the next MainActor turn.
  func trackRenderSnapshotChanges<P: Publisher>(from publishers: [P])
  where P.Output == Void, P.Failure == Never {
    for publisher in publishers {
      publisher
        .sink { [weak self] in
          Task { @MainActor [weak self] in
            self?.scheduleRenderSnapshotRefresh()
          }
        }
        .store(in: &snapshotObservationCancellables)
    }
  }

  /// Tracks the properties read by the visionOS snapshot provider. Observation callbacks are
  /// one-shot, so every publication installs tracking for the next change.
  func trackObservedRenderSnapshotChanges() {
    tracksObservationSnapshotChanges = true
    publishObservedRenderSnapshot()
  }

  private func scheduleRenderSnapshotRefresh() {
    guard !snapshotRefreshScheduled else { return }
    snapshotRefreshScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      self.captureSettingsChanges()
      self.snapshotRefreshScheduled = false
      if self.tracksObservationSnapshotChanges {
        self.publishObservedRenderSnapshot()
      } else {
        self.publishRenderSnapshot()
      }
    }
  }

  private func publishObservedRenderSnapshot() {
    let snapshot = withObservationTracking {
      snapshotProvider()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.scheduleRenderSnapshotRefresh()
      }
    }
    renderSnapshotStore.publish(snapshot)
    captureUncommittedChanges(observedFrame: snapshot)
  }

  func startCommandRecording() {
    lock.withLock {
      guard !isCommandRecording, pendingRecordedActions == 0 else { return }
      suppressCommandEvents = true
      defer {
        lastObservedFrame = renderSnapshotStore.load()
        suppressCommandEvents = false
      }
      recordedEvents.removeAll(keepingCapacity: true)
      recordingID = UUID()
      pendingRecordedActions = 0
      recordsCommands = true
      isCommandRecording = true
      commandRecordingError = nil
      lastRecordedSettings = nil
      lastRecordedInterface = nil
      lastRecordedFrame = nil
      publishRenderSnapshot()
      let frame = frameSnapshot()
      emit(.setRenderMode(frame.visualization.renderMode), source: .userInterface)
      emit(.setTransform(frame.visualization.transform), source: .userInterface)
      emit(.setClipping(minimum: frame.visualization.clipMinimum,
        maximum: frame.visualization.clipMaximum), source: .userInterface)
      emit(.setNormalizedIsoValue(frame.visualization.normalizedIsoValue), source: .userInterface)
      for transferFunction in transferFunctionSnapshotProvider() {
        emit(.setTransferFunction(transferFunction), source: .userInterface)
      }
      let light = frame.visualization.lighting
      emit(.setLighting(direction: light.direction, ambient: light.ambient,
        diffuse: light.diffuse, specular: light.specular), source: .userInterface)
      emit(.clearObjects, source: .userInterface)
      emit(.clearMeasurements, source: .userInterface)
      let annotations = annotationSnapshotProvider()
      for object in annotations.objects { emit(.upsertObject(object), source: .userInterface) }
      for measurement in annotations.measurements { emit(.upsertMeasurement(measurement), source: .userInterface) }
      emit(.setAnnotationVisibility(objects: frame.visualization.objectsVisible,
        measurements: frame.visualization.measurementsVisible), source: .userInterface)
      let mask = frame.visualization.brickVisualizationMask
      emit(.setBrickVisualization(enabled: frame.visualization.brickVisualization,
        resident: mask & 1 != 0, empty: mask & 2 != 0, missing: mask & 4 != 0), source: .userInterface)
      emit(.setRenderOptimizations(subbrickSkipping: frame.settings.subbrickSkipping,
        opacityAdaptiveSampling: frame.settings.opacityAdaptiveSampling,
        alphaEpsilon: frame.settings.alphaEpsilon), source: .userInterface)
      emit(.setBoundingBox(frame.settings.showDatasetBoundingBox), source: .userInterface)
#if os(iOS) || os(macOS)
      emit(.setScreenProjection(fieldOfView: frame.settings.screenFieldOfView,
        parallel: frame.settings.parallelProjection), source: .userInterface)
      if let background = frame.settings.background { emit(.setBackground(background), source: .userInterface) }
#endif
      captureSettingsChanges()
      updateRecordingBaseline()
      for action in recordingContextProvider?() ?? [] { emit(.action(action), source: .userInterface) }
      if let recordingBaselineProvider {
        recordingPreparation?()
        pendingRecordedActions += 1
        let id = recordingID
        recordingBaselineTask = Task { @MainActor [weak self] in
          guard let self else { return }
          defer {
            if self.recordingID == id {
              self.recordingPreparationFinished?()
              self.pendingRecordedActions -= 1
            }
          }
          do {
            let actions = try await recordingBaselineProvider()
            guard self.recordingID == id else { return }
            self.recordedEvents.insert(contentsOf: actions.map {
              BorgVRCommandEvent(command: .action($0), source: .userInterface, timestamp: Date())
            }, at: 0)
          } catch {
            if self.recordingID == id { self.commandRecordingError = error.localizedDescription }
          }
        }
      }
    }
  }

  func stopCommandRecording() -> [BorgVRCommandEvent] {
    lock.withLock {
      commitPendingExternalMutations()
      captureUncommittedChanges()
      captureSettingsChanges()
      recordsCommands = false
      isCommandRecording = false
      return recordedEvents
    }
  }

  func recordedGSCScript() throws -> String {
    try lock.withLock {
      if let commandRecordingError { throw BorgVRMCPCommandError.unsupported(commandRecordingError) }
      guard pendingRecordedActions == 0 else {
        throw BorgVRMCPCommandError.unsupported("Recorded actions are still running. Wait before saving the recording.")
      }
      guard recordedEvents.count <= BorgVRRecordedGSC.maximumCommands else { throw BorgVRRecordingError.recordingLimitExceeded }
      var bytes = 0
      return try recordedEvents.map { event in
        if case .mutation(let domain) = event.command { throw BorgVRRecordingError.unrepresentedMutation(domain) }
        let line = try event.command.encodedGSCStatement()
        bytes += line.utf8.count + 1
        guard bytes <= BorgVRRecordedGSC.maximumFileBytes else { throw BorgVRRecordingError.recordingLimitExceeded }
        return line
      }.joined(separator: "\n")
    }
  }

  @discardableResult
  private func emit(_ command: BorgVRCommand, source: BorgVRCommandSource, committed: Bool = true) -> UUID? {
    guard !BorgVRCommandExecutionContext.executingAction else { return nil }
    if committed { publishCommandEvent(command, source: source) }
    let event = BorgVRCommandEvent(command: command, source: source, timestamp: Date())
    if recordsCommands, source != .sharePlay {
      if let lastIndex = recordedEvents.indices.last,
         command.replacesRecordedCommand(recordedEvents[lastIndex].command) {
        recordedEvents[lastIndex] = event
      } else {
        recordedEvents.append(event)
      }
      return event.id
    }
    return nil
  }

  private func publishCommandEvent(_ command: BorgVRCommand, source: BorgVRCommandSource,
                                   id: UUID = UUID(), phase: BorgVRCommandEvent.Phase = .committed) {
    guard !suppressCommandEvents else { return }
    if phase != .began { lastObservedFrame = snapshotProvider() }
    let origin = BorgVRCommandExecutionContext.originOverride ?? source
    commandEventSubject.send(.init(id: id, command: command, source: origin, timestamp: Date(), phase: phase))
  }

  private func inferredCommands(
    from before: BorgVRVisualizationSnapshot,
    to after: BorgVRVisualizationSnapshot,
    fallback domain: BorgVRMutationDomain
  ) -> [BorgVRCommand] {
    var commands: [BorgVRCommand] = []
    if before.transform != after.transform {
      commands.append(.setTransform(after.transform))
    }
    if before.renderMode != after.renderMode {
      commands.append(.setRenderMode(after.renderMode))
    }
    if before.brickVisualization != after.brickVisualization ||
       before.brickVisualizationMask != after.brickVisualizationMask {
      let mask = after.brickVisualizationMask
      commands.append(.setBrickVisualization(enabled: after.brickVisualization,
        resident: mask & 1 != 0, empty: mask & 2 != 0, missing: mask & 4 != 0))
    }
    if before.normalizedIsoValue != after.normalizedIsoValue {
      commands.append(.setNormalizedIsoValue(after.normalizedIsoValue))
    }
    if before.clipMinimum != after.clipMinimum || before.clipMaximum != after.clipMaximum {
      commands.append(.setClipping(minimum: after.clipMinimum, maximum: after.clipMaximum))
    }
    if before.lighting != after.lighting {
      commands.append(.setLighting(
        direction: after.lighting.direction,
        ambient: after.lighting.ambient,
        diffuse: after.lighting.diffuse,
        specular: after.lighting.specular
      ))
    }
    if before.objectsVisible != after.objectsVisible ||
       before.measurementsVisible != after.measurementsVisible {
      commands.append(.setAnnotationVisibility(
        objects: before.objectsVisible == after.objectsVisible ? nil : after.objectsVisible,
        measurements: before.measurementsVisible == after.measurementsVisible
          ? nil
          : after.measurementsVisible
      ))
    }
    if before.transferFunctionRevisions != after.transferFunctionRevisions {
      let snapshots = Dictionary(
        uniqueKeysWithValues: transferFunctionSnapshotProvider().map { ($0.channel, $0) }
      )
      for channel in after.transferFunctionRevisions.indices where
        channel >= before.transferFunctionRevisions.count ||
        before.transferFunctionRevisions[channel] != after.transferFunctionRevisions[channel] {
        if let snapshot = snapshots[channel] {
          commands.append(.setTransferFunction(snapshot))
        }
      }
      if !commands.contains(where: { command in
        if case .setTransferFunction = command { return true }
        return false
      }) {
        commands.append(.mutation(.transferFunction))
      }
    }
    return commands
  }

  private func inferredSettingsCommands(
    from before: BorgVRRenderSettingsSnapshot, to after: BorgVRRenderSettingsSnapshot
  ) -> [BorgVRCommand] {
    var commands: [BorgVRCommand] = []
    if before.background != after.background, let background = after.background {
      commands.append(.setBackground(background))
    }
    if before.showDatasetBoundingBox != after.showDatasetBoundingBox {
      commands.append(.setBoundingBox(after.showDatasetBoundingBox))
    }
    if before.screenFieldOfView != after.screenFieldOfView ||
       before.parallelProjection != after.parallelProjection {
      commands.append(.setScreenProjection(fieldOfView: after.screenFieldOfView,
        parallel: after.parallelProjection))
    }
    if before.subbrickSkipping != after.subbrickSkipping ||
          before.opacityAdaptiveSampling != after.opacityAdaptiveSampling ||
          before.alphaEpsilon != after.alphaEpsilon {
      commands.append(.setRenderOptimizations(subbrickSkipping: after.subbrickSkipping,
        opacityAdaptiveSampling: after.opacityAdaptiveSampling, alphaEpsilon: after.alphaEpsilon))
    }
    return commands
  }

  private func refreshAnnotationSnapshot(for command: BorgVRCommand) {
    switch command {
      case .upsertObject, .removeObject, .clearObjects,
           .upsertMeasurement, .removeMeasurement, .clearMeasurements:
        cachedAnnotationSnapshot = annotationSnapshotProvider()
      default:
        break
    }
  }

  private func refreshAnnotationSnapshot(
    for domain: BorgVRMutationDomain
  ) -> BorgVRAnnotationSnapshot {
    guard domain == .objects || domain == .measurements else {
      return cachedAnnotationSnapshot
    }
    let snapshot = annotationSnapshotProvider()
    cachedAnnotationSnapshot = snapshot
    return snapshot
  }

  private func inferredAnnotationCommands(
    from before: BorgVRAnnotationSnapshot,
    to after: BorgVRAnnotationSnapshot,
    domain: BorgVRMutationDomain
  ) -> [BorgVRCommand] {
    switch domain {
      case .objects:
        if !before.objects.isEmpty, after.objects.isEmpty { return [.clearObjects] }
        let oldObjects = Dictionary(uniqueKeysWithValues: before.objects.map { ($0.id, $0) })
        let newObjects = Dictionary(uniqueKeysWithValues: after.objects.map { ($0.id, $0) })
        let removed = oldObjects.keys.filter { newObjects[$0] == nil }.sorted {
          $0.uuidString < $1.uuidString
        }.map(BorgVRCommand.removeObject)
        let changed = after.objects.filter { oldObjects[$0.id] != $0 }.map {
          BorgVRCommand.upsertObject($0)
        }
        return removed + changed
      case .measurements:
        if !before.measurements.isEmpty, after.measurements.isEmpty {
          return [.clearMeasurements]
        }
        let oldMeasurements = Dictionary(
          uniqueKeysWithValues: before.measurements.map { ($0.id, $0) }
        )
        let newMeasurements = Dictionary(
          uniqueKeysWithValues: after.measurements.map { ($0.id, $0) }
        )
        let removed = oldMeasurements.keys.filter { newMeasurements[$0] == nil }.sorted {
          $0.uuidString < $1.uuidString
        }.map(BorgVRCommand.removeMeasurement)
        let changed = after.measurements.filter { oldMeasurements[$0.id] != $0 }.map {
          BorgVRCommand.upsertMeasurement($0)
        }
        return removed + changed
      default:
        return []
    }
  }
}

private extension BorgVRCommand {
  func replacesRecordedCommand(_ previous: BorgVRCommand) -> Bool {
    switch (self, previous) {
      case (.setTransform, .setTransform),
           (.setNormalizedIsoValue, .setNormalizedIsoValue),
           (.setClipping, .setClipping):
        true
      case (.setTransferFunction(let current), .setTransferFunction(let old)):
        current.channel == old.channel
      case (.upsertObject(let current), .upsertObject(let old)):
        current.id == old.id
      case (.upsertMeasurement(let current), .upsertMeasurement(let old)):
        current.id == old.id
      default:
        false
    }
  }
}

private extension RenderMode {
  var gscName: String {
    switch self {
      case .transferFunction1D: "tf"
      case .transferFunction1DLighting: "lighting"
      case .isoValue: "iso"
    }
  }
}

#if os(iOS) || os(macOS)
typealias ScreenBorgVRSession = BorgVRSession<RenderingParameters, AppModel, AppSettings>

extension BorgVRSession where VisualizationState == RenderingParameters,
                              RuntimeState == AppModel,
                              SettingsState == AppSettings {
  static func screen(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    appSettings: AppSettings,
    synchronizeTransform: @escaping () -> Void = {},
    synchronizeState: @escaping () -> Void = {},
    synchronizeFullState: @escaping () -> Void = {},
    synchronizeObjects: @escaping () -> Void = {},
    synchronizeMeasurements: @escaping () -> Void = {},
    renderModeDidChange: @escaping (RenderMode) -> Void = { _ in }
  ) -> ScreenBorgVRSession {
    let session = ScreenBorgVRSession(
      visualizationState: renderingParameters,
      runtimeState: appModel,
      settingsState: appSettings,
      commandHandler: { command, _ in
        switch command {
          case .setRenderMode(let mode):
            renderingParameters.renderMode = mode
            renderModeDidChange(mode)
            synchronizeState()
          case .setBrickVisualization(let enabled, let resident, let empty, let missing):
            guard enabled != nil || resident != nil || empty != nil || missing != nil else {
              throw BorgVRSessionCommandError.invalidRenderingOptions
            }
            if let enabled { renderingParameters.brickVis = enabled }
            if let resident { renderingParameters.brickVisResident = resident }
            if let empty { renderingParameters.brickVisEmpty = empty }
            if let missing { renderingParameters.brickVisMissing = missing }
            if enabled != nil { synchronizeState() }
          case .setRenderOptimizations(let subbrick, let adaptive, let epsilon):
            guard subbrick != nil || adaptive != nil || epsilon != nil,
                  epsilon.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
              throw BorgVRSessionCommandError.invalidRenderingOptions
            }
            if let subbrick { appSettings.subbrickSkipping = subbrick }
            if let adaptive { appSettings.opacityAdaptiveSampling = adaptive }
            if let epsilon { appSettings.alphaEpsilon = Double(epsilon) }
          case .setScreenProjection(let fieldOfView, let parallel):
            guard fieldOfView != nil || parallel != nil,
                  fieldOfView.map({ $0.isFinite && ScreenProjection.fieldOfViewRange.contains($0) }) ?? true else {
              throw BorgVRSessionCommandError.invalidRenderingOptions
            }
            if let fieldOfView { appSettings.screenFieldOfView = Double(fieldOfView) }
            if let parallel { appSettings.parallelProjection = parallel }
          case .setBoundingBox(let visible):
            appSettings.showDatasetBoundingBox = visible
          case .setTransform(let transform):
            guard transform.rotation.x.isFinite, transform.rotation.y.isFinite,
                  transform.rotation.z.isFinite, transform.rotation.w.isFinite,
                  simd_length_squared(transform.rotation).isFinite,
                  simd_length_squared(transform.rotation) > 0.000_001 else {
              throw BorgVRSessionCommandError.invalidRotation
            }
            guard transform.scale.x.isFinite, transform.scale.y.isFinite, transform.scale.z.isFinite,
                  transform.translation.x.isFinite, transform.translation.y.isFinite, transform.translation.z.isFinite,
                  transform.scale.x > 0,
                  transform.scale.y > 0,
                  transform.scale.z > 0 else {
              throw BorgVRSessionCommandError.invalidScale
            }
            guard transform.translation.z == 0, transform.scale.x == transform.scale.y,
                  transform.scale.y == transform.scale.z else {
              throw BorgVRMCPCommandError.unsupported("The screen renderer supports XY translation and uniform scaling only.")
            }
            renderingParameters.orientation = simd_normalize(
              simd_quatf(vector: transform.rotation)
            )
            renderingParameters.pan = SIMD2<Float>(
              transform.translation.x,
              transform.translation.y
            )
            renderingParameters.scale = transform.scale.x
            synchronizeTransform()
          case .rotate(let axis, let degrees):
            guard simd_length_squared(axis) > 0.000_001 else {
              throw BorgVRSessionCommandError.invalidRotation
            }
            let rotation = simd_quatf(
              angle: degrees * .pi / 180,
              axis: simd_normalize(axis)
            )
            renderingParameters.orientation = simd_normalize(
              rotation * renderingParameters.orientation
            )
            synchronizeTransform()
          case .setNormalizedIsoValue(let value):
            guard value.isFinite, (0...1).contains(value) else {
              throw BorgVRSessionCommandError.invalidIsoValue
            }
            renderingParameters.normIsoValue = value
            synchronizeState()
          case .setClipping(let minimum, let maximum):
            guard validClipping(minimum: minimum, maximum: maximum) else {
              throw BorgVRSessionCommandError.invalidClipping
            }
            renderingParameters.clipMin = minimum
            renderingParameters.clipMax = maximum
            renderingParameters.clippingTranslation = .zero
            synchronizeState()
          case .setTransferFunction(let snapshot):
            guard renderingParameters.transferFunctions.indices.contains(snapshot.channel),
                  renderingParameters.transferFunctions[snapshot.channel].data.count ==
                    snapshot.samples.count else {
              throw BorgVRSessionCommandError.invalidTransferFunction
            }
            renderingParameters.objectWillChange.send()
            try renderingParameters.transferFunctions[snapshot.channel].updateData(
              with: snapshot.samples
            )
            synchronizeFullState()
          case .setBackground(let background):
            try appSettings.applyAutomationBackground(background)
          case .restoreDatasetViewState(let data):
            let state = try DatasetViewStateDocument.decode(from: data)
            guard state.datasetID == appModel.activeDataset?.uniqueId else {
              throw DatasetViewStateDocumentError.invalidState
            }
            renderingParameters.applyDatasetViewState(state)
            renderModeDidChange(state.common.renderMode)
            synchronizeFullState()
          case .setLighting(let direction, let ambient, let diffuse, let specular):
            if let direction {
              guard simd_length_squared(direction) > 0.000_001 else {
                throw BorgVRSessionCommandError.invalidLightDirection
              }
              renderingParameters.lightDirection = simd_normalize(direction)
            }
            if let ambient {
              renderingParameters.ambientLightColor = try validatedLightColor(ambient)
            }
            if let diffuse {
              renderingParameters.diffuseLightColor = try validatedLightColor(diffuse)
            }
            if let specular {
              renderingParameters.specularLightColor = try validatedLightColor(specular)
            }
            synchronizeState()
          case .setAnnotationVisibility(let objects, let measurements):
            guard objects != nil || measurements != nil else {
              throw BorgVRSessionCommandError.emptyAnnotationVisibility
            }
            if let objects { appModel.objectsHidden = !objects }
            if let measurements { appModel.measurementsHidden = !measurements }
          case .upsertObject(let object):
            switch object {
              case .marker(let state):
                let marker = try state.marker()
                if let index = appModel.volumeMarkers.firstIndex(where: { $0.id == marker.id }) {
                  appModel.volumeMarkers[index] = marker
                } else {
                  appModel.volumeMarkers.append(marker)
                }
              case .mesh(let state):
                let asset = appModel.sceneMeshAssets[state.assetID]
                  ?? SceneMeshAssetCatalog.load(assetID: state.assetID, logger: appModel.logger)
                guard let asset else {
                  throw BorgVRSessionCommandError.meshAssetNotFound(state.assetID)
                }
                appModel.sceneMeshAssets[asset.id] = asset
                let instance = try state.instance(asset: asset)
                if let index = appModel.sceneMeshInstances.firstIndex(where: {
                  $0.id == instance.id
                }) {
                  appModel.sceneMeshInstances[index] = instance
                } else {
                  appModel.sceneMeshInstances.append(instance)
                }
            }
            synchronizeObjects()
          case .removeObject(let id):
            let removedMarker = appModel.removeVolumeMarkers(withIDs: [id])
            let removedMesh = appModel.removeSceneMeshInstance(id: id)
            guard removedMarker || removedMesh else {
              throw BorgVRSessionCommandError.annotationNotFound
            }
            synchronizeObjects()
          case .clearObjects:
            appModel.replaceVolumeMarkers([])
            appModel.replaceSceneMeshInstances([])
            appModel.selectedSceneMeshInstanceID = nil
            synchronizeObjects()
          case .upsertMeasurement(let state):
            let measurement = try state.measurement(
              physicalExtent: appModel.activeDatasetMetadata?.physicalExtentMeters
            )
            if let index = appModel.volumeMeasurements.firstIndex(where: {
              $0.id == measurement.id
            }) {
              appModel.volumeMeasurements[index] = measurement
            } else {
              appModel.volumeMeasurements.append(measurement)
            }
            synchronizeMeasurements()
          case .removeMeasurement(let id):
            let oldCount = appModel.volumeMeasurements.count
            appModel.volumeMeasurements.removeAll { $0.id == id }
            guard appModel.volumeMeasurements.count != oldCount else {
              throw BorgVRSessionCommandError.annotationNotFound
            }
            if appModel.selectedVolumeMeasurementID == id {
              appModel.clearVolumeMeasurementSelection()
            }
            synchronizeMeasurements()
          case .clearMeasurements:
            appModel.replaceVolumeMeasurements([])
            appModel.clearVolumeMeasurementSelection()
            synchronizeMeasurements()
          case .reset(let scope):
            switch scope {
              case .all:
                renderingParameters.reset()
                synchronizeFullState()
              case .transform:
                renderingParameters.resetTransform()
                synchronizeTransform()
              case .clipping:
                renderingParameters.clipMin = .zero
                renderingParameters.clipMax = .one
                renderingParameters.clippingTranslation = .zero
                synchronizeState()
              case .transferFunction:
                renderingParameters.transferFunction.reset()
                renderingParameters.objectWillChange.send()
                synchronizeFullState()
              case .lighting:
                let lighting = BorgVRLightingState.default
                renderingParameters.lightDirection = lighting.direction
                renderingParameters.ambientLightColor = lighting.ambientColor
                renderingParameters.diffuseLightColor = lighting.diffuseColor
                renderingParameters.specularLightColor = lighting.specularColor
                synchronizeState()
            }
          case .mutation:
            break
          case .setSettings(let data):
            try appSettings.settingsStore().importRecording(data)
          case .setInteractionMode(let value):
            guard let mode = AppModel.InteractionMode(rawValue: value) else {
              throw BorgVRSessionCommandError.invalidRenderingOptions
            }
            appModel.interactionMode = mode
          case .selectTransferFunctionChannel(let channel):
            guard (0..<renderingParameters.componentCount).contains(channel) else {
              throw BorgVRSessionCommandError.invalidTransferFunction
            }
            renderingParameters.selectedTransferFunctionChannel = channel
          case .setTransferEditing(let red, let green, let blue, let opacity):
            renderingParameters.transferEditing = TransferEditing(red: red, green: green, blue: blue, opacity: opacity)
          case .action(let action):
            switch action {
              case .purgeAtlas:
                guard let purge = appModel.renderAtlasPurgeHandler else { throw BorgVRMCPCommandError.noDataset }
                purge()
              default:
                throw BorgVRMCPCommandError.unsupported("This action requires the asynchronous command executor.")
            }
        }
      },
      snapshotProvider: {
        let orientation = renderingParameters.orientation.vector
        let transferFunctions = renderingParameters.activeTransferFunctions.enumerated().map {
          channel, transferFunction in
          BorgVRTransferFunctionSnapshot(
            channel: channel,
            samples: transferFunction.data,
            revision: transferFunction.revision
          )
        }
        let visualization = BorgVRVisualizationSnapshot(
          transform: BorgVRTransformSnapshot(
            rotation: orientation,
            translation: SIMD3<Float>(
              renderingParameters.pan.x,
              renderingParameters.pan.y,
              0
            ),
            scale: SIMD3<Float>(repeating: renderingParameters.scale)
          ),
          clipMinimum: renderingParameters.clipMin,
          clipMaximum: renderingParameters.clipMax,
          normalizedIsoValue: renderingParameters.normIsoValue,
          isoValue: renderingParameters.isoValue,
          renderMode: renderingParameters.renderMode,
          brickVisualization: renderingParameters.brickVis,
          brickVisualizationMask: renderingParameters.brickVisualizationMask,
          transferBiases: renderingParameters.transferBiases,
          lighting: BorgVRLightingSnapshot(
            direction: renderingParameters.lightDirection,
            ambient: renderingParameters.ambientLightColor,
            diffuse: renderingParameters.diffuseLightColor,
            specular: renderingParameters.specularLightColor
          ),
          objectsVisible: !appModel.objectsHidden,
          measurementsVisible: !appModel.measurementsHidden,
          objectCount: appModel.volumeMarkers.count + appModel.sceneMeshInstances.count,
          measurementCount: appModel.volumeMeasurements.count,
          transferFunctionRevisions: renderingParameters.activeTransferFunctions.map(\.revision)
        )
        let maximumExtent: Float
        if let metadata = appModel.activeDatasetMetadata {
          let extent = metadata.physicalExtentMeters
          maximumExtent = max(extent.x, max(extent.y, extent.z))
        } else {
          maximumExtent = 1
        }
        return BorgVRFrameSnapshot(
          visualization: visualization,
          transferFunctions: transferFunctions,
          annotations: BorgVRRenderAnnotationsSnapshot(
            markers: appModel.volumeMarkers,
            meshAssets: appModel.sceneMeshAssets,
            meshInstances: appModel.sceneMeshInstances,
            measurements: appModel.volumeMeasurements,
            remoteToolPreviews: appModel.activeRemoteSpatialToolPreviews(),
            selectedMarkerIDs: appModel.selectedVolumeMarkerIDs,
            selectedMeasurementID: appModel.selectedVolumeMeasurementID,
            selectedMeasurementPointID: appModel.selectedVolumeMeasurementPointID,
            datasetMaximumExtentMeters: maximumExtent,
            localToolColor: SIMD4<Float>(1, 0, 0, 1)
          ),
          spatialViews: .empty,
          settings: BorgVRRenderSettingsSnapshot(
            sampleJitter: appSettings.sampleJitter,
            alphaEpsilon: Float(appSettings.alphaEpsilon),
            subbrickSkipping: appSettings.subbrickSkipping,
            opacityAdaptiveSampling: appSettings.opacityAdaptiveSampling,
            transferFunctionDisplayMode: 0,
            purgeAtlas: false,
            rotationCaptureRequestID: 0,
            screenFieldOfView: Float(appSettings.screenFieldOfView),
            parallelProjection: appSettings.parallelProjection,
            showDatasetBoundingBox: appSettings.showDatasetBoundingBox,
            background: appSettings.automationBackground
          )
        )
      },
      annotationSnapshotProvider: {
        BorgVRAnnotationSnapshot(
          markers: appModel.volumeMarkers,
          meshInstances: appModel.sceneMeshInstances,
          measurements: appModel.volumeMeasurements
        )
      },
      transferFunctionSnapshotProvider: {
        renderingParameters.activeTransferFunctions.enumerated().map { channel, transferFunction in
          BorgVRTransferFunctionSnapshot(
            channel: channel,
            samples: transferFunction.data,
            revision: transferFunction.revision
          )
        }
      }
    )
    appModel.commandExecutor = session
    appModel.volumeBrush.installCommandExecutor(session)
    session.configureActionRecording(prepare: { appModel.volumeBrush.beginRecordingPreparation() },
      baseline: {
        let dataset = appModel.activeDataset.map { BorgVRRecordedAction.openDataset($0.uniqueId) }
        return try await (dataset.map { [$0] } ?? []) + appModel.volumeBrush.recordingBaseline()
      },
      finish: { appModel.volumeBrush.finishRecordingPreparation() })
    session.configureSettingsRecording { try appSettings.settingsStore().exportForRecording() }
    session.configureInterfaceRecording {
      let editing = renderingParameters.transferEditing
      return [.setInteractionMode(appModel.interactionMode.rawValue),
        .selectTransferFunctionChannel(renderingParameters.selectedTransferFunctionChannel),
        .setTransferEditing(red: editing.red, green: editing.green, blue: editing.blue, opacity: editing.opacity)]
    }
    session.trackRenderSnapshotChanges(from: [
      renderingParameters.objectWillChange,
      appModel.objectWillChange,
      appSettings.objectWillChange
    ])
    session.trackObservedRenderSnapshotChanges()
    return session
  }
}
#endif

private func validClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>) -> Bool {
  minimum.x >= 0 && minimum.y >= 0 && minimum.z >= 0 &&
    maximum.x <= 1 && maximum.y <= 1 && maximum.z <= 1 &&
    minimum.x <= maximum.x && minimum.y <= maximum.y && minimum.z <= maximum.z
}

private func validatedLightColor(_ color: SIMD3<Float>) throws -> SIMD3<Float> {
  guard color.x.isFinite, color.y.isFinite, color.z.isFinite,
        color.x >= 0, color.x <= 1,
        color.y >= 0, color.y <= 1,
        color.z >= 0, color.z <= 1 else {
    throw BorgVRSessionCommandError.invalidLightColor
  }
  return color
}
