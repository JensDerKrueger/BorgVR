import Foundation

private struct EditingAutomationTestError: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw EditingAutomationTestError(message: message) }
}
private func rejects(_ message: String, _ body: () throws -> Void) throws {
  do { try body() }
  catch { return }
  throw EditingAutomationTestError(message: message)
}

private final class PausedEditExportSource: BORGVRDatasetProtocol {
  let source: BORGVRDatasetProtocol
  let gate = DispatchSemaphore(value: 0)
  let lock = NSLock()
  private var waiting = false
  var hasStarted: Bool { lock.withLock { waiting } }
  init(_ source: BORGVRDatasetProtocol) { self.source = source }
  func getMetadata() -> BORGVRMetaData { source.getMetadata() }
  func newRequest() {}
  func allocateBrickBuffer() -> UnsafeMutablePointer<UInt8> { source.allocateBrickBuffer() }
  func getBrick(index: Int, outputBuffer: UnsafeMutablePointer<UInt8>) throws {
    let first = lock.withLock { () -> Bool in
      guard !waiting else { return false }
      waiting = true
      return true
    }
    if first { gate.wait() }
    try source.getBrick(index: index, outputBuffer: outputBuffer)
  }
  func getFirstBrick(outputBuffer: UnsafeMutablePointer<UInt8>) throws { try getBrick(index: 0, outputBuffer: outputBuffer) }
}

