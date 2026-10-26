import Darwin
import Foundation
import GroupActivities
import SwiftUI
import LinkPresentation
import Combine

let groupActivityIdentifier = "de.cgvis.borgvr.collaboration"
private let localBorgVRSharePlayInitiatorID = UUID()

struct BorgVRActivity: GroupActivity, Transferable {
  static let activityIdentifier = groupActivityIdentifier
  let initiatorID: UUID

  init(initiatorID: UUID = localBorgVRSharePlayInitiatorID) {
    self.initiatorID = initiatorID
  }

  var metadata: GroupActivityMetadata = {
    var metadata = GroupActivityMetadata()
    metadata.title = "BorgVR Live Collaboration"
    metadata.subtitle = "Begin a collaborative BorgVR experience that lets multiple users—near and far—interact with the same volumetric dataset together."
    metadata.type = .generic
    metadata.sceneAssociationBehavior = .content(groupActivityIdentifier)  // TODO: check
    return metadata
  }()
}

class GroupActivityHelper {
  private var groupSession : GroupSession<BorgVRActivity>? = nil
  private var messenger : GroupSessionMessenger? = nil
  private var messageTask: Task<Void, Never>?
  private var sessionGeneration = 0
  private weak var sharedAppModel : SharedAppModel?
  private weak var runtimeAppModel : RuntimeAppModel? = nil
  private weak var storedAppModel : StoredAppModel? = nil
  private var subscriptions = Set<AnyCancellable>()
  private var localDatasetCacheCompletionObservation: AnyCancellable?
  private var pendingSynchronization = BorgVRSharePlayPendingSynchronization()
  private var pendingScreenViewState: BorgVRScreenViewState?
  private var synchronizationTask: Task<Void, Never>?
  private var visionTransformRevision: UInt64 = 0
  private var receivedVisionTransformRevisionByParticipantID: [UUID: UInt64] = [:]
  private var lastVisionTransformSendBlockReason: String?
  private var hasReportedVisionTransformSendState = false
  private var knownParticipants = Set<Participant>()
  private var sessionEngine = BorgVRSharePlaySessionEngine()
  private var screenViewStateByParticipantID: [UUID: BorgVRScreenViewState] = [:]
  private let sharePlayServerHost = BorgVRServerHost(logger: GUILogger())
  private var serverStartup: (datasetID: String, task: Task<(origins: [String], authToken: String), Never>)?
  private var serverGeneration = UUID()
  private var sharePlayDatasetID: String?
  private var sharePlayAuthToken = ""
  private var sharePlayServerRunning = false
  private var sharePlayServerPort = StoredAppModel.int("sharePlayServerPort")
  private var sharePlayMeshAssetIDs = Set<UUID>()
  private struct PendingDatasetLoad {
    let uniqueID: String
    let description: String
    let generation: Int
  }
  private var pendingDatasetLoad: PendingDatasetLoad?
  private var pendingDatasetLoadTask: Task<Void, Never>?
  private var sceneMeshResolutionTask: Task<Void, Never>?
  private var sceneMeshResolutionRetryRequested = false
  private var stateVersionDatasetID: String?
  private var editCollaboration: BorgVRVolumeEditCollaboration?

  @MainActor
  private func refreshEditCollaboration() {
    guard let runtimeAppModel, let localID = sessionEngine.localParticipantID, groupSession != nil else { return }
    if editCollaboration == nil {
      editCollaboration = BorgVRVolumeEditCollaboration(model: runtimeAppModel.volumeBrush, send: { [weak self] data, target in
        guard let self, self.messenger != nil else { throw CancellationError() }
        if let target {
          guard let participant = self.knownParticipants.first(where: { $0.id == target }) else { throw CancellationError() }
          try await self.sendData(data: data, of: .volumeEditing, to: .only(Set([participant])))
        } else { try await self.sendData(data: data, of: .volumeEditing) }
      }, log: { [weak runtimeAppModel] in runtimeAppModel?.logger.warning($0) },
        info: { [weak runtimeAppModel] in runtimeAppModel?.logger.info($0) })
    }
    editCollaboration?.configure(localID: localID, hostID: sessionEngine.currentHostParticipantID,
      datasetID: sessionEngine.sessionDatasetID, participants: Set(knownParticipants.map(\.id)))
  }

  init(_ sharedAppModel: SharedAppModel) {
    self.sharedAppModel = sharedAppModel
  }

  @MainActor func markLocalActivityStarter() {
    runtimeAppModel?.groupSessionHost = true
  }

  @MainActor var isInGroupSession: Bool {
    groupSession != nil
  }

  @MainActor func datasetRendererDidLoad() {
    guard groupSession != nil, let runtimeAppModel else { return }
    retryMissingSceneMeshAssets()
    if runtimeAppModel.groupSessionHost {
      Task { await sendInitialData() }
    } else {
      Task { await requestInitialState() }
    }
  }

  @MainActor func leaveGroupActivity() {
    guard let runtimeAppModel else { return }

    setSessionDatasetID(nil)
    self.groupSession?.leave()
    runtimeAppModel.groupSessionHost = false
    resetSessionReceivers()
  }

