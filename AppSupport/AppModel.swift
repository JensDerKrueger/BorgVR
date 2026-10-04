import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  typealias RenderScreenshotHandler = (
    _ url: URL?,
    _ accessURL: URL?,
    _ completion: @escaping (Result<URL, Error>) -> Void
  ) -> Void
  typealias RenderDisplaySyncHandler = (_ enabled: Bool) -> Void
  typealias MarkerPositionHandler = (
    _ normalizedScreenPosition: SIMD2<Float>,
    _ positionToPreserveDepth: SIMD3<Float>?
  ) -> SIMD3<Float>?
  typealias MarkerHitTestHandler = (_ normalizedScreenPosition: SIMD2<Float>) -> UUID?
  typealias SceneObjectHitTestHandler = (_ normalizedScreenPosition: SIMD2<Float>) -> UUID?
  typealias MarkerDirectionOriginHandler = (
    _ normalizedScreenPosition: SIMD2<Float>
  ) -> SIMD3<Float>?
  typealias MarkerDepthAdjustmentHandler = (
    _ position: SIMD3<Float>,
    _ worldDistance: Float
  ) -> SIMD3<Float>?

  struct MeasurementPointHit: Equatable {
    let measurementID: UUID
    let pointID: UUID
  }

  struct MeasurementScreenLabel: Identifiable, Equatable {
    let id: UUID
    let text: String
    let position: SIMD2<Float>
    let color: SIMD4<Float>
  }

  typealias MeasurementHitTestHandler = (
    _ normalizedScreenPosition: SIMD2<Float>
  ) -> MeasurementPointHit?

  enum NavigationState {
    case start
    case settings
    case importData
    case selectData
  }

  enum InteractionMode: String, CaseIterable, Identifiable {
    case model
    case clipping
    case transferEditing
    case drawing
    case objectPlacement
    case measurement

    var id: String { rawValue }
  }

  enum DatasetSource: Equatable {
    case local
    case remote(address: String, port: Int, password: String)
    case builtIn
  }

  struct DatasetEntry: Equatable, Identifiable {
    let identifier: String
    let description: String
    let source: DatasetSource
    let uniqueId: String
    let metadataSummary: String?

    var id: String { uniqueId }

    init(
      identifier: String,
      description: String,
      source: DatasetSource,
      uniqueId: String,
      metadataSummary: String? = nil
    ) {
      self.identifier = identifier
      self.description = description
      self.source = source
      self.uniqueId = uniqueId
      self.metadataSummary = metadataSummary
    }
  }

  enum DatasetCloseDestination: Equatable {
    case start
    case datasetSelection
    case sharePlayWaiting(SharePlayWaitingReason)
  }

  enum DatasetSessionState: Equatable {
    case inactive
    case waitingForSharePlay(SharePlayWaitingReason)
    case resolving(uniqueID: String, description: String)
    case opening(dataset: DatasetEntry, requestID: UUID)
    case rendering(dataset: DatasetEntry, requestID: UUID)
    case closing(dataset: DatasetEntry?, requestID: UUID, destination: DatasetCloseDestination)

    var logDescription: String {
      switch self {
        case .inactive:
          return "inactive"
        case .waitingForSharePlay(let reason):
          return "waiting(\(reason))"
        case .resolving(let uniqueID, _):
          return "resolving(\(uniqueID))"
        case .opening(let dataset, _):
          return "opening(\(dataset.uniqueId))"
        case .rendering(let dataset, _):
          return "rendering(\(dataset.uniqueId))"
        case .closing(let dataset, _, let destination):
          return "closing(\(dataset?.uniqueId ?? "none"), \(destination))"
      }
    }
  }

  @Published var navigationState: NavigationState = .start
  @Published private(set) var datasetSessionState = DatasetSessionState.inactive {
    didSet {
      guard oldValue != datasetSessionState else { return }
      logger.dev(
        "Dataset session: \(oldValue.logDescription) -> \(datasetSessionState.logDescription)"
      )
    }
  }
  @Published private(set) var activeDatasetMetadata: BORGVRMetaData?
  @Published var sharePlayDatasetSource: DatasetOrigin?
  @Published var groupSessionHost = true
  @Published var interactionMode: InteractionMode = .model
  @Published var volumeMarkers: [VolumeMarker] = []
  @Published var sceneMeshAssets: [UUID: SceneMeshAsset] = [:]
  @Published var sceneMeshInstances: [SceneMeshInstance] = []
  @Published var selectedSceneMeshInstanceID: UUID?
  @Published var selectedSceneObjectPrototype: SceneObjectPrototype = .sphere
  @Published var selectedVolumeMarkerIDs: Set<UUID> = []
  @Published var selectedVolumeMarkerID: UUID? {
    didSet {
      guard let selectedVolumeMarkerID else {
        selectedVolumeMarkerIDs.removeAll()
        return
      }
      if !selectedVolumeMarkerIDs.contains(selectedVolumeMarkerID) {
        selectedVolumeMarkerIDs = [selectedVolumeMarkerID]
      }
    }
  }
  @Published var volumeMeasurements: [VolumeMeasurement] = []
  @Published var measurementKind: VolumeMeasurementKind = .length
  @Published var selectedVolumeMeasurementID: UUID?
  @Published var selectedVolumeMeasurementPointID: UUID?
  @Published var projectObjectsOntoVolume: Bool = {
    UserDefaults.standard.object(forKey: "projectObjectsOntoVolume") as? Bool ?? true
  }() {
    didSet {
      UserDefaults.standard.set(projectObjectsOntoVolume, forKey: "projectObjectsOntoVolume")
    }
  }
  @Published var projectMeasurementsOntoVolume: Bool = {
    UserDefaults.standard.object(forKey: "projectMeasurementsOntoVolume") as? Bool ?? true
  }() {
    didSet {
      UserDefaults.standard.set(
        projectMeasurementsOntoVolume,
        forKey: "projectMeasurementsOntoVolume"
      )
    }
  }
  @Published private(set) var measurementScreenLabels: [MeasurementScreenLabel] = []
  @Published private(set) var remoteSpatialToolPreviews: [UUID: [SpatialToolPreview]] = [:]
  /// Radius used for sphere markers created locally during this app session.
  var defaultVolumeMarkerRadius = VolumeMarkerRadius.sphereDefault
  /// Direction visibility used for sphere markers created later in this app session.
  var defaultVolumeMarkerShowsDirection = false
  @Published var timer: CPUFrameTimer?
  @Published var performanceModel = PerformanceGraphModel()
  let logger = GUILogger()
  var renderScreenshotHandler: RenderScreenshotHandler?
  var renderDisplaySyncHandler: RenderDisplaySyncHandler?
  var markerPositionHandler: MarkerPositionHandler?
  var projectedVolumePositionHandler: MarkerPositionHandler?
  var beginProjectedStrokeHandler: (() -> Void)?
  var endProjectedStrokeHandler: (() -> Void)?
  var markerHitTestHandler: MarkerHitTestHandler?
  var sceneObjectHitTestHandler: SceneObjectHitTestHandler?
  var markerDirectionOriginHandler: MarkerDirectionOriginHandler?
  var markerDepthAdjustmentHandler: MarkerDepthAdjustmentHandler?
  var measurementHitTestHandler: MeasurementHitTestHandler?
  let defaultVolumeMarkerColor = SIMD4<Float>(
    Float.random(in: 0.2...1),
    Float.random(in: 0.2...1),
    Float.random(in: 0.2...1),
    1
  )
  private(set) var renderDisplaySyncEnabled = true
  private(set) var brickReadbackCount: UInt64 = 0
  private(set) var lastMissingBrickCount: Int = 0
  private(set) var consecutiveEmptyBrickReadbacks: UInt64 = 0
  private(set) var renderedDatasetKey = ""
  private(set) var failedRenderedDatasetKey = ""
  private(set) var completedRenderFrameCount: UInt64 = 0
  private(set) var lastCompletedFrameDatasetKey = ""

  init() {
    logger.setMinimumLogLevel(.warning)
    refreshSceneMeshCatalog()
  }

  var activeDataset: DatasetEntry? {
    switch datasetSessionState {
      case .opening(let dataset, _), .rendering(let dataset, _), .closing(let dataset?, _, _):
        return dataset
      case .inactive, .waitingForSharePlay, .resolving, .closing(nil, _, _):
        return nil
    }
  }

  var sharePlayWaitingReason: SharePlayWaitingReason? {
    switch datasetSessionState {
      case .waitingForSharePlay(let reason):
        return reason
      case .resolving:
        return .datasetSource
      case .closing(_, _, .sharePlayWaiting(let reason)):
        return reason
      default:
        return nil
    }
  }

  func isOpeningOrRenderingDataset(withUniqueID uniqueID: String) -> Bool {
    switch datasetSessionState {
      case .opening(let dataset, _), .rendering(let dataset, _):
        return dataset.uniqueId == uniqueID
      case .closing(let dataset?, _, _):
        return dataset.uniqueId == uniqueID
      default:
        return false
    }
  }

  func openDataset(_ dataset: DatasetEntry, asGroupSessionHost: Bool? = nil) {
    if let asGroupSessionHost {
      groupSessionHost = asGroupSessionHost
    }
    sharePlayDatasetSource = nil
    resetRenderedDatasetState()
    datasetSessionState = .opening(dataset: dataset, requestID: UUID())
  }

  func waitForSharePlayDataset(reason: SharePlayWaitingReason) {
    sharePlayDatasetSource = nil
    resetRenderedDatasetState()
    datasetSessionState = .waitingForSharePlay(reason)
  }

  func beginResolvingSharePlayDataset(uniqueID: String, description: String) {
    if case .resolving(let currentID, _) = datasetSessionState,
       currentID == uniqueID {
      return
    }
    resetRenderedDatasetState()
    datasetSessionState = .resolving(uniqueID: uniqueID, description: description)
  }

  func closeDataset(destination: DatasetCloseDestination = .datasetSelection) {
    let requestID = UUID()
    datasetSessionState = .closing(
      dataset: activeDataset,
      requestID: requestID,
      destination: destination
    )
    sharePlayDatasetSource = nil
    resetRenderedDatasetState()
    switch destination {
      case .start:
        datasetSessionState = .inactive
        navigationState = .start
      case .datasetSelection:
        datasetSessionState = .inactive
        navigationState = .selectData
      case .sharePlayWaiting(let reason):
        datasetSessionState = .waitingForSharePlay(reason)
    }
  }

  func setLogLevel(_ setting: String) {
    let logLevel = AppLogLevel(rawValue: setting) ?? .warning
    logger.setMinimumLogLevel(logLevel.level)
  }

  func nextVolumeMarkerName(for kind: VolumeMarkerKind = .sphere) -> String {
    let baseName = switch kind {
      case .sphere: String(localized: "Marker")
      case .stroke: String(localized: "Stroke")
    }
    let usedNames = Set(volumeMarkers.map(\.name))
    var markerIndex = volumeMarkers.count(where: { $0.kind == kind }) + 1
    while usedNames.contains("\(baseName) \(markerIndex)") {
      markerIndex += 1
    }
    return "\(baseName) \(markerIndex)"
  }

  func replaceVolumeMarkers(_ markers: [VolumeMarker]) {
    volumeMarkers = markers
    setVolumeMarkerSelection(selectedVolumeMarkerIDs, primary: selectedVolumeMarkerID)
  }

  func registerSceneMeshAsset(_ asset: SceneMeshAsset, persist: Bool = true) throws {
    sceneMeshAssets[asset.id] = asset
    if persist {
      try SceneMeshAssetCatalog.store(asset, logger: logger)
    }
  }

  func refreshSceneMeshCatalog() {
    let documentsURLs = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )
    for asset in SceneMeshAssetCatalog.allAssets(
      additionalDirectoryURLs: documentsURLs,
      logger: logger
    ) {
      sceneMeshAssets[asset.id] = asset
    }
    validateSelectedSceneObjectPrototype()
  }

  @discardableResult
  func validateSelectedSceneObjectPrototype() -> SceneObjectPrototype {
    guard case .mesh(let assetID) = selectedSceneObjectPrototype else {
      return selectedSceneObjectPrototype
    }
    if sceneMeshAssets[assetID] == nil,
       let asset = SceneMeshAssetCatalog.load(assetID: assetID, logger: logger) {
      sceneMeshAssets[assetID] = asset
    }
    guard sceneMeshAssets[assetID] != nil else {
      selectedSceneObjectPrototype = .sphere
      return .sphere
    }
    return selectedSceneObjectPrototype
  }

  @discardableResult
  func addSceneMeshInstance(for asset: SceneMeshAsset) throws -> SceneMeshInstance {
    try registerSceneMeshAsset(asset)
    let instance = SceneMeshInstance(
      name: nextSceneMeshInstanceName(assetName: asset.name),
      asset: asset.reference
    )
    sceneMeshInstances.append(instance)
    selectedSceneMeshInstanceID = instance.id
    return instance
  }

  func replaceSceneMeshInstances(_ instances: [SceneMeshInstance]) {
    sceneMeshInstances = instances
    resolveSceneMeshAssets(for: instances)
    if let selectedSceneMeshInstanceID,
       !instances.contains(where: { $0.id == selectedSceneMeshInstanceID }) {
      self.selectedSceneMeshInstanceID = nil
    }
  }

  func resolveSceneMeshAssets(for instances: [SceneMeshInstance]? = nil) {
    let instances = instances ?? sceneMeshInstances
    for assetID in Set(instances.map(\.asset.assetID)) where sceneMeshAssets[assetID] == nil {
      if let asset = SceneMeshAssetCatalog.load(assetID: assetID, logger: logger) {
        sceneMeshAssets[assetID] = asset
      }
    }
  }

  @discardableResult
  func removeSceneMeshInstance(id: UUID) -> Bool {
    let previousCount = sceneMeshInstances.count
    sceneMeshInstances.removeAll { $0.id == id }
    guard sceneMeshInstances.count != previousCount else { return false }
    if selectedSceneMeshInstanceID == id { selectedSceneMeshInstanceID = nil }
    return true
  }

  func nextSceneMeshInstanceName(assetName: String) -> String {
    let usedNames = Set(sceneMeshInstances.map(\.name))
    if !usedNames.contains(assetName) { return assetName }
    var index = 2
    while usedNames.contains("\(assetName) \(index)") { index += 1 }
    return "\(assetName) \(index)"
  }

  func setVolumeMarkerSelection(_ ids: Set<UUID>, primary: UUID? = nil) {
    let availableIDs = Set(volumeMarkers.map(\.id))
    let validIDs = ids.intersection(availableIDs)
    selectedVolumeMarkerIDs = validIDs
    selectedVolumeMarkerID = primary.flatMap { validIDs.contains($0) ? $0 : nil }
      ?? selectedVolumeMarkerID.flatMap { validIDs.contains($0) ? $0 : nil }
      ?? volumeMarkers.first(where: { validIDs.contains($0.id) })?.id
  }

  func clearVolumeMarkerSelection() {
    selectedVolumeMarkerID = nil
  }

  @discardableResult
  func removeVolumeMarkers(withIDs markerIDs: Set<UUID>) -> Bool {
    guard !markerIDs.isEmpty else { return false }
    let previousCount = volumeMarkers.count
    volumeMarkers.removeAll { markerIDs.contains($0.id) }
    guard volumeMarkers.count != previousCount else { return false }
    setVolumeMarkerSelection(
      selectedVolumeMarkerIDs.subtracting(markerIDs),
      primary: selectedVolumeMarkerID
    )
    return true
  }

  @discardableResult
  func removeLastVolumeMarker() -> Bool {
    guard let markerID = volumeMarkers.last?.id else { return false }
    return removeVolumeMarkers(withIDs: [markerID])
  }

  @discardableResult
  func removeLastSceneObject() -> Bool {
    if let selectedSceneMeshInstanceID,
       removeSceneMeshInstance(id: selectedSceneMeshInstanceID) {
      return true
    }
    if let selectedVolumeMarkerID,
       removeVolumeMarkers(withIDs: [selectedVolumeMarkerID]) {
      return true
    }
    if removeLastVolumeMarker() { return true }
    guard let instanceID = sceneMeshInstances.last?.id else { return false }
    return removeSceneMeshInstance(id: instanceID)
  }

  @discardableResult
  func removeAllVolumeMarkers() -> Bool {
    guard !volumeMarkers.isEmpty else { return false }
    volumeMarkers.removeAll()
    clearVolumeMarkerSelection()
    return true
  }

  func nextVolumeMeasurementName() -> String {
    let prefix: String
    switch measurementKind {
      case .length: prefix = String(localized: "measurement_kind_length")
      case .area: prefix = String(localized: "measurement_kind_area")
      case .volume: prefix = String(localized: "measurement_kind_volume")
    }
    let count = volumeMeasurements.filter { $0.kind == measurementKind }.count
    return "\(prefix) \(count + 1)"
  }

  @discardableResult
  func createVolumeMeasurement() -> UUID {
    removeEmptyVolumeMeasurements()
    let measurement = VolumeMeasurement(
      name: nextVolumeMeasurementName(),
      kind: measurementKind,
      physicalExtent: activeDatasetMetadata?.physicalExtentMeters
    )
    volumeMeasurements.append(measurement)
    selectedVolumeMeasurementID = measurement.id
    selectedVolumeMeasurementPointID = nil
    return measurement.id
  }

  func replaceVolumeMeasurements(_ measurements: [VolumeMeasurement]) {
    let extent = activeDatasetMetadata?.physicalExtentMeters
    volumeMeasurements = measurements.map { measurement in
      var measurement = measurement
      if let extent { measurement.updatePhysicalExtent(extent) }
      return measurement
    }
    let available = Set(volumeMeasurements.map(\.id))
    if let selectedVolumeMeasurementID,
       !available.contains(selectedVolumeMeasurementID) {
      clearVolumeMeasurementSelection()
    }
  }

  func mutateVolumeMeasurements<Result>(
    _ mutation: (inout [VolumeMeasurement]) -> Result
  ) -> Result {
    mutation(&volumeMeasurements)
  }

  @discardableResult
  func removeVolumeMeasurementPoint(measurementID: UUID, pointID: UUID) -> Bool {
    guard let index = volumeMeasurements.firstIndex(where: { $0.id == measurementID }),
          volumeMeasurements[index].removePoint(id: pointID) else { return false }
    if volumeMeasurements[index].points.isEmpty {
      volumeMeasurements.remove(at: index)
      if selectedVolumeMeasurementID == measurementID {
        selectedVolumeMeasurementID = volumeMeasurements.last?.id
      }
    }
    if selectedVolumeMeasurementPointID == pointID {
      selectedVolumeMeasurementPointID = nil
    }
    return true
  }

  @discardableResult
  func removeSelectedVolumeMeasurementPoint() -> Bool {
    guard let measurementID = selectedVolumeMeasurementID,
          let pointID = selectedVolumeMeasurementPointID else { return false }
    return removeVolumeMeasurementPoint(measurementID: measurementID, pointID: pointID)
  }

  @discardableResult
  func removeLastVolumeMeasurementPoint() -> Bool {
    let index = selectedVolumeMeasurementID.flatMap { selectedID in
      volumeMeasurements.firstIndex { $0.id == selectedID }
    } ?? volumeMeasurements.indices.last
    guard let index, let pointID = volumeMeasurements[index].points.last?.id else {
      return false
    }
    return removeVolumeMeasurementPoint(
      measurementID: volumeMeasurements[index].id,
      pointID: pointID
    )
  }

  @discardableResult
  func removeEmptyVolumeMeasurements() -> Bool {
    let oldCount = volumeMeasurements.count
    volumeMeasurements.removeAll { $0.points.isEmpty }
    guard volumeMeasurements.count != oldCount else { return false }
    if let selectedVolumeMeasurementID,
       !volumeMeasurements.contains(where: { $0.id == selectedVolumeMeasurementID }) {
      self.selectedVolumeMeasurementID = volumeMeasurements.last?.id
      selectedVolumeMeasurementPointID = nil
    }
    return true
  }

  @discardableResult
  func removeSelectedVolumeMeasurement() -> Bool {
    guard let selectedVolumeMeasurementID else { return false }
    let oldCount = volumeMeasurements.count
    volumeMeasurements.removeAll { $0.id == selectedVolumeMeasurementID }
    guard volumeMeasurements.count != oldCount else { return false }
    self.selectedVolumeMeasurementID = volumeMeasurements.last?.id
    selectedVolumeMeasurementPointID = nil
    return true
  }

  @discardableResult
  func removeAllVolumeMeasurements() -> Bool {
    guard !volumeMeasurements.isEmpty else { return false }
    volumeMeasurements.removeAll()
    clearVolumeMeasurementSelection()
    return true
  }

  func renameVolumeMeasurement(id: UUID, to name: String) {
    guard let index = volumeMeasurements.firstIndex(where: { $0.id == id }) else { return }
    volumeMeasurements[index].name = name
  }

  func clearVolumeMeasurementSelection() {
    selectedVolumeMeasurementID = nil
    selectedVolumeMeasurementPointID = nil
  }

  func updateMeasurementScreenLabels(_ labels: [MeasurementScreenLabel]) {
    if measurementScreenLabels != labels {
      measurementScreenLabels = labels
    }
  }

  func updateRemoteSpatialToolPreviews(
    _ previews: [SpatialToolPreview],
    participantID: UUID
  ) {
    remoteSpatialToolPreviews[participantID] = previews
  }

  func activeRemoteSpatialToolPreviews() -> [SpatialToolPreview] {
    remoteSpatialToolPreviews.values.flatMap { $0.filter(\.isActive) }
  }

  func clearRemoteSpatialToolPreviews() {
    remoteSpatialToolPreviews.removeAll()
  }

  func requestRenderScreenshot(
    to url: URL?,
    accessURL: URL?,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard let renderScreenshotHandler else {
      completion(.failure(AppModelError.rendererUnavailable))
      return
    }
    renderScreenshotHandler(url, accessURL, completion)
  }

  func setRenderDisplaySyncEnabled(_ enabled: Bool) {
    renderDisplaySyncEnabled = enabled
    renderDisplaySyncHandler?(enabled)
  }

  func transferFunctionFileURL(for dataset: DatasetEntry? = nil) -> URL? {
    guard let dataset = dataset ?? activeDataset else { return nil }

    switch dataset.source {
      case .local:
        let datasetURL: URL
        if dataset.identifier.hasPrefix("/") {
          datasetURL = URL(fileURLWithPath: dataset.identifier)
        } else if let documentsURL = documentsDirectoryURL() {
          datasetURL = documentsURL.appendingPathComponent(dataset.identifier)
        } else {
          return nil
        }
        let localURL = datasetURL.deletingPathExtension().appendingPathExtension("tf1d")
        movePersistentTransferFunctionIfNeeded(for: dataset, to: localURL)
        return localURL

      case .builtIn:
        return persistentTransferFunctionFileURL(for: dataset)

      case .remote:
        return persistentTransferFunctionFileURL(for: dataset)
    }
  }

  func datasetRenderKey(for dataset: DatasetEntry?) -> String {
    guard let dataset else { return "" }
    let sourceKey: String
    switch dataset.source {
      case .local:
        sourceKey = "local"
      case .builtIn:
        sourceKey = "builtIn"
      case let .remote(address, port, _):
        sourceKey = "remote:\(address):\(port)"
    }
    return "\(sourceKey)-\(dataset.identifier)"
  }

  var activeDatasetRenderKey: String {
    datasetRenderKey(for: activeDataset)
  }

  var rendererHasActiveDataset: Bool {
    !activeDatasetRenderKey.isEmpty && renderedDatasetKey == activeDatasetRenderKey
  }

  var rendererFailedActiveDataset: Bool {
    !activeDatasetRenderKey.isEmpty && failedRenderedDatasetKey == activeDatasetRenderKey
  }

  func markRenderedDataset(key: String, metadata: BORGVRMetaData? = nil) {
    renderedDatasetKey = key
    failedRenderedDatasetKey = ""
    guard !key.isEmpty else {
      activeDatasetMetadata = nil
      return
    }
    guard case .opening(let dataset, let requestID) = datasetSessionState,
          datasetRenderKey(for: dataset) == key else { return }
    activeDatasetMetadata = metadata
    datasetSessionState = .rendering(dataset: dataset, requestID: requestID)
  }

  func markRenderedDatasetFailed(key: String) {
    renderedDatasetKey = ""
    failedRenderedDatasetKey = key
    activeDatasetMetadata = nil
  }

  private func resetRenderedDatasetState() {
    renderedDatasetKey = ""
    failedRenderedDatasetKey = ""
    activeDatasetMetadata = nil
    resetBrickReadbackState()
  }

  func resetBrickReadbackState() {
    brickReadbackCount = 0
    lastMissingBrickCount = 0
    consecutiveEmptyBrickReadbacks = 0
    completedRenderFrameCount = 0
    lastCompletedFrameDatasetKey = ""
  }

  func recordCompletedRenderFrame(datasetKey: String, missingBrickCount: Int) {
    completedRenderFrameCount += 1
    lastCompletedFrameDatasetKey = datasetKey
    brickReadbackCount += 1
    lastMissingBrickCount = missingBrickCount
    if missingBrickCount == 0 {
      consecutiveEmptyBrickReadbacks += 1
    } else {
      consecutiveEmptyBrickReadbacks = 0
    }
  }

  private func transferFunctionDirectoryURL() -> URL? {
    TransferFunctionCatalog.storageDirectoryURL(logger: logger)
  }

  private func persistentTransferFunctionFileURL(for dataset: DatasetEntry) -> URL? {
    guard let directoryURL = transferFunctionDirectoryURL() else { return nil }
    let fallbackName = URL(fileURLWithPath: dataset.identifier).deletingPathExtension().lastPathComponent
    let stem = sanitizedTransferFunctionFilename(dataset.uniqueId.isEmpty ? fallbackName : dataset.uniqueId)
    return directoryURL.appendingPathComponent(stem).appendingPathExtension("tf1d")
  }

  private func movePersistentTransferFunctionIfNeeded(for dataset: DatasetEntry, to localURL: URL) {
    guard let persistentURL = persistentTransferFunctionFileURL(for: dataset),
          persistentURL != localURL else {
      return
    }

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: persistentURL.path),
          !fileManager.fileExists(atPath: localURL.path) else {
      return
    }

    do {
      try fileManager.moveItem(at: persistentURL, to: localURL)
      logger.info("Transfer function migrated to \(localURL.lastPathComponent)")
    } catch {
      logger.warning("Transfer function migration failed: \(error.localizedDescription)")
    }
  }

  private func documentsDirectoryURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  }

  private func sanitizedTransferFunctionFilename(_ filename: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitizedScalars = filename.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(sanitizedScalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return sanitized.isEmpty ? "transfer-function" : sanitized
  }
}

enum AppModelError: LocalizedError {
  case rendererUnavailable

  var errorDescription: String? {
    switch self {
      case .rendererUnavailable:
        return String(localized: "Renderer is not available.")
    }
  }
}