@MainActor
func runVolumeEditingAutomationTests() async throws {
  for value: Any in [true, "1", Double.infinity, Double.nan] {
    try rejects("Invalid number accepted") { _ = try BorgVRVolumeEditingArguments.number(value) }
  }
  try require(try BorgVRVolumeEditingArguments.number(1.25) == 1.25, "Number changed precision")
  try rejects("Numeric boolean accepted") { _ = try BorgVRVolumeEditingArguments.boolean(1) }
  try require(try BorgVRVolumeEditingArguments.boolean(false) == false, "False was lost")
  try rejects("Invalid mode accepted") { _ = try BorgVRVolumeEditingArguments.mode("paint") }
  let samples = try BorgVRVolumeEditingArguments.samples(text: "0.8 1.1 1.5 0.7, 0.9 1.2 1.5 0.6")
  let json = try JSONSerialization.jsonObject(with: Data("[{\"center_meters\":[0.8,1.1,1.5],\"radius_meters\":0.7}]".utf8))
  try require(try BorgVRVolumeEditingArguments.samples(json) == [samples[0]], "MCP and GSC samples differ")
  for text in ["", "1 2 3", "1 2 3 -1", "1 2 3 nan"] {
    try rejects("Invalid samples accepted") { _ = try BorgVRVolumeEditingArguments.samples(text: text) }
  }
  try rejects("Boolean coordinate accepted") {
    _ = try BorgVRVolumeEditingArguments.samples([["center_meters": [true, 1, 2], "radius_meters": 1]])
  }

  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-automation-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let sourceURL = root.appendingPathComponent("original.data")
  let source = try makeEditExportSource(EditTestDataset(bytesPerComponent: 2), compressed: true, url: sourceURL)
  let originalFile = try Data(contentsOf: sourceURL)
  let model = VolumeBrushModel()
  defer { model.close() }
  try require(!model.volumeEditingState().available, "Unopened editor available")
  let edited = model.open(source, datasetURL: sourceURL)
  try await model.waitForStateReady()
  try require(model.volumeEditingState().available, "Editor unavailable after open")
  try model.setVolumeBrushChannels(BorgVRVolumeEditingArguments.channels("2"))
  try require(model.channels == .selected([1]) && model.context.settings().channels == .selected([1]) &&
    model.volumeEditingState().channels == [2] && model.componentCount == 2,
    "GUI/automation channel selection or one-based MCP state differs")
  do {
    try model.setVolumeBrushChannels(.selected([2]))
    throw EditingAutomationTestError(message: "Out-of-range channel accepted")
  } catch BorgVRVolumeEditError.invalidBrush {}
  try require(model.channels == .selected([1]), "Rejected channel changed the selection")
  try model.setVolumeBrushChannels(BorgVRVolumeEditingArguments.channels([NSNumber(value: 2), NSNumber(value: 1)]))
  try require(model.channels == .all, "Selecting all channels did not normalize to the fast path")
  for timeout in [0.0, -1, .infinity, 100_000] {
    do { try await model.waitForVolumeEdits(timeout: timeout); throw EditingAutomationTestError(message: "Invalid timeout accepted") }
    catch BorgVRVolumeEditingCommandError.invalidArgument {}
  }
  do { try await model.editVolume(mode: .erase, samples: []); throw EditingAutomationTestError(message: "Empty batch accepted") }
  catch BorgVRVolumeEditingCommandError.invalidArgument {}
  try model.configureVolumeBrush(mode: .restore, radiusFraction: 0.1, projectsOntoVolume: false)
  try rejects("Invalid radius accepted") {
    try model.configureVolumeBrush(mode: .erase, radiusFraction: 0, projectsOntoVolume: true)
  }
  try require(model.mode == .restore && !model.projectsOntoVolume && model.radius == 0.1, "Invalid settings partially applied")
  try await model.editVolume(mode: .erase, samples: samples)
  try require(model.volumeEditingState().hasEdits, "Journaled edit not reported")
  try await model.waitForVolumeEdits(timeout: 10)
  try require(!model.volumeEditingState().isUpdatingBricks, "Background jobs did not finish")

  let output = root.appendingPathComponent("edited.data")
  let job = try model.startVolumeExport(to: output, name: "Edited name", description: "Edited description")
  try require(job.status == .running, "Export did not start asynchronously")
  try rejects("Concurrent export accepted") { _ = try model.startVolumeExport(to: root.appendingPathComponent("second.data"), name: nil, description: nil) }
  try rejects("Different export was cancelled") { try model.cancelVolumeExport(id: UUID()) }
  let completed = try await model.waitForVolumeExport(id: job.id)
  try require(completed.status == .completed && completed.progress == 1, "Export never completed")
  try require(model.exportedURL == nil, "Automation export opened the native save dialog")
  let exported = try BORGVRFileData(filename: output.path)
  try require(exported.getMetadata().compression == source.getMetadata().compression, "Compression changed")
  try require(exported.getMetadata().datasetDescription == "Edited name" && exported.getMetadata().metaDescription == "Edited description", "Export metadata lost")
  let a = source.allocateBrickBuffer(), b = source.allocateBrickBuffer()
  defer { a.deallocate(); b.deallocate() }
  let count = source.getMetadata().brickSize * source.getMetadata().brickSize * source.getMetadata().brickSize * 4
  var changed = false
  for index in source.getMetadata().brickMetadata.indices {
    try edited.getBrick(index: index, outputBuffer: a)
    try exported.getBrick(index: index, outputBuffer: b)
    try require(memcmp(a, b, count) == 0, "Export differs from current edited volume")
    try source.getBrick(index: index, outputBuffer: b)
    changed = changed || memcmp(a, b, count) != 0
  }
  try require(changed, "Brush did not affect any physical voxels")
  try rejects("Existing file overwritten") { _ = try model.startVolumeExport(to: output, name: nil, description: nil) }
  try rejects("Invalid extension accepted") { _ = try model.startVolumeExport(to: root.appendingPathComponent("bad.obj"), name: nil, description: nil) }
  let encoded = try JSONEncoder().encode(model.volumeEditingState())
  try require(try JSONDecoder().decode(BorgVRVolumeEditingState.self, from: encoded).export?.id == job.id, "Editing state is not round-trip Codable")

  try await model.editVolume(mode: .restore, samples: [.init(center: SIMD3(1, 1, 1), radius: 10)])
  try await model.waitForVolumeEdits(timeout: 10)
  try require(!model.volumeEditingState().hasEdits, "Restored volume still reports edits")
  let cancelledEdit = Task { try await model.editVolume(mode: .erase, samples: samples) }
  cancelledEdit.cancel()
  do { try await cancelledEdit.value; throw EditingAutomationTestError(message: "Cancelled brush accepted") }
  catch is CancellationError {}
  try require(!model.volumeEditingState().hasEdits, "Cancelled brush was journaled")
  try await model.editVolume(mode: .erase, samples: samples)
  try await model.discardVolumeEdits()
  try require(!model.volumeEditingState().hasEdits, "Discard retained edits")
  try require(!FileManager.default.fileExists(atPath: sourceURL.path + ".edits"), "Discard retained sidecar directory")
  try require(try Data(contentsOf: sourceURL) == originalFile, "Original dataset changed")

  model.prepareExport()
  model.export()
  guard let uiJob = model.exportJob else { throw EditingAutomationTestError(message: "UI export did not start") }
  _ = try await model.waitForVolumeExport(id: uiJob.id)
  guard let uiTemporary = model.exportedURL else { throw EditingAutomationTestError(message: "UI export no longer offers a save destination") }
  let uiDestination = root.appendingPathComponent("ui-export.data")
  try FileManager.default.moveItem(at: uiTemporary, to: uiDestination)
  try require(model.exportMoveCompleted(.success(uiDestination)), "UI export move was rejected")
  try require(FileManager.default.fileExists(atPath: uiDestination.path), "UI cleanup removed saved output")

  let paused = PausedEditExportSource(source)
  _ = model.open(paused, datasetURL: sourceURL)
  try await model.waitForStateReady()
  let cancelURL = root.appendingPathComponent("cancelled.data")
  let pending = try model.startVolumeExport(to: cancelURL, name: nil, description: nil)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !paused.hasStarted && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
  guard paused.hasStarted else { paused.gate.signal(); throw EditingAutomationTestError(message: "Export never read the source") }
  try model.cancelVolumeExport(id: pending.id)
  try require(model.exportJob?.status == .cancelling, "Cancellation not published")
  paused.gate.signal()
  do { _ = try await model.waitForVolumeExport(id: pending.id); throw EditingAutomationTestError(message: "Cancelled export succeeded") }
  catch is CancellationError {}
  try require(!FileManager.default.fileExists(atPath: cancelURL.path), "Cancelled export left output")
  try require(FileManager.default.fileExists(atPath: output.path), "Cancellation deleted another destination")

  let pausedAgain = PausedEditExportSource(source)
  _ = model.open(pausedAgain, datasetURL: sourceURL)
  try await model.waitForStateReady()
  let taskOutput = root.appendingPathComponent("task-cancelled.data")
  let taskJob = try model.startVolumeExport(to: taskOutput, name: nil, description: nil)
  let taskDeadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !pausedAgain.hasStarted && ContinuousClock.now < taskDeadline { try await Task.sleep(for: .milliseconds(5)) }
  guard pausedAgain.hasStarted else { pausedAgain.gate.signal(); throw EditingAutomationTestError(message: "Second export never read the source") }
  let waiter = Task { try await model.waitForVolumeExport(id: taskJob.id) }
  await Task.yield()
  waiter.cancel()
  do { _ = try await waiter.value; throw EditingAutomationTestError(message: "Cancelled task succeeded") }
  catch is CancellationError {}
  try require(model.exportJob?.status == .cancelling, "Stopping an awaiting script did not cancel its export")
  pausedAgain.gate.signal()
  do { _ = try await model.waitForVolumeExport(id: taskJob.id); throw EditingAutomationTestError(message: "Task-cancelled export succeeded") }
  catch is CancellationError {}
  try require(!FileManager.default.fileExists(atPath: taskOutput.path), "Task-cancelled export left output")
  model.close()
  try require(!model.volumeEditingState().available, "Closed editor still available")
  do { try await model.waitForVolumeEdits(timeout: 1); throw EditingAutomationTestError(message: "Wait accepted closed dataset") }
  catch BorgVRVolumeEditingCommandError.unavailable {}
  try await testExclusiveExportAdmission(source: source, root: root)
  try await testSharePlayCancelsExport(source: source, root: root, leaveBeforeCompletion: false)
  try await testSharePlayCancelsExport(source: source, root: root, leaveBeforeCompletion: true)
  try await testClosingDuringExport(source: source, root: root)
  try await testDeletingClosedDataset(root: root)
  print("Volume editing automation tests passed")
}

