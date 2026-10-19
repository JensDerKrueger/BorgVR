import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): message
    }
  }
}

private func expect(
  _ condition: @autoclosure () -> Bool,
  _ message: String
) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func expectThrows(
  _ message: String,
  _ operation: () throws -> Void
) throws {
  do {
    try operation()
    throw TestFailure.failed(message)
  } catch is TestFailure {
    throw TestFailure.failed(message)
  } catch {}
}

private func testVersionAndWireCodecs() throws {
  let version = BorgVRSemanticVersion(major: 3, minor: 1, patch: 4)
  let decodedVersion = try BorgVRSharePlayVersionCodec.decode(
    BorgVRSharePlayVersionCodec.encode(version)
  )
  try expect(
    decodedVersion == version,
    "Protocol-version roundtrip failed"
  )
  try expectThrows("Trailing protocol-version bytes were accepted") {
    var data = BorgVRSharePlayVersionCodec.encode(version)
    data.append(0)
    _ = try BorgVRSharePlayVersionCodec.decode(data)
  }

  let stateVersion = BorgVRSharePlayStateVersion(
    sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
    revision: 7
  )
  let payload = Data([1, 2, 3, 4])
  let encoded = try BorgVRSharePlayWireCodec.encode(
    payload,
    type: .renderingUpdate,
    stateVersion: stateVersion
  )
  let decoded = try BorgVRSharePlayWireCodec.decode(encoded)
  try expect(decoded.type == .renderingUpdate, "Wire message type changed")
  try expect(decoded.stateVersion == stateVersion, "Wire state version changed")
  try expect(decoded.payload == payload, "Wire payload changed")

  try expectThrows("A stateful message without a state version was accepted") {
    _ = try BorgVRSharePlayWireCodec.encode(
      payload,
      type: .initMessage,
      stateVersion: nil
    )
  }

  let request = try BorgVRSharePlayWireCodec.encode(
    payload,
    type: .stateRequest,
    stateVersion: nil
  )
  let decodedRequest = try BorgVRSharePlayWireCodec.decode(request)
  try expect(decodedRequest.stateVersion == nil, "Stateless message gained a version")
  try expect(decodedRequest.payload == payload, "Stateless payload changed")
}

private func testHandshakeAndStateInitialization() throws {
  let hostID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  let clientID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
  var host = BorgVRSharePlaySessionEngine()
  host.beginSession(
    localParticipantID: hostID,
    activeParticipantIDs: [hostID, clientID],
    isHost: true,
    datasetID: "dataset-a"
  )
  try expect(host.isLocalHost, "Host did not retain its role")
  guard let hostVersion = host.stateVersion else {
    throw TestFailure.failed("Host did not create a state version")
  }
  try expect(
    host.acceptStateVersion(
      BorgVRSharePlayStateVersion(),
      for: .renderingUpdate,
      from: clientID
    ) == .sendInitialState,
    "Host did not answer an unknown state version with initial state"
  )

  let versionData = BorgVRSharePlayVersionCodec.encode()
  switch try host.receiveProtocolVersion(versionData, from: clientID) {
    case .accepted: break
    default: throw TestFailure.failed("Compatible participant was rejected")
  }
  try expect(host.acceptsMessages(from: clientID), "Handshake was not retained")
  switch try host.receiveProtocolVersion(versionData, from: clientID) {
    case .alreadyAccepted: break
    default: throw TestFailure.failed("Repeated handshake was not idempotent")
  }

  var client = BorgVRSharePlaySessionEngine()
  client.beginSession(
    localParticipantID: clientID,
    activeParticipantIDs: [hostID, clientID],
    isHost: false,
    datasetID: nil
  )
  try expect(
    client.acceptStateVersion(
      hostVersion,
      for: .renderingUpdate,
      from: hostID
    ) == .requestInitialState,
    "Client accepted an update before its initial state"
  )
  try expect(
    client.acceptStateVersion(
      hostVersion,
      for: .renderingUpdate,
      from: hostID
    ) == .reject,
    "Client repeated an initial-state request for the same version"
  )
  try expect(
    client.acceptStateVersion(
      hostVersion,
      for: .initMessage,
      from: hostID
    ) == .accept,
    "Client rejected the matching initial state"
  )
  try expect(
    client.acceptStateVersion(
      hostVersion,
      for: .renderingUpdate,
      from: hostID
    ) == .accept,
    "Client rejected an update after applying initial state"
  )
}

