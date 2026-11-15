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
    try rendererStartupSnapshots(device: device)
    fusionWizardNavigation()
    directoryImportWizardNavigation()
    try await supportingFileExplanationPreference()
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

  @MainActor
  private static func rendererStartupSnapshots(device: MTLDevice) throws {
    let parameters = RenderingParameters()
    parameters.updateRanges(minValue: 0, maxValue: 255, rangeMax: 255, componentCount: 4)
    let session = ScreenBorgVRSession.screen(appModel: AppModel(),
      renderingParameters: parameters, appSettings: AppSettings())
    precondition(session.frameSnapshot().transferFunctions.count == 4)

    // Dataset loading updates the model in one MainActor turn; observation has not
    // published those changes yet when the render worker is submitted.
    parameters.updateRanges(minValue: 0, maxValue: 4095, rangeMax: 65535, componentCount: 1)
    let old = session.frameSnapshot()
    precondition(old.transferFunctions.count == 4, "Fixture must reproduce the deferred snapshot")
    let renderer = RenderTransferFunctionSet(device: device)
    do {
      try renderer.synchronize(with: old.transferFunctions,
        componentRanges: parameters.componentRanges, rangeMax: parameters.rangeMax)
      fatalError("The old four-channel snapshot must not fit a single-channel dataset")
    } catch is TransferFunction1DError { }

    for channels in [1, 2, 4, 1] {
      parameters.updateRanges(minValue: 0, maxValue: 4095, rangeMax: 65535, componentCount: channels)
      let startup = session.currentFrameSnapshot()
      precondition(startup.transferFunctions.count == channels)
      precondition(session.frameSnapshot().transferFunctions.count == channels)
      try renderer.synchronize(with: startup.transferFunctions,
        componentRanges: parameters.componentRanges, rangeMax: parameters.rangeMax)
      precondition(renderer.activeTransferFunctions.count == channels)
      precondition(abs(renderer.activeTransferFunctions[0].textureBias - Float(65535) / 4095) < 0.0001)
    }
    print("Renderer startup snapshots passed: four-channel color to scalar and repeated channel changes")
  }

  @MainActor
  private static func supportingFileExplanationPreference() async throws {
    let suite = "BorgVR-supporting-file-explanation-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    precondition(!ExplanationDialogPreference.hasSuppressedDialogs(defaults: defaults))
    precondition(SupportingFileAccessExplanation.shouldShow(defaults: defaults))
    SupportingFileAccessExplanation.disable(defaults: defaults)
    precondition(ExplanationDialogPreference.hasSuppressedDialogs(defaults: defaults))
    precondition(!SupportingFileAccessExplanation.shouldShow(defaults: defaults))
    let reloaded = UserDefaults(suiteName: suite)!
    precondition(ExplanationDialogPreference.hasSuppressedDialogs(defaults: reloaded))
    precondition(!SupportingFileAccessExplanation.shouldShow(defaults: reloaded))
    defaults.set(false, forKey: "appStoreUpdateChecksEnabled")
    defaults.set("3.8", forKey: "appStoreIgnoredUpdateVersion")
    defaults.set(true, forKey: "sharePlayDisplayNameOnboardingCompleted")
    defaults.set(64, forKey: "brickSize")
    let store = BorgVRSettingsStore(defaultValues: ExplanationDialogPreference.defaultValues, defaults: defaults)
    let archive = try store.export(includeCredentials: false)
    let presentation = ExplanationDialogSettingsState(defaults: defaults)
    precondition(presentation.hasSuppressedDialogs)
    presentation.restoreAll()
    precondition(!presentation.hasSuppressedDialogs)
    SupportingFileAccessExplanation.disable(defaults: defaults)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    for _ in 0..<100 {
      if presentation.hasSuppressedDialogs { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    precondition(presentation.hasSuppressedDialogs)
    presentation.restoreAll()
    precondition(!presentation.hasSuppressedDialogs)
    for dialog in ExplanationDialogPreference.allCases { dialog.disable(defaults: defaults) }
    ExplanationDialogPreference.restoreAll(defaults: defaults)
    precondition(!ExplanationDialogPreference.hasSuppressedDialogs(defaults: defaults))
    for dialog in ExplanationDialogPreference.allCases { precondition(dialog.shouldShow(defaults: defaults)) }
    precondition(SupportingFileAccessExplanation.shouldShow(defaults: defaults))
    precondition(!defaults.bool(forKey: "appStoreUpdateChecksEnabled"))
    precondition(defaults.string(forKey: "appStoreIgnoredUpdateVersion") == "3.8")
    precondition(defaults.bool(forKey: "sharePlayDisplayNameOnboardingCompleted"))
    precondition(defaults.integer(forKey: "brickSize") == 64)
    ExplanationDialogPreference.restoreAll(defaults: defaults)
    precondition(!ExplanationDialogPreference.hasSuppressedDialogs(defaults: defaults))
    try store.apply(store.prepareImport(archive))
    precondition(ExplanationDialogPreference.hasSuppressedDialogs(defaults: defaults))
    precondition(!SupportingFileAccessExplanation.shouldShow(defaults: defaults))
    try store.resetForAutomation()
    precondition(!ExplanationDialogPreference.hasSuppressedDialogs(defaults: defaults))
    precondition(SupportingFileAccessExplanation.shouldShow(defaults: defaults))
    print("Explanation preferences passed: conditional visibility, immediate hiding, external changes, persistent opt-out, targeted reset and archive round-trip")
  }

  private static func fusionWizardNavigation() {
    let steps = VolumeFusionWizardStep.allCases
    precondition(steps.map(\.number) == [2, 3, 4, 5])
    precondition(VolumeFusionWizardStep.reference.previous == nil)
    precondition(VolumeFusionWizardStep.conversion.next == nil)
    precondition(VolumeFusionWizardStep.reference.next == .registered)
    precondition(VolumeFusionWizardStep.registered.next == .options)
    precondition(VolumeFusionWizardStep.options.next == .conversion)
    precondition(VolumeFusionWizardStep.conversion.previous == .options)
    precondition(VolumeFusionWizardStep.options.previous == .registered)
    precondition(VolumeFusionWizardStep.registered.previous == .reference)
    precondition(VolumeFusionWizardStep.reference.sourceTitle != nil)
    precondition(VolumeFusionWizardStep.registered.sourceTitle != nil)
    precondition(VolumeFusionWizardStep.options.sourceTitle == nil)
    precondition(VolumeFusionWizardStep.conversion.sourceTitle == nil)
    for reference in [false, true] {
      for registered in [false, true] {
        precondition(VolumeFusionWizardStep.reference.canContinue(
          referenceSelected: reference, registeredSelected: registered) == reference)
        precondition(VolumeFusionWizardStep.registered.canContinue(
          referenceSelected: reference, registeredSelected: registered) == (reference && registered))
        precondition(VolumeFusionWizardStep.options.canContinue(
          referenceSelected: reference, registeredSelected: registered) == (reference && registered))
        precondition(!VolumeFusionWizardStep.conversion.canContinue(
          referenceSelected: reference, registeredSelected: registered))
        for step in steps {
          precondition(step.canStart(referenceSelected: reference, registeredSelected: registered) ==
            (step == .conversion && reference && registered))
        }
      }
    }
    print("Fusion wizard passed: reference, registered volume, options, separate conversion, reverse navigation and start validation")
  }

  private static func directoryImportWizardNavigation() {
    precondition(DICOMSourceWizardStep.directory.previous == nil)
    precondition(DICOMSourceWizardStep.directory.next == .preview)
    precondition(DICOMSourceWizardStep.preview.previous == .directory)
    precondition(DICOMSourceWizardStep.preview.next == nil)
    precondition(VolumeImportKind.volumeFile.macWizardStepCount() == 7)
    precondition(VolumeImportKind.dicomDirectory.macWizardStepCount() == 8)
    precondition(VolumeImportKind.imageSequence.macWizardStepCount() == 8)
    for reference in [false, true] {
      for registered in [false, true] {
        precondition(VolumeImportKind.volumeFusion.macWizardStepCount(
          referenceIsDICOM: reference, registeredIsDICOM: registered) ==
          8 + (reference ? 1 : 0) + (registered ? 1 : 0))
      }
    }
    precondition(VolumeImportKind.imageSequence.compactWizardStepCount == 4)
    precondition(VolumeImportKind.volumeFusion.compactWizardStepCount == 5)
    precondition(VolumeImportKind.volumeFile.compactWizardStepCount == 4)
    precondition(VolumeImportKind.dicomDirectory.compactWizardStepCount == 4)
    precondition(VolumeImportWizardStep.allCases.map(\.number) == [2, 3, 4])
    precondition(VolumeImportWizardStep.source.previous == nil)
    precondition(VolumeImportWizardStep.source.next == .options)
    precondition(VolumeImportWizardStep.options.next == .conversion)
    precondition(VolumeImportWizardStep.conversion.previous == .options)
    precondition(VolumeImportWizardStep.options.previous == .source)
    precondition(VolumeImportWizardStep.conversion.next == nil)
    precondition(DirectoryImportWizardStep.allCases.map(\.number) == [2, 3])
    precondition(DirectoryImportWizardStep.directory.previous == nil)
    precondition(DirectoryImportWizardStep.options.next == nil)
    precondition(DirectoryImportWizardStep.directory.next == .options)
    precondition(DirectoryImportWizardStep.options.previous == .directory)
    for directory in [false, true] {
      precondition(VolumeImportWizardStep.source.canContinue(sourceSelected: directory) == directory)
      precondition(VolumeImportWizardStep.options.canContinue(sourceSelected: directory) == directory)
      precondition(!VolumeImportWizardStep.conversion.canContinue(sourceSelected: directory))
      precondition(!VolumeImportWizardStep.source.canStart(sourceSelected: directory))
      precondition(!VolumeImportWizardStep.options.canStart(sourceSelected: directory))
      precondition(VolumeImportWizardStep.conversion.canStart(sourceSelected: directory) == directory)
      precondition(DirectoryImportWizardStep.directory.canContinue(directorySelected: directory) == directory)
      precondition(DirectoryImportWizardStep.options.canContinue(directorySelected: directory) == directory)
      for size in [false, true] {
        precondition(VolumeImportWizardStep.source.canContinue(
          sourceSelected: directory, sizeIsValid: size) == directory)
        precondition(VolumeImportWizardStep.options.canContinue(
          sourceSelected: directory, sizeIsValid: size) == (directory && size))
        precondition(!VolumeImportWizardStep.conversion.canContinue(
          sourceSelected: directory, sizeIsValid: size))
        precondition(!VolumeImportWizardStep.source.canStart(sourceSelected: directory, sizeIsValid: size))
        precondition(!VolumeImportWizardStep.options.canStart(sourceSelected: directory, sizeIsValid: size))
        precondition(VolumeImportWizardStep.conversion.canStart(
          sourceSelected: directory, sizeIsValid: size) == (directory && size))
        precondition(DirectoryImportWizardStep.directory.canContinue(
          directorySelected: directory, sizeIsValid: size) == directory)
        precondition(DirectoryImportWizardStep.options.canContinue(
          directorySelected: directory, sizeIsValid: size) == (directory && size))
      }
    }
    print("Import wizards passed: files, DICOM and images; separate sources, metadata and conversion; reverse navigation and start validation")
  }
}
