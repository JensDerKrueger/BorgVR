import Foundation

struct BorgVRSharePlayWireMessage: Sendable {
  let type: BorgVRSharePlayProtocol.MessageType
  let stateVersion: BorgVRSharePlayStateVersion?
  let payload: Data
}

enum BorgVRSharePlayWireError: Error {
  case emptyMessage
  case invalidMessageType(UInt8)
}

enum BorgVRSharePlayWireCodec {
  static func encode(
    _ payload: Data,
    type: BorgVRSharePlayProtocol.MessageType,
    stateVersion: BorgVRSharePlayStateVersion?
  ) throws -> Data {
    let encodedPayload: Data
    if type.carriesStateVersion {
      guard let stateVersion else {
        throw BorgVRSharePlayProtocolError.missingStateVersion
      }
      encodedPayload = BorgVRSharePlayStateEnvelopeCodec.encode(
        payload,
        version: stateVersion
      )
    } else {
      encodedPayload = payload
    }
    return Data([type.rawValue]) + encodedPayload
  }

  static func decode(_ data: Data) throws -> BorgVRSharePlayWireMessage {
    guard let firstByte = data.first else {
      throw BorgVRSharePlayWireError.emptyMessage
    }
    guard let type = BorgVRSharePlayProtocol.MessageType(rawValue: firstByte) else {
      throw BorgVRSharePlayWireError.invalidMessageType(firstByte)
    }

    let encodedPayload = Data(data.dropFirst())
    guard type.carriesStateVersion else {
      return BorgVRSharePlayWireMessage(
        type: type,
        stateVersion: nil,
        payload: encodedPayload
      )
    }

    let envelope = try BorgVRSharePlayStateEnvelopeCodec.decode(encodedPayload)
    return BorgVRSharePlayWireMessage(
      type: type,
      stateVersion: envelope.version,
      payload: envelope.payload
    )
  }
}

enum BorgVRSharePlayCommonUpdate {
  case spatialToolPreviews([SpatialToolPreview])
  case annotations(VolumeMarkerSharePlayContents)
  case measurements([VolumeMeasurement])
  case screenView(BorgVRScreenViewUpdate)
}

enum BorgVRSharePlayCommonUpdateDecoder {
  static func decode(_ data: Data) throws -> BorgVRSharePlayCommonUpdate? {
    if let previews = try SpatialToolPreviewSharePlayCodec.decodeIfPresent(data) {
      return .spatialToolPreviews(previews)
    }
    if let annotations = try VolumeMarkerSharePlayCodec.decodeIfPresent(data) {
      return .annotations(annotations)
    }
    if let measurements = try VolumeMeasurementSharePlayCodec.decodeIfPresent(data) {
      return .measurements(measurements)
    }
    if let screenView = try BorgVRScreenViewStateCodec.decodeUpdateIfPresent(data) {
      return .screenView(screenView)
    }
    return nil
  }
}

struct BorgVRSharePlayPendingSynchronization {
  struct Batch: Sendable {
    let commonState: Bool
    let transferFunction: Bool
    let transform: Bool
    let annotations: Bool
    let measurements: Bool
  }

  private(set) var commonState = false
  private(set) var transferFunction = false
  private(set) var transform = false
  private(set) var annotations = false
  private(set) var measurements = false

  var preferredDelayNanoseconds: UInt64 {
    transferFunction ? 200_000_000 : 50_000_000
  }

  mutating func markCommonState(includeTransferFunction: Bool) {
    commonState = true
    transferFunction = transferFunction || includeTransferFunction
  }

  mutating func markTransform() {
    transform = true
  }

  mutating func clearTransform() {
    transform = false
  }

  mutating func markAnnotations() {
    annotations = true
  }

  mutating func markMeasurements() {
    measurements = true
  }

  mutating func takeBatch() -> Batch {
    let batch = Batch(
      commonState: commonState,
      transferFunction: transferFunction,
      transform: transform,
      annotations: annotations,
      measurements: measurements
    )
    reset()
    return batch
  }