@MainActor
private func testDeletingClosedDataset(root: URL) async throws {
  let url = root.appendingPathComponent("delete-with-pending-edits.data")
  let source = try makeEditExportSource(EditTestDataset(bytesPerComponent: 2), compressed: true, url: url)
  let model = VolumeBrushModel()
  defer { model.close() }
  _ = model.open(source, datasetURL: url)
  try await model.waitForStateReady()
  try await model.editVolume(mode: .erase, samples: [.init(center: SIMD3(1, 1, 1), radius: 0.7)])
  do {
    try await model.deleteClosedDataset(at: url, datasetID: source.getMetadata().uniqueID)
    throw EditingAutomationTestError(message: "Deleted a dataset while it was still open")
  } catch BorgVRVolumeEditingCommandError.busy {}
  try require(FileManager.default.fileExists(atPath: url.path + ".edits"),
    "Deleting an active dataset removed its edits")
  model.close()
  try await model.deleteClosedDataset(at: url, datasetID: source.getMetadata().uniqueID)
  try require(!FileManager.default.fileExists(atPath: url.path) &&
    !FileManager.default.fileExists(atPath: url.path + ".edits"),
    "Dataset deletion returned before closed workers and their storage were removed")
  for _ in 0..<20 { await Task.yield() }
  try require(!FileManager.default.fileExists(atPath: url.path + ".edits"),
    "A closed background worker recreated deleted edits")
}

