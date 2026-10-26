import Foundation

private struct EditCollaborationFailure: Error { let message: String }
private func verify(_ value: Bool, _ message: String) throws {
  if !value { throw EditCollaborationFailure(message: message) }
}

@MainActor
private final class EditTransport {
  var peers: [UUID: BorgVRVolumeEditCollaboration] = [:]
  var dropCommitTo: UUID?
  var largestPacket = 0
  var warnings: [String] = []
  var activeSnapshots: [UUID: (id: String, chunks: Int)] = [:]
  var deliveredChunks = 0
  var largestTransferChunks = 0
  func sendWithFlowControl(_ data: Data, from source: UUID, to target: UUID?) async throws {
    await Task.yield()
    let fields = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    if let header = (fields?["snapshot"] as? [String: Any])?["_0"] as? [String: Any],
       let id = header["id"] as? String, let count = header["chunks"] as? Int {
      guard activeSnapshots[source] == nil else { throw EditCollaborationFailure(message: "Overlapping edit-state transfers") }
      activeSnapshots[source] = (id, count)
      largestTransferChunks = max(largestTransferChunks, count)
    }
    if let receipt = fields?["receipt"] as? [String: Any], receipt["_1"] as? Int == -2, let target {
      activeSnapshots[target] = nil
    }
    if let chunk = fields?["chunk"] as? [String: Any], let id = chunk["_0"] as? String, let index = chunk["_1"] as? Int {
      deliveredChunks += 1
      if let transfer = activeSnapshots[source], transfer.id == id, index + 1 == transfer.chunks { activeSnapshots[source] = nil }
    }
    send(data, from: source, to: target)
  }
  func send(_ data: Data, from source: UUID, to target: UUID?) {
    largestPacket = max(largestPacket, data.count)
    let isCommit = ((try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any])?["commit"] != nil
    for (id, peer) in peers where id != source && (target == nil || target == id) {
      if dropCommitTo == id && isCommit { dropCommitTo = nil; continue }
      peer.receive(data, from: source)
    }
  }
}