private func testHostElectionAndParticipantCleanup() throws {
  let localID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
  let lowerID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
  let higherID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
  var engine = BorgVRSharePlaySessionEngine()
  engine.beginSession(
    localParticipantID: localID,
    activeParticipantIDs: [localID, lowerID, higherID],
    isHost: false,
    datasetID: nil
  )
  _ = engine.registerHostClaim(.init(term: 0, candidateID: higherID))
  _ = engine.registerHostClaim(.init(term: 0, candidateID: lowerID))
  guard let transition = engine.resolveHostElection(term: 0) else {
    throw TestFailure.failed("Host election did not resolve")
  }
  try expect(transition.hostID == lowerID, "Host election was not deterministic")

  _ = engine.setParticipantInfo(
    .init(platform: .macOS, displayName: "Remote", sharesScreenView: true),
    for: lowerID
  )
  let change = engine.updateActiveParticipants([localID, higherID])
  try expect(change.departedIDs == [lowerID], "Departed participant was not reported")
  try expect(change.hostDeparted, "Host departure was not reported")
  try expect(engine.participants.allSatisfy { $0.id != lowerID }, "Participant metadata leaked")
}

private func testOriginsAndDatasetAnnouncement() throws {
  let participantID = UUID()
  let originA = DatasetOrigin(address: "host-a", port: 1234, password: "")
  let originB = DatasetOrigin(address: "host-b", port: 5678, password: "secret")
  var engine = BorgVRSharePlaySessionEngine()
  engine.beginSession(
    localParticipantID: UUID(),
    activeParticipantIDs: [participantID],
    isHost: false,
    datasetID: nil
  )
  engine.mergeSessionOrigins([originA, originA], for: "dataset")
  engine.setAdvertisedOrigins([originB], for: "dataset", participantID: participantID)
  try expect(
    Set(engine.knownSessionOrigins(for: "dataset")) == [originA, originB],
    "Session origins were not merged and deduplicated"
  )
  _ = engine.updateActiveParticipants([])
  try expect(
    engine.knownSessionOrigins(for: "dataset") == [originA],
    "Departed participant origins were not removed"
  )

  let announcement = BorgVRSharePlayDatasetAnnouncement(
    uniqueID: "dataset",
    origins: [originA, originB],
    description: "Dataset description"
  )
  guard let decoded = BorgVRSharePlayDatasetAnnouncement(data: announcement.encoded()) else {
    throw TestFailure.failed("Dataset announcement did not decode")
  }
  try expect(decoded.uniqueID == announcement.uniqueID, "Dataset ID changed")
  try expect(decoded.origins == announcement.origins, "Dataset origins changed")
  try expect(decoded.description == announcement.description, "Dataset description changed")

  var malformed = announcement.encoded()
  malformed.removeLast()
  try expect(
    BorgVRSharePlayDatasetAnnouncement(data: malformed) == nil,
    "Truncated dataset announcement was accepted"
  )
}

private func testDatasetOriginCatalogPersistenceAndPrivacy() throws {
  let suiteName = "borgvr-origin-tests-\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    throw TestFailure.failed("Could not create isolated UserDefaults")
  }
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let publicOrigin = DatasetOrigin(address: "public.example", port: 1234, password: "")
  let privateOrigin = DatasetOrigin(address: "private.example", port: 4321, password: "secret")
  let remoteOrigin = DatasetOrigin(address: "remote.example", port: 9876, password: "remote")
  let catalog = DatasetOriginCatalog(defaults: defaults)
  catalog.recordServerSnapshot(
    origin: publicOrigin,
    datasetIDs: ["a", "b"],
    allowsSharing: true
  )
  catalog.record(origin: privateOrigin, for: "a", allowsSharing: false)
  try expect(
    catalog.origins(for: "a") == [privateOrigin, publicOrigin],
    "Origin recency order is incorrect"
  )
  try expect(
    catalog.shareableOrigins(for: "a") == [publicOrigin],
    "Private credentials leaked into shareable origins"
  )

  catalog.mergeRemoteSnapshot(.init(entries: [
    .init(origin: remoteOrigin, datasetIDs: ["a"])
  ]))
  try expect(
    catalog.origins(for: "a").first == remoteOrigin,
    "Remote snapshot was not prioritized"
  )
  try expect(
    !catalog.sharingAllowed(for: remoteOrigin),
    "Remotely learned credentials became shareable"
  )

  let reloaded = DatasetOriginCatalog(defaults: defaults)
  try expect(
    reloaded.origins(for: "a") == catalog.origins(for: "a"),
    "Origin catalog did not persist"
  )
  catalog.recordServerSnapshot(
    origin: publicOrigin,
    datasetIDs: ["b"],
    allowsSharing: true
  )
  try expect(
    !catalog.origins(for: "a").contains(publicOrigin),
    "A stale server dataset entry survived a catalog refresh"
  )
}

@main
private enum SharePlaySessionEngineTestRunner {
  static func main() throws {
    try testVersionAndWireCodecs()
    try testHandshakeAndStateInitialization()
    try testHostElectionAndParticipantCleanup()
    try testOriginsAndDatasetAnnouncement()
    try testDatasetOriginCatalogPersistenceAndPrivacy()
    print("SharePlay protocol and session-engine tests passed")
  }
}