@MainActor
private func awaitEditingCondition(_ message: String, _ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while ContinuousClock.now < deadline {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw EditingAutomationTestError(message: message)
}

@MainActor
private func testExclusiveExportAdmission(source: BORGVRDatasetProtocol, root: URL) async throws {
  let model = VolumeBrushModel()
  let sourceURL = root.appendingPathComponent("exclusive-admission.data")
  let edited = model.open(source, datasetURL: sourceURL) as! BorgVRVolumeEditDataSource
  try await model.waitForStateReady()
  let samples = [BorgVRVolumeBrushSample(center: SIMD3(1, 1, 1), radius: 0.7)]
  let acceptedID = UUID()
  edited.brush(samples, mode: .erase, operationID: acceptedID)
  let exportID = try model.beginReadOnlyExport(cancel: {})
  defer { model.finishReadOnlyExport(id: exportID); model.close() }
  try await model.prepareReadOnlyExport(id: exportID)
  let snapshot = try await model.stateSnapshot()
  try require(snapshot.operationIDs.contains(acceptedID) && snapshot.revision == 1,
    "Export overtook already accepted brush input")
  do { try await model.editVolume(mode: .restore, samples: samples); throw EditingAutomationTestError(message: "Automation edited during export") }
  catch BorgVRVolumeEditingCommandError.busy {}
  do {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      model.context.applySamples(samples, mode: .restore, cancellationToken: .init()) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    throw EditingAutomationTestError(message: "Device input edited during export")
  } catch BorgVRVolumeEditingCommandError.busy {}
  do {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      edited.brush(samples, mode: .restore) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    throw EditingAutomationTestError(message: "Data-source admission bypassed the export lock")
  } catch BorgVRVolumeEditError.editingBlocked {}
  model.context.apply(at: SIMD3(repeating: 0.5), source: "test-device", mode: .restore)
  try require(try await model.stateSnapshot().revision == 1, "Physical tool input changed an exporting dataset")
  do { try await model.selectState(nil); throw EditingAutomationTestError(message: "Variant switched during export") }
  catch BorgVRVolumeEditingCommandError.busy {}
  do { try await model.duplicateState(empty: true); throw EditingAutomationTestError(message: "Variant created during export") }
  catch BorgVRVolumeEditingCommandError.busy {}
  do { try await model.discardVolumeEdits(); throw EditingAutomationTestError(message: "Edits discarded during export") }
  catch BorgVRVolumeEditingCommandError.busy {}
  try rejects("Concurrent dataset export accepted") {
    _ = try model.startVolumeExport(to: root.appendingPathComponent("concurrent.data"), name: nil, description: nil)
  }
  model.finishReadOnlyExport(id: UUID())
  try require(model.isExporting, "An unrelated export completion released the lock")
  model.finishReadOnlyExport(id: exportID)
  try require(!model.isExporting && model.canExport, "Completed export retained its admission lock")
  try await model.editVolume(mode: .restore, samples: samples)
  let failed = try model.startVolumeExport(to: root.appendingPathComponent("missing-directory/output.data"), name: nil, description: nil)
  do { _ = try await model.waitForVolumeExport(id: failed.id); throw EditingAutomationTestError(message: "Invalid export destination succeeded") }
  catch BorgVRVolumeEditingCommandError.exportFailed {}
  try require(model.canExport && !model.isExporting, "Failed export retained its admission lock")
  model.close()
  try await model.prepareOpening(datasetID: source.getMetadata().uniqueID, datasetURL: sourceURL, interactive: false)
}

@MainActor
private func testSharePlayCancelsExport(source: BORGVRDatasetProtocol, root: URL, leaveBeforeCompletion: Bool) async throws {
  let model = VolumeBrushModel()
  let paused = PausedEditExportSource(source)
  defer { paused.gate.signal(); model.close() }
  let sourceURL = root.appendingPathComponent("shareplay-export-\(leaveBeforeCompletion).data")
  _ = model.open(paused, datasetURL: sourceURL)
  try await model.waitForStateReady()
  try await model.duplicateState(name: "Personal state", empty: true)
  let personalID = model.activeState!.id
  let snapshot = try await model.stateSnapshot()
  let url = root.appendingPathComponent("interrupted-export-\(leaveBeforeCompletion).data")
  let job = try model.startVolumeExport(to: url, name: nil, description: nil)
  try await awaitEditingCondition("Export did not start reading", { paused.hasStarted })
  model.setSharePlayActive(true)
  try require(model.isExporting && model.exportJob?.status == .cancelling,
    "Joining SharePlay did not cancel the running export")
  do { _ = try model.beginReadOnlyExport(cancel: {}); throw EditingAutomationTestError(message: "Isosurface export allowed in SharePlay") }
  catch BorgVRVolumeEditingCommandError.exportUnavailableDuringSharePlay {}
  do {
    _ = try model.startVolumeExport(to: root.appendingPathComponent("forbidden.data"), name: nil, description: nil)
    throw EditingAutomationTestError(message: "Dataset export allowed in SharePlay")
  } catch BorgVRVolumeEditingCommandError.exportUnavailableDuringSharePlay {}
  let installation = Task { try await model.installSessionSnapshot(snapshot) }
  await Task.yield()
  try require(model.activeState?.id == personalID && model.isWaitingForSharedState,
    "Shared snapshot replaced the dataset while export was still reading")
  if leaveBeforeCompletion {
    model.setSharePlayActive(false)
    try require(model.isRestoringPersonalState, "Personal state restoration was not retained while export was cancelling")
  }
  paused.gate.signal()
  do { _ = try await model.waitForVolumeExport(id: job.id); throw EditingAutomationTestError(message: "SharePlay-interrupted export succeeded") }
  catch is CancellationError {}
  if leaveBeforeCompletion {
    do { try await installation.value; throw EditingAutomationTestError(message: "Stale shared snapshot was installed after leaving") }
    catch is CancellationError {}
  } else {
    try await installation.value
    try require(model.activeState?.kind == .sharePlay && !model.isWaitingForSharedState,
      "Join did not resume after the export worker finished")
    try require(!model.canExport, "Shared state offered dataset export")
    model.setSharePlayActive(false)
  }
  try await awaitEditingCondition("Personal edit state was not restored", {
    model.activeState?.id == personalID && !model.isOpeningState && !model.isRestoringPersonalState
  })
  try require(model.canExport && !FileManager.default.fileExists(atPath: url.path),
    "Cancelled export kept its lock or produced an output file")
  model.close()
  try await model.prepareOpening(datasetID: snapshot.datasetID, datasetURL: sourceURL, interactive: false)
}

@MainActor
private func testClosingDuringExport(source: BORGVRDatasetProtocol, root: URL) async throws {
  let model = VolumeBrushModel()
  let paused = PausedEditExportSource(source)
  defer { paused.gate.signal(); model.close() }
  let url = root.appendingPathComponent("closed-export-source.data")
  _ = model.open(paused, datasetURL: url)
  try await model.waitForStateReady()
  let output = root.appendingPathComponent("closed-export.data")
  _ = try model.startVolumeExport(to: output, name: nil, description: nil)
  try await awaitEditingCondition("Closing test never entered export", { paused.hasStarted })
  model.close()
  try require(model.isExporting, "Closing released the lock before its export worker stopped")
  _ = model.open(source, datasetURL: root.appendingPathComponent("next-dataset.data"))
  paused.gate.signal()
  try await model.waitForStateReady()
  try require(!model.isExporting && model.canExport, "Opening the next dataset kept the old export lock")
  try require(!FileManager.default.fileExists(atPath: output.path), "Closing during export published an incomplete file")
  model.close()
  try await model.prepareOpening(datasetID: source.getMetadata().uniqueID, datasetURL: url, interactive: false)
}