@MainActor
private func eventually(_ message: String, _ predicate: () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  while ContinuousClock.now < deadline {
    if try await predicate() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw EditCollaborationFailure(message: message)
}

private func equalMasks(_ a: BorgVRVolumeEditMask, _ b: BorgVRVolumeEditMask) -> Bool {
  guard a.size == b.size, a.spacing == b.spacing, a.componentCount == b.componentCount else { return false }
  for z in 0..<a.size.z { for y in 0..<a.size.y { for x in 0..<a.size.x {
    let low = SIMD3(x, y, z)
    for channel in 0..<a.componentCount {
      if a.isErased(at: low, component: channel) != b.isErased(at: low, component: channel) { return false }
    }
  } } }
  return true
}

@MainActor
func runVolumeEditCollaborationTests() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-edit-collaboration-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = try makeEditExportSource(EditTestDataset(bytesPerComponent: 2), compressed: true,
    url: root.appendingPathComponent("original.data"))
  let datasetID = source.getMetadata().uniqueID
  try await testUnannouncedDatasetDoesNotRequestEdits(source: source, root: root)
  try await testOpeningStateDeletionDuringSharePlay(source: source, root: root)
  try await testUntouchedSharePlay(source: source, root: root)
  let host = VolumeBrushModel(), client = VolumeBrushModel(), late = VolumeBrushModel()
  let hostURL = root.appendingPathComponent("host.data"), clientURL = root.appendingPathComponent("client.data")
  _ = host.open(source, datasetURL: hostURL)
  _ = client.open(source, datasetURL: clientURL)
  try await host.waitForStateReady(); try await client.waitForStateReady()
  try await host.editVolume(mode: .erase, samples: [.init(center: SIMD3(0.5, 1, 1), radius: 0.7)])
  try await client.editVolume(mode: .erase, samples: [.init(center: SIMD3(1.5, 2, 2), radius: 0.7)])
  try await eventually("Personal states not registered") { host.activeState != nil && client.activeState != nil }
  let hostPersonal = try await host.stateSnapshot(), clientPersonal = try await client.stateSnapshot()
  let hostPersonalID = host.activeState!.id, clientPersonalID = client.activeState!.id
  try verify(!equalMasks(hostPersonal.mask, clientPersonal.mask), "Test did not create distinct personal edits")

  // Checkpoint and reopen the host before sharing: no old brush history is needed.
  try await host.waitForVolumeEdits(timeout: 10)
  host.close()
  let chooseSavedState = Task { try await host.prepareOpening(datasetID: datasetID, datasetURL: hostURL) }
  try await eventually("Reopening did not offer saved edit states") { host.openingRequest != nil }
  host.completeOpeningSelection(id: host.openingRequest!.id, stateID: hostPersonalID)
  try await chooseSavedState.value
  let persisted = try VolumeBrushModel.catalog(datasetID: datasetID, datasetURL: hostURL)
  let persistedDirectory = try persisted.directory(for: hostPersonalID)
  try verify((try Data(contentsOf: persistedDirectory.appendingPathComponent("brush.journal"))).isEmpty,
    "Close did not checkpoint the journal")
  try FileManager.default.removeItem(at: persistedDirectory.appendingPathComponent("bricks.cache"))
  let reopened = host.open(source, datasetURL: hostURL)
  // Atlas construction can precede asynchronous edit-state activation. It then
  // has only the original overview and cannot generate requests until ready.
  let overview = source.allocateBrickBuffer()
  defer { overview.deallocate() }
  try reopened.getFirstBrick(outputBuffer: overview)
  try await host.waitForStateReady()
  try verify(host.volumeEditingState().pendingBrickCount == 0, "Opening preparation left unfinished edit bricks")
  try await eventually("Reopened edits never become renderable without render requests") { reopened.isContentReady }
  try reopened.getFirstBrick(outputBuffer: overview)
  let expectedOverview = try BorgVRCPUVolumeEditExecutor(source: source, border: .clamp).materialize(
    index: source.getMetadata().brickMetadata.count - 1, mask: hostPersonal.mask, revision: hostPersonal.revision)
  try verify(Array(UnsafeBufferPointer(start: overview, count: expectedOverview.bytes.count)) == expectedOverview.bytes,
    "Reopened overview does not contain the selected edits")
  try verify(equalMasks(try await host.stateSnapshot().mask, hostPersonal.mask), "Personal edits did not survive reopen")
  try await host.prepareVolumeEdits()
  let cancelledPreparation = Task { try await host.prepareVolumeEdits() }
  cancelledPreparation.cancel()
  do { try await cancelledPreparation.value; throw EditCollaborationFailure(message: "Cancelled preparation succeeded") }
  catch is CancellationError {}
  try verify(equalMasks(try await host.stateSnapshot().mask, hostPersonal.mask), "Cancelling preparation changed the edits")

  let transport = EditTransport()
  let hostID = UUID(), clientID = UUID(), lateID = UUID()
  let h = BorgVRVolumeEditCollaboration(model: host, send: { transport.send($0, from: hostID, to: $1) }, log: { transport.warnings.append($0) })
  let c = BorgVRVolumeEditCollaboration(model: client, send: { transport.send($0, from: clientID, to: $1) }, log: { transport.warnings.append($0) })
  let l = BorgVRVolumeEditCollaboration(model: late, send: { transport.send($0, from: lateID, to: $1) }, log: { transport.warnings.append($0) })
  transport.peers = [hostID: h, clientID: c]
  defer { h.stop(); c.stop(); l.stop(); host.close(); client.close(); late.close() }
  h.configure(localID: hostID, hostID: hostID, datasetID: datasetID, participants: [hostID, clientID])
  c.configure(localID: clientID, hostID: hostID, datasetID: datasetID, participants: [hostID, clientID])
  await h.sendSnapshot(to: clientID)
  try await eventually("Initial snapshot never installed") {
    guard client.activeState?.kind == .sharePlay, !client.isOpeningState else { return false }
    return equalMasks(try await host.stateSnapshot().mask, try await client.stateSnapshot().mask)
  }
  try verify(host.activeState?.id != hostPersonalID && client.activeState?.id != clientPersonalID, "SharePlay overwrote personal state")

  // MCP and GSC both call this command interface, not just the disabled UI.
  func rejectsSharedStateChange(_ operation: () async throws -> Void) async throws {
    do {
      try await operation()
      throw EditCollaborationFailure(message: "State management was allowed during SharePlay")
    } catch BorgVRVolumeEditingCommandError.busy {}
  }
  for (model, privateID) in [(host, hostPersonalID), (client, clientPersonalID)] {
    let commands: any BorgVRVolumeEditingCommands = model
    let sharedID = model.activeState?.id
    let savedIDs = Set(model.states.map(\.id))
    try await rejectsSharedStateChange { try await commands.selectState(nil) }
    try await rejectsSharedStateChange { try await commands.selectState(privateID) }
    try await rejectsSharedStateChange { try await commands.duplicateState(name: "Blocked", empty: true) }
    try await rejectsSharedStateChange { try await commands.duplicateState(name: "Blocked", empty: false) }
    try await rejectsSharedStateChange { try commands.renameState(privateID, name: "Blocked") }
    try await rejectsSharedStateChange { try commands.deleteState(privateID) }
    try verify(model.activeState?.id == sharedID && Set(model.states.map(\.id)) == savedIDs,
      "Rejected command changed the shared state or its catalog")
  }

  try host.setVolumeBrushChannels(.selected([0]))
  try client.setVolumeBrushChannels(.selected([1]))
  let first = Task { try await host.editVolume(mode: .erase, samples: [.init(center: SIMD3(1, 1, 1), radius: 0.8)]) }
  let second = Task { try await client.editVolume(mode: .restore, samples: [.init(center: SIMD3(0.8, 1, 1), radius: 0.4)]) }
  try await first.value; try await second.value
  try await eventually("Concurrent edits diverged") {
    let a = try await host.stateSnapshot(), b = try await client.stateSnapshot()
    return a.revision == b.revision && equalMasks(a.mask, b.mask)
  }
  try verify(host.channels == .selected([0]) && client.channels == .selected([1]), "Peer changed local channel selection")
  let sharedMask = try await host.stateSnapshot().mask
  try verify(sharedMask.isErased(at: SIMD3(4, 1, 0), component: 0) &&
    !sharedMask.isErased(at: SIMD3(4, 1, 0), component: 1), "Shared operation lost its channel selection")

  client.context.showPreview(at: SIMD3(0.3, 0.4, 0.5), source: "test", mode: .restore)
  try await eventually("Remote restore cursor missing") { host.context.previewMarkers().count == 1 }
  client.context.finish(source: "test")
  try await eventually("Remote cursor did not disappear") { host.context.previewMarkers().isEmpty }

  // A missed commit causes snapshot recovery rather than silently applying a gap.
  transport.dropCommitTo = clientID
  try await host.editVolume(mode: .erase, samples: [.init(center: SIMD3(1.2, 1.5, 1.2), radius: 0.4)])
  try await host.editVolume(mode: .restore, samples: [.init(center: SIMD3(1, 1, 1), radius: 0.2)])
  try await eventually("Revision gap was not recovered") {
    guard !client.isOpeningState else { return false }
    let a = try await host.stateSnapshot(), b = try await client.stateSnapshot()
    return a.revision == b.revision && equalMasks(a.mask, b.mask)
  }

  // Snapshot may arrive before the original volume is available on a late joiner.
  transport.peers[lateID] = l
  l.configure(localID: lateID, hostID: hostID, datasetID: datasetID, participants: [hostID, clientID, lateID])
  await h.sendSnapshot(to: lateID)
  _ = late.open(source, datasetURL: root.appendingPathComponent("late.data"))
  try await eventually("Late join did not use the current mask") {
    guard late.activeState?.kind == .sharePlay, !late.isOpeningState else { return false }
    let a = try await host.stateSnapshot(), b = try await late.stateSnapshot()
    return a.revision == b.revision && equalMasks(a.mask, b.mask)
  }
  try verify(transport.largestPacket <= 64 * 1024, "SharePlay edit message exceeds chunk limit")

  // Reloading the same dataset replaces its edit source, not the wire epoch.
  // Even a revision-0 snapshot must be installed again for that fresh source.
  let beforeReload = try await client.stateSnapshot()
  _ = client.open(source, datasetURL: clientURL)
  try await eventually("Reloading a joined dataset remained stuck in edit synchronization") {
    !client.isOpeningState && !client.isWaitingForSharedState && client.activeState?.kind == .sharePlay
  }
  try verify(equalMasks(try await client.stateSnapshot().mask, beforeReload.mask), "Reload lost the shared mask")

  // Authority changes continue the shared state, never the new host's private edits.
  let beforeTakeover = try await client.stateSnapshot()
  h.stop()
  transport.peers[hostID] = nil
  c.configure(localID: clientID, hostID: clientID, datasetID: datasetID, participants: [clientID, lateID])
  l.configure(localID: lateID, hostID: clientID, datasetID: datasetID, participants: [clientID, lateID])
  await c.sendSnapshot(to: lateID)
  try await eventually("Host takeover lost the shared state") {
    guard !client.isOpeningState, !late.isOpeningState else { return false }
    let a = try await client.stateSnapshot(), b = try await late.stateSnapshot()
    return a.stateID == b.stateID && equalMasks(a.mask, beforeTakeover.mask) && equalMasks(a.mask, b.mask)
  }
  try await late.editVolume(mode: .erase, samples: [.init(center: SIMD3(0.3, 0.5, 0.5), radius: 0.2)])
  try await eventually("Editing after host takeover failed") {
    let a = try await client.stateSnapshot(), b = try await late.stateSnapshot()
    return a.revision == b.revision && equalMasks(a.mask, b.mask)
  }

  let hostCatalog = try VolumeBrushModel.catalog(datasetID: datasetID, datasetURL: hostURL)
  let clientCatalog = try VolumeBrushModel.catalog(datasetID: datasetID, datasetURL: clientURL)
  for (catalog, id, personal) in [(hostCatalog, hostPersonalID, hostPersonal), (clientCatalog, clientPersonalID, clientPersonal)] {
    let journal = try BorgVRVolumeEditJournal(directory: catalog.directory(for: id), datasetID: datasetID,
      size: personal.mask.size, spacing: personal.mask.spacing, componentCount: personal.mask.componentCount)
    try verify(equalMasks(journal.snapshot().mask, personal.mask), "Personal sidecar was modified by the session")
    try journal.closeStorage()
  }

  h.stop(); c.stop(); l.stop()
  try await eventually("Leaving did not restore personal selection") {
    host.activeState?.id == hostPersonalID && client.activeState?.id == clientPersonalID && !host.isOpeningState && !client.isOpeningState
  }
  try verify(equalMasks(try await host.stateSnapshot().mask, hostPersonal.mask), "Host's personal state changed")
  try verify(equalMasks(try await client.stateSnapshot().mask, clientPersonal.mask), "Client's personal state changed")
  let shared = try hostCatalog.states().first { $0.kind == .sharePlay }
  try verify(shared != nil, "Shared work was not retained after leaving")
  try await host.duplicateState(name: "Test copy")
  let copyID = host.activeState!.id
  try host.renameState(copyID, name: "Renamed")
  try verify(host.activeState?.name == "Renamed", "Rename was not persisted")
  try await host.selectState(nil)
  try host.deleteState(copyID)
  try verify(!(try hostCatalog.states()).contains { $0.id == copyID }, "Deleted state still listed")
  try verify((try hostCatalog.states()).contains { $0.id == hostPersonalID }, "Deleting one state removed another")
  try await host.duplicateState(name: "Explicit empty variant", empty: true)
  let emptyID = host.activeState!.id
  try host.renameState(emptyID, name: "Named empty variant")
  try verify((try hostCatalog.states()).contains { $0.id == emptyID && $0.name == "Named empty variant" },
    "Deliberately creating an empty named variant no longer persists it")
  try await host.selectState(nil)
  try host.deleteState(emptyID)
  try await host.editVolume(mode: .erase, samples: [.init(center: SIMD3(0.5, 0.5, 0.5), radius: 0.2)])
  try await host.discardVolumeEdits()
  try await host.editVolume(mode: .erase, samples: [.init(center: SIMD3(0.5, 0.5, 0.5), radius: 0.2)])
  try await eventually("New edits after discard were not cataloged") { host.activeState != nil && host.states.contains { $0.id == host.activeState?.id } }
  let selectedBeforeDialog = host.activeState?.id
  let opening = Task { try await host.prepareOpening(datasetID: datasetID, datasetURL: hostURL) }
  try await eventually("Saved states did not trigger selection") { host.openingRequest != nil }
  let requestID = host.openingRequest!.id
  host.cancelOpeningSelection(id: requestID)
  do { try await opening.value; throw EditCollaborationFailure(message: "Cancelled state selection succeeded") }
  catch is CancellationError {}
  try verify(host.activeState?.id == selectedBeforeDialog, "Cancel changed the active state")

  print("Volume edit collaboration and state catalog tests passed")
  try await testHeadEditInitialization(root: root)
}

