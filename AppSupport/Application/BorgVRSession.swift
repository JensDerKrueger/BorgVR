import Foundation
import Combine
import Observation
import simd

enum BorgVRCommandSource: Equatable, Sendable {
  case userInterface
  case hand
  case muse
  case controller(String)
  case mouse
  case touch
  case gsc
  case mcp
  case sharePlay
  case stateRestore
}

enum BorgVRStateResetScope: String, Sendable {
  case all
  case transform
  case clipping
  case transferFunction
  case lighting
}

enum BorgVRMutationDomain: String, Hashable, Sendable {
  case visualization
  case transferFunction
  case objects
  case measurements
  case interaction
}

struct BorgVRTransformSnapshot: Equatable, Sendable {
  var rotation: SIMD4<Float>
  var translation: SIMD3<Float>
  var scale: SIMD3<Float>
}

struct BorgVRLightingSnapshot: Equatable, Sendable {
  var direction: SIMD3<Float>
  var ambient: SIMD3<Float>
  var diffuse: SIMD3<Float>
  var specular: SIMD3<Float>
}

struct BorgVRTransferFunctionSnapshot: Equatable, Sendable {
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
  let transferFunctionDisplayMode: Int
  let purgeAtlas: Bool
  let rotationCaptureRequestID: UInt64

  static let `default` = BorgVRRenderSettingsSnapshot(
    sampleJitter: false,
    alphaEpsilon: 0,
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

enum BorgVRCommand: Sendable {
  case setRenderMode(RenderMode)
  case setTransform(BorgVRTransformSnapshot)
  case rotate(axis: SIMD3<Float>, degrees: Float)
  case setNormalizedIsoValue(Float)
  case setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>)
  case setTransferFunction(BorgVRTransferFunctionSnapshot)
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
  /// A semantic boundary for state that does not yet have a lossless GSC representation.
  case mutation(BorgVRMutationDomain)
}

struct BorgVRCommandEvent: Sendable {
  let command: BorgVRCommand
  let source: BorgVRCommandSource
  let timestamp: Date

