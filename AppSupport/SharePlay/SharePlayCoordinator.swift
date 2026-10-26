import Combine
import Foundation
import GroupActivities
import SwiftUI

private let borgVRSharePlayActivityIdentifier = "de.cgvis.borgvr.collaboration"
private let localBorgVRSharePlayInitiatorID = UUID()

struct BorgVRSharePlayActivity: GroupActivity, Transferable {
  static let activityIdentifier = borgVRSharePlayActivityIdentifier
  let initiatorID: UUID

  init(initiatorID: UUID = localBorgVRSharePlayInitiatorID) {
    self.initiatorID = initiatorID
  }

  var metadata: GroupActivityMetadata = {
    var metadata = GroupActivityMetadata()
#if os(iOS)
    metadata.title = String(localized: "BorgVR Mobile Live Collaboration")
#else
    metadata.title = String(localized: "BorgVR Live Collaboration")
#endif
    metadata.subtitle = String(localized: "Collaborate on the same volumetric dataset.")
    metadata.type = .generic
    metadata.sceneAssociationBehavior = .content(borgVRSharePlayActivityIdentifier)
    return metadata
  }()
}

@MainActor
final class SharePlayCoordinator: ObservableObject {
  @Published private(set) var isInSession = false
  @Published private(set) var participants: [BorgVRSharePlayParticipant] = []
  @Published private(set) var isScreenViewSynchronized = true
  @Published private(set) var showsSystemSharePlayJoinInstructions = false
  @Published var showsHostDeparturePrompt = false
  @Published var protocolCompatibilityIssue: BorgVRSharePlayCompatibilityIssue?

  private var groupSession: GroupSession<BorgVRSharePlayActivity>?
  private var messenger: GroupSessionMessenger?
  private var sessionObservationTask: Task<Void, Never>?
  private var messageTask: Task<Void, Never>?
  private var sessionGeneration = 0
  private var appModel: AppModel?
  private var renderingParameters: RenderingParameters?
  private var appSettings: AppSettings?
  private let platformAdapter: BorgVRSharePlayPlatformAdapter
  private var subscriptions = Set<AnyCancellable>()
  private var localDatasetCacheCompletionObservation: AnyCancellable?
  private var pendingSynchronization = BorgVRSharePlayPendingSynchronization()
  private var synchronizationTask: Task<Void, Never>?
  private var knownParticipants = Set<Participant>()
  private var sessionEngine = BorgVRSharePlaySessionEngine()
  private var sharedScreenViewState: BorgVRScreenViewState?
  private var screenViewSynchronizationGeneration = 0
  private struct PendingDatasetLoad {
    let uniqueID: String
    let description: String
    let generation: Int
  }
  private var pendingDatasetLoad: PendingDatasetLoad?
  private var pendingDatasetLoadTask: Task<Void, Never>?
  private var sceneMeshResolutionTask: Task<Void, Never>?
  private var sceneMeshResolutionRetryRequested = false
  private var eligibilityObservation: AnyCancellable?
  private var lastGroupSessionEligibility: Bool?
  private var awaitsSessionFromSharingController = false
  private var editCollaboration: BorgVRVolumeEditCollaboration?

  private func refreshEditCollaboration() {
    guard let appModel, let localID = sessionEngine.localParticipantID, isInSession else { return }
    if editCollaboration == nil {
      editCollaboration = BorgVRVolumeEditCollaboration(model: appModel.volumeBrush, send: { [weak self] data, target in
        guard let self, self.messenger != nil else { throw CancellationError() }
        if let target {
          guard let participant = self.knownParticipants.first(where: { $0.id == target }) else { throw CancellationError() }
          try await self.sendData(data, of: .volumeEditing, to: .only(Set([participant])))
        } else { try await self.sendData(data, of: .volumeEditing) }
      }, log: { [weak appModel] in appModel?.logger.warning($0) },
        info: { [weak appModel] in appModel?.logger.info($0) })
    }
    editCollaboration?.configure(localID: localID, hostID: sessionEngine.currentHostParticipantID,
      datasetID: sessionEngine.sessionDatasetID, participants: Set(knownParticipants.map(\.id)))
  }

  init(platformAdapter: BorgVRSharePlayPlatformAdapter) {
    self.platformAdapter = platformAdapter
  }

  func startObservingSessions(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    appSettings: AppSettings
  ) {
    self.appModel = appModel
    self.renderingParameters = renderingParameters
    self.appSettings = appSettings

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

    if eligibilityObservation == nil,
       let eligibilityPublisher = platformAdapter.eligibilityPublisher {
      eligibilityObservation = eligibilityPublisher
        .sink { [weak self] isEligible in
          Task { @MainActor [weak self] in
            guard let self else { return }
            let previousEligibility = lastGroupSessionEligibility
            if let previousEligibility {
              appModel.logger.info(
                "SharePlay group-session eligibility changed: \(previousEligibility) -> \(isEligible)."
              )
            } else {
              appModel.logger.info(
                "Initial SharePlay group-session eligibility: \(isEligible)."
              )
            }
            lastGroupSessionEligibility = isEligible
            if isEligible,
               previousEligibility == false,
               awaitsSessionFromSharingController,
               !isInSession {
              showsSystemSharePlayJoinInstructions = true
              appModel.logger.info(
                "SharePlay is ready in FaceTime; waiting for the local user to join from the system SharePlay menu."
              )
            } else if !isEligible, awaitsSessionFromSharingController {
              clearPendingSharePlayStart(resetHost: true)
            }
          }
        }
    }

    guard sessionObservationTask == nil else { return }
    appModel.logger.info("Starting SharePlay group-session observation.")
    let sessions = BorgVRSharePlayActivity.sessions()
    sessionObservationTask = Task { [weak self] in
      for await session in sessions {
        guard let self else { return }
        appModel.logger.info(
          "SharePlay delivered a group session; activity initiator: \(session.activity.initiatorID.uuidString), initial participant count: \(session.activeParticipants.count)."
        )
        configure(session)
      }
    }
  }