@MainActor
private func testUnannouncedDatasetDoesNotRequestEdits(source: BORGVRDatasetProtocol, root: URL) async throws {
  let model = VolumeBrushModel()
  var attempts = 0
  var warnings: [String] = []
  let collaboration = BorgVRVolumeEditCollaboration(model: model,
    send: { _, _ in attempts += 1; throw CancellationError() },
    log: { warnings.append($0) }, info: { _ in })
  defer { collaboration.stop(); model.close() }
  let localID = UUID(), hostID = UUID()
  collaboration.configure(localID: localID, hostID: hostID, datasetID: nil)
  for _ in 0..<20 { await Task.yield() }
  try verify(attempts == 0 && warnings.isEmpty,
    "Edit synchronization started before any dataset was announced: \(warnings)")
  _ = model.open(source, datasetURL: root.appendingPathComponent("unannounced-client.data"))
  try await model.waitForStateReady()
  collaboration.configure(localID: localID, hostID: hostID, datasetID: source.getMetadata().uniqueID)
  try await eventually("Loaded dataset never requested its shared edit state") { attempts == 1 }
  try verify(warnings.isEmpty, "Normal transport cancellation was logged as a failure: \(warnings)")
}

@MainActor
private func testOpeningStateDeletionDuringSharePlay(source: BORGVRDatasetProtocol, root: URL) async throws {
  let model = VolumeBrushModel()
  defer { model.close() }
  let datasetID = source.getMetadata().uniqueID
  let url = root.appendingPathComponent("opening-state-deletion.data")
  _ = model.open(source, datasetURL: url)
  try await model.waitForStateReady()
  try await model.duplicateState(name: "Unused variant", empty: true)
  let unusedID = model.activeState!.id
  try await model.duplicateState(name: "Active variant", empty: true)
  let activeID = model.activeState!.id
  let catalog = try VolumeBrushModel.catalog(datasetID: datasetID, datasetURL: url)
  model.isSharePlayHost = true
  model.setSharePlayActive(true)

  let opening = Task { try await model.prepareOpening(datasetID: datasetID, datasetURL: url) }
  try await eventually("Host did not receive the opening-state selection") { model.openingRequest != nil }
  let requestID = model.openingRequest!.id
  try verify(model.canDeleteOpeningState(unusedID, requestID: requestID), "SharePlay host cannot delete an unused opening variant")
  try verify(!model.canDeleteOpeningState(activeID, requestID: requestID), "Active variant became deletable")
  do {
    try model.deleteOpeningState(activeID, requestID: requestID)
    throw EditCollaborationFailure(message: "Host deleted the active variant")
  } catch BorgVRVolumeEditingCommandError.busy {}
  do {
    try model.deleteOpeningState(unusedID, requestID: UUID())
    throw EditCollaborationFailure(message: "Stale opening dialog deleted a variant")
  } catch BorgVRVolumeEditingCommandError.busy {}
  try model.deleteOpeningState(unusedID, requestID: requestID)
  try verify(!(try catalog.states()).contains { $0.id == unusedID }, "Host deletion did not remove the variant")
  try verify((try catalog.states()).contains { $0.id == activeID } && model.activeState?.id == activeID,
    "Deleting an unused opening variant changed the active state")
  model.isSharePlayHost = false
  try verify(model.openingRequest == nil, "Losing host authority left its opening dialog active")
  do { try await opening.value; throw EditCollaborationFailure(message: "Client retained host opening authority") }
  catch is CancellationError {}
  try verify(!model.canDeleteOpeningState(activeID, requestID: requestID), "Client retained delete permission")
  do {
    try model.deleteOpeningState(activeID, requestID: requestID)
    throw EditCollaborationFailure(message: "Client deleted a saved variant")
  } catch BorgVRVolumeEditingCommandError.busy {}

  model.close()
  model.isSharePlayHost = true
  let reopen = Task { try await model.prepareOpening(datasetID: datasetID, datasetURL: url) }
  try await eventually("Host could not reopen the edit-state selection") { model.openingRequest != nil }
  let newRequestID = model.openingRequest!.id
  try verify(model.canDeleteOpeningState(activeID, requestID: newRequestID), "Closed variant remained incorrectly protected")
  try model.deleteOpeningState(activeID, requestID: newRequestID)
  model.completeOpeningSelection(id: newRequestID, stateID: nil)
  try await reopen.value
  try verify(try catalog.states().isEmpty, "Deleting the final opening variant failed")
}