  func configureSession(runtimeAppModel:RuntimeAppModel, storedAppModel: StoredAppModel) async {
    runtimeAppModel.logger.info("Starting SharePlay group-session observation on this Vision Pro.")
    self.runtimeAppModel = runtimeAppModel
    self.storedAppModel = storedAppModel
    if localDatasetCacheCompletionObservation == nil {
      localDatasetCacheCompletionObservation = NotificationCenter.default.publisher(
        for: BORGVRLocalDatasetCacheCompletion.notification
      ).sink { [weak self] notification in
        guard let completion = notification.object as? BORGVRLocalDatasetCacheCompletion else {
          return
        }
        Task { @MainActor [weak self] in
          self?.handleLocalDatasetCacheCompletion(completion)
        }
      }
    }
    for await session in BorgVRActivity.sessions() {
      runtimeAppModel.logger.info(
        "SharePlay delivered a group session to this Vision Pro; activity initiator: \(session.activity.initiatorID.uuidString), initial state: \(String(describing: session.state)), active participant count: \(session.activeParticipants.count)."
      )
      await resetSessionReceivers()
      sessionGeneration += 1
      let generation = sessionGeneration

      guard let systemCoordinator = await session.systemCoordinator else { continue }
      var config = SystemCoordinator.Configuration()
      config.spatialTemplatePreference = .sideBySide
      config.supportsGroupImmersiveSpace = true
      systemCoordinator.configuration = config

      self.groupSession = session
      let localUserStartedActivity = session.activity.initiatorID == localBorgVRSharePlayInitiatorID
      await MainActor.run {
        self.stopSharePlayServer()
        runtimeAppModel.sharePlaySessionIsActive = true
        runtimeAppModel.groupSessionHost = localUserStartedActivity
        self.sessionEngine.beginSession(
          localParticipantID: session.localParticipant.id,
          activeParticipantIDs: Set(session.activeParticipants.map(\.id)),
          isHost: localUserStartedActivity,
          datasetID: runtimeAppModel.activeDataset?.uniqueId
        )
        self.stateVersionDatasetID = localUserStartedActivity
          ? runtimeAppModel.activeDataset?.uniqueId
          : nil
      }
      knownParticipants = session.activeParticipants

      session.$activeParticipants
        .sink { activeParticipants in
          guard generation == self.sessionGeneration else { return }
          let previousParticipants = self.knownParticipants
          let newParticipants = activeParticipants.subtracting(self.knownParticipants)
          let departedParticipants = previousParticipants.subtracting(activeParticipants)
          self.knownParticipants = activeParticipants
          let activeIDs = Set(activeParticipants.map(\.id))
          Task { @MainActor in
            let change = self.sessionEngine.updateActiveParticipants(activeIDs)
            self.screenViewStateByParticipantID = self.screenViewStateByParticipantID.filter {
              activeIDs.contains($0.key)
            }
            self.receivedVisionTransformRevisionByParticipantID =
              self.receivedVisionTransformRevisionByParticipantID.filter {
                activeIDs.contains($0.key)
              }
            if !newParticipants.isEmpty || !departedParticipants.isEmpty {
              let joinedIDs = newParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
              let departedIDs = departedParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
              let hostID = self.sessionEngine.currentHostParticipantID?.uuidString ?? "unknown"
              runtimeAppModel.logger.info(
                "SharePlay participants changed; joined: [\(joinedIDs)], departed: [\(departedIDs)], host: \(hostID), active count: \(activeIDs.count)."
              )
            }
            self.handleHostParticipantChanges(change)
            self.publishParticipants()
            self.applyMinimumScreenViewportAspectRatio()
          }

          if newParticipants.isEmpty { return }

          Task { @MainActor in
            runtimeAppModel.logger.dev("New Participants joined the groupsession")
          }

          Task {
            await self.sendProtocolVersion(to: .only(newParticipants))
          }

        } .store(in: &subscriptions)

      session.$state
        .sink { [weak self] state in
          Task { @MainActor in
            guard let self, self.sessionGeneration == generation else { return }
            self.runtimeAppModel?.logger.info(
              "SharePlay group-session state changed to: \(String(describing: state))."
            )
            guard case .invalidated(let reason) = state else { return }
            self.runtimeAppModel?.logger.warning(
              "SharePlay session invalidated by the system: \(reason.localizedDescription)"
            )
            self.stopSharePlayServer()
            self.resetSessionReceivers()
            self.runtimeAppModel?.groupSessionHost = false
          }
        }
        .store(in: &subscriptions)

      let messenger = GroupSessionMessenger(session: session)
      self.messenger = messenger
      await refreshEditCollaboration()

      if let pose = systemCoordinator.localParticipantState.pose {
        runtimeAppModel.logger.dev("Joined groupsession with pose \(pose)")
      } else {
        runtimeAppModel.logger.dev("Joined groupsession no pose available")
      }

      messageTask = Task.detached { [weak self] in
        for await (data, context) in messenger.messages(of: Data.self) {
          if Task.isCancelled { return }
          await self?.handleIncoming(data: data, from: context.source, sessionGeneration: generation)
        }
      }
      runtimeAppModel.logger.info(
        "Calling session.join() for the delivered SharePlay group session."
      )
      session.join()
      runtimeAppModel.logger.info(
        "session.join() returned; current state: \(String(describing: session.state))."
      )
      Task { await self.sendProtocolVersion() }
    }
  }

  @MainActor
  func shutdownGroupsession() async {
    defer { setSessionDatasetID(nil) }
    guard groupSession != nil else { return }

    await MainActor.run {
      advanceHostStateVersion(for: nil)
    }

    do {
      try await sendData(data: Data(), of: .shutdownRequest)
    } catch {
      runtimeAppModel?.logger
        .error("Failed to send shutdown data to all participants: \(error)")
    }
  }

  func synchronize(kind: SharedAppModel.UpdateKind) {
    Task { @MainActor [weak self] in
      self?.scheduleSynchronization(kind: kind)
    }
  }

  func flushSynchronization() {
    Task { @MainActor [weak self] in
      guard let self, self.messenger != nil else { return }
      self.synchronizationTask?.cancel()
      self.synchronizationTask = nil
      await self.flushPendingSynchronization()
    }
  }