  func markLocalActivityStarter() {
    appModel?.groupSessionHost = true
  }

  func startSharePlay() {
    clearPendingSharePlayStart()
    markLocalActivityStarter()
    let activity = BorgVRSharePlayActivity()
    Task { [weak self] in
      guard let self else { return }
      do {
        switch try await platformAdapter.activate(activity) {
          case .sessionExpected(let sessionWillBeDelivered):
            appModel?.logger.info(
              "SharePlay activation completed; session will be delivered: \(sessionWillBeDelivered)."
            )
            if !sessionWillBeDelivered, !isInSession {
              clearPendingSharePlayStart(resetHost: true)
            }
          case .waitingForSystemJoin:
            awaitsSessionFromSharingController = true
            appModel?.logger.info(
              "SharePlay sharing completed; waiting for its group session."
            )
            if lastGroupSessionEligibility == true, !isInSession {
              showsSystemSharePlayJoinInstructions = true
            }
          case .disabled:
            appModel?.logger.info("SharePlay activation is disabled.")
            clearPendingSharePlayStart(resetHost: true)
          case .cancelled:
            appModel?.logger.info("SharePlay activation was cancelled.")
            clearPendingSharePlayStart(resetHost: true)
        }
      } catch {
        appModel?.logger.error("Failed to start SharePlay: \(error.localizedDescription)")
        clearPendingSharePlayStart(resetHost: true)
      }
    }
  }

  private func clearPendingSharePlayStart(resetHost: Bool = false) {
    awaitsSessionFromSharingController = false
    showsSystemSharePlayJoinInstructions = false
    if resetHost, !isInSession {
      appModel?.groupSessionHost = false
    }
  }

  func datasetOpened() {
    guard isInSession else { return }
    if appModel?.groupSessionHost == true {
      advanceHostStateVersion()
      setSessionDatasetID(appModel?.activeDataset?.uniqueId)
      resetPendingSynchronizationForDatasetChange()
      sharedScreenViewState = nil
    }
    Task {
      await sendOriginCatalogSnapshot()
      await advertiseCurrentLocalDataset()
      if appModel?.groupSessionHost == true {
        await sendDatasetAnnouncement()
      }
    }
  }

  func datasetRendererDidLoad() {
    guard isInSession else { return }
    retryMissingSceneMeshAssets()
    if appModel?.groupSessionHost == true {
      if isScreenViewSynchronized, let renderingParameters {
        sharedScreenViewState = renderingParameters.screenViewState
      }
      Task { await sendInitialData() }
    } else {
      Task { await requestInitialState() }
    }
  }

  func closeSharedDataset() {
    guard isInSession else { return }
    if appModel?.groupSessionHost == true {
      advanceHostStateVersion()
      setSessionDatasetID(nil)
      Task { try? await sendData(Data(), of: .shutdownRequest) }
    } else {
      groupSession?.leave()
    }
  }

  func leaveGroupActivity() {
    clearPendingSharePlayStart()
    setSessionDatasetID(nil)
    groupSession?.leave()
    appModel?.groupSessionHost = false
    isInSession = false
    resetSessionReceivers()
  }