@MainActor
private func testUntouchedSharePlay(source: BORGVRDatasetProtocol, root: URL) async throws {
  let datasetID = source.getMetadata().uniqueID
  for editAfterJoin in [false, true] {
    let host = VolumeBrushModel(), client = VolumeBrushModel()
    let hostURL = root.appendingPathComponent("untouched-host-\(editAfterJoin).data")
    let clientURL = root.appendingPathComponent("untouched-client-\(editAfterJoin).data")
    _ = host.open(source, datasetURL: hostURL)
    _ = client.open(source, datasetURL: clientURL)
    try await host.waitForStateReady(); try await client.waitForStateReady()
    let transport = EditTransport()
    let hostID = UUID(), clientID = UUID()
    let h = BorgVRVolumeEditCollaboration(model: host,
      send: { transport.send($0, from: hostID, to: $1) }, log: { transport.warnings.append($0) }, info: { _ in })
    let c = BorgVRVolumeEditCollaboration(model: client,
      send: { transport.send($0, from: clientID, to: $1) }, log: { transport.warnings.append($0) }, info: { _ in })
    transport.peers = [hostID: h, clientID: c]
    defer { h.stop(); c.stop(); host.close(); client.close() }
    h.configure(localID: hostID, hostID: hostID, datasetID: datasetID, participants: [hostID, clientID])
    c.configure(localID: clientID, hostID: hostID, datasetID: datasetID, participants: [hostID, clientID])
    await h.sendSnapshot(to: clientID)
    try await eventually("Untouched SharePlay initialization failed") {
      !host.isWaitingForSharedState && !client.isWaitingForSharedState &&
        !host.isOpeningState && !client.isOpeningState
    }
    let snapshot = try await host.stateSnapshot()
    let received = try await client.stateSnapshot()
    try verify(snapshot.stateID == received.stateID && snapshot.revision == received.revision && received.mask.isOriginal,
      "Untouched SharePlay peers have different epochs")
    // Replacing an in-memory state must not try deleting a nonexistent variant.
    try await client.installSessionSnapshot(snapshot)
    for (model, url) in [(host, hostURL), (client, clientURL)] {
      try verify(!FileManager.default.fileExists(atPath: url.appendingPathExtension("edits").path),
        "SharePlay without edits created a sidecar directory")
      try verify(model.states.isEmpty, "SharePlay without edits created a saved variant")
    }
    if editAfterJoin {
      try await client.editVolume(mode: .erase, samples: [.init(center: SIMD3(1, 1, 1), radius: 0.8)])
      try await eventually("First shared edit did not register saved variants on both peers") {
        !host.states.isEmpty && !client.states.isEmpty
      }
      let a = try await host.stateSnapshot(), b = try await client.stateSnapshot()
      try verify(a.stateID == snapshot.stateID && a.revision == 1 && b.revision == 1 &&
        !a.mask.isOriginal && equalMasks(a.mask, b.mask), "First shared brush lost its transient epoch or edit")
      for (model, url) in [(host, hostURL), (client, clientURL)] {
        let catalog = try VolumeBrushModel.catalog(datasetID: datasetID, datasetURL: url)
        try verify(try catalog.states().count == 1 && model.states.count == 1,
          "First shared edit did not persist exactly one variant")
      }
    }
    try verify(transport.warnings.isEmpty, "Untouched session logged errors: \(transport.warnings)")
    h.stop(); c.stop()
    try await eventually("Leaving SharePlay did not restore the original state") {
      host.activeState == nil && client.activeState == nil && !host.isOpeningState && !client.isOpeningState
    }
    host.close(); client.close()
    try await host.prepareOpening(datasetID: datasetID, datasetURL: hostURL, interactive: false)
    try await client.prepareOpening(datasetID: datasetID, datasetURL: clientURL, interactive: false)
    if !editAfterJoin {
      try verify(!FileManager.default.fileExists(atPath: hostURL.appendingPathExtension("edits").path) &&
        !FileManager.default.fileExists(atPath: clientURL.appendingPathExtension("edits").path),
        "Closing an untouched shared session created sidecar storage")
    }
  }
}

