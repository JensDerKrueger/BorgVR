import AppKit
import Foundation
import SwiftUI
import simd
@testable import BorgVR

private enum RecordingTestFailure: Error { case failed(String) }

@MainActor
func testCommandRecordingRoundtrip(fixture: URL, directory: URL) async throws {
  func require(_ value: Bool, _ message: String) throws {
    if !value { throw RecordingTestFailure.failed(message) }
  }
  let settings = AppSettings()
  let safeDefaults = AppSettings.values.filter { BorgVRSettingsStore.recordingKeys.contains($0.key) }
  let previousPreferences = Dictionary(uniqueKeysWithValues: safeDefaults.keys.map {
    ($0, UserDefaults.standard.object(forKey: $0))
  })
  defer {
    for key in safeDefaults.keys {
      if let value = previousPreferences[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
  }
  // Exercise real @AppStorage bindings without reading/writing account or service credentials.
  let safeStore = BorgVRSettingsStore(defaultValues: safeDefaults,
    maximumAtlasSizeMB: AppSettings.maximumAtlasSizeMB, didImport: { settings.objectWillChange.send() })
  let source = directory.appendingPathComponent("recording.data")
  try FileManager.default.copyItem(at: fixture, to: source)
  let metadata = try BORGVRMetaData(url: source)
  let model = AppModel(), parameters = RenderingParameters()
  model.openDataset(.init(identifier: source.path, description: "Recording fixture", source: .local,
    uniqueId: metadata.uniqueID), automaticallyLoadState: false)
  guard case .opening(_, let request) = model.datasetSessionState else { fatalError() }
  model.prepareDatasetRenderer(key: model.activeDatasetRenderKey, metadata: metadata, requestID: request)
  _ = model.markRenderedDataset(key: model.activeDatasetRenderKey, requestID: request)
  parameters.updateRanges(minValue: 0, maxValue: 255, rangeMax: 255, componentCount: metadata.componentCount)
  let session = ScreenBorgVRSession.screen(appModel: model, renderingParameters: parameters, appSettings: settings)
  let service = BorgVRScreenCommandService(session: session, settingsStoreProvider: { safeStore })
  _ = model.volumeBrush.open(try BORGVRFileData(filename: source.path), datasetURL: source)
  try await model.volumeBrush.waitForStateReady()
  defer { model.volumeBrush.close() }

  let extent = SIMD3<Double>(metadata.physicalExtentMeters)
  let sample = BorgVRVolumeBrushSample(center: extent * 0.5, radius: max(extent.x, extent.y, extent.z) * 0.12)
  // Existing edits must be part of the recording baseline, not depend on a local variant UUID.
  try await model.volumeBrush.editVolume(mode: .erase, samples: [sample])
  try await model.volumeBrush.waitForVolumeEdits(timeout: 30)
  let initiallyActiveID = model.volumeBrush.activeState!.id
  try await model.volumeBrush.duplicateState(name: "Preexisting inactive variant", empty: false)
  let inactiveID = model.volumeBrush.activeState!.id
  try await model.volumeBrush.selectState(initiallyActiveID)
  session.startCommandRecording()
  // Starting twice must not reset an in-flight baseline capture.
  session.startCommandRecording()
  // The initial mask snapshot holds editing admission only until its consistent copy is ready.
  try await session.waitForRecordingPreparation()
  try await model.volumeBrush.waitForStateReady()
  try model.volumeBrush.renameState(inactiveID, name: "Renamed inactive variant")
  session.settingsBinding(Binding(get: { settings.oversampling }, set: { settings.oversampling = $0 })).wrappedValue = 3.25
  session.settingsBinding(Binding(get: { settings.sampleJitter }, set: { settings.sampleJitter = $0 })).wrappedValue = true
  session.mutateSettings { settings.alphaEpsilon = 0.012; settings.opacityAdaptiveSampling = false }
  let settingsInput = directory.appendingPathComponent("recorded-settings-input.borgvrsettings")
  try settings.settingsStore().exportForRecording().write(to: settingsInput)
  try service.resetSettings()
  try service.loadSettings(from: settingsInput)
  session.settingsBinding(Binding(get: { settings.showDatasetBoundingBox }, set: { settings.showDatasetBoundingBox = $0 })).wrappedValue = true
  try session.perform(.setBrickVisualization(enabled: true, resident: false, empty: true, missing: false), source: .userInterface)
  try session.perform(.setRenderMode(.isoValue), source: .userInterface)
  try session.perform(.setClipping(minimum: SIMD3(0.1, 0.2, 0), maximum: SIMD3(0.9, 1, 0.8)), source: .userInterface)
  session.mutate(source: .mouse, domain: .visualization) {
    parameters.pan = SIMD2(0.12, -0.08)
    parameters.scale = 1.37
  }
  // A renderer read between a legacy UI setter and its commit must not consume the delta.
  parameters.normIsoValue = 0.376
  _ = session.currentFrameSnapshot()
  session.commitExternalMutation(source: .touch, domain: .visualization)
  try parameters.transferFunction.updateData(with: parameters.transferFunction.data.enumerated().map {
    SIMD4(UInt8($0.offset % 256), 93, 207, $0.element.w)
  })
  session.publishRenderSnapshot()
  model.interactionMode = .volumeEditing
  parameters.transferEditing = .init(red: true, green: false, blue: true, opacity: false)
  model.volumeBrush.radius = 0.065
  try await model.volumeBrush.editVolume(mode: .restore,
    samples: [.init(center: extent * 0.5, radius: sample.radius * 0.5)])
  try await model.volumeBrush.waitForVolumeEdits(timeout: 30)
  try await model.volumeBrush.duplicateState(name: "Recorded copy", empty: false)
  let copyID = model.volumeBrush.activeState!.id
  try model.volumeBrush.renameState(copyID, name: "Renamed recorded copy")
  try await model.volumeBrush.duplicateState(name: "Temporary recorded state", empty: true)
  let temporaryID = model.volumeBrush.activeState!.id
  try await model.volumeBrush.selectState(copyID)
  try model.volumeBrush.deleteState(temporaryID)
  try model.volumeBrush.deleteState(inactiveID)
  try await model.volumeBrush.selectState(nil)
  try await model.volumeBrush.editVolume(mode: .erase, samples: [sample])
  try await model.volumeBrush.waitForVolumeEdits(timeout: 30)
  let originalWorkingID = model.volumeBrush.activeState!.id
  try model.volumeBrush.renameState(originalWorkingID, name: "New edits from Original")
  try await model.volumeBrush.selectState(copyID)
  try model.volumeBrush.deleteState(originalWorkingID)
  let marker = VolumeMarker(id: UUID(), name: "Recorded marker", position: SIMD3(0.3, 0.4, 0.5),
    radius: 0.02, color: SIMD4(1, 0.5, 0, 1), directionOrigin: SIMD3(0.3, 0.4, 0.5))
  session.mutate(source: .userInterface, domain: .objects) { model.replaceVolumeMarkers([marker]) }
  try service.setBackground(.init(mode: "gradient", primary: [0.1, 0.2, 0.3, 1], secondary: [0, 0, 0, 1]))
  try service.setLighting(direction: SIMD3(0, 1, 0), ambient: SIMD3(repeating: 0.35),
    diffuse: SIMD3(repeating: 0.6), specular: SIMD3(repeating: 0.2))
  let measurement = BorgVRMeasurementCommandState(id: UUID(), name: "Recorded distance", kind: .length,
    points: [.init(id: UUID(), position: SIMD3(0.1, 0.2, 0.3)),
      .init(id: UUID(), position: SIMD3(0.4, 0.5, 0.6))])
  try session.perform(.upsertMeasurement(measurement), source: .userInterface)
  let output = directory.appendingPathComponent("recorded-panel.json")
  let outputData = Data("{\"value\":0.376}".utf8)
  try session.performFileAction(outputs: [output]) { try outputData.write(to: output) }
  let volumeOutput = directory.appendingPathComponent("recorded-export.data")
  _ = try model.volumeBrush.startVolumeExport(to: volumeOutput, name: "Recorded export", description: "Roundtrip test")
  try await session.finishCommandRecording()
  func decodedBricks(_ url: URL) throws -> Data {
    let volume = try BORGVRFileData(filename: url.path)
    let metadata = volume.getMetadata()
    let size = try metadata.voxelBrickByteCount()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    defer { buffer.deallocate() }
    var bytes = Data()
    for index in metadata.brickMetadata.indices {
      try volume.getBrick(index: index, outputBuffer: buffer)
      bytes.append(buffer, count: size)
    }
    return bytes
  }
  let expectedVolumeBytes = try decodedBricks(volumeOutput)
  let script = try session.recordedGSCScript()
  let decodedCommands = try BorgVRRecordedGSC.commands(in: Data(script.utf8))
  try require(decodedCommands.contains { if case .setTransferFunction = $0 { return true }; return false },
    "Missing transfer-function serialization")
  let expected = session.currentFrameSnapshot()
  let expectedTF = parameters.activeTransferFunctions.map(\.data)
  let expectedSettings = try settings.settingsStore().exportForRecording()
  let expectedMask = try await model.volumeBrush.stateSnapshot().mask
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let expectedMaskData = try encoder.encode(expectedMask)

  try service.reset(.all)
  try await model.volumeBrush.discardVolumeEdits()
  model.replaceVolumeMarkers([])
  parameters.transferEditing = .init()
  model.interactionMode = .model
  settings.oversampling = 1
  settings.sampleJitter = false
  model.replaceVolumeMeasurements([])
  try FileManager.default.removeItem(at: output)
  try FileManager.default.removeItem(at: volumeOutput)
  let runner = BorgVRScriptRunner()
  let stored = StoredAppModel()
  let sharePlay = SharePlayCoordinator(platformAdapter: MacSharePlayPlatformAdapter(
    storedAppModel: stored, serverController: BackgroundServerController()))
  runner.configure(appModel: model, renderingParameters: parameters, session: session,
    appSettings: settings, storedAppModel: stored, sharePlay: sharePlay,
    docking: DockingController(), commandService: service)
  let url = directory.appendingPathComponent("recorded-roundtrip.gsc")
  try script.write(to: url, atomically: true, encoding: .utf8)
  runner.runScript(at: url)
  let deadline = ContinuousClock.now + .seconds(60)
  while runner.isRunning {
    guard ContinuousClock.now < deadline else { runner.stopScript(); throw RecordingTestFailure.failed("Replay timeout") }
    try await Task.sleep(for: .milliseconds(10))
  }
  try require(runner.scriptLogText.contains("Script finished"), "Recorded GSC failed: \(runner.scriptLogText)")
  let actual = session.currentFrameSnapshot()
  try require(actual.visualization.transform.translation == expected.visualization.transform.translation &&
    abs(simd_dot(actual.visualization.transform.rotation, expected.visualization.transform.rotation)) > 0.99999 &&
    abs(actual.visualization.transform.scale.x - expected.visualization.transform.scale.x) < 0.00001,
    "Transform did not round-trip")
  try require(actual.visualization.brickVisualization == expected.visualization.brickVisualization &&
    actual.visualization.brickVisualizationMask == expected.visualization.brickVisualizationMask,
    "Brick visualization filters did not round-trip")
  try require(actual.visualization.clipMinimum == expected.visualization.clipMinimum &&
    actual.visualization.clipMaximum == expected.visualization.clipMaximum &&
    actual.visualization.normalizedIsoValue == expected.visualization.normalizedIsoValue &&
    actual.visualization.renderMode == expected.visualization.renderMode,
    "Render parameters did not round-trip: iso \(actual.visualization.normalizedIsoValue) vs \(expected.visualization.normalizedIsoValue), mode \(actual.visualization.renderMode) vs \(expected.visualization.renderMode)")
  try require(parameters.activeTransferFunctions.map(\.data) == expectedTF, "TF data did not round-trip")
  try require(actual.visualization.lighting == expected.visualization.lighting, "Lighting did not round-trip")
  try require(try settings.settingsStore().exportForRecording() == expectedSettings, "Settings did not round-trip")
  try require(model.volumeMarkers.map(BorgVRMarkerCommandState.init) == [BorgVRMarkerCommandState(marker)],
    "Object baseline/delta did not round-trip")
  try require(model.interactionMode == .volumeEditing && parameters.transferEditing.red &&
    parameters.transferEditing.blue && !parameters.transferEditing.opacity, "Interaction state did not round-trip")
  try require(try encoder.encode(await model.volumeBrush.stateSnapshot().mask) == expectedMaskData,
    "Existing edits plus erase/restore samples did not round-trip")
  try require(abs(model.volumeBrush.radius - 0.065) < 0.000001, "Brush configuration did not round-trip")
  try require(model.volumeMeasurements.map(BorgVRMeasurementCommandState.init) == [measurement],
    "Measurements did not round-trip")
  try require(try Data(contentsOf: output) == outputData, "Committed panel output was not replayed")
  try require(try decodedBricks(volumeOutput) == expectedVolumeBytes, "Edited-volume export did not round-trip")
  // The native reader is shared by macOS, iOS and visionOS, independent of AppKit/DSL execution.
  try service.reset(.all)
  try await model.volumeBrush.discardVolumeEdits()
  try FileManager.default.removeItem(at: volumeOutput)
  try await service.replayCommandRecording(Data(script.utf8))
  try require(parameters.activeTransferFunctions.map(\.data) == expectedTF &&
    session.currentSnapshot().clipMinimum == expected.visualization.clipMinimum &&
    session.currentSnapshot().lighting == expected.visualization.lighting,
    "Shared native playback did not restore the scene")
  try require(try encoder.encode(await model.volumeBrush.stateSnapshot().mask) == expectedMaskData &&
    decodedBricks(volumeOutput) == expectedVolumeBytes, "Shared native playback changed the edits/export")
  let beforeInvalidReplay = session.currentSnapshot()
  let invalidReplay = try BorgVRCommand.setNormalizedIsoValue(0.123).encodedGSCStatement() + "\nnot-a-recorded-command\n"
  do {
    try await service.replayCommandRecording(Data(invalidReplay.utf8))
    throw RecordingTestFailure.failed("Invalid recording was accepted")
  } catch is BorgVRMCPCommandError {}
  try require(session.currentSnapshot() == beforeInvalidReplay, "Invalid recording was partially executed")
  try await model.volumeBrush.selectState(nil)
  let originalSnapshot = try await model.volumeBrush.stateSnapshot()
  let savedBeforeOriginalRestore = model.volumeBrush.states.count
  try await service.executeRecordedCommand(.action(.restoreEditState(snapshot: originalSnapshot, state: nil)))
  try require(model.volumeBrush.states.count == savedBeforeOriginalRestore && model.volumeBrush.activeState == nil,
    "Restoring Original created a spurious saved edit state")

  // Lossless full 3D payloads, arbitrary rotations and malformed/future documents.
  let transform = BorgVRCommand.setTransform(.init(rotation: SIMD4(0, 0, 0, 1),
    translation: SIMD3(0.1, 0.2, 0.3), scale: SIMD3(1, 2, 3)))
  for command in [transform, .rotate(axis: SIMD3(1, 2, 3), degrees: 17), .reset(.transform)] {
    let line = try command.encodedGSCStatement()
    let payload = String(line.split(separator: " ", maxSplits: 1)[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    let restored = try BorgVRCommand.decodeGSCCommand(payload)
    try require(try encoder.encode(command) == encoder.encode(restored), "Command codec changed a payload")
  }
  let beforeUnsupportedTransform = session.currentSnapshot().transform
  do {
    try session.perform(transform, source: .gsc)
    throw RecordingTestFailure.failed("A 3D transform was silently flattened by the screen renderer")
  } catch is BorgVRMCPCommandError {}
  try require(session.currentSnapshot().transform == beforeUnsupportedTransform,
    "An unsupported transform partially changed the scene")
  for payload in ["invalid", Data("{\"version\":99,\"command\":{}}".utf8).base64EncodedString()] {
    do { _ = try BorgVRCommand.decodeGSCCommand(payload); throw RecordingTestFailure.failed("Invalid payload accepted") }
    catch is RecordingTestFailure { throw RecordingTestFailure.failed("Invalid payload accepted") }
    catch {}
  }

  session.startCommandRecording()
  session.trackActionCompletion { throw RecordingTestFailure.failed("Simulated delayed export failure") }
  do { _ = try session.recordedGSCScript(); throw RecordingTestFailure.failed("Pending actions silently exported") }
  catch is BorgVRMCPCommandError {}
  try await session.finishCommandRecording()
  do { _ = try session.recordedGSCScript(); throw RecordingTestFailure.failed("Failed action silently exported") }
  catch is BorgVRMCPCommandError {}
  session.startCommandRecording()
  try await session.waitForRecordingPreparation()
  try session.perform(.mutation(.interaction), source: .userInterface)
  try await session.finishCommandRecording()
  do { _ = try session.recordedGSCScript(); throw RecordingTestFailure.failed("Unsupported mutation silently dropped") }
  catch is BorgVRRecordingError {}
  print("Command recording roundtrips passed: real GSC interpreter and shared native playback; UI bindings, settings reset/import, TF, clipping, transform, light, annotations, saved edit states, erase/restore, volume export, file outputs; pending/failure guards, atomic document parsing and 3D codec")
}