  func synchronize(kind: RenderingParameters.UpdateKind) {
    guard isInSession else { return }

    switch kind {
      case .full:
        pendingSynchronization.markCommonState(includeTransferFunction: true)
      case .stateOnly:
        pendingSynchronization.markCommonState(includeTransferFunction: false)
      case .transformOnly:
        pendingSynchronization.markTransform()
    }

    guard synchronizationTask == nil else {
      return
    }

    let delay = pendingSynchronization.preferredDelayNanoseconds
    synchronizationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      await self?.flushPendingSynchronization()
    }
  }

  func flushSynchronization() {
    guard isInSession else { return }
    synchronizationTask?.cancel()
    synchronizationTask = nil
    Task { await flushPendingSynchronization() }
  }

  func synchronizeMarkers(immediately: Bool = false) {
    guard isInSession else { return }
    refreshAdvertisedSceneMeshAssetsIfNeeded()
    pendingSynchronization.markAnnotations()
    if immediately {
      flushSynchronization()
      return
    }
    guard synchronizationTask == nil else { return }
    synchronizationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard !Task.isCancelled else { return }
      await self?.flushPendingSynchronization()
    }
  }

  private func refreshAdvertisedSceneMeshAssetsIfNeeded() {
    guard let appModel,
          let dataset = appModel.activeDataset else { return }
    let referencedAssetIDs = Set(appModel.sceneMeshInstances.map(\.asset.assetID))
    guard !platformAdapter.serves(
      meshAssetIDs: referencedAssetIDs,
      for: dataset.uniqueId
    ) else { return }
    Task { await advertiseCurrentLocalDataset() }
  }

  func synchronizeMeasurements(immediately: Bool = false) {
    guard isInSession else { return }
    pendingSynchronization.markMeasurements()
    if immediately {
      flushSynchronization()
      return
    }
    guard synchronizationTask == nil else { return }
    synchronizationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard !Task.isCancelled else { return }
      await self?.flushPendingSynchronization()
    }
  }

  func participantInfoChanged() {
    Task { await sendParticipantInfo() }
  }

  func setScreenViewSynchronizationEnabled(_ enabled: Bool) {
    guard isScreenViewSynchronized != enabled else { return }
    isScreenViewSynchronized = enabled
    screenViewSynchronizationGeneration += 1
    let generation = screenViewSynchronizationGeneration
    if !enabled {
      pendingSynchronization.clearTransform()
    }

    guard let renderingParameters else { return }
    let localState = renderingParameters.screenViewState
    Task {
      await sendParticipantInfo()
      guard isInSession, generation == screenViewSynchronizationGeneration else { return }

      if enabled {
        if hasOtherSynchronizedScreenParticipant {
          if let sharedScreenViewState {
            renderingParameters.apply(sharedScreenViewState)
          }
          try? await sendData(Data(), of: .screenViewRequest)
        } else {
          sharedScreenViewState = localState
          try? await sendScreenViewState(localState, isShared: true)
        }
      } else {
        try? await sendScreenViewState(localState, isShared: false)
      }
    }
  }

  private func configure(_ session: GroupSession<BorgVRSharePlayActivity>) {
    clearPendingSharePlayStart()
    appModel?.logger.info(
      "Configuring delivered SharePlay group session; local participant: \(session.localParticipant.id.uuidString), initial state: \(String(describing: session.state)), active participant count: \(session.activeParticipants.count)."
    )
    platformAdapter.stopSharePlayServer()
    resetSessionReceivers()
    sessionGeneration += 1
    let generation = sessionGeneration
    subscriptions.removeAll()
    groupSession = session
    isInSession = true
    let isHost = session.activity.initiatorID == localBorgVRSharePlayInitiatorID
    appModel?.groupSessionHost = isHost
    knownParticipants = session.activeParticipants
    sessionEngine.beginSession(
      localParticipantID: session.localParticipant.id,
      activeParticipantIDs: Set(session.activeParticipants.map(\.id)),
      isHost: isHost,
      datasetID: appModel?.activeDataset?.uniqueId
    )

    session.$activeParticipants
      .sink { [weak self] activeParticipants in
        Task { @MainActor [weak self] in
          guard let self, self.sessionGeneration == generation else { return }
          let previousParticipants = self.knownParticipants
          let newParticipants = activeParticipants.subtracting(self.knownParticipants)
          let departedParticipants = previousParticipants.subtracting(activeParticipants)
          self.knownParticipants = activeParticipants
          let activeIDs = Set(activeParticipants.map(\.id))
          if !newParticipants.isEmpty || !departedParticipants.isEmpty {
            let joinedIDs = newParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
            let departedIDs = departedParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
            let hostID = self.sessionEngine.currentHostParticipantID?.uuidString ?? "unknown"
            self.appModel?.logger.info(
              "SharePlay participants changed; joined: [\(joinedIDs)], departed: [\(departedIDs)], host: \(hostID), active count: \(activeIDs.count)."
            )
          }
          let change = self.sessionEngine.updateActiveParticipants(activeIDs)
          self.handleHostParticipantChanges(change)
          self.publishParticipants()
          guard !newParticipants.isEmpty else { return }
          await self.sendProtocolVersion(to: .only(newParticipants))
        }
      }
      .store(in: &subscriptions)

    session.$state
      .sink { [weak self] state in
        Task { @MainActor [weak self] in
          guard let self, self.sessionGeneration == generation else { return }
          self.appModel?.logger.info(
            "SharePlay group-session state changed to: \(String(describing: state))."
          )
          guard case .invalidated(let reason) = state else { return }
          self.appModel?.logger.warning(
            "SharePlay session invalidated by the system: \(reason.localizedDescription)"
          )
          self.platformAdapter.stopSharePlayServer()
          self.clearPendingSharePlayStart()
          self.resetSessionReceivers()
          self.isInSession = false
          self.appModel?.groupSessionHost = false
        }
      }
      .store(in: &subscriptions)

    let messenger = GroupSessionMessenger(session: session)
    self.messenger = messenger
    refreshEditCollaboration()
    messageTask = Task.detached { [weak self] in
      for await (data, context) in messenger.messages(of: Data.self) {
        if Task.isCancelled { return }
        await self?.handleIncoming(data: data, from: context.source, sessionGeneration: generation)
      }
    }
    appModel?.logger.info("Calling session.join() for the delivered SharePlay group session.")
    session.join()
    appModel?.logger.info(
      "session.join() returned; current state: \(String(describing: session.state))."
    )
    Task { await sendProtocolVersion() }
  }

  private typealias MessageType = BorgVRSharePlayProtocol.MessageType

  private func sendData(
    _ data: Data,
    of messageType: MessageType,
    to participants: Participants = .all
  ) async throws {
    guard let messenger else { return }
    let message = try BorgVRSharePlayWireCodec.encode(
      data,
      type: messageType,
      stateVersion: sessionEngine.stateVersion
    )
    try await messenger.send(message, to: participants)
  }

  private func sendParticipantInfo(to participants: Participants = .all) async {
    guard messenger != nil else { return }
    let configuredName = platformAdapter.configuredDisplayName
    let displayName = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
    let info = BorgVRSharePlayParticipantInfo(
      platform: platformAdapter.participantPlatform,
      displayName: displayName.isEmpty ? platformAdapter.defaultDisplayName : displayName,
      sharesScreenView: isScreenViewSynchronized
    )
    guard let data = try? BorgVRSharePlayParticipantInfoCodec.encode(info) else { return }
    try? await sendData(data, of: .participantInfo, to: participants)
  }

  private func sendProtocolVersion(to participants: Participants = .all) async {
    try? await sendData(
      BorgVRSharePlayVersionCodec.encode(),
      of: .protocolVersion,
      to: participants
    )
  }

  private func handleProtocolVersion(data: Data, from participant: Participant) {
    do {
      switch try sessionEngine.receiveProtocolVersion(data, from: participant.id) {
        case .alreadyAccepted:
          return
        case .incompatible(let issue):
          appModel?.logger.error(
            "Incompatible SharePlay protocol; version \(issue.requiredVersion) or later is required."
          )
          groupSession?.leave()
          platformAdapter.stopSharePlayServer()
          appModel?.groupSessionHost = false
          isInSession = false
          resetSessionReceivers()
          protocolCompatibilityIssue = issue
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
        if appModel?.groupSessionHost == true {
          await sendInitialData(to: .only(Set([participant])))
        } else {
          await requestInitialState(to: .only(Set([participant])))
        }
      }
    } catch {
      appModel?.logger.error("Invalid SharePlay protocol handshake: \(error)")
    }
  }

  private func handleParticipantInfo(data: Data, from participant: Participant) {
    do {
      let info = try BorgVRSharePlayParticipantInfoCodec.decode(data)
      let previousInfo = sessionEngine.setParticipantInfo(info, for: participant.id)
      publishParticipants()
      if info.platform != .visionOS,
         info.sharesScreenView,
         previousInfo?.sharesScreenView != true,
         isScreenViewSynchronized,
         let renderingParameters {
        let state = sharedScreenViewState ?? renderingParameters.screenViewState
        Task {
          try? await sendScreenViewState(
            state,
            isShared: true,
            to: .only(Set([participant]))
          )
        }
      }
    } catch {
      appModel?.logger.error("Failed to read SharePlay participant information: \(error)")
    }
  }

  private func publishParticipants() {
    refreshEditCollaboration()
    participants = sessionEngine.participants
  }

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
    isScreenViewSynchronized = true
    sharedScreenViewState = nil
    screenViewSynchronizationGeneration += 1
    knownParticipants.removeAll()
    sessionEngine.reset()
    pendingDatasetLoadTask?.cancel()
    pendingDatasetLoadTask = nil
    pendingDatasetLoad = nil
    sceneMeshResolutionTask?.cancel()
    sceneMeshResolutionTask = nil
    sceneMeshResolutionRetryRequested = false
    showsHostDeparturePrompt = false
    participants = []
    appModel?.clearRemoteSpatialToolPreviews()
  }

  private func resetPendingSynchronizationForDatasetChange() {
    synchronizationTask?.cancel()
    synchronizationTask = nil
    pendingSynchronization.reset()
  }

  private func sendDatasetAnnouncement(to participants: Participants = .all) async {
    guard appModel?.groupSessionHost == true else { return }

    guard let dataset = appModel?.activeDataset else {
      setSessionDatasetID(nil)
      try? await sendData(
        BorgVRSharePlayDatasetAnnouncement(
          uniqueID: "",
          origins: [],
          description: ""
        ).encoded(),
        of: .initMessage,
        to: participants
      )
      return
    }
    setSessionDatasetID(dataset.uniqueId)

    let message = BorgVRSharePlayDatasetAnnouncement(
      uniqueID: dataset.uniqueId,
      origins: await shareOrigins(for: dataset),
      description: dataset.description
    )
    guard isInSession, appModel?.groupSessionHost == true, appModel?.activeDataset?.uniqueId == dataset.uniqueId else { return }
    try? await sendData(message.encoded(), of: .initMessage, to: participants)
  }

  private func sendInitialData(to participants: Participants = .all) async {
    guard appModel?.groupSessionHost == true else { return }
    let generation = sessionGeneration
    let datasetID = appModel?.activeDataset?.uniqueId
    await sendDatasetAnnouncement(to: participants)
    guard !Task.isCancelled, generation == sessionGeneration, isInSession,
          appModel?.groupSessionHost == true, appModel?.activeDataset?.uniqueId == datasetID else { return }
    refreshEditCollaboration()
    guard appModel?.activeDataset != nil else { return }
    if let renderingParameters {
      try? await sendData(
        renderingParameters.serializeCommonSharePlayState(includeTransferFunction: true),
        of: .renderingUpdate,
        to: participants
      )
      if isScreenViewSynchronized {
        let state = sharedScreenViewState ?? renderingParameters.screenViewState
        sharedScreenViewState = state
        try? await sendScreenViewState(
          state,
          isShared: true,
          to: participants
        )
      }
    }
    if let appModel {
      try? await sendData(
        VolumeMarkerSharePlayCodec.encode(
          appModel.volumeMarkers,
          meshInstances: appModel.sceneMeshInstances
        ),
        of: .renderingUpdate,
        to: participants
      )
      try? await sendData(
        VolumeMeasurementSharePlayCodec.encode(appModel.volumeMeasurements),
        of: .renderingUpdate,
        to: participants
      )
    }
    switch participants {
      case .all: await editCollaboration?.sendSnapshot()
      case .only(let members):
        for participant in members { await editCollaboration?.sendSnapshot(to: participant.id) }
      @unknown default: break
    }
  }

  private func requestInitialState(to participants: Participants = .all) async {
    try? await sendData(Data(), of: .stateRequest, to: participants)
  }

  private func flushPendingSynchronization() async {
    synchronizationTask = nil
    guard let renderingParameters else { return }

    let batch = pendingSynchronization.takeBatch()

    do {
      if batch.commonState {
        try await sendData(
          renderingParameters.serializeCommonSharePlayState(
            includeTransferFunction: batch.transferFunction
          ),
          of: .renderingUpdate
        )
      }

      if batch.transform {
        let state = renderingParameters.screenViewState
        if isScreenViewSynchronized {
          sharedScreenViewState = state
        }
        try await sendScreenViewState(state, isShared: isScreenViewSynchronized)
      }

      if batch.annotations, let appModel {
        try await sendData(
          VolumeMarkerSharePlayCodec.encode(
            appModel.volumeMarkers,
            meshInstances: appModel.sceneMeshInstances
          ),
          of: .renderingUpdate
        )
      }
      if batch.measurements, let appModel {
        try await sendData(
          VolumeMeasurementSharePlayCodec.encode(appModel.volumeMeasurements),
          of: .renderingUpdate
        )
      }
    } catch {
      appModel?.logger.error("Failed to send SharePlay update: \(error.localizedDescription)")
    }
  }

  private func handleIncoming(data: Data, from participant: Participant, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, isInSession else { return }
    let message: BorgVRSharePlayWireMessage
    do {
      message = try BorgVRSharePlayWireCodec.decode(data)
    } catch {
      appModel?.logger.error("Invalid SharePlay message: \(error)")
      return
    }

    if message.type == .protocolVersion {
      handleProtocolVersion(data: message.payload, from: participant)
      return
    }
    guard sessionEngine.acceptsMessages(from: participant.id) else {
      appModel?.logger.warning("Ignored SharePlay data received before the protocol handshake.")
      return
    }
    if let stateVersion = message.stateVersion,
       !acceptStateVersion(stateVersion, for: message.type, from: participant) {
        return
    }

    switch message.type {
      case .volumeEditing:
        refreshEditCollaboration()
        editCollaboration?.receive(message.payload, from: participant.id)
      case .initMessage:
        guard appModel?.groupSessionHost != true else { return }
        handleInit(data: message.payload, sessionGeneration: generation)
      case .renderingUpdate:
        handleUpdate(data: message.payload, from: participant)
      case .shutdownRequest:
        guard appModel?.groupSessionHost != true else { return }
        setSessionDatasetID(nil)
        pendingDatasetLoadTask?.cancel()
        pendingDatasetLoadTask = nil
        pendingDatasetLoad = nil
        appModel?.removeAllVolumeMarkers()
        appModel?.removeAllVolumeMeasurements()
        appModel?.closeDataset(destination: .sharePlayWaiting(.hostDataset))
      case .stateRequest:
        guard appModel?.groupSessionHost == true else { return }
        Task { await sendInitialData(to: .only(Set([participant]))) }
      case .participantInfo:
        handleParticipantInfo(data: message.payload, from: participant)
      case .screenViewRequest:
        guard let renderingParameters else { return }
        Task {
          let state = isScreenViewSynchronized
            ? (sharedScreenViewState ?? renderingParameters.screenViewState)
            : renderingParameters.screenViewState
          try? await sendScreenViewState(
            state,
            isShared: isScreenViewSynchronized,
            to: .only(Set([participant]))
          )
        }
      case .originCatalogSnapshot:
        handleOriginCatalogSnapshot(data: message.payload)
      case .datasetOriginAdvertisement:
        handleDatasetOriginAdvertisement(data: message.payload, from: participant)
      case .hostClaim:
        handleHostClaim(data: message.payload, from: participant.id)
      case .hostState:
        handleHostState(data: message.payload, from: participant.id)
      case .protocolVersion:
        break
    }
  }

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
        return true
      case .sendInitialState:
        Task { await sendInitialData(to: .only(Set([participant]))) }
        return false
      case .requestInitialState:
        appModel?.logger.info(
          "Received a SharePlay update for an unknown state version; requesting the current initial state."
        )
        Task { await requestInitialState() }
        return false
      case .reject:
        return false
    }
  }

  private func advanceHostStateVersion() {
    sessionEngine.advanceHostStateVersion()
  }

  private func handleUpdate(data: Data, from participant: Participant) {
    do {
      if let update = try BorgVRSharePlayCommonUpdateDecoder.decode(data) {
        switch update {
          case .spatialToolPreviews(let previews):
            appModel?.updateRemoteSpatialToolPreviews(
              previews,
              participantID: participant.id
            )
          case .annotations(let annotations):
            appModel?.replaceVolumeMarkers(annotations.markers)
            appModel?.replaceSceneMeshInstances(annotations.meshInstances)
            retryMissingSceneMeshAssets()
          case .measurements(let measurements):
            appModel?.replaceVolumeMeasurements(measurements)
            appModel?.clearVolumeMeasurementSelection()
          case .screenView(let screenView):
            if screenView.isShared {
              sharedScreenViewState = screenView.state
              if isScreenViewSynchronized {
                renderingParameters?.apply(screenView.state)
              }
            }
        }
        return
      }
      if try renderingParameters?.applySharePlayUpdate(from: data) == true {
        return
      }
      try renderingParameters?.applyUpdate(from: data)
    } catch {
      appModel?.logger.error("Failed to apply SharePlay update: \(error.localizedDescription)")
    }
  }

  private var hasOtherSynchronizedScreenParticipant: Bool {
    sessionEngine.participantInfoByID.values.contains {
      ($0.platform == .iOS || $0.platform == .macOS) && $0.sharesScreenView
    }
  }

  private func sendScreenViewState(
    _ state: BorgVRScreenViewState,
    isShared: Bool,
    to participants: Participants = .all
  ) async throws {
    try await sendData(
      BorgVRScreenViewStateCodec.encode(state, isShared: isShared),
      of: .renderingUpdate,
      to: participants
    )
  }

  private func handleInit(data: Data, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, isInSession else { return }
    guard let appModel else { return }
    guard appModel.groupSessionHost != true else { return }
    appModel.groupSessionHost = false

    guard let message = BorgVRSharePlayDatasetAnnouncement(data: data),
          !message.uniqueID.isEmpty else {
      setSessionDatasetID(nil)
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil
      appModel.waitForSharePlayDataset(reason: .hostDataset)
      return
    }

    setSessionDatasetID(message.uniqueID)

    DatasetOriginCatalog.shared.prioritize(message.origins, for: message.uniqueID)
    mergeSessionOrigins(message.origins, for: message.uniqueID)

    if appModel.activeDataset?.uniqueId != message.uniqueID {
      sharedScreenViewState = nil
    }

    if appModel.isOpeningOrRenderingDataset(withUniqueID: message.uniqueID) {
      Task { await advertiseCurrentLocalDataset() }
      return
    }

    if pendingDatasetLoad?.uniqueID == message.uniqueID {
      retryPendingDatasetLoad()
      return
    }

    if let localDataset = findLocalDataset(id: message.uniqueID, description: message.description) {
      appModel.logger.info("Found SharePlay dataset \(message.uniqueID) locally at \(localDataset.identifier).")
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil
      appModel.openDataset(localDataset, asGroupSessionHost: false)
      Task { await advertiseCurrentLocalDataset() }
      return
    }
    appModel.logger.info("SharePlay dataset \(message.uniqueID) is not available locally; searching known network sources.")
    pendingDatasetLoadTask?.cancel()
    pendingDatasetLoadTask = nil
    pendingDatasetLoad = PendingDatasetLoad(
      uniqueID: message.uniqueID,
      description: message.description,
      generation: generation
    )
    appModel.beginResolvingSharePlayDataset(
      uniqueID: message.uniqueID,
      description: message.description
    )
    retryPendingDatasetLoad()
  }

  private func retryPendingDatasetLoad() {
    guard let pending = pendingDatasetLoad,
          pending.generation == sessionGeneration,
          isInSession,
          appModel?.groupSessionHost != true else { return }
    guard pendingDatasetLoadTask == nil else { return }
    let origins = knownOrigins(for: pending.uniqueID)
    appModel?.beginResolvingSharePlayDataset(
      uniqueID: pending.uniqueID,
      description: pending.description
    )
    guard !origins.isEmpty else {
      appModel?.sharePlayDatasetSource = nil
      appModel?.logger.warning("No known source currently provides SharePlay dataset \(pending.uniqueID); waiting for participant sources.")
      schedulePendingDatasetLoadRetry(
        uniqueID: pending.uniqueID,
        generation: pending.generation
      )
      return
    }
    appModel?.logger.info("Trying \(origins.count) known source(s) for SharePlay dataset \(pending.uniqueID).")
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

  private func openFirstReachableRemoteDataset(
    uniqueID: String,
    description: String,
    origins: [DatasetOrigin],
    sessionGeneration generation: Int
  ) async {
    guard generation == sessionGeneration, isInSession else { return }
    guard let appModel else { return }

    guard let remoteSource = await firstReachableOrigin(origins, datasetID: uniqueID) else {
      guard !Task.isCancelled, generation == sessionGeneration,
            isInSession,
            pendingDatasetLoad?.uniqueID == uniqueID else { return }
      appModel.sharePlayDatasetSource = nil
      appModel.logger.warning("None of the known sources currently provides SharePlay dataset \(uniqueID); retrying after all sources have timed out.")
      schedulePendingDatasetLoadRetry(uniqueID: uniqueID, generation: generation)
      return
    }

    guard generation == sessionGeneration,
          isInSession,
          appModel.groupSessionHost != true,
          pendingDatasetLoad?.uniqueID == uniqueID else { return }
    appModel.sharePlayDatasetSource = nil
    let dataset = AppModel.DatasetEntry(
      identifier: uniqueID,
      description: description,
      source: .remote(address: remoteSource.address, port: remoteSource.port, password: remoteSource.password),
      uniqueId: uniqueID
    )
    appModel.logger.info("Loading SharePlay dataset \(uniqueID) from \(remoteSource.address):\(remoteSource.port).")
    pendingDatasetLoad = nil
    pendingDatasetLoadTask = nil
    appModel.openDataset(dataset, asGroupSessionHost: false)
  }

  private func schedulePendingDatasetLoadRetry(uniqueID: String, generation: Int) {
    pendingDatasetLoadTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard !Task.isCancelled, let self else { return }
      guard generation == sessionGeneration,
            pendingDatasetLoad?.generation == generation,
            pendingDatasetLoad?.uniqueID == uniqueID,
            isInSession else { return }
      pendingDatasetLoadTask = nil
      retryPendingDatasetLoad()
    }
  }

  @MainActor
  private func firstReachableOrigin(_ origins: [DatasetOrigin], datasetID: String) async -> DatasetOrigin? {
    await BorgVRRemoteOriginResolver.firstReachable(
      origins, datasetID: datasetID, timeout: max(0.1, appSettings?.timeout ?? AppSettings.double("timeout")), logger: appModel?.logger,
      checking: { [weak self] origin in self?.appModel?.sharePlayDatasetSource = origin },
      receivedCatalog: { origin, ids in
        DatasetOriginCatalog.shared.recordServerSnapshot(origin: origin, datasetIDs: ids,
          allowsSharing: DatasetOriginCatalog.shared.sharingAllowed(for: origin))
      }
    )
  }

  private func findLocalDataset(id: String, description: String) -> AppModel.DatasetEntry? {
    if let bundleURLs = Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) {
      for url in bundleURLs {
        guard let metadata = try? BORGVRMetaData(url: url), metadata.uniqueID == id else { continue }
        return AppModel.DatasetEntry(
          identifier: url.path,
          description: metadata.datasetDescription.isEmpty ? description : metadata.datasetDescription,
          source: .builtIn,
          uniqueId: metadata.uniqueID,
          metadataSummary: metadata.summaryText
        )
      }
    }

    return platformAdapter.findLocalDataset(id: id, description: description)
  }

  private func shareOrigins(for dataset: AppModel.DatasetEntry) async -> [DatasetOrigin] {
    var immediateOrigins: [DatasetOrigin] = []
    switch dataset.source {
      case .remote(let address, let port, let password):
        let origin = DatasetOrigin(address: address, port: port, password: password)
        let mayShare = appSettings?.servers.first {
          $0.address.caseInsensitiveCompare(address) == .orderedSame && $0.port == port
        }?.shareViaSharePlay ?? false
        DatasetOriginCatalog.shared.record(origin: origin, for: dataset.uniqueId, allowsSharing: mayShare)
        if mayShare {
          immediateOrigins.append(origin)
        }
      case .local, .builtIn:
        immediateOrigins = await platformAdapter.ensureServing(dataset: dataset)
    }
    return DatasetOriginCatalog.deduplicated(
      immediateOrigins + DatasetOriginCatalog.shared.shareableOrigins(for: dataset.uniqueId)
    )
  }

  private func knownOrigins(for datasetID: String) -> [DatasetOrigin] {
    return DatasetOriginCatalog.deduplicated(
      sessionEngine.knownSessionOrigins(for: datasetID)
        + DatasetOriginCatalog.shared.origins(for: datasetID)
    )
  }

  private func retryMissingSceneMeshAssets() {
    guard isInSession,
          let appModel,
          let datasetID = appModel.activeDataset?.uniqueId else { return }
    appModel.resolveSceneMeshAssets()
    let missingIDs = Set(appModel.sceneMeshInstances.map(\.asset.assetID)).subtracting(
      appModel.sceneMeshAssets.keys
    )
    guard !missingIDs.isEmpty else { return }
    guard sceneMeshResolutionTask == nil else {
      sceneMeshResolutionRetryRequested = true
      return
    }
    let origins = knownOrigins(for: datasetID)
    guard !origins.isEmpty else { return }

    let generation = sessionGeneration
    let timeout = max(0.1, appSettings?.timeout ?? AppSettings.double("timeout"))
    appModel.logger.info(
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
      guard let self, generation == sessionGeneration, isInSession else { return }

      appModel.resolveSceneMeshAssets()
      for attempt in result.attempts {
        if attempt.resolvedCount > 0 {
          appModel.logger.info(
            "Loaded \(attempt.resolvedCount) shared object asset(s) from \(attempt.endpoint)."
          )
        } else if let error = attempt.errorDescription {
          appModel.logger.warning(
            "Could not load shared object assets from \(attempt.endpoint): \(error)"
          )
        }
      }
      if !result.missingIDs.isEmpty {
        appModel.logger.warning(
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

  private func mergeSessionOrigins(_ origins: [DatasetOrigin], for datasetID: String) {
    sessionEngine.mergeSessionOrigins(origins, for: datasetID)
  }

  private func sendOriginCatalogSnapshot(to participants: Participants = .all) async {
    let snapshot = sessionEngine.combinedOriginSnapshot(
      with: DatasetOriginCatalog.shared.shareableSnapshot()
    )
    guard let data = try? DatasetOriginSharePlayCodec.encode(snapshot) else { return }
    try? await sendData(data, of: .originCatalogSnapshot, to: participants)
  }

  private func handleOriginCatalogSnapshot(data: Data) {
    do {
      let snapshot = try DatasetOriginSharePlayCodec.decode(DatasetOriginSnapshot.self, from: data)
      DatasetOriginCatalog.shared.mergeRemoteSnapshot(snapshot)
      sessionEngine.mergeOriginSnapshot(snapshot)
      appModel?.logger.info("Received a SharePlay source catalog with \(snapshot.entries.count) server(s).")
      retryPendingDatasetLoad()
      retryMissingSceneMeshAssets()
    } catch {
      appModel?.logger.warning("Could not decode SharePlay source catalog: \(error.localizedDescription)")
    }
  }

  private func advertiseCurrentLocalDataset(to participants: Participants = .all) async {
    guard isInSession,
          let dataset = appModel?.activeDataset,
          dataset.uniqueId == sessionEngine.sessionDatasetID else { return }
    let origins = await platformAdapter.ensureServing(dataset: dataset)
    guard isInSession, dataset.uniqueId == sessionEngine.sessionDatasetID else { return }
    guard !origins.isEmpty else { return }
    let advertisement = DatasetOriginAdvertisement(datasetID: dataset.uniqueId, origins: origins)
    guard let data = try? DatasetOriginSharePlayCodec.encode(advertisement) else { return }
    appModel?.logger.info("Advertising this Mac as a SharePlay source for dataset \(dataset.uniqueId).")
    try? await sendData(data, of: .datasetOriginAdvertisement, to: participants)
  }

  private func handleLocalDatasetCacheCompletion(
    _ completion: BORGVRLocalDatasetCacheCompletion
  ) {
    guard isInSession,
          completion.datasetID == sessionEngine.sessionDatasetID,
          appModel?.activeDataset?.uniqueId == completion.datasetID else { return }
    appModel?.logger.info(
      "The SharePlay dataset is now fully cached locally; enabling its ad-hoc source."
    )
    Task { await advertiseCurrentLocalDataset() }
  }

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
      appModel?.logger.info("Received \(advertisement.origins.count) participant source(s) for dataset \(advertisement.datasetID).")
      retryPendingDatasetLoad()
      retryMissingSceneMeshAssets()
    } catch {
      appModel?.logger.warning("Could not decode SharePlay participant source: \(error.localizedDescription)")
    }
  }

  func takeOverHostRole() {
    guard isInSession,
          let claim = sessionEngine.makeLocalHostClaim() else { return }
    showsHostDeparturePrompt = false
    resolveHostElection(term: claim.term)
    Task {
      guard let data = try? BorgVRSharePlayHostCodec.encode(claim) else { return }
      try? await sendData(data, of: .hostClaim)
    }
  }

  func ignoreHostDeparture() {
    showsHostDeparturePrompt = false
  }

  private func handleHostParticipantChanges(
    _ change: BorgVRSharePlaySessionEngine.ParticipantChange
  ) {
    resolveHostElection(term: sessionEngine.hostElectionTerm)
    guard change.hostDeparted, sessionEngine.currentHostParticipantID == nil else { return }
    appModel?.groupSessionHost = false
    showsHostDeparturePrompt = true
    appModel?.logger.warning("The SharePlay host left the session; waiting for a new host.")
  }

  private func sendCurrentHostState(to participants: Participants = .all) async {
    guard let state = sessionEngine.currentHostState() else { return }
    guard let data = try? BorgVRSharePlayHostCodec.encode(state) else { return }
    try? await sendData(data, of: .hostState, to: participants)
  }

  private func handleHostClaim(data: Data, from participantID: UUID) {
    guard let claim = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostClaim.self,
      from: data
    ), claim.candidateID == participantID else { return }
    registerHostClaim(claim)
  }

  private func registerHostClaim(_ claim: BorgVRSharePlayHostClaim) {
    switch sessionEngine.registerHostClaim(claim) {
      case .ignored:
        return
      case .resolutionRequested(let term):
        appModel?.groupSessionHost = false
        resolveHostElection(term: term)
    }
  }

  private func resolveHostElection(term: UInt64) {
    guard let transition = sessionEngine.resolveHostElection(term: term) else { return }
    applyHostTransition(transition)
    Task {
      await sendCurrentHostState()
      if transition.isLocalHost { await sendInitialData() }
    }
  }

  private func handleHostState(data: Data, from participantID: UUID) {
    guard let state = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostState.self,
      from: data
    ), let transition = sessionEngine.receiveHostState(state, from: participantID) else { return }
    applyHostTransition(transition)
    if transition.isLocalHost { Task { await sendInitialData() } }
  }

  private func applyHostTransition(
    _ transition: BorgVRSharePlaySessionEngine.HostTransition
  ) {
    showsHostDeparturePrompt = false
    appModel?.groupSessionHost = transition.isLocalHost
    refreshEditCollaboration()
    if transition.isLocalHost {
      setSessionDatasetID(appModel?.activeDataset?.uniqueId)
    }
    appModel?.logger.info(transition.isLocalHost
      ? "This device took over the SharePlay host role."
      : "A participant took over the SharePlay host role.")
  }

  private func setSessionDatasetID(_ datasetID: String?) {
    guard sessionEngine.setSessionDatasetID(datasetID) else { return }
    refreshEditCollaboration()
    platformAdapter.stopSharePlayServer()
    if let datasetID {
      appModel?.logger.info("SharePlay ad-hoc server is restricted to host dataset \(datasetID).")
    } else {
      appModel?.logger.info("SharePlay ad-hoc server stopped because no host dataset is active.")
    }
  }

}

extension BORGVRMetaData {
  var summaryText: String {
    let bitsPerComponent = bytesPerComponent * 8
    let channelText = componentCount == 1
      ? String(localized: "1 channel")
      : String(format: String(localized: "metadata_channel_count_format"), componentCount)
    let compressionText = compression
      ? String(localized: "compressed")
      : String(localized: "uncompressed")
    let lodText = levelMetadata.count == 1
      ? String(localized: "1 LOD")
      : String(format: String(localized: "metadata_lod_count_format"), levelMetadata.count)

    return "\(width) x \(height) x \(depth) - " +
      "\(bitsPerComponent)-bit, \(channelText) - " +
      "\(String(localized: "Brick")) \(brickSize) - \(lodText) - " +
      "\(compressionText) - \(String(localized: "Values")) \(minValue)...\(maxValue)"
  }
}