@MainActor
private func testHeadEditInitialization(root: URL) async throws {
  let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("head_32.data")
  let source = try BORGVRFileData(filename: file.path)
  let m = source.getMetadata()
  let host = VolumeBrushModel(), client = VolumeBrushModel()
  let transport = EditTransport(), hostID = UUID(), clientID = UUID()
  _ = host.open(source, datasetURL: root.appendingPathComponent("head-host.data"))
  try await host.waitForStateReady()
  let extent = SIMD3(Double(m.width) * Double(m.voxelSpacingX), Double(m.height) * Double(m.voxelSpacingY), Double(m.depth) * Double(m.voxelSpacingZ))
  let radius = max(extent.x, extent.y, extent.z) * 0.03
  for offset in [0.35, 0.5, 0.65] {
    try await host.editVolume(mode: .erase, samples: [.init(center: extent * SIMD3(offset, 0.5, 0.5), radius: radius)])
  }
  // A few compact spheres fit in one chunk. Add a more complex real mask to
  // retain multi-chunk flow-control coverage with the smaller representation.
  var seed: UInt64 = 42
  func random() -> Double {
    seed = seed &* 6364136223846793005 &+ 1
    return Double(seed >> 32) / Double(UInt32.max)
  }
  let samples = (0..<64).map { _ in
    BorgVRVolumeBrushSample(center: extent * SIMD3(0.15 + random() * 0.7, 0.15 + random() * 0.7, 0.15 + random() * 0.7),
      radius: max(extent.x, extent.y, extent.z) * (0.025 + random() * 0.025))
  }
  try await host.editVolume(mode: .erase, samples: samples)
  let original = try await host.stateSnapshot()
  let h = BorgVRVolumeEditCollaboration(model: host, send: { try await transport.sendWithFlowControl($0, from: hostID, to: $1) },
    log: { transport.warnings.append($0) })
  let c = BorgVRVolumeEditCollaboration(model: client, send: { try await transport.sendWithFlowControl($0, from: clientID, to: $1) },
    log: { transport.warnings.append($0) })
  defer { h.stop(); c.stop(); host.close(); client.close() }
  transport.peers = [hostID: h, clientID: c]
  h.configure(localID: hostID, hostID: hostID, datasetID: m.uniqueID, participants: [hostID, clientID])
  c.configure(localID: clientID, hostID: hostID, datasetID: m.uniqueID, participants: [hostID, clientID])
  // Initial-state broadcast, explicit join reply and request may race in the real apps.
  let first = Task { await h.sendSnapshot(to: clientID) }
  let second = Task { await h.sendSnapshot(to: clientID) }
  await first.value; await second.value
  _ = client.open(source, datasetURL: root.appendingPathComponent("head-client.data"))
  try await eventually("Head edit initialization remained stuck") {
    !client.isOpeningState && !client.isWaitingForSharedState && client.activeState?.kind == .sharePlay
  }
  let received = try await client.stateSnapshot()
  // Tree encoding is deterministic and avoids scanning the entire Head voxel grid.
  try verify(original.mask.computeNodes() == received.mask.computeNodes(), "Head edit mask changed during transfer")
  try verify(transport.largestTransferChunks > 1, "Head test did not exercise a multi-chunk mask")
  try verify(!transport.warnings.contains { $0.hasPrefix("Could not send") || $0.hasPrefix("Invalid edit") },
    "Head transfer required error recovery: \(transport.warnings)")
  try verify(transport.largestPacket < 20 * 1024, "Edit-state message exceeded the bounded chunk size")
  let delivered = transport.deliveredChunks
  await h.sendSnapshot(to: clientID)
  try verify(transport.deliveredChunks == delivered, "An already installed edit state was retransmitted")
  // Head initializes at revision zero; reloading must not mistake that for ready.
  _ = client.open(source, datasetURL: root.appendingPathComponent("head-client.data"))
  try await eventually("Head revision-zero reload remained stuck") {
    !client.isOpeningState && !client.isWaitingForSharedState && client.activeState?.kind == .sharePlay
  }
  try verify(try await client.stateSnapshot().mask.computeNodes() == original.mask.computeNodes(), "Revision-zero reload lost Head edits")
  print("Head edit initialization with asynchronous, coalesced transport passed (\(transport.largestTransferChunks) chunks)")
}