  var gscStatement: String? {
    switch command {
      case .setRenderMode(let mode):
        return "rendermode \(mode.gscName)"
      case .setTransform(let transform):
        let r = transform.rotation
        let t = transform.translation
        let s = transform.scale
        return [
          "setrotationquaternion \(r.x) \(r.y) \(r.z) \(r.w)",
          "settranslation \(t.x) \(t.y)",
          "setscale \((s.x + s.y + s.z) / 3)"
        ].joined(separator: "\n")
      case .rotate(let axis, let degrees):
        if axis == SIMD3<Float>(1, 0, 0) { return "addrotationx \(degrees)" }
        if axis == SIMD3<Float>(0, 1, 0) { return "addrotationy \(degrees)" }
        if axis == SIMD3<Float>(0, 0, 1) { return "addrotationz \(degrees)" }
        return nil
      case .setNormalizedIsoValue(let value):
        return "isovalueNormalized \(value)"
      case .setClipping(let minimum, let maximum):
        return "clip \(minimum.x) \(maximum.x) \(minimum.y) \(maximum.y) \(minimum.z) \(maximum.z)"
      case .setTransferFunction(let transferFunction):
        return "settransferfunction \(transferFunction.channel) \(gscQuote(transferFunction.base64EncodedSamples))"
      case .setLighting(let direction, let ambient, let diffuse, let specular):
        var statements: [String] = []
        if let direction {
          statements.append("setlightdirection \(direction.x) \(direction.y) \(direction.z)")
        }
        if let ambient {
          statements.append("setambientlight \(ambient.x) \(ambient.y) \(ambient.z)")
        }
        if let diffuse {
          statements.append("setdiffuselight \(diffuse.x) \(diffuse.y) \(diffuse.z)")
        }
        if let specular {
          statements.append("setspecularlight \(specular.x) \(specular.y) \(specular.z)")
        }
        return statements.isEmpty ? nil : statements.joined(separator: "\n")
      case .setAnnotationVisibility(let objects, let measurements):
        var statements: [String] = []
        if let objects { statements.append("hideobjects \(objects ? "false" : "true")") }
        if let measurements {
          statements.append("hidemeasurements \(measurements ? "false" : "true")")
        }
        return statements.isEmpty ? nil : statements.joined(separator: "\n")
      case .upsertObject(let object):
        return object.gscStatement
      case .removeObject(let id):
        return "removeobject \(gscQuote(id.uuidString))"
      case .clearObjects:
        return "clearobjects"
      case .upsertMeasurement(let measurement):
        return measurement.gscStatement
      case .removeMeasurement(let id):
        return "removemeasurement \(gscQuote(id.uuidString))"
      case .clearMeasurements:
        return "clearmeasurements"
      case .reset(let scope):
        return switch scope {
          case .all: "reset"
          case .transform: "resetrotation"
          case .clipping: "resetclip"
          case .transferFunction: "resettf"
          case .lighting: "resetlighting"
        }
      case .mutation:
        return nil
    }
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
final class BorgVRSession<VisualizationState: AnyObject, RuntimeState: AnyObject, SettingsState: AnyObject>: ObservableObject, @unchecked Sendable {
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
  private var recordsCommands = false
  @Published private(set) var isCommandRecording = false

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
    self.renderSnapshotStore = BorgVRRenderSnapshotStore(snapshotProvider())
    self.cachedAnnotationSnapshot = annotationSnapshotProvider()
  }

  func perform(_ command: BorgVRCommand, source: BorgVRCommandSource) throws {
    lock.lock()
    defer { lock.unlock() }
    try commandHandler(command, source)
    publishRenderSnapshot()
    refreshAnnotationSnapshot(for: command)
    emit(command, source: source)
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
    let before = renderSnapshot()
    let annotationsBefore = cachedAnnotationSnapshot
    let result = try mutation()
    let after = snapshotProvider()
    renderSnapshotStore.publish(after)
    let commands = inferredCommands(from: before, to: after.visualization, fallback: domain)
    let annotationCommands = inferredAnnotationCommands(
      from: annotationsBefore,
      to: refreshAnnotationSnapshot(for: domain),
      domain: domain
    )
    for command in commands + annotationCommands {
      emit(command, source: source)
    }
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
    let before = renderSnapshot()
    let annotationsBefore = cachedAnnotationSnapshot
    let after = snapshotProvider()
    renderSnapshotStore.publish(after)
    let commands = inferredCommands(from: before, to: after.visualization, fallback: domain)
    let annotationCommands = inferredAnnotationCommands(
      from: annotationsBefore,
      to: refreshAnnotationSnapshot(for: domain),
      domain: domain
    )
    for command in commands + annotationCommands {
      emit(command, source: source)
    }
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
    let before = renderSnapshot()
    let annotationsBefore = cachedAnnotationSnapshot
    let after = snapshotProvider()
    renderSnapshotStore.publish(after)

    let fallback = pending.domains.sorted { $0.rawValue < $1.rawValue }.first ?? .interaction
    var commands = inferredCommands(
      from: before,
      to: after.visualization,
      fallback: fallback
    )
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
  }

  nonisolated func renderSnapshot() -> BorgVRVisualizationSnapshot {
    renderSnapshotStore.load().visualization
  }

  nonisolated func frameSnapshot() -> BorgVRFrameSnapshot {
    renderSnapshotStore.load()
  }

  func currentSnapshot() -> BorgVRVisualizationSnapshot {
    publishRenderSnapshot()
    return renderSnapshot()
  }

  func publishRenderSnapshot() {
    renderSnapshotStore.publish(snapshotProvider())
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
  }

  func startCommandRecording() {
    lock.withLock {
      recordedEvents.removeAll(keepingCapacity: true)
      recordsCommands = true
      isCommandRecording = true
    }
  }

  func stopCommandRecording() -> [BorgVRCommandEvent] {
    lock.withLock {
      recordsCommands = false
      isCommandRecording = false
      return recordedEvents
    }
  }

  func recordedGSCScript() -> String {
    lock.withLock {
      recordedEvents.compactMap(\.gscStatement).joined(separator: "\n")
    }
  }

  private func emit(_ command: BorgVRCommand, source: BorgVRCommandSource) {
    let event = BorgVRCommandEvent(command: command, source: source, timestamp: Date())
    if recordsCommands, source != .sharePlay {
      if let lastIndex = recordedEvents.indices.last,
         command.replacesRecordedCommand(recordedEvents[lastIndex].command) {
        recordedEvents[lastIndex] = event
      } else {
        recordedEvents.append(event)
      }
    }
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
    if commands.isEmpty, domain != .objects, domain != .measurements {
      commands.append(.mutation(domain))
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
          case .setTransform(let transform):
            guard simd_length_squared(transform.rotation) > 0.000_001 else {
              throw BorgVRSessionCommandError.invalidRotation
            }
            guard transform.scale.x > 0,
                  transform.scale.y > 0,
                  transform.scale.z > 0 else {
              throw BorgVRSessionCommandError.invalidScale
            }
            renderingParameters.orientation = simd_normalize(
              simd_quatf(vector: transform.rotation)
            )
            renderingParameters.pan = SIMD2<Float>(
              transform.translation.x,
              transform.translation.y
            )
            renderingParameters.scale = (
              transform.scale.x + transform.scale.y + transform.scale.z
            ) / 3
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
            transferFunctionDisplayMode: 0,
            purgeAtlas: false,
            rotationCaptureRequestID: 0
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