  @MainActor
  private func scheduleSynchronization(kind: SharedAppModel.UpdateKind) {
    guard messenger != nil else { return }

    switch kind {
      case .full:
        pendingSynchronization.markCommonState(includeTransferFunction: true)
        pendingSynchronization.markTransform()
      case .stateOnly:
        pendingSynchronization.markCommonState(includeTransferFunction: false)
      case .transformOnly:
        pendingSynchronization.markTransform()
    }

    guard synchronizationTask == nil else { return }
    let delay = pendingSynchronization.preferredDelayNanoseconds
    synchronizationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard !Task.isCancelled else { return }
      await self?.flushPendingSynchronization()
    }
  }

  @MainActor
  private func flushPendingSynchronization() async {
    synchronizationTask = nil
    guard let sharedAppModel, messenger != nil else { return }

    let batch = pendingSynchronization.takeBatch()
    let screenViewState = pendingScreenViewState
    pendingScreenViewState = nil

    do {
      if batch.commonState {
        try await sendData(
          data: sharedAppModel.serializeCommonSharePlayState(
            includeTransferFunction: batch.transferFunction
          ),
          of: .renderingUpdate
        )
      }
      if batch.transform {
        if let data = makeVisionTransformData() {
          try await sendData(data: data, of: .renderingUpdate)
        } else {
          pendingSynchronization.markTransform()
        }
      }
      if let screenViewState {
        try await sendData(
          data: BorgVRScreenViewStateCodec.encode(screenViewState, isShared: true),
          of: .renderingUpdate
        )
      }
    } catch {
      runtimeAppModel?.logger
        .error("Failed to send synchronize data to all participants: \(error)")
    }
  }

  @MainActor
  private func makeVisionTransformData() -> Data? {
    guard let runtimeAppModel,
          let sharedAppModel,
          let datasetID = runtimeAppModel.activeDataset?.uniqueId else { return nil }
    let anchorSnapshot = runtimeAppModel.spatialAnchorSessionState.snapshot()
    guard anchorSnapshot.sharePlayIsActive else {
      reportVisionTransformSendBlock("the SharePlay session is not active")
      return nil
    }

    let anchorID: UUID
    if anchorSnapshot.localParticipantIsHost {
      guard anchorSnapshot.activeAnchorIsShared,
            let activeAnchorID = anchorSnapshot.activeAnchorID else {
        reportVisionTransformSendBlock("the host has no active shared WorldAnchor")
        return nil
      }
      anchorID = activeAnchorID
    } else {
      guard let expectedAnchorID = anchorSnapshot.expectedSharedAnchorID else {
        reportVisionTransformSendBlock("the client has not received the host WorldAnchor ID")
        return nil
      }
      guard anchorSnapshot.activeAnchorID == expectedAnchorID else {
        reportVisionTransformSendBlock("the client is not rendering with the host WorldAnchor")
        return nil
      }
      anchorID = expectedAnchorID
    }

    reportVisionTransformSendBlock(nil)
    visionTransformRevision &+= 1
    return sharedAppModel.serializeVisionSharePlayTransform(
      datasetID: datasetID,
      anchorID: anchorID,
      revision: visionTransformRevision
    )
  }

  @MainActor
  private func reportVisionTransformSendBlock(_ reason: String?) {
    guard !hasReportedVisionTransformSendState || reason != lastVisionTransformSendBlockReason else {
      return
    }
    hasReportedVisionTransformSendState = true
    lastVisionTransformSendBlockReason = reason
    if let reason {
      runtimeAppModel?.logger.dev("SharePlay transform pending because \(reason).")
    } else {
      runtimeAppModel?.logger.dev("SharePlay transform sending is ready.")
    }
  }

  func synchronizeMarkers() {
    guard messenger != nil else { return }
    Task {
      guard let sharedAppModel else { return }
      await refreshAdvertisedSceneMeshAssetsIfNeeded()
      do {
        try await sendData(
          data: sharedAppModel.serializeVolumeMarkersSharePlayState(),
          of: .renderingUpdate
        )
      } catch {
        runtimeAppModel?.logger
          .error("Failed to send marker data to all participants: \(error)")
      }
    }
  }

  @MainActor
  private func refreshAdvertisedSceneMeshAssetsIfNeeded() async {
    guard let sharedAppModel,
          runtimeAppModel?.activeDataset != nil else { return }
    let referencedAssetIDs = Set(sharedAppModel.sceneMeshInstances.map(\.asset.assetID))
    guard !referencedAssetIDs.isSubset(of: sharePlayMeshAssetIDs) else { return }
    await advertiseCurrentLocalDataset()
  }

  func synchronizeMeasurements() {
    guard messenger != nil else { return }
    Task {
      guard let sharedAppModel else { return }
      do {
        try await sendData(
          data: sharedAppModel.serializeVolumeMeasurementsSharePlayState(),
          of: .renderingUpdate
        )
      } catch {
        runtimeAppModel?.logger.error(
          "Failed to send measurement data to all participants: \(error)"
        )
      }
    }
  }

  func synchronizeScreenView(_ state: BorgVRScreenViewState) {
    guard messenger != nil else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingScreenViewState = state
      guard self.synchronizationTask == nil else { return }
      self.synchronizationTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard !Task.isCancelled else { return }
        await self?.flushPendingSynchronization()
      }
    }
  }

  func participantInfoChanged() {
    Task { @MainActor [weak self] in
      await self?.sendParticipantInfo()
    }
  }

  func synchronizeSpatialToolPreviews(
    points: [VolumeMarkerPoint],
    color: SIMD4<Float>
  ) {
    guard messenger != nil else { return }
    Task {
      do {
        try await sendData(
          data: SpatialToolPreviewSharePlayCodec.encode(points: points, color: color),
          of: .renderingUpdate
        )
      } catch {
        runtimeAppModel?.logger.error(
          "Failed to send spatial tool previews: \(error)"
        )
      }
    }
  }

  @MainActor
  func sendInitialData(to:Participants = .all) async  {
    guard let runtimeAppModel else { return }
    guard let sharedAppModel else { return }
    guard runtimeAppModel.groupSessionHost else { return }

    runtimeAppModel.logger.dev("sendInitialData")
    let generation = sessionGeneration

    if let dataset = runtimeAppModel.activeDataset {
      advanceHostStateVersionIfNeeded(for: dataset.uniqueId)
      setSessionDatasetID(dataset.uniqueId)
      refreshEditCollaboration()
      let sharedDataset = await shareOrigins(for: dataset)
      guard generation == sessionGeneration, groupSession != nil,
            runtimeAppModel.groupSessionHost,
            runtimeAppModel.activeDataset?.uniqueId == dataset.uniqueId else { return }
      let initMessage = BorgVRSharePlayDatasetAnnouncement(
        uniqueID: dataset.uniqueId,
        origins: sharedDataset,
        description:dataset.description
      )

      let data = initMessage.encoded()
      do {
        try await sendData(data:data, of: .initMessage, to: to)
        try await sendData(
          data: sharedAppModel.serializeCommonSharePlayState(includeTransferFunction: true),
          of: .renderingUpdate,
          to: to
        )
        if let transformData = makeVisionTransformData() {
          try await sendData(data: transformData, of: .renderingUpdate, to: to)
        }
        try await sendData(
          data: sharedAppModel.serializeVolumeMarkersSharePlayState(),
          of: .renderingUpdate,
          to: to
        )
        try await sendData(
          data: sharedAppModel.serializeVolumeMeasurementsSharePlayState(),
          of: .renderingUpdate,
          to: to
        )
        if let screenViewState = sharedAppModel.screenSharePlayViewState {
          try await sendData(
            data: BorgVRScreenViewStateCodec.encode(screenViewState, isShared: true),
            of: .renderingUpdate,
            to: to
          )
        }
        switch to {
          case .all: await editCollaboration?.sendSnapshot()
          case .only(let members):
            for participant in members { await editCollaboration?.sendSnapshot(to: participant.id) }
          @unknown default: break
        }
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    } else {
      advanceHostStateVersionIfNeeded(for: nil)
      let data = BorgVRSharePlayDatasetAnnouncement(
        uniqueID: "",
        origins: [],
        description: ""
      ).encoded()
      do {
        try await sendData(data:data, of: .initMessage, to: to)
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    }

  }

  @MainActor
  func requestInitialState(to participants: Participants = .all) async {
    try? await sendData(data: Data(), of: .stateRequest, to: participants)
  }

  @MainActor
  private func handleIncoming(data: Data, from: Participant, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel else { return }

    let message: BorgVRSharePlayWireMessage
    do {
      message = try BorgVRSharePlayWireCodec.decode(data)
    } catch {
      runtimeAppModel.logger.error("Invalid SharePlay message: \(error)")
      return
    }

    if message.type == .protocolVersion {
      handleProtocolVersion(data: message.payload, from: from)
      return
    }
    guard sessionEngine.acceptsMessages(from: from.id) else {
      runtimeAppModel.logger.warning("Ignored SharePlay data received before the protocol handshake.")
      return
    }
    if let stateVersion = message.stateVersion,
       !acceptStateVersion(stateVersion, for: message.type, from: from) {
      return
    }

    switch message.type {
      case .volumeEditing:
        refreshEditCollaboration()
        editCollaboration?.receive(message.payload, from: from.id)
      case .initMessage:
        guard !runtimeAppModel.groupSessionHost else { return }
        handleInit(data: message.payload, from: from, sessionGeneration: generation)
      case .renderingUpdate:
        handleUpdate(data: message.payload, from: from)
      case .shutdownRequest:
        guard !runtimeAppModel.groupSessionHost else { return }
        handleShutdown(from: from)
      case .stateRequest:
        guard runtimeAppModel.groupSessionHost else { return }
        Task { await self.sendInitialData(to: .only(Set([from]))) }
      case .participantInfo:
        handleParticipantInfo(data: message.payload, from: from)
      case .screenViewRequest:
        guard let screenViewState = sharedAppModel?.screenSharePlayViewState else { return }
        Task {
          try? await sendData(
            data: BorgVRScreenViewStateCodec.encode(screenViewState, isShared: true),
            of: .renderingUpdate,
            to: .only(Set([from]))
          )
        }
      case .originCatalogSnapshot:
        handleOriginCatalogSnapshot(data: message.payload)
      case .datasetOriginAdvertisement:
        handleDatasetOriginAdvertisement(data: message.payload, from: from)
      case .hostClaim:
        handleHostClaim(data: message.payload, from: from.id)
      case .hostState:
        handleHostState(data: message.payload, from: from.id)
      case .protocolVersion:
        break
    }
  }

  private typealias MessageType = BorgVRSharePlayProtocol.MessageType

  private func sendData(data:Data, of messageType:MessageType,
                        to participants:Participants = .all) async throws {
    guard let messenger else { return }
    let message = try BorgVRSharePlayWireCodec.encode(
      data,
      type: messageType,
      stateVersion: sessionEngine.stateVersion
    )
    try await messenger.send(message, to: participants)
  }

  @MainActor
  private func acceptStateVersion(
    _ incoming: BorgVRSharePlayStateVersion,
    for messageType: MessageType,
    from participant: Participant
  ) -> Bool {
    switch sessionEngine.acceptStateVersion(
      incoming,
      for: messageType,
      from: participant.id
    ) {
      case .accept:
        if messageType == .initMessage || messageType == .shutdownRequest {
          stateVersionDatasetID = nil
        }
        return true
      case .sendInitialState:
        Task { await sendInitialData(to: .only(Set([participant]))) }
        return false
      case .requestInitialState:
        runtimeAppModel?.logger.info(
          "Received a SharePlay update for an unknown state version; requesting the current initial state."
        )
        Task { await requestInitialState() }
        return false
      case .reject:
        return false
    }
  }

  @MainActor
  private func advanceHostStateVersion(for datasetID: String?) {
    sessionEngine.advanceHostStateVersion()
    stateVersionDatasetID = datasetID
  }

  @MainActor
  private func advanceHostStateVersionIfNeeded(for datasetID: String?) {
    guard runtimeAppModel?.groupSessionHost == true else { return }
    guard sessionEngine.stateVersion == nil || stateVersionDatasetID != datasetID else { return }
    advanceHostStateVersion(for: datasetID)
  }

  private func sendProtocolVersion(to participants: Participants = .all) async {
    try? await sendData(
      data: BorgVRSharePlayVersionCodec.encode(),
      of: .protocolVersion,
      to: participants
    )
  }

  @MainActor
  private func handleProtocolVersion(data: Data, from participant: Participant) {
    guard let runtimeAppModel else { return }
    do {
      switch try sessionEngine.receiveProtocolVersion(data, from: participant.id) {
        case .alreadyAccepted:
          return
        case .incompatible(let issue):
          runtimeAppModel.logger.error(
            "Incompatible SharePlay protocol; version \(issue.requiredVersion) or later is required."
          )
          groupSession?.leave()
          stopSharePlayServer()
          runtimeAppModel.groupSessionHost = false
          resetSessionReceivers()
          runtimeAppModel.protocolCompatibilityIssue = issue
          return
        case .accepted:
          break
      }
      Task {
        await sendProtocolVersion(to: .only(Set([participant])))
        await sendParticipantInfo(to: .only(Set([participant])))
        await sendOriginCatalogSnapshot(to: .only(Set([participant])))
        await advertiseCurrentLocalDataset(to: .only(Set([participant])))
        await sendCurrentHostState(to: .only(Set([participant])))
        if runtimeAppModel.groupSessionHost {
          await sendInitialData(to: .only(Set([participant])))
        } else {
          await requestInitialState(to: .only(Set([participant])))
        }
      }
    } catch {
      runtimeAppModel.logger.error("Invalid SharePlay protocol handshake: \(error)")
    }
  }

  @MainActor
  private func sendParticipantInfo(to participants: Participants = .all) async {
    guard messenger != nil else { return }
    let configuredName = storedAppModel?.sharePlayDisplayName ?? ""
    let displayName = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
    let info = BorgVRSharePlayParticipantInfo(
      platform: .visionOS,
      displayName: displayName.isEmpty
        ? String(localized: "Apple Vision Pro")
        : displayName,
      sharesScreenView: false
    )
    guard let data = try? BorgVRSharePlayParticipantInfoCodec.encode(info) else { return }
    try? await sendData(data: data, of: .participantInfo, to: participants)
  }

  @MainActor
  private func handleParticipantInfo(data: Data, from participant: Participant) {
    do {
      let info = try BorgVRSharePlayParticipantInfoCodec.decode(data)
      _ = sessionEngine.setParticipantInfo(info, for: participant.id)
      publishParticipants()
      applyMinimumScreenViewportAspectRatio()
      if (info.platform == .iOS || info.platform == .macOS),
         screenViewStateByParticipantID[participant.id] == nil {
        Task {
          try? await sendData(
            data: Data(),
            of: .screenViewRequest,
            to: .only(Set([participant]))
          )
        }
      }
    } catch {
      runtimeAppModel?.logger.error("Failed to read SharePlay participant information: \(error)")
    }
  }

  @MainActor
  private func applyScreenViewUpdate(
    _ update: BorgVRScreenViewUpdate,
    from participant: Participant
  ) {
    screenViewStateByParticipantID[participant.id] = update.state
    let participantSharesView = sessionEngine.participantInfoByID[participant.id]?.sharesScreenView
      ?? update.isShared
    if update.isShared, participantSharesView {
      var sharedState = update.state
      if let minimumAspectRatio = minimumScreenViewportAspectRatio() {
        sharedState.viewportAspectRatio = minimumAspectRatio
      }
      sharedAppModel?.screenSharePlayViewState = sharedState
    }
    publishDetachedScreenViews()
  }

  @MainActor
  private func applyMinimumScreenViewportAspectRatio() {
    guard var state = sharedAppModel?.screenSharePlayViewState,
          let minimumAspectRatio = minimumScreenViewportAspectRatio() else {
      return
    }
    guard abs(state.viewportAspectRatio - minimumAspectRatio) > 0.0001 else {
      return
    }
    state.viewportAspectRatio = minimumAspectRatio
    sharedAppModel?.screenSharePlayViewState = state
  }

  private func minimumScreenViewportAspectRatio() -> Float? {
    screenViewStateByParticipantID.compactMap { participantID, state in
      guard let platform = sessionEngine.participantInfoByID[participantID]?.platform,
            platform == .iOS || platform == .macOS,
            sessionEngine.participantInfoByID[participantID]?.sharesScreenView == true else {
        return nil
      }
      return state.viewportAspectRatio
    }.min()
  }

  @MainActor
  private func publishParticipants() {
    refreshEditCollaboration()
    let participants = sessionEngine.participants
    sharedAppModel?.sharePlayParticipants = participants
    publishDetachedScreenViews()
    let hasScreenParticipant = participants.contains {
      $0.platform == .iOS || $0.platform == .macOS
    }
    if !hasScreenParticipant,
       runtimeAppModel?.interactionMode == .screenView {
      runtimeAppModel?.interactionMode = .model
      sharedAppModel?.screenViewInteractionActive = false
    }
  }

  @MainActor
  private func publishDetachedScreenViews() {
    sharedAppModel?.detachedScreenSharePlayViewStates = screenViewStateByParticipantID.filter {
      participantID, _ in
      guard let info = sessionEngine.participantInfoByID[participantID] else { return false }
      return (info.platform == .iOS || info.platform == .macOS) && !info.sharesScreenView
    }
  }

  @MainActor
  private func resetSessionReceivers() {
    editCollaboration?.stop()
    editCollaboration = nil
    messageTask?.cancel()
    messageTask = nil
    groupSession = nil
    messenger = nil
    subscriptions.removeAll()
    synchronizationTask?.cancel()
    synchronizationTask = nil
    pendingSynchronization.reset()
    pendingScreenViewState = nil
    visionTransformRevision = 0
    receivedVisionTransformRevisionByParticipantID.removeAll()
    lastVisionTransformSendBlockReason = nil
    hasReportedVisionTransformSendState = false
    knownParticipants.removeAll()
    sessionEngine.reset()
    screenViewStateByParticipantID.removeAll()
    pendingDatasetLoadTask?.cancel()
    pendingDatasetLoadTask = nil
    pendingDatasetLoad = nil
    sceneMeshResolutionTask?.cancel()
    sceneMeshResolutionTask = nil
    sceneMeshResolutionRetryRequested = false
    stateVersionDatasetID = nil
    runtimeAppModel?.showsHostDeparturePrompt = false
    runtimeAppModel?.sharePlaySessionIsActive = false
    sharedAppModel?.sharePlayParticipants = []
    sharedAppModel?.screenSharePlayViewState = nil
    sharedAppModel?.detachedScreenSharePlayViewStates = [:]
    sharedAppModel?.screenViewInteractionActive = false
    sharedAppModel?.clearRemoteSpatialToolPreviews()
  }

  static func registerGroupActivity() {
    let borgVRActivity = BorgVRActivity()
    let itemProvider = NSItemProvider()
    itemProvider.registerGroupActivity(borgVRActivity)

    // Create the activity items configuration
    let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider])

    // Provide the metadata for the group activity
    configuration.metadataProvider = { key in
      guard key == .linkPresentationMetadata else { return nil }
      let metadata = LPLinkMetadata()
      metadata.title = borgVRActivity.metadata.title
      return metadata
    }

    UIApplication.shared
      .connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?
      .windows
      .first?
      .rootViewController?
      .activityItemsConfiguration = configuration
  }

  @MainActor
  func handleInit(data: Data, from: Participant, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel = runtimeAppModel else { return }
    guard !runtimeAppModel.groupSessionHost else { return }
    runtimeAppModel.logger.dev("Received groupsession init data")
    runtimeAppModel.groupSessionHost = false

    guard let initMessage = BorgVRSharePlayDatasetAnnouncement(data: data) else {
      runtimeAppModel.logger.dev("Received incomplete init message, waiting for host")
      runtimeAppModel.waitForSharePlayDataset(reason: .hostDataset)
      return
    }

    guard initMessage.uniqueID != "" else {
      if let activeDataset = runtimeAppModel.activeDataset,
         runtimeAppModel.isOpeningOrDisplayingDataset(withUniqueID: activeDataset.uniqueId) {
        runtimeAppModel.logger.dev("Ignored stale empty groupsession init data while a dataset is opening or open")
        return
      }
      runtimeAppModel.logger.dev("Received empty dataset in init message, waiting for host")
      setSessionDatasetID(nil)
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil
      runtimeAppModel.waitForSharePlayDataset(reason: .hostDataset)
      return
    }

    setSessionDatasetID(initMessage.uniqueID)

    DatasetOriginCatalog.shared.prioritize(initMessage.origins, for: initMessage.uniqueID)
    mergeSessionOrigins(initMessage.origins, for: initMessage.uniqueID)

    if runtimeAppModel.isOpeningOrDisplayingDataset(withUniqueID: initMessage.uniqueID) {
      runtimeAppModel.logger.dev("Dataset is already opening or open, ignoring duplicate groupsession init data")
      Task { await advertiseCurrentLocalDataset() }
      return
    }

    if let pendingDatasetLoad,
       pendingDatasetLoad.uniqueID == initMessage.uniqueID,
       pendingDatasetLoad.generation == generation {
      runtimeAppModel.logger.dev("Dataset source search is already active, keeping the existing load attempt")
      retryPendingDatasetLoad()
      return
    }

    if let localDataset = findLocalDataset(id: initMessage.uniqueID) {
      let localFile = localDataset.url
      runtimeAppModel.logger.info("Found SharePlay dataset \(initMessage.uniqueID) locally at \(localFile.path()).")
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil

      runtimeAppModel.startImmersiveSpace(identifier: localFile.path(),
                                   description: initMessage.description,
                                   source: localDataset.source,
                                   uniqueId: initMessage.uniqueID,
                                   asGroupSessionHost: false)
      Task { await advertiseCurrentLocalDataset() }
    } else {
      runtimeAppModel.logger.info("SharePlay dataset \(initMessage.uniqueID) is not available locally; searching known network sources.")
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = PendingDatasetLoad(
        uniqueID: initMessage.uniqueID,
        description: initMessage.description,
        generation: generation
      )
      retryPendingDatasetLoad()
    }
  }

  @MainActor
  private func retryPendingDatasetLoad() {
    guard let pending = pendingDatasetLoad,
          pending.generation == sessionGeneration,
          groupSession != nil,
          runtimeAppModel?.groupSessionHost != true else { return }
    guard pendingDatasetLoadTask == nil else { return }
    let origins = knownOrigins(for: pending.uniqueID)
    runtimeAppModel?.beginResolvingSharePlayDataset(
      uniqueID: pending.uniqueID,
      description: pending.description
    )
    guard !origins.isEmpty else {
      runtimeAppModel?.sharePlayDatasetSource = nil
      runtimeAppModel?.logger.warning("No known source currently provides SharePlay dataset \(pending.uniqueID); waiting for participant sources.")
      schedulePendingDatasetLoadRetry(
        uniqueID: pending.uniqueID,
        generation: pending.generation
      )
      return
    }
    runtimeAppModel?.logger.info("Trying \(origins.count) known source(s) for SharePlay dataset \(pending.uniqueID).")
    pendingDatasetLoadTask = Task { [weak self] in
      guard let self else { return }
      await self.openFirstReachableRemoteDataset(
        uniqueID: pending.uniqueID,
        description: pending.description,
        origins: origins,
        sessionGeneration: pending.generation
      )
    }
  }

  @MainActor
  private func openFirstReachableRemoteDataset(
    uniqueID: String,
    description: String,
    origins: [DatasetOrigin],
    sessionGeneration generation: Int
  ) async {
    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel else { return }

    guard let remoteSource = await firstReachableOrigin(origins, datasetID: uniqueID) else {
      guard !Task.isCancelled, generation == sessionGeneration,
            groupSession != nil,
            pendingDatasetLoad?.uniqueID == uniqueID else { return }
      runtimeAppModel.sharePlayDatasetSource = nil
      runtimeAppModel.logger.warning("None of the known sources currently provides SharePlay dataset \(uniqueID); retrying after all sources have timed out.")
      schedulePendingDatasetLoadRetry(uniqueID: uniqueID, generation: generation)
      return
    }

    guard generation == sessionGeneration,
          groupSession != nil,
          !runtimeAppModel.groupSessionHost,
          pendingDatasetLoad?.uniqueID == uniqueID else { return }
    runtimeAppModel.sharePlayDatasetSource = nil
    let dataset = RuntimeAppModel.DatasetEntry(
      identifier: uniqueID,
      description: description,
      source:.remote(address: remoteSource.address, port: remoteSource.port, password: remoteSource.password),
      uniqueId: uniqueID
    )
    runtimeAppModel.logger.info("Loading SharePlay dataset \(uniqueID) from \(remoteSource.address):\(remoteSource.port).")
    pendingDatasetLoad = nil
    pendingDatasetLoadTask = nil
    runtimeAppModel.startImmersiveSpace(dataset: dataset, asGroupSessionHost:false)
  }

  @MainActor
  private func schedulePendingDatasetLoadRetry(uniqueID: String, generation: Int) {
    pendingDatasetLoadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled, let self else { return }
      guard generation == sessionGeneration,
            pendingDatasetLoad?.generation == generation,
            pendingDatasetLoad?.uniqueID == uniqueID,
            groupSession != nil else { return }
      pendingDatasetLoadTask = nil
      retryPendingDatasetLoad()
    }
  }

  @MainActor
  private func firstReachableOrigin(_ origins: [DatasetOrigin], datasetID: String) async -> DatasetOrigin? {
    await BorgVRRemoteOriginResolver.firstReachable(
      origins, datasetID: datasetID, timeout: max(0.1, storedAppModel?.timeout ?? StoredAppModel.double("timeout")), logger: runtimeAppModel?.logger,
      checking: { [weak self] origin in self?.runtimeAppModel?.sharePlayDatasetSource = origin },
      receivedCatalog: { origin, ids in
        DatasetOriginCatalog.shared.recordServerSnapshot(origin: origin, datasetIDs: ids,
          allowsSharing: DatasetOriginCatalog.shared.sharingAllowed(for: origin))
      }
    )
  }

  @MainActor
  private func shareOrigins(for dataset: RuntimeAppModel.DatasetEntry) async -> [DatasetOrigin] {
    var immediateOrigins: [DatasetOrigin] = []
    switch dataset.source {
      case .remote(let address, let port, let password):
        let origin = DatasetOrigin(address: address, port: port, password: password)
        let mayShare = storedAppModel?.servers.first {
          $0.address.caseInsensitiveCompare(address) == .orderedSame && $0.port == port
        }?.shareViaSharePlay ?? false
        DatasetOriginCatalog.shared.record(origin: origin, for: dataset.uniqueId, allowsSharing: mayShare)
        if mayShare {
          immediateOrigins.append(origin)
        }
      case .local, .builtIn:
        let served = await ensureServing(dataset: dataset)
        immediateOrigins = served.origins.compactMap { value in
          guard let endpoint = splitAddressAndPort(value) else { return nil }
          return DatasetOrigin(address: endpoint.address, port: endpoint.port, password: served.authToken)
        }
    }
    return DatasetOriginCatalog.deduplicated(
      immediateOrigins + DatasetOriginCatalog.shared.shareableOrigins(for: dataset.uniqueId)
    )
  }

  @MainActor
  private func knownOrigins(for datasetID: String) -> [DatasetOrigin] {
    return DatasetOriginCatalog.deduplicated(
      sessionEngine.knownSessionOrigins(for: datasetID)
        + DatasetOriginCatalog.shared.origins(for: datasetID)
    )
  }

  @MainActor
  private func retryMissingSceneMeshAssets() {
    guard groupSession != nil,
          let sharedAppModel,
          let datasetID = runtimeAppModel?.activeDataset?.uniqueId else { return }
    sharedAppModel.resolveSceneMeshAssets()
    let missingIDs = Set(sharedAppModel.sceneMeshInstances.map(\.asset.assetID)).subtracting(
      sharedAppModel.sceneMeshAssets.keys
    )
    guard !missingIDs.isEmpty else { return }
    guard sceneMeshResolutionTask == nil else {
      sceneMeshResolutionRetryRequested = true
      return
    }
    let origins = knownOrigins(for: datasetID)
    guard !origins.isEmpty else { return }

    let generation = sessionGeneration
    let timeout = max(0.1, storedAppModel?.timeout ?? StoredAppModel.double("timeout"))
    runtimeAppModel?.logger.info(
      "Searching \(origins.count) known source(s) for \(missingIDs.count) missing shared object asset(s)."
    )
    sceneMeshResolutionTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        SceneMeshAssetCatalog.resolveRemoteAssets(
          assetIDs: missingIDs,
          origins: origins,
          timeout: timeout
        )
      }.value
      guard let self, generation == sessionGeneration, groupSession != nil else { return }

      sharedAppModel.resolveSceneMeshAssets()
      for attempt in result.attempts {
        if attempt.resolvedCount > 0 {
          runtimeAppModel?.logger.info(
            "Loaded \(attempt.resolvedCount) shared object asset(s) from \(attempt.endpoint)."
          )
        } else if let error = attempt.errorDescription {
          runtimeAppModel?.logger.warning(
            "Could not load shared object assets from \(attempt.endpoint): \(error)"
          )
        }
      }
      if !result.missingIDs.isEmpty {
        runtimeAppModel?.logger.warning(
          "\(result.missingIDs.count) shared object asset(s) are still unavailable."
        )
      }

      sceneMeshResolutionTask = nil
      if sceneMeshResolutionRetryRequested {
        sceneMeshResolutionRetryRequested = false
        retryMissingSceneMeshAssets()
      }
    }
  }

  @MainActor
  private func mergeSessionOrigins(_ origins: [DatasetOrigin], for datasetID: String) {
    sessionEngine.mergeSessionOrigins(origins, for: datasetID)
  }

  @MainActor
  private func sendOriginCatalogSnapshot(to participants: Participants = .all) async {
    let snapshot = sessionEngine.combinedOriginSnapshot(
      with: DatasetOriginCatalog.shared.shareableSnapshot()
    )
    guard let data = try? DatasetOriginSharePlayCodec.encode(snapshot) else { return }
    try? await sendData(data: data, of: .originCatalogSnapshot, to: participants)
  }

  @MainActor
  private func handleOriginCatalogSnapshot(data: Data) {
    do {
      let snapshot = try DatasetOriginSharePlayCodec.decode(DatasetOriginSnapshot.self, from: data)
      DatasetOriginCatalog.shared.mergeRemoteSnapshot(snapshot)
      sessionEngine.mergeOriginSnapshot(snapshot)
      runtimeAppModel?.logger.info("Received a SharePlay source catalog with \(snapshot.entries.count) server(s).")
      retryPendingDatasetLoad()
      retryMissingSceneMeshAssets()
    } catch {
      runtimeAppModel?.logger.warning("Could not decode SharePlay source catalog: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func advertiseCurrentLocalDataset(to participants: Participants = .all) async {
    guard groupSession != nil,
          let dataset = runtimeAppModel?.activeDataset,
          dataset.uniqueId == sessionEngine.sessionDatasetID else { return }
    let served = await ensureServing(dataset: dataset)
    guard groupSession != nil, dataset.uniqueId == sessionEngine.sessionDatasetID else { return }
    let origins = served.origins.compactMap { value -> DatasetOrigin? in
      guard let endpoint = splitAddressAndPort(value) else { return nil }
      return DatasetOrigin(address: endpoint.address, port: endpoint.port, password: served.authToken)
    }
    guard !origins.isEmpty else { return }
    let advertisement = DatasetOriginAdvertisement(datasetID: dataset.uniqueId, origins: origins)
    guard let data = try? DatasetOriginSharePlayCodec.encode(advertisement) else { return }
    runtimeAppModel?.logger.info("Advertising this Apple Vision Pro as a SharePlay source for dataset \(dataset.uniqueId).")
    try? await sendData(data: data, of: .datasetOriginAdvertisement, to: participants)
  }

  @MainActor
  private func handleLocalDatasetCacheCompletion(
    _ completion: BORGVRLocalDatasetCacheCompletion
  ) {
    if storedAppModel?.showNotifications == true {
      NotificationHelper.notify(
        title: NSLocalizedString(
          "notfication_dataset_downloaded_title",
          value: "Remote Dataset Complete",
          comment: ""
        ),
        body: NSLocalizedString(
          "notfication_dataset_downloaded_text",
          value: "The dataset has been downloaded in its entirety and is now available locally.",
          comment: ""
        ),
        sound: nil
      )
    }

    guard groupSession != nil,
          completion.datasetID == sessionEngine.sessionDatasetID,
          runtimeAppModel?.activeDataset?.uniqueId == completion.datasetID else { return }
    runtimeAppModel?.logger.info(
      "The SharePlay dataset is now fully cached locally; enabling its ad-hoc source."
    )
    Task { await advertiseCurrentLocalDataset() }
  }

  @MainActor
  private func handleDatasetOriginAdvertisement(data: Data, from participant: Participant) {
    do {
      let advertisement = try DatasetOriginSharePlayCodec.decode(
        DatasetOriginAdvertisement.self,
        from: data
      )
      sessionEngine.setAdvertisedOrigins(
        advertisement.origins,
        for: advertisement.datasetID,
        participantID: participant.id
      )
      runtimeAppModel?.logger.info("Received \(advertisement.origins.count) participant source(s) for dataset \(advertisement.datasetID).")
      retryPendingDatasetLoad()
      retryMissingSceneMeshAssets()
    } catch {
      runtimeAppModel?.logger.warning("Could not decode SharePlay participant source: \(error.localizedDescription)")
    }
  }

  @MainActor
  func takeOverHostRole() {
    guard groupSession != nil,
          let claim = sessionEngine.makeLocalHostClaim() else { return }
    runtimeAppModel?.showsHostDeparturePrompt = false
    resolveHostElection(term: claim.term)
    Task {
      guard let data = try? BorgVRSharePlayHostCodec.encode(claim) else { return }
      try? await sendData(data: data, of: .hostClaim)
    }
  }

  @MainActor
  func ignoreHostDeparture() {
    runtimeAppModel?.showsHostDeparturePrompt = false
  }

  @MainActor
  private func handleHostParticipantChanges(
    _ change: BorgVRSharePlaySessionEngine.ParticipantChange
  ) {
    resolveHostElection(term: sessionEngine.hostElectionTerm)
    guard change.hostDeparted, sessionEngine.currentHostParticipantID == nil else { return }
    runtimeAppModel?.groupSessionHost = false
    runtimeAppModel?.showsHostDeparturePrompt = true
    runtimeAppModel?.logger.warning("The SharePlay host left the session; waiting for a new host.")
  }

  @MainActor
  private func sendCurrentHostState(to participants: Participants = .all) async {
    guard let state = sessionEngine.currentHostState() else { return }
    guard let data = try? BorgVRSharePlayHostCodec.encode(state) else { return }
    try? await sendData(data: data, of: .hostState, to: participants)
  }

  @MainActor
  private func handleHostClaim(data: Data, from participantID: UUID) {
    guard let claim = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostClaim.self,
      from: data
    ), claim.candidateID == participantID else { return }
    registerHostClaim(claim)
  }

  @MainActor
  private func registerHostClaim(_ claim: BorgVRSharePlayHostClaim) {
    switch sessionEngine.registerHostClaim(claim) {
      case .ignored:
        return
      case .resolutionRequested(let term):
        runtimeAppModel?.groupSessionHost = false
        resolveHostElection(term: term)
    }
  }

  @MainActor
  private func resolveHostElection(term: UInt64) {
    guard let transition = sessionEngine.resolveHostElection(term: term) else { return }
    applyHostTransition(transition)
    Task {
      await sendCurrentHostState()
      if transition.isLocalHost { await sendInitialData() }
    }
  }

  @MainActor
  private func handleHostState(data: Data, from participantID: UUID) {
    guard let state = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostState.self,
      from: data
    ), let transition = sessionEngine.receiveHostState(state, from: participantID) else { return }
    applyHostTransition(transition)
    if transition.isLocalHost { Task { await sendInitialData() } }
  }

  @MainActor
  private func applyHostTransition(
    _ transition: BorgVRSharePlaySessionEngine.HostTransition
  ) {
    runtimeAppModel?.showsHostDeparturePrompt = false
    runtimeAppModel?.groupSessionHost = transition.isLocalHost
    refreshEditCollaboration()
    if transition.isLocalHost {
      stateVersionDatasetID = runtimeAppModel?.activeDataset?.uniqueId
      setSessionDatasetID(runtimeAppModel?.activeDataset?.uniqueId)
    } else if transition.previousHostID != transition.hostID {
      stateVersionDatasetID = nil
    }
    runtimeAppModel?.logger.info(transition.isLocalHost
      ? "This device took over the SharePlay host role."
      : "A participant took over the SharePlay host role.")
  }

  @MainActor
  private func setSessionDatasetID(_ datasetID: String?) {
    guard sessionEngine.setSessionDatasetID(datasetID) else { return }
    refreshEditCollaboration()
    stopSharePlayServer()
    if let datasetID {
      runtimeAppModel?.logger.info("SharePlay ad-hoc server is restricted to host dataset \(datasetID).")
    } else {
      runtimeAppModel?.logger.info("SharePlay ad-hoc server stopped because no host dataset is active.")
    }
  }

  private func splitAddressAndPort(_ input: String) -> (address: String, port: Int)? {
    guard let idx = input.lastIndex(of: ":"),
          let port = Int(input[input.index(after: idx)...]) else { return nil }
    return (String(input[..<idx]), port)
  }

  @MainActor
  private func ensureServing(dataset: RuntimeAppModel.DatasetEntry) async -> (origins: [String], authToken: String) {
    if let startup = serverStartup, startup.datasetID == dataset.uniqueId { return await startup.task.value }
    if sharePlayServerRunning, sharePlayDatasetID == dataset.uniqueId,
       sharePlayMeshAssetIDs == Set(SceneMeshAssetCatalog.serverFiles(logger: runtimeAppModel?.logger).map(\.id)) {
      return (originAddresses(port: sharePlayServerPort), sharePlayAuthToken)
    }
    stopSharePlayServer()
    let generation = serverGeneration
    let task = Task { @MainActor in await self.startServing(dataset: dataset, generation: generation) }
    serverStartup = (dataset.uniqueId, task)
    let result = await task.value
    if serverGeneration == generation { serverStartup = nil }
    return result
  }

  @MainActor
  private func startServing(dataset: RuntimeAppModel.DatasetEntry, generation: UUID) async -> (origins: [String], authToken: String) {
    guard !Task.isCancelled, serverGeneration == generation else { return ([], "") }
    guard let datasetInfo = serverDatasetInfo(for: dataset) else {
      stopSharePlayServer()
      return ([], "")
    }
    let meshFiles = SceneMeshAssetCatalog.serverFiles(logger: runtimeAppModel?.logger)
    let meshAssetIDs = Set(meshFiles.map(\.id))

    if sharePlayServerRunning,
       sharePlayDatasetID == dataset.uniqueId,
       sharePlayMeshAssetIDs == meshAssetIDs {
      return (originAddresses(port: sharePlayServerPort), sharePlayAuthToken)
    }

    let authToken = BorgVRServerAuthentication.randomToken()
    for port in sharePlayCandidatePorts(preferredPort: storedAppModel?.sharePlayServerPort ?? sharePlayServerPort) {
      guard !Task.isCancelled, serverGeneration == generation else { return ([], "") }
      let state = await sharePlayServerHost.start(
        configuration: BorgVRServerConfiguration(
          dataDirectory: "",
          port: port,
          maxBricksPerGetRequest: BorgVRSharedDefaults.maximumBricksPerRequest,
          authSecret: authToken,
          enableWebServer: storedAppModel?.enableWebServer ?? false,
          webPort: sharePlayWebPort(for: port),
          useWebServerTLS: storedAppModel?.webServerUsesTLS ?? true,
          webServerCertificateData: storedAppModel?.webServerCertificateData ?? Data(),
          webServerCertificatePassword: storedAppModel?.webServerCertificatePassword ?? ""
        ),
        additionalDatasets: [datasetInfo],
        additionalMeshFiles: meshFiles,
        includeScannedDatasets: false
      )

      guard !Task.isCancelled, serverGeneration == generation else { return ([], "") }
      guard state.serverError == nil, state.isRunning,
            state.datasets.contains(where: { $0.id == dataset.uniqueId }) else {
        continue
      }

      sharePlayDatasetID = dataset.uniqueId
      sharePlayAuthToken = authToken
      sharePlayServerRunning = true
      sharePlayServerPort = state.port
      sharePlayMeshAssetIDs = meshAssetIDs
      return (originAddresses(port: state.port), authToken)
    }

    runtimeAppModel?.logger.error("SharePlay asset server did not start for dataset \(dataset.uniqueId).")
    return ([], "")
  }

  @MainActor
  private func stopSharePlayServer() {
    serverGeneration = UUID()
    serverStartup?.task.cancel(); serverStartup = nil
    sharePlayServerHost.stop()
    sharePlayDatasetID = nil
    sharePlayAuthToken = ""
    sharePlayServerRunning = false
    sharePlayMeshAssetIDs.removeAll()
  }

  @MainActor
  private func sharePlayWebPort(for serverPort: Int) -> Int {
    guard let storedAppModel else {
      return min(65535, max(1, serverPort + 1))
    }
    if storedAppModel.sharePlayWebServerPort == storedAppModel.sharePlayServerPort {
      return min(65535, max(1, serverPort + 1))
    }
    return storedAppModel.sharePlayWebServerPort
  }

  @MainActor
  private func serverDatasetInfo(for dataset: RuntimeAppModel.DatasetEntry) -> DatasetInfo? {
    let url: URL
    let shouldLogMetadataFailure: Bool
    switch dataset.source {
      case .local, .builtIn:
        url = URL(fileURLWithPath: dataset.identifier)
        shouldLogMetadataFailure = true
      case .remote:
        guard let documentsDirectory = FileManager.default.urls(
          for: .documentDirectory,
          in: .userDomainMask
        ).first else { return nil }
        url = documentsDirectory.appendingPathComponent("\(dataset.uniqueId).data")
        shouldLogMetadataFailure = false
    }

    guard let metadata = try? BORGVRMetaData(url: url),
          metadata.uniqueID.caseInsensitiveCompare(dataset.uniqueId) == .orderedSame else {
      if shouldLogMetadataFailure {
        runtimeAppModel?.logger.error("SharePlay dataset server could not read metadata for \(dataset.identifier).")
      }
      return nil
    }
    return DatasetInfo(
      id: metadata.uniqueID,
      filename: url.path,
      datasetDescription: metadata.datasetDescription.isEmpty ? dataset.description : metadata.datasetDescription,
      size: [metadata.width, metadata.height, metadata.depth],
      voxelSpacing: [
        metadata.voxelSpacingX,
        metadata.voxelSpacingY,
        metadata.voxelSpacingZ
      ]
    )
  }

  @MainActor
  private func originAddresses(port: Int) -> [String] {
    let addresses = Self.localIPv4Addresses()
    var seen = Set<String>()
    let uniqueAddresses = addresses.filter { address in
      seen.insert(address).inserted
    }

    guard !uniqueAddresses.isEmpty else {
      runtimeAppModel?.logger.error("SharePlay dataset server could not determine a local network address.")
      return []
    }
    return uniqueAddresses.map { "\($0):\(port)" }
  }

  private func sharePlayCandidatePorts(preferredPort: Int) -> [Int] {
    let basePort = min(65534, max(1024, preferredPort))
    var ports: [Int] = [basePort]
    for offset in 1...64 {
      let port = basePort + offset
      if port <= 65535 {
        ports.append(port)
      }
    }
    for offset in 1...64 {
      let port = basePort - offset
      if port >= 1024 {
        ports.append(port)
      }
    }

    var seen = Set<Int>()
    return ports.filter { seen.insert($0).inserted }
  }

  private static func localIPv4Addresses() -> [String] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return []
    }
    defer { freeifaddrs(interfaces) }

    var preferredAddresses: [String] = []
    var fallbackAddresses: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let interface = pointer?.pointee {
      defer { pointer = interface.ifa_next }

      let flags = Int32(interface.ifa_flags)
      guard (flags & IFF_UP) != 0,
            (flags & IFF_LOOPBACK) == 0,
            let addressPointer = interface.ifa_addr,
            addressPointer.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        addressPointer,
        socklen_t(addressPointer.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard result == 0 else { continue }

      let address = String(cString: hostname)
      let name = String(cString: interface.ifa_name)
      if name.hasPrefix("en") {
        preferredAddresses.append(address)
      } else {
        fallbackAddresses.append(address)
      }
    }

    return preferredAddresses + fallbackAddresses
  }

  @MainActor
  func handleUpdate(data: Data, from: Participant) {
    guard let sharedAppModel else { return }
    do {
      if let transformUpdate = try SharedAppModel.decodeVisionSharePlayTransformIfPresent(data) {
        guard let runtimeAppModel,
              runtimeAppModel.activeDataset?.uniqueId == transformUpdate.datasetID else {
          runtimeAppModel?.logger.warning(
            "Ignored a SharePlay transform for a dataset that is not active."
          )
          return
        }
        let previousRevision = receivedVisionTransformRevisionByParticipantID[from.id] ?? 0
        guard transformUpdate.revision > previousRevision else { return }
        receivedVisionTransformRevisionByParticipantID[from.id] = transformUpdate.revision
        runtimeAppModel.spatialAnchorSessionState.expectSharedAnchor(transformUpdate.anchorID)
        let activeAnchorID = runtimeAppModel.spatialAnchorSessionState.snapshot().activeAnchorID
        sharedAppModel.receiveVisionSharePlayTransform(
          transformUpdate,
          activeDatasetID: transformUpdate.datasetID,
          activeAnchorID: activeAnchorID
        )
        return
      }
      if let update = try BorgVRSharePlayCommonUpdateDecoder.decode(data) {
        switch update {
          case .spatialToolPreviews(let previews):
            sharedAppModel.updateRemoteSpatialToolPreviews(
              previews,
              participantID: from.id
            )
          case .measurements(let measurements):
            let extent = runtimeAppModel?.activeDatasetInfo?.physicalExtentMeters
            sharedAppModel.volumeMeasurements = measurements.map { measurement in
              guard let extent else { return measurement }
              return VolumeMeasurement(
                id: measurement.id,
                name: measurement.name,
                kind: measurement.kind,
                points: measurement.points,
                physicalExtent: extent
              )
            }
            sharedAppModel.clearVolumeMeasurementSelection()
          case .annotations(let annotations):
            sharedAppModel.volumeMarkers = annotations.markers
            sharedAppModel.replaceSceneMeshInstances(annotations.meshInstances)
            sharedAppModel.setVolumeMarkerSelection(
              sharedAppModel.selectedVolumeMarkerIDs,
              primary: sharedAppModel.selectedVolumeMarkerID
            )
            retryMissingSceneMeshAssets()
          case .screenView(let screenView):
            applyScreenViewUpdate(screenView, from: from)
        }
        return
      }
      if try sharedAppModel.applySharePlayUpdate(from: data) {
        runtimeAppModel?.clampSelectedTransferFunctionChannel(
          to: sharedAppModel.componentCount
        )
        return
      }
      try sharedAppModel.applyUpdate(from: data)
      runtimeAppModel?.clampSelectedTransferFunctionChannel(
        to: sharedAppModel.componentCount
      )
    } catch {
      print("Failed to apply update: \(error)")
    }
  }

  @MainActor
  func handleShutdown(from: Participant) {
    setSessionDatasetID(nil)
    runtimeAppModel?.requestDatasetClose(
      destination: .sharePlayWaiting(.hostDataset)
    )
  }
}
