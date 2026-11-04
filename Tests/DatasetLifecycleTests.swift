import AppKit
import Foundation
import Metal
import simd
@testable import BorgVR

@main
struct DatasetLifecycleTests {
  @MainActor
  static func main() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("imported.data")
    try FileManager.default.copyItem(atPath: CommandLine.arguments[1], toPath: url.path)
    let metadata = try BORGVRMetaData(url: url)
    let model = AppModel()
    let settings = AppSettings()
    let parameters = RenderingParameters()
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device required for TF tests") }
    for tf in parameters.transferFunctions { tf.initMetal(device: device) }
    let keys = ["autoloadTF", "autoloadObjects", "autoloadMeasurements", "autoloadRenderState"]
    let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, previous) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
      }
    }
    settings.autoloadTF = true
    settings.autoloadObjects = true
    settings.autoloadMeasurements = true
    settings.autoloadRenderState = true
    let entry = AppModel.DatasetEntry(identifier: url.path, description: metadata.datasetDescription,
                                      source: .local, uniqueId: metadata.uniqueID)
    model.openDataset(entry)
    guard case .opening(_, let requestID) = model.datasetSessionState else { fatalError() }
    let key = model.activeDatasetRenderKey
    model.prepareDatasetRenderer(key: key, metadata: metadata, requestID: requestID)
    precondition(model.markRenderedDataset(key: key, requestID: requestID))
    parameters.scale = 1.7
    parameters.pan = SIMD2(0.2, -0.1)
    parameters.clipMin = SIMD3(0.1, 0, 0)
    parameters.normIsoValue = 0.42
    parameters.ambientLightColor = SIMD3(repeating: 0.3)
    try parameters.transferFunction.updateData(with: Array(repeating: SIMD4<UInt8>(200, 10, 20, 30),
      count: parameters.transferFunction.data.count))
    let savedTransferFunction = parameters.transferFunction.data
    model.volumeBrush.radius = 0.07
    let marker = VolumeMarker(id: UUID(), name: "Saved marker", position: .zero, radius: 0.01,
                              color: SIMD4(repeating: 1), directionOrigin: SIMD3(0, 0, 1))
    model.replaceVolumeMarkers([marker])
    let measurement = VolumeMeasurement(name: "Saved measurement", kind: .length,
      points: [.init(position: .zero), .init(position: SIMD3(0.2, 0, 0))],
      physicalExtent: metadata.physicalExtentMeters)
    model.replaceVolumeMeasurements([measurement])

    // Exercise the real termination delegate without closing the dataset first.
    let delegate = AppDelegate()
    delegate.saveOpenDatasetState = {
      model.saveAutomaticallyManagedDatasetState(appSettings: settings, renderingParameters: parameters)
    }
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    guard case .rendering = model.datasetSessionState else { fatalError("Saving must not close the dataset") }
    let stateURL = model.viewStateFileURL()!
    let state = try DatasetStateStorage.loadViewState(datasetID: metadata.uniqueID, from: stateURL)
    precondition(state.screenView?.scale == 1.7 && state.screenView?.pan == SIMD2(0.2, -0.1))
    precondition(state.common.normalizedIsoValue == 0.42 && state.common.clipMin.x == 0.1)
    precondition(PanelParameterStorage.datasetFileURLs(beside: stateURL).allSatisfy {
      FileManager.default.fileExists(atPath: $0.path)
    })
    precondition(FileManager.default.fileExists(atPath: model.transferFunctionFileURL()!.path))
    let objects = try DatasetStateStorage.loadObjects(datasetID: metadata.uniqueID, from: model.objectFileURL()!)
    precondition(objects.markers == [marker])
    let measurements = try DatasetStateStorage.loadMeasurements(datasetID: metadata.uniqueID,
      physicalExtent: metadata.physicalExtentMeters, from: model.measurementFileURL()!)
    precondition(measurements.map(\.id) == [measurement.id])

    let saved = try Data(contentsOf: stateURL)
    settings.autoloadTF = false
    settings.autoloadObjects = false
    settings.autoloadMeasurements = false
    settings.autoloadRenderState = false
    parameters.scale = 4
    model.replaceVolumeMarkers([])
    model.replaceVolumeMeasurements([])
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    let afterDisabledSave = try Data(contentsOf: stateURL)
    precondition(afterDisabledSave == saved, "Disabled auto-save must preserve existing files")
    precondition(FileManager.default.fileExists(atPath: model.objectFileURL()!.path))
    precondition(FileManager.default.fileExists(atPath: model.measurementFileURL()!.path))

    settings.autoloadTF = true
    settings.autoloadObjects = true
    settings.autoloadMeasurements = true
    settings.autoloadRenderState = true
    model.replaceVolumeMarkers([marker])
    model.replaceVolumeMeasurements([measurement])
    model.openDataset(entry, automaticallyLoadState: false)
    guard case .opening(_, let automatedRequest) = model.datasetSessionState else { fatalError() }
    model.prepareDatasetRenderer(key: model.activeDatasetRenderKey, metadata: metadata, requestID: automatedRequest)
    parameters.reset()
    let defaultTransferFunction = parameters.transferFunction.data
    model.loadAutomaticallyManagedTransferFunctions(appSettings: settings, metadata: metadata, renderingParameters: parameters)
    model.loadAutomaticallyManagedDatasetState(appSettings: settings, metadata: metadata, renderingParameters: parameters)
    precondition(parameters.scale == 1 && parameters.normIsoValue == 0.1)
    precondition(parameters.transferFunction.data == defaultTransferFunction)
    precondition(model.volumeMarkers.isEmpty && model.volumeMeasurements.isEmpty && model.sceneMeshInstances.isEmpty)
    precondition(settings.autoloadTF && settings.autoloadObjects && settings.autoloadMeasurements && settings.autoloadRenderState,
                 "Automated opening must not modify user preferences")
    let explicitlyRestored = try model.restoreSavedDatasetState(renderingParameters: parameters)
    precondition(explicitlyRestored && parameters.scale == 1.7 && parameters.transferFunction.data == savedTransferFunction,
                 "Explicit restore must remain available to automation")

    model.openDataset(entry)
    precondition(model.automaticallyLoadsDatasetState, "A later UI open must restore the normal policy")
    parameters.reset()
    model.loadAutomaticallyManagedTransferFunctions(appSettings: settings, metadata: metadata, renderingParameters: parameters)
    model.loadAutomaticallyManagedDatasetState(appSettings: settings, metadata: metadata, renderingParameters: parameters)
    precondition(parameters.scale == 1.7 && parameters.transferFunction.data == savedTransferFunction)
    precondition(model.volumeMarkers == [marker] && model.volumeMeasurements.map(\.id) == [measurement.id])

    let brush = model.volumeBrush
    let source = try BORGVRFileData(filename: url.path)
    _ = brush.open(source, datasetURL: url)
    try await brush.waitForStateReady()
    try await brush.duplicateState(name: "Remembered edit state", empty: true)
    let rememberedID = brush.activeState!.id
    brush.close()
    try await brush.prepareOpening(datasetID: metadata.uniqueID, datasetURL: url,
                                   interactive: false, restoreLastSelection: false)
    _ = brush.open(source, datasetURL: url)
    try await brush.waitForStateReady()
    precondition(brush.activeState == nil, "Automated opening must not restore the remembered edit state")
    precondition(brush.states.contains { $0.id == rememberedID }, "Saved edits must not be deleted")
    brush.close()
    try await brush.prepareOpening(datasetID: metadata.uniqueID, datasetURL: url, interactive: false)

    let openModel = AppModel()
    let workflow = DatasetOpenWorkflow()
    let sharePlay = SharePlayCoordinator(platformAdapter: MacSharePlayPlatformAdapter(
      storedAppModel: StoredAppModel(), serverController: BackgroundServerController()))
    let storage = DatasetStorageAccess(directoryURL: directory)
    workflow.startOpeningImportedDataset(at: directory.appendingPathComponent("missing.data"),
      appModel: openModel, appSettings: settings, sharePlay: sharePlay, storage: storage)
    precondition(workflow.openErrorMessage != nil && openModel.activeDataset == nil)
    workflow.openErrorMessage = nil
    workflow.startOpeningImportedDataset(at: url, appModel: openModel,
      appSettings: settings, sharePlay: sharePlay, storage: storage)
    var showedEditSelection = false
    for _ in 0..<100 {
      if let request = openModel.volumeBrush.openingRequest {
        showedEditSelection = true
        openModel.volumeBrush.completeOpeningSelection(id: request.id, stateID: nil)
      }
      if openModel.activeDataset != nil || workflow.openErrorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    precondition(workflow.openErrorMessage == nil)
    precondition(openModel.activeDataset?.identifier == url.path)
    precondition(openModel.activeDataset?.uniqueId == metadata.uniqueID)
    precondition(showedEditSelection, "Interactive opening must retain the edit-selection dialog")
    print("Termination auto-save, direct import opening and deterministic automation (TF/state/objects/measurements/edits) passed")
  }
}