  mutating func reset() {
    commonState = false
    transferFunction = false
    transform = false
    annotations = false
    measurements = false
  }
}

struct BorgVRSharePlaySessionEngine {
  struct ParticipantChange: Sendable {
    let joinedIDs: Set<UUID>
    let departedIDs: Set<UUID>
    let hostDeparted: Bool
  }

  struct HostTransition: Sendable {
    let previousHostID: UUID?
    let hostID: UUID
    let isLocalHost: Bool
  }

  enum StateVersionDecision: Sendable {
    case accept
    case reject
    case sendInitialState
    case requestInitialState
  }

  enum HostClaimRegistration: Sendable {
    case ignored
    case resolutionRequested(term: UInt64)
  }

  private(set) var activeParticipantIDs = Set<UUID>()
  private(set) var participantInfoByID: [UUID: BorgVRSharePlayParticipantInfo] = [:]
  private(set) var sessionDatasetID: String?
  private(set) var stateVersion: BorgVRSharePlayStateVersion?
  private(set) var localParticipantID: UUID?
  private(set) var currentHostParticipantID: UUID?
  private(set) var hostElectionTerm: UInt64 = 0

  private var protocolHandshake = BorgVRSharePlayHandshakeState()
  private var requestedStateVersion: BorgVRSharePlayStateVersion?
  private var hostClaims: [UUID] = []
  private var deferredHostClaims: [UUID] = []
  private var hostArbiterID: UUID?
  private var hasKnownHost = false
  private var sessionOriginsByDatasetID: [String: [DatasetOrigin]] = [:]
  private var adHocOriginsByParticipantID: [UUID: [String: [DatasetOrigin]]] = [:]

  var isLocalHost: Bool {
    guard let localParticipantID else { return false }
    return currentHostParticipantID == localParticipantID
  }

