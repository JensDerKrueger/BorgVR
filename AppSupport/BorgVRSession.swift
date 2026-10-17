import Foundation
import Combine
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

enum BorgVRMutationDomain: String, Sendable {
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

struct BorgVRVisualizationSnapshot: Equatable, Sendable {
  var transform: BorgVRTransformSnapshot
  var clipMinimum: SIMD3<Float>
  var clipMaximum: SIMD3<Float>
  var normalizedIsoValue: Float
  var isoValue: Float
  var renderMode: RenderMode
  var brickVisualization: Bool
  var transferBias: Float
  var lighting: BorgVRLightingSnapshot
  var objectsVisible: Bool
  var measurementsVisible: Bool
  var objectCount: Int
  var measurementCount: Int
  var transferFunctionRevisions: [UInt64]
}

enum BorgVRCommand: Sendable {
  case setRenderMode(RenderMode)
  case setTransform(BorgVRTransformSnapshot)
  case rotate(axis: SIMD3<Float>, degrees: Float)
  case setNormalizedIsoValue(Float)
  case setClipping(minimum: SIMD3<Float>, maximum: SIMD3<Float>)
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
  typealias SnapshotProvider = () -> BorgVRVisualizationSnapshot
  typealias AnnotationSnapshotProvider = () -> BorgVRAnnotationSnapshot
  typealias CommandObserver = (BorgVRCommandEvent) -> Void

  nonisolated(unsafe) let visualizationState: VisualizationState
  nonisolated(unsafe) let runtimeState: RuntimeState
  nonisolated(unsafe) let settingsState: SettingsState

  private let lock = NSRecursiveLock()
  private let commandHandler: CommandHandler
  nonisolated(unsafe) private let snapshotProvider: SnapshotProvider
  private let annotationSnapshotProvider: AnnotationSnapshotProvider
  nonisolated private let snapshotLock = NSLock()
  nonisolated(unsafe) private var cachedSnapshot: BorgVRVisualizationSnapshot
  private var cachedAnnotationSnapshot: BorgVRAnnotationSnapshot
  private var commandObservers: [UUID: CommandObserver] = [:]
  private var recordedEvents: [BorgVRCommandEvent] = []
  private var recordsCommands = false

  init(
    visualizationState: VisualizationState,
    runtimeState: RuntimeState,
    settingsState: SettingsState,
    commandHandler: @escaping CommandHandler,
    snapshotProvider: @escaping SnapshotProvider,
    annotationSnapshotProvider: @escaping AnnotationSnapshotProvider = { .empty }
  ) {
    self.visualizationState = visualizationState
    self.runtimeState = runtimeState
    self.settingsState = settingsState
    self.commandHandler = commandHandler
    self.snapshotProvider = snapshotProvider
    self.annotationSnapshotProvider = annotationSnapshotProvider
    self.cachedSnapshot = snapshotProvider()
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
    snapshotLock.withLock { cachedSnapshot = after }
    let commands = inferredCommands(from: before, to: after, fallback: domain)
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
    snapshotLock.withLock { cachedSnapshot = after }
    let commands = inferredCommands(from: before, to: after, fallback: domain)
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
    Task { @MainActor [weak self] in
      self?.commitExternalMutation(source: source, domain: domain)
    }
  }

  nonisolated func renderSnapshot() -> BorgVRVisualizationSnapshot {
    snapshotLock.withLock { cachedSnapshot }
  }

  func currentSnapshot() -> BorgVRVisualizationSnapshot {
    publishRenderSnapshot()
    return renderSnapshot()
  }

  func publishRenderSnapshot() {
    _ = refreshRenderSnapshot()
  }

  /// Captures the wrapped domains once for a render frame. Vision currently has both MainActor
  /// UI bindings and render-actor device input, so access is serialized by each domain's existing
  /// synchronization while this method freezes the resulting value state.
  nonisolated func refreshRenderSnapshot() -> BorgVRVisualizationSnapshot {
    let snapshot = snapshotProvider()
    snapshotLock.withLock { cachedSnapshot = snapshot }
    return snapshot
  }

  @discardableResult
  func observeCommands(_ observer: @escaping CommandObserver) -> UUID {
    lock.withLock {
      let id = UUID()
      commandObservers[id] = observer
      return id
    }
  }

  func removeCommandObserver(_ id: UUID) {
    lock.withLock { _ = commandObservers.removeValue(forKey: id) }
  }

  func startCommandRecording() {
    lock.withLock {
      recordedEvents.removeAll(keepingCapacity: true)
      recordsCommands = true
    }
  }

  func stopCommandRecording() -> [BorgVRCommandEvent] {
    lock.withLock {
      recordsCommands = false
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
         recordedEvents[lastIndex].source == source,
         command.replacesRecordedAnnotationCommand(recordedEvents[lastIndex].command) {
        recordedEvents[lastIndex] = event
      } else {
        recordedEvents.append(event)
      }
    }
    for observer in commandObservers.values {
      observer(event)
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
      commands.append(.mutation(.transferFunction))
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
  func replacesRecordedAnnotationCommand(_ previous: BorgVRCommand) -> Bool {
    switch (self, previous) {
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
    ScreenBorgVRSession(
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
        return BorgVRVisualizationSnapshot(
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
          transferBias: renderingParameters.transferFunction.textureBias,
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
      },
      annotationSnapshotProvider: {
        BorgVRAnnotationSnapshot(
          markers: appModel.volumeMarkers,
          meshInstances: appModel.sceneMeshInstances,
          measurements: appModel.volumeMeasurements
        )
      }
    )
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