  var participants: [BorgVRSharePlayParticipant] {
    participantInfoByID.map {
      BorgVRSharePlayParticipant(id: $0.key, info: $0.value)
    }.sorted {
      if $0.displayName == $1.displayName {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  mutating func beginSession(
    localParticipantID: UUID,
    activeParticipantIDs: Set<UUID>,
    isHost: Bool,
    datasetID: String?
  ) {
    reset()
    self.localParticipantID = localParticipantID
    self.activeParticipantIDs = activeParticipantIDs
    currentHostParticipantID = isHost ? localParticipantID : nil
    hasKnownHost = isHost
    sessionDatasetID = isHost ? datasetID : nil
    stateVersion = isHost ? BorgVRSharePlayStateVersion() : nil
  }

  mutating func reset() {
    activeParticipantIDs.removeAll()
    participantInfoByID.removeAll()
    sessionDatasetID = nil
    stateVersion = nil
    localParticipantID = nil
    currentHostParticipantID = nil
    hostElectionTerm = 0
    hostArbiterID = nil
    hasKnownHost = false
    protocolHandshake.reset()
    requestedStateVersion = nil
    hostClaims.removeAll()
    deferredHostClaims.removeAll()
    sessionOriginsByDatasetID.removeAll()
    adHocOriginsByParticipantID.removeAll()
  }

  mutating func updateActiveParticipants(_ participantIDs: Set<UUID>) -> ParticipantChange {
    let joinedIDs = participantIDs.subtracting(activeParticipantIDs)
    let departedIDs = activeParticipantIDs.subtracting(participantIDs)
    activeParticipantIDs = participantIDs
    participantInfoByID = participantInfoByID.filter { participantIDs.contains($0.key) }
    adHocOriginsByParticipantID = adHocOriginsByParticipantID.filter {
      participantIDs.contains($0.key)
    }
    protocolHandshake.retainParticipants(participantIDs)

    let hostDeparted: Bool
    if let currentHostParticipantID,
       currentHostParticipantID != localParticipantID,
       !participantIDs.contains(currentHostParticipantID) {
      self.currentHostParticipantID = nil
      hostElectionTerm &+= 1
      hostClaims = deferredHostClaims
      deferredHostClaims.removeAll()
      hostArbiterID = nil
      stateVersion = nil
      requestedStateVersion = nil
      hostDeparted = true
    } else {
      hostDeparted = false
    }
    hostClaims = hostClaims.filter(isParticipantActive)

    return ParticipantChange(
      joinedIDs: joinedIDs,
      departedIDs: departedIDs,
      hostDeparted: hostDeparted
    )
  }

  mutating func receiveProtocolVersion(
    _ data: Data,
    from participantID: UUID
  ) throws -> BorgVRSharePlayHandshakeState.Result {
    try protocolHandshake.receive(data, from: participantID)
  }

  func acceptsMessages(from participantID: UUID) -> Bool {
    protocolHandshake.acceptsMessages(from: participantID)
  }

  mutating func setParticipantInfo(
    _ info: BorgVRSharePlayParticipantInfo,
    for participantID: UUID
  ) -> BorgVRSharePlayParticipantInfo? {
    let previous = participantInfoByID.updateValue(info, forKey: participantID)
    return previous
  }

  mutating func setSessionDatasetID(_ datasetID: String?) -> Bool {
    guard sessionDatasetID != datasetID else { return false }
    sessionDatasetID = datasetID
    return true
  }

  mutating func advanceHostStateVersion() {
    guard isLocalHost else { return }
    stateVersion = stateVersion?.nextRevision ?? BorgVRSharePlayStateVersion()
    requestedStateVersion = nil
  }

  mutating func acceptStateVersion(
    _ incoming: BorgVRSharePlayStateVersion,
    for messageType: BorgVRSharePlayProtocol.MessageType,
    from participantID: UUID
  ) -> StateVersionDecision {
    if messageType == .initMessage || messageType == .shutdownRequest {
      guard !isLocalHost else { return .reject }
      if let currentHostParticipantID,
         currentHostParticipantID != participantID {
        return .reject
      }
      if let stateVersion,
         stateVersion.sessionID == incoming.sessionID,
         incoming.revision < stateVersion.revision {
        return .reject
      }
      currentHostParticipantID = currentHostParticipantID ?? participantID
      hasKnownHost = true
      stateVersion = incoming
      requestedStateVersion = nil
      return .accept
    }

    guard stateVersion == incoming else {
      if isLocalHost {
        return .sendInitialState
      }
      if stateVersion?.sessionID != incoming.sessionID
          || (stateVersion?.revision ?? 0) < incoming.revision {
        guard requestedStateVersion != incoming else { return .reject }
        requestedStateVersion = incoming
        return .requestInitialState
      }
      return .reject
    }
    return .accept
  }

  func currentHostState() -> BorgVRSharePlayHostState? {
    guard let currentHostParticipantID else { return nil }
    return BorgVRSharePlayHostState(
      term: hostElectionTerm,
      hostID: currentHostParticipantID,
      arbiterID: hostArbiterID
    )
  }

  mutating func makeLocalHostClaim() -> BorgVRSharePlayHostClaim? {
    guard currentHostParticipantID == nil,
          let localParticipantID else { return nil }
    let claim = BorgVRSharePlayHostClaim(
      term: hostElectionTerm,
      candidateID: localParticipantID
    )
    guard case .resolutionRequested = registerHostClaim(claim) else { return nil }
    return claim
  }

  mutating func registerHostClaim(
    _ claim: BorgVRSharePlayHostClaim
  ) -> HostClaimRegistration {
    guard isParticipantActive(claim.candidateID) else { return .ignored }
    if currentHostParticipantID != nil, claim.term == (hostElectionTerm &+ 1) {
      // Reliable messages may precede the local active-participant publication.
      if !deferredHostClaims.contains(claim.candidateID) { deferredHostClaims.append(claim.candidateID) }
      return .ignored
    }
    guard currentHostParticipantID == nil,
          claim.term == hostElectionTerm else { return .ignored }
    if !hostClaims.contains(claim.candidateID) {
      hostClaims.append(claim.candidateID)
    }
    return .resolutionRequested(term: claim.term)
  }

  mutating func resolveHostElection(
    term: UInt64
  ) -> HostTransition? {
    guard currentHostParticipantID == nil, term == hostElectionTerm,
          electionArbiterID == localParticipantID,
          let winner = hostClaims.first(where: isParticipantActive) else { return nil }
    return applyHostState(
      BorgVRSharePlayHostState(term: term, hostID: winner, arbiterID: localParticipantID)
    )
  }

  mutating func receiveHostState(
    _ state: BorgVRSharePlayHostState,
    from participantID: UUID
  ) -> HostTransition? {
    guard isParticipantActive(state.hostID),
          state.term >= hostElectionTerm else { return nil }
    if !hasKnownHost && currentHostParticipantID == nil {
      // A joining participant learns the already elected host directly from that host.
      guard participantID == state.hostID else { return nil }
    } else {
      guard currentHostParticipantID != state.hostID,
            let arbiterID = state.arbiterID,
            participantID == arbiterID else { return nil }
      if let currentHostParticipantID {
        // Membership publication can lag behind the arbiter's decision.
        guard state.term == (hostElectionTerm &+ 1),
              arbiterID == smallestParticipant(excluding: currentHostParticipantID) else { return nil }
      } else {
        guard state.term == hostElectionTerm,
              arbiterID == electionArbiterID else { return nil }
      }
    }
    return applyHostState(state)
  }

  private var electionArbiterID: UUID? { smallestParticipant(excluding: nil) }

  private func smallestParticipant(excluding excluded: UUID?) -> UUID? {
    var participants = activeParticipantIDs
    if let localParticipantID { participants.insert(localParticipantID) }
    if let excluded { participants.remove(excluded) }
    return participants.min { $0.uuidString < $1.uuidString }
  }

  mutating func mergeSessionOrigins(
    _ origins: [DatasetOrigin],
    for datasetID: String
  ) {
    guard !datasetID.isEmpty else { return }
    sessionOriginsByDatasetID[datasetID] = DatasetOriginCatalog.deduplicated(
      origins + (sessionOriginsByDatasetID[datasetID] ?? [])
    )
  }

  mutating func mergeOriginSnapshot(_ snapshot: DatasetOriginSnapshot) {
    for (datasetID, origins) in snapshot.originsByDatasetID() {
      mergeSessionOrigins(origins, for: datasetID)
    }
  }

  mutating func setAdvertisedOrigins(
    _ origins: [DatasetOrigin],
    for datasetID: String,
    participantID: UUID
  ) {
    adHocOriginsByParticipantID[participantID, default: [:]][datasetID] =
      DatasetOriginCatalog.deduplicated(origins)
  }

  func knownSessionOrigins(for datasetID: String) -> [DatasetOrigin] {
    let advertised = adHocOriginsByParticipantID.values.flatMap { $0[datasetID] ?? [] }
    return DatasetOriginCatalog.deduplicated(
      advertised + (sessionOriginsByDatasetID[datasetID] ?? [])
    )
  }

  func combinedOriginSnapshot(with localSnapshot: DatasetOriginSnapshot) -> DatasetOriginSnapshot {
    var combined = localSnapshot.originsByDatasetID()
    for (datasetID, origins) in sessionOriginsByDatasetID {
      combined[datasetID, default: []].append(contentsOf: origins)
    }
    var datasetIDsByOrigin: [DatasetOrigin: Set<String>] = [:]
    for (datasetID, origins) in combined {
      for origin in DatasetOriginCatalog.deduplicated(origins) {
        datasetIDsByOrigin[origin, default: []].insert(datasetID)
      }
    }
    return DatasetOriginSnapshot(entries: datasetIDsByOrigin.map {
      .init(origin: $0.key, datasetIDs: $0.value.sorted())
    })
  }

  private mutating func applyHostState(
    _ state: BorgVRSharePlayHostState
  ) -> HostTransition {
    let previousHostID = currentHostParticipantID
    hostElectionTerm = state.term
    currentHostParticipantID = state.hostID
    hostArbiterID = state.arbiterID
    hasKnownHost = true
    hostClaims.removeAll()
    deferredHostClaims.removeAll()
    let localHost = state.hostID == localParticipantID
    if localHost {
      if previousHostID != localParticipantID || stateVersion == nil {
        stateVersion = BorgVRSharePlayStateVersion()
        requestedStateVersion = nil
      }
    } else if previousHostID != state.hostID {
      stateVersion = nil
      requestedStateVersion = nil
    }
    return HostTransition(
      previousHostID: previousHostID,
      hostID: state.hostID,
      isLocalHost: localHost
    )
  }

  private func isParticipantActive(_ participantID: UUID) -> Bool {
    participantID == localParticipantID || activeParticipantIDs.contains(participantID)
  }
}

struct BorgVRSharePlayDatasetAnnouncement: Sendable {
  let uniqueID: String
  let origins: [DatasetOrigin]
  let description: String

  init(uniqueID: String, origins: [DatasetOrigin], description: String) {
    self.uniqueID = uniqueID
    self.origins = origins
    self.description = description
  }

  init?(data: Data) {
    var cursor = data.startIndex

    func readString() -> String? {
      guard cursor + 4 <= data.endIndex else { return nil }
      let lengthData = data[cursor..<(cursor + 4)]
      cursor += 4
      let length = UInt32(
        bigEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
      )
      guard length <= 1024 * 1024,
            cursor + Int(length) <= data.endIndex else { return nil }
      let stringData = data[cursor..<(cursor + Int(length))]
      cursor += Int(length)
      return String(data: stringData, encoding: .utf8)
    }

    func readOrigins() -> [DatasetOrigin]? {
      guard cursor + 4 <= data.endIndex else { return nil }
      let countData = data[cursor..<(cursor + 4)]
      cursor += 4
      let count = UInt32(
        bigEndian: countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
      )
      guard count <= 10000 else { return nil }
      var origins: [DatasetOrigin] = []
      origins.reserveCapacity(Int(count))
      for _ in 0..<count {
        guard let address = readString(),
              cursor + 4 <= data.endIndex else { return nil }
        let portData = data[cursor..<(cursor + 4)]
        cursor += 4
        let port = UInt32(
          bigEndian: portData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        )
        guard port <= UInt16.max,
              let password = readString() else { return nil }
        origins.append(DatasetOrigin(
          address: address,
          port: Int(port),
          password: password
        ))
      }
      return origins
    }

    guard let uniqueID = readString(),
          let origins = readOrigins(),
          let description = readString(),
          cursor == data.endIndex else { return nil }
    self.uniqueID = uniqueID
    self.origins = origins
    self.description = description
  }

  func encoded() -> Data {
    var data = Data()

    func writeString(_ string: String) {
      let utf8 = string.data(using: .utf8) ?? Data()
      var length = UInt32(utf8.count).bigEndian
      data.append(Data(bytes: &length, count: 4))
      data.append(utf8)
    }

    func writeOrigins(_ origins: [DatasetOrigin]) {
      var count = UInt32(origins.count).bigEndian
      data.append(Data(bytes: &count, count: 4))
      for origin in origins {
        writeString(origin.address)
        var port = UInt32(origin.port).bigEndian
        data.append(Data(bytes: &port, count: 4))
        writeString(origin.password)
      }
    }

    writeString(uniqueID)
    writeOrigins(origins)
    writeString(description)
    return data
  }
}
