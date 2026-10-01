import Combine
import Darwin
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
    metadata.title = String(localized: "BorgVR Mobile Live Collaboration")
    metadata.subtitle = String(localized: "Collaborate on the same volumetric dataset.")
    metadata.type = .generic
    metadata.sceneAssociationBehavior = .content(borgVRSharePlayActivityIdentifier)
    return metadata
  }()
}

@MainActor
final class SharePlayCoordinator: ObservableObject {
  @Published private(set) var isInSession = false
  @Published private(set) var hasObservedGroupSession = false
  @Published private(set) var participants: [BorgVRSharePlayParticipant] = []
  @Published private(set) var isScreenViewSynchronized = true
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
  private var subscriptions = Set<AnyCancellable>()
  private var pendingCommonState = false
  private var pendingTransferFunction = false
  private var pendingTransform = false
  private var pendingMarkers = false
  private var synchronizationTask: Task<Void, Never>?
  private var knownParticipants = Set<Participant>()
  private var protocolHandshake = BorgVRSharePlayHandshakeState()
  private var participantInfoByID: [UUID: BorgVRSharePlayParticipantInfo] = [:]
  private var sharedScreenViewState: BorgVRScreenViewState?
  private var screenViewSynchronizationGeneration = 0
  private let sharePlayServerHost = BorgVRServerHost(logger: GUILogger())
  private var sharePlayDatasetID: String?
  private var sharePlayAuthToken = ""
  private var sharePlayServerRunning = false
  private var sharePlayServerPort = AppSettings.int("sharePlayServerPort")
  private struct PendingDatasetLoad {
    let uniqueID: String
    let description: String
    let generation: Int
  }
  private var pendingDatasetLoad: PendingDatasetLoad?
  private var pendingDatasetLoadTask: Task<Void, Never>?
  private var sessionOriginsByDatasetID: [String: [DatasetOrigin]] = [:]
  private var adHocOriginsByParticipantID: [UUID: [String: [DatasetOrigin]]] = [:]
  private var localParticipantID: UUID?
  private var currentHostParticipantID: UUID?
  private var hostElectionTerm: UInt64 = 0
  private var hostClaims: [UInt64: Set<UUID>] = [:]
  private var hostElectionTask: Task<Void, Never>?

  func startObservingSessions(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    appSettings: AppSettings
  ) {
    self.appModel = appModel
    self.renderingParameters = renderingParameters
    self.appSettings = appSettings

    guard sessionObservationTask == nil else { return }
    appModel.logger.info("Starting SharePlay group-session observation on this iOS device.")
    let sessions = BorgVRSharePlayActivity.sessions()
    sessionObservationTask = Task { [weak self] in
      for await session in sessions {
        guard let self else { return }
        appModel.logger.info(
          "SharePlay delivered a group session to this iOS device; activity initiator: \(session.activity.initiatorID.uuidString), initial participant count: \(session.activeParticipants.count)."
        )
        configure(session)
      }
    }
  }

  func startSharePlay() {
    markLocalActivityStarter()
    appModel?.logger.info("Starting SharePlay from this iOS device.")
    Task {
      do {
        let activity = BorgVRSharePlayActivity()
        let activationPreparation = await activity.prepareForActivation()
        appModel?.logger.info(
          "SharePlay prepareForActivation completed with: \(String(describing: activationPreparation))."
        )
        switch activationPreparation {
          case .activationPreferred:
            appModel?.logger.info("Calling SharePlay activity.activate() on this iOS device.")
            let sessionWillBeDelivered = try await activity.activate()
            appModel?.logger.info(
              "SharePlay activity.activate() returned; session will be delivered: \(sessionWillBeDelivered), session already observed: \(hasObservedGroupSession), currently joined: \(isInSession)."
            )
            if !sessionWillBeDelivered, !isInSession {
              clearLocalActivityStarter()
            }
          case .activationDisabled:
            clearLocalActivityStarter()
            appModel?.logger.info("SharePlay activation is disabled.")
          case .cancelled:
            clearLocalActivityStarter()
            break
          @unknown default:
            break
        }
        await sendInitialData()
      } catch {
        clearLocalActivityStarter()
        appModel?.logger.error("Failed to start SharePlay: \(error.localizedDescription)")
      }
    }
  }

  func markLocalActivityStarter() {
    appModel?.groupSessionHost = true
  }

  private func clearLocalActivityStarter() {
    appModel?.groupSessionHost = false
  }

  func datasetOpened() {
    guard isInSession else { return }
    if appModel?.groupSessionHost == true {
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
    if appModel?.groupSessionHost == true {
      if isScreenViewSynchronized, let renderingParameters {
        sharedScreenViewState = renderingParameters.screenViewState
      }
      Task { await sendInitialDataReliably() }
    } else {
      Task { await requestInitialStateReliably() }
    }
  }

  func closeSharedDataset() {
    guard isInSession else { return }
    if appModel?.groupSessionHost == true {
      stopSharePlayServer()
      Task { try? await sendData(Data(), of: .shutdownRequest) }
    } else {
      groupSession?.leave()
    }
  }

  func leaveGroupActivity() {
    stopSharePlayServer()
    groupSession?.leave()
    appModel?.groupSessionHost = false
    isInSession = false
    resetSessionReceivers()
  }

  func synchronize(kind: RenderingParameters.UpdateKind) {
    guard isInSession else { return }

    switch kind {
      case .full:
        pendingCommonState = true
        pendingTransferFunction = true
      case .stateOnly:
        pendingCommonState = true
      case .transformOnly:
        pendingTransform = true
    }

    guard synchronizationTask == nil else {
      return
    }

    let delay: UInt64 = pendingTransferFunction ? 200_000_000 : 50_000_000
    synchronizationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      await self?.flushPendingSynchronization()
    }
  }

  func flushSynchronization() {
    guard isInSession else { return }
    synchronizationTask?.cancel()
    synchronizationTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      await self?.flushPendingSynchronization()
    }
  }

  func synchronizeMarkers(immediately: Bool = false) {
    guard isInSession else { return }
    pendingMarkers = true
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
      pendingTransform = false
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
    hasObservedGroupSession = true
    appModel?.logger.info(
      "Configuring delivered SharePlay group session; local participant: \(session.localParticipant.id.uuidString), initial state: \(String(describing: session.state)), active participant count: \(session.activeParticipants.count)."
    )
    resetSessionReceivers()
    sessionGeneration += 1
    let generation = sessionGeneration
    subscriptions.removeAll()
    groupSession = session
    isInSession = true
    let isHost = session.activity.initiatorID == localBorgVRSharePlayInitiatorID
    appModel?.groupSessionHost = isHost
    localParticipantID = session.localParticipant.id
    currentHostParticipantID = isHost ? session.localParticipant.id : nil
    hostElectionTerm = 0
    knownParticipants = session.activeParticipants

    session.$activeParticipants
      .sink { [weak self] activeParticipants in
        guard let self else { return }
        let previousParticipants = self.knownParticipants
        let newParticipants = activeParticipants.subtracting(self.knownParticipants)
        let departedParticipants = previousParticipants.subtracting(activeParticipants)
        self.knownParticipants = activeParticipants
        let activeIDs = Set(activeParticipants.map(\.id))
        if !newParticipants.isEmpty || !departedParticipants.isEmpty {
          let joinedIDs = newParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
          let departedIDs = departedParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
          let hostID = self.currentHostParticipantID?.uuidString ?? "unknown"
          self.appModel?.logger.info(
            "SharePlay participants changed; joined: [\(joinedIDs)], departed: [\(departedIDs)], host: \(hostID), active count: \(activeIDs.count)."
          )
        }
        self.participantInfoByID = self.participantInfoByID.filter {
          activeIDs.contains($0.key)
        }
        self.adHocOriginsByParticipantID = self.adHocOriginsByParticipantID.filter {
          activeIDs.contains($0.key)
        }
        self.protocolHandshake.retainParticipants(activeIDs)
        self.handleHostParticipantChanges(activeParticipantIDs: activeIDs)
        self.publishParticipants()
        guard !newParticipants.isEmpty else { return }
        Task {
          await self.sendProtocolVersion(to: .only(newParticipants))
        }
      }
      .store(in: &subscriptions)

    session.$state
      .sink { [weak self] state in
        guard let self else { return }
        Task { @MainActor in
          guard self.sessionGeneration == generation else { return }
          self.appModel?.logger.info(
            "SharePlay group-session state changed to: \(String(describing: state))."
          )
          guard case .invalidated(let reason) = state else { return }
          self.appModel?.logger.warning(
            "SharePlay session invalidated by the system: \(reason.localizedDescription)"
          )
          self.stopSharePlayServer()
          self.resetSessionReceivers()
          self.isInSession = false
          self.appModel?.groupSessionHost = false
        }
      }
      .store(in: &subscriptions)

    let messenger = GroupSessionMessenger(session: session)
    self.messenger = messenger
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
    try await messenger.send(Data([messageType.rawValue]) + data, to: participants)
  }

  private func sendParticipantInfo(to participants: Participants = .all) async {
    guard messenger != nil else { return }
    let configuredName = appSettings?.sharePlayDisplayName ?? ""
    let displayName = configuredName.trimmingCharacters(in: .whitespacesAndNewlines)
    let info = BorgVRSharePlayParticipantInfo(
      platform: .iOS,
      displayName: displayName.isEmpty
        ? String(localized: "iPhone or iPad")
        : displayName,
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
      switch try protocolHandshake.receive(data, from: participant.id) {
        case .alreadyAccepted:
          return
        case .incompatible(let issue):
          appModel?.logger.error(
            "Incompatible SharePlay protocol; version \(issue.requiredVersion) or later is required."
          )
          groupSession?.leave()
          stopSharePlayServer()
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
          await sendInitialDataReliably(to: .only(Set([participant])))
        } else {
          await requestInitialStateReliably(to: .only(Set([participant])))
        }
      }
    } catch {
      appModel?.logger.error("Invalid SharePlay protocol handshake: \(error)")
    }
  }

  private func establishInitialScreenView(sessionGeneration generation: Int) async {
    await sendParticipantInfo()
    try? await sendData(Data(), of: .screenViewRequest)
    try? await Task.sleep(nanoseconds: 400_000_000)
    guard generation == sessionGeneration,
          isInSession,
          isScreenViewSynchronized,
          sharedScreenViewState == nil,
          let renderingParameters else { return }
    let state = renderingParameters.screenViewState
    sharedScreenViewState = state
    try? await sendScreenViewState(state, isShared: true)
  }

  private func handleParticipantInfo(data: Data, from participant: Participant) {
    do {
      let previousInfo = participantInfoByID[participant.id]
      let info = try BorgVRSharePlayParticipantInfoCodec.decode(data)
      participantInfoByID[participant.id] = info
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
    participants = participantInfoByID.map {
      BorgVRSharePlayParticipant(id: $0.key, info: $0.value)
    }.sorted {
      if $0.displayName == $1.displayName {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private func resetSessionReceivers() {
    messageTask?.cancel()
    messageTask = nil
    groupSession = nil
    messenger = nil
    subscriptions.removeAll()
    synchronizationTask?.cancel()
    synchronizationTask = nil
    pendingCommonState = false
    pendingTransferFunction = false
    pendingTransform = false
    pendingMarkers = false
    isScreenViewSynchronized = true
    sharedScreenViewState = nil
    screenViewSynchronizationGeneration += 1
    knownParticipants.removeAll()
    protocolHandshake.reset()
    participantInfoByID.removeAll()
    sessionOriginsByDatasetID.removeAll()
    adHocOriginsByParticipantID.removeAll()
    pendingDatasetLoadTask?.cancel()
    pendingDatasetLoadTask = nil
    pendingDatasetLoad = nil
    hostElectionTask?.cancel()
    hostElectionTask = nil
    localParticipantID = nil
    currentHostParticipantID = nil
    hostClaims.removeAll()
    showsHostDeparturePrompt = false
    participants = []
    appModel?.clearRemoteSpatialToolPreviews()
  }

  private func resetPendingSynchronizationForDatasetChange() {
    synchronizationTask?.cancel()
    synchronizationTask = nil
    pendingCommonState = false
    pendingTransferFunction = false
    pendingTransform = false
    pendingMarkers = false
  }

  private func sendDatasetAnnouncement(to participants: Participants = .all) async {
    guard appModel?.groupSessionHost == true else { return }

    guard let dataset = appModel?.activeDataset else {
      try? await sendData(
        InitMessage(uniqueID: "", origins: [], description: "").toData(),
        of: .initMessage,
        to: participants
      )
      return
    }

    let message = InitMessage(
      uniqueID: dataset.uniqueId,
      origins: shareOrigins(for: dataset),
      description: dataset.description
    )
    try? await sendData(message.toData(), of: .initMessage, to: participants)
  }

  private func sendInitialData(to participants: Participants = .all) async {
    guard appModel?.groupSessionHost == true else { return }

    await sendDatasetAnnouncement(to: participants)
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
        VolumeMarkerSharePlayCodec.encode(appModel.volumeMarkers),
        of: .renderingUpdate,
        to: participants
      )
    }
  }

  private func sendInitialDataReliably(to participants: Participants = .all) async {
    await sendInitialData(to: participants)
    try? await Task.sleep(nanoseconds: 250_000_000)
    await sendInitialData(to: participants)
  }

  private func requestInitialStateReliably(to participants: Participants = .all) async {
    try? await sendData(Data(), of: .stateRequest, to: participants)
    try? await Task.sleep(nanoseconds: 250_000_000)
    try? await sendData(Data(), of: .stateRequest, to: participants)
  }

  private func flushPendingSynchronization() async {
    synchronizationTask = nil
    guard let renderingParameters else { return }

    let shouldSendCommonState = pendingCommonState
    let shouldSendTransferFunction = pendingTransferFunction
    let shouldSendTransform = pendingTransform
    let shouldSendMarkers = pendingMarkers
    pendingCommonState = false
    pendingTransferFunction = false
    pendingTransform = false
    pendingMarkers = false

    do {
      if shouldSendCommonState {
        try await sendData(
          renderingParameters.serializeCommonSharePlayState(includeTransferFunction: shouldSendTransferFunction),
          of: .renderingUpdate
        )
      }

      if shouldSendTransform {
        let state = renderingParameters.screenViewState
        if isScreenViewSynchronized {
          sharedScreenViewState = state
        }
        try await sendScreenViewState(state, isShared: isScreenViewSynchronized)
      }

      if shouldSendMarkers, let appModel {
        try await sendData(
          VolumeMarkerSharePlayCodec.encode(appModel.volumeMarkers),
          of: .renderingUpdate
        )
      }
    } catch {
      appModel?.logger.error("Failed to send SharePlay update: \(error.localizedDescription)")
    }
  }

  private func handleIncoming(data: Data, from participant: Participant, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, isInSession else { return }
    guard let firstByte = data.first else { return }
    let payload = Data(data.dropFirst())

    if firstByte == MessageType.protocolVersion.rawValue {
      handleProtocolVersion(data: payload, from: participant)
      return
    }
    guard protocolHandshake.acceptsMessages(from: participant.id) else {
      appModel?.logger.warning("Ignored SharePlay data received before the protocol handshake.")
      return
    }

    switch firstByte {
      case MessageType.initMessage.rawValue:
        guard appModel?.groupSessionHost != true else { return }
        handleInit(data: payload, sessionGeneration: generation)
      case MessageType.renderingUpdate.rawValue:
        handleUpdate(data: payload, from: participant)
      case MessageType.shutdownRequest.rawValue:
        guard appModel?.groupSessionHost != true else { return }
        pendingDatasetLoadTask?.cancel()
        pendingDatasetLoadTask = nil
        pendingDatasetLoad = nil
        appModel?.removeAllVolumeMarkers()
        appModel?.closeDataset(destination: .sharePlayWaiting(.hostDataset))
      case MessageType.stateRequest.rawValue:
        guard appModel?.groupSessionHost == true else { return }
        Task { await sendInitialDataReliably(to: .only(Set([participant]))) }
      case MessageType.participantInfo.rawValue:
        handleParticipantInfo(data: payload, from: participant)
      case MessageType.screenViewRequest.rawValue:
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
      case MessageType.originCatalogSnapshot.rawValue:
        handleOriginCatalogSnapshot(data: payload)
      case MessageType.datasetOriginAdvertisement.rawValue:
        handleDatasetOriginAdvertisement(data: payload, from: participant)
      case MessageType.hostClaim.rawValue:
        handleHostClaim(data: payload)
      case MessageType.hostState.rawValue:
        handleHostState(data: payload)
      default:
        appModel?.logger.error("Invalid SharePlay message type: \(firstByte)")
    }
  }

  private func handleUpdate(data: Data, from participant: Participant) {
    do {
      if let previews = try SpatialToolPreviewSharePlayCodec.decodeIfPresent(data) {
        appModel?.updateRemoteSpatialToolPreviews(
          previews,
          participantID: participant.id
        )
        return
      }
      if let markers = try VolumeMarkerSharePlayCodec.decodeIfPresent(data) {
        appModel?.replaceVolumeMarkers(markers)
        return
      }
      if let update = try BorgVRScreenViewStateCodec.decodeUpdateIfPresent(data) {
        if update.isShared {
          sharedScreenViewState = update.state
          if isScreenViewSynchronized {
            renderingParameters?.apply(update.state)
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
    participantInfoByID.values.contains {
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

    guard let message = InitMessage(data: data), !message.uniqueID.isEmpty else {
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil
      appModel.waitForSharePlayDataset(reason: .hostDataset)
      return
    }

    DatasetOriginCatalog.shared.prioritize(message.origins, for: message.uniqueID)
    mergeSessionOrigins(message.origins, for: message.uniqueID)

    if appModel.activeDataset?.uniqueId != message.uniqueID {
      sharedScreenViewState = nil
    }

    if appModel.isOpeningOrRenderingDataset(withUniqueID: message.uniqueID) {
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
      guard generation == sessionGeneration,
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
      guard
        generation == sessionGeneration,
        pendingDatasetLoad?.generation == generation,
        pendingDatasetLoad?.uniqueID == uniqueID,
        isInSession
      else { return }
      pendingDatasetLoadTask = nil
      retryPendingDatasetLoad()
    }
  }

  private func firstReachableOrigin(
    _ origins: [DatasetOrigin],
    datasetID: String
  ) async -> DatasetOrigin? {
    let timeout = max(0.1, appSettings?.timeout ?? AppSettings.double("timeout"))
    for origin in origins {
      guard !Task.isCancelled else { return nil }
      appModel?.sharePlayDatasetSource = origin
      appModel?.logger.info("Checking \(origin.address):\(origin.port) for SharePlay dataset \(datasetID).")
      let result = await Task.detached(priority: .userInitiated) {
        do {
          let manager = BORGVRRemoteDataManager(
            host: origin.address,
            port: UInt16(clamping: origin.port),
            authSecret: origin.password,
            logger: nil,
            notifier: nil
          )
          try manager.connect(timeout: timeout)
          let datasets = try manager.requestDatasetList()
          DatasetOriginCatalog.shared.recordServerSnapshot(
            origin: origin,
            datasetIDs: datasets.map(\.id),
            allowsSharing: DatasetOriginCatalog.shared.sharingAllowed(for: origin)
          )
          return (datasets.contains { $0.id == datasetID }, "")
        } catch {
          return (false, error.localizedDescription)
        }
      }.value

      if result.0 {
        appModel?.logger.info("Found SharePlay dataset \(datasetID) at \(origin.address):\(origin.port).")
        return origin
      }
      if result.1.isEmpty {
        appModel?.logger.info("Source \(origin.address):\(origin.port) is reachable but does not provide dataset \(datasetID).")
      } else {
        appModel?.logger.warning("Could not query \(origin.address):\(origin.port): \(result.1)")
      }
    }

    return nil
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

    let fileManager = FileManager.default
    guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
          let files = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
    else {
      return nil
    }

    for url in files where url.pathExtension.lowercased() == "data" {
      guard let metadata = try? BORGVRMetaData(url: url), metadata.uniqueID == id else { continue }
      return AppModel.DatasetEntry(
        identifier: url.path,
        description: metadata.datasetDescription.isEmpty ? description : metadata.datasetDescription,
        source: .local,
        uniqueId: metadata.uniqueID,
        metadataSummary: metadata.summaryText
      )
    }

    return nil
  }

  private func shareOrigins(for dataset: AppModel.DatasetEntry) -> [DatasetOrigin] {
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
        let served = ensureServing(dataset: dataset)
        immediateOrigins = served.origins.compactMap { value in
          guard let endpoint = splitAddressAndPort(value) else { return nil }
          return DatasetOrigin(address: endpoint.address, port: endpoint.port, password: served.authToken)
        }
    }
    return DatasetOriginCatalog.deduplicated(
      immediateOrigins + DatasetOriginCatalog.shared.shareableOrigins(for: dataset.uniqueId)
    )
  }

  private func knownOrigins(for datasetID: String) -> [DatasetOrigin] {
    let advertised = adHocOriginsByParticipantID.values.flatMap { $0[datasetID] ?? [] }
    return DatasetOriginCatalog.deduplicated(
      advertised + (sessionOriginsByDatasetID[datasetID] ?? [])
        + DatasetOriginCatalog.shared.origins(for: datasetID)
    )
  }

  private func mergeSessionOrigins(_ origins: [DatasetOrigin], for datasetID: String) {
    guard !datasetID.isEmpty else { return }
    sessionOriginsByDatasetID[datasetID] = DatasetOriginCatalog.deduplicated(
      origins + (sessionOriginsByDatasetID[datasetID] ?? [])
    )
  }

  private func sendOriginCatalogSnapshot(to participants: Participants = .all) async {
    let local = DatasetOriginCatalog.shared.shareableSnapshot()
    var combined = local.originsByDatasetID()
    for (datasetID, origins) in sessionOriginsByDatasetID {
      combined[datasetID, default: []].append(contentsOf: origins)
    }
    var datasetIDsByOrigin: [DatasetOrigin: Set<String>] = [:]
    for (datasetID, origins) in combined {
      for origin in DatasetOriginCatalog.deduplicated(origins) {
        datasetIDsByOrigin[origin, default: []].insert(datasetID)
      }
    }
    let snapshot = DatasetOriginSnapshot(entries: datasetIDsByOrigin.map {
      .init(origin: $0.key, datasetIDs: $0.value.sorted())
    })
    guard let data = try? DatasetOriginSharePlayCodec.encode(snapshot) else { return }
    try? await sendData(data, of: .originCatalogSnapshot, to: participants)
  }

  private func handleOriginCatalogSnapshot(data: Data) {
    do {
      let snapshot = try DatasetOriginSharePlayCodec.decode(DatasetOriginSnapshot.self, from: data)
      DatasetOriginCatalog.shared.mergeRemoteSnapshot(snapshot)
      for (datasetID, origins) in snapshot.originsByDatasetID() {
        mergeSessionOrigins(origins, for: datasetID)
      }
      appModel?.logger.info("Received a SharePlay source catalog with \(snapshot.entries.count) server(s).")
      retryPendingDatasetLoad()
    } catch {
      appModel?.logger.warning("Could not decode SharePlay source catalog: \(error.localizedDescription)")
    }
  }

  private func advertiseCurrentLocalDataset(to participants: Participants = .all) async {
    guard isInSession, let dataset = appModel?.activeDataset else { return }
    guard dataset.source == .local || dataset.source == .builtIn else { return }
    let origins = shareOrigins(for: dataset).filter { origin in
      !DatasetOriginCatalog.shared.shareableOrigins(for: dataset.uniqueId).contains(origin)
    }
    guard !origins.isEmpty else { return }
    let advertisement = DatasetOriginAdvertisement(datasetID: dataset.uniqueId, origins: origins)
    guard let data = try? DatasetOriginSharePlayCodec.encode(advertisement) else { return }
    appModel?.logger.info("Advertising this device as a SharePlay source for dataset \(dataset.uniqueId).")
    try? await sendData(data, of: .datasetOriginAdvertisement, to: participants)
  }

  private func handleDatasetOriginAdvertisement(data: Data, from participant: Participant) {
    do {
      let advertisement = try DatasetOriginSharePlayCodec.decode(
        DatasetOriginAdvertisement.self,
        from: data
      )
      adHocOriginsByParticipantID[participant.id, default: [:]][advertisement.datasetID] =
        DatasetOriginCatalog.deduplicated(advertisement.origins)
      appModel?.logger.info("Received \(advertisement.origins.count) participant source(s) for dataset \(advertisement.datasetID).")
      retryPendingDatasetLoad()
    } catch {
      appModel?.logger.warning("Could not decode SharePlay participant source: \(error.localizedDescription)")
    }
  }

  func takeOverHostRole() {
    guard isInSession,
          currentHostParticipantID == nil,
          let localParticipantID else { return }
    showsHostDeparturePrompt = false
    let claim = BorgVRSharePlayHostClaim(
      term: hostElectionTerm,
      candidateID: localParticipantID
    )
    registerHostClaim(claim)
    Task {
      guard let data = try? BorgVRSharePlayHostCodec.encode(claim) else { return }
      try? await sendData(data, of: .hostClaim)
    }
  }

  func ignoreHostDeparture() {
    showsHostDeparturePrompt = false
  }

  private func handleHostParticipantChanges(activeParticipantIDs: Set<UUID>) {
    guard let currentHostParticipantID,
          currentHostParticipantID != localParticipantID,
          !activeParticipantIDs.contains(currentHostParticipantID) else { return }
    self.currentHostParticipantID = nil
    hostElectionTerm &+= 1
    hostClaims = [hostElectionTerm: []]
    appModel?.groupSessionHost = false
    showsHostDeparturePrompt = true
    appModel?.logger.warning("The SharePlay host left the session; waiting for a new host.")
  }

  private func sendCurrentHostState(to participants: Participants = .all) async {
    guard let currentHostParticipantID else { return }
    let state = BorgVRSharePlayHostState(
      term: hostElectionTerm,
      hostID: currentHostParticipantID
    )
    guard let data = try? BorgVRSharePlayHostCodec.encode(state) else { return }
    try? await sendData(data, of: .hostState, to: participants)
  }

  private func handleHostClaim(data: Data) {
    guard let claim = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostClaim.self,
      from: data
    ) else { return }
    registerHostClaim(claim)
  }

  private func registerHostClaim(_ claim: BorgVRSharePlayHostClaim) {
    guard claim.term >= hostElectionTerm, isParticipantActive(claim.candidateID) else { return }
    if claim.term > hostElectionTerm {
      hostElectionTerm = claim.term
      currentHostParticipantID = nil
      appModel?.groupSessionHost = false
      hostClaims.removeAll()
    }
    hostClaims[claim.term, default: []].insert(claim.candidateID)
    scheduleHostElectionResolution(term: claim.term)
  }

  private func scheduleHostElectionResolution(term: UInt64) {
    hostElectionTask?.cancel()
    hostElectionTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      self?.resolveHostElection(term: term)
    }
  }

  private func resolveHostElection(term: UInt64) {
    guard term == hostElectionTerm else { return }
    let candidates = (hostClaims[term] ?? []).filter(isParticipantActive)
    guard let winner = candidates.min(by: { $0.uuidString < $1.uuidString }) else { return }
    applyHostState(BorgVRSharePlayHostState(term: term, hostID: winner))
    if winner == localParticipantID {
      Task {
        await sendCurrentHostState()
        await sendInitialDataReliably()
      }
    }
  }

  private func handleHostState(data: Data) {
    guard let state = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostState.self,
      from: data
    ), isParticipantActive(state.hostID) else { return }
    guard state.term >= hostElectionTerm else { return }
    if state.term == hostElectionTerm,
       let existing = currentHostParticipantID,
       existing.uuidString < state.hostID.uuidString {
      return
    }
    applyHostState(state)
  }

  private func applyHostState(_ state: BorgVRSharePlayHostState) {
    hostElectionTerm = state.term
    currentHostParticipantID = state.hostID
    hostClaims = [state.term: [state.hostID]]
    hostElectionTask?.cancel()
    hostElectionTask = nil
    showsHostDeparturePrompt = false
    let isLocalHost = state.hostID == localParticipantID
    appModel?.groupSessionHost = isLocalHost
    appModel?.logger.info(isLocalHost
      ? "This device took over the SharePlay host role."
      : "A participant took over the SharePlay host role.")
  }

  private func isParticipantActive(_ participantID: UUID) -> Bool {
    participantID == localParticipantID || knownParticipants.contains { $0.id == participantID }
  }

  private func splitAddressAndPort(_ input: String) -> (address: String, port: Int)? {
    guard let idx = input.lastIndex(of: ":"),
          let port = Int(input[input.index(after: idx)...]) else { return nil }
    return (String(input[..<idx]), port)
  }

  private func ensureServing(dataset: AppModel.DatasetEntry) -> (origins: [String], authToken: String) {
    guard let datasetInfo = serverDatasetInfo(for: dataset) else {
      return ([], "")
    }

    if sharePlayServerRunning,
       sharePlayDatasetID == datasetInfo.id {
      return (originAddresses(port: sharePlayServerPort), sharePlayAuthToken)
    }

    stopSharePlayServer()
    let authToken = BorgVRServerAuthentication.randomToken()
    for port in sharePlayCandidatePorts(preferredPort: appSettings?.sharePlayServerPort ?? sharePlayServerPort) {
      let state = sharePlayServerHost.start(
        configuration: BorgVRServerConfiguration(
          dataDirectory: "",
          port: port,
          maxBricksPerGetRequest: appSettings?.maxBricksPerGetRequest
            ?? BorgVRSharedDefaults.maximumBricksPerRequest,
          authSecret: authToken,
          enableWebServer: appSettings?.enableWebServer ?? false,
          webPort: sharePlayWebPort(for: port),
          useWebServerTLS: appSettings?.webServerUsesTLS ?? true,
          webServerCertificateData: appSettings?.webServerCertificateData ?? Data(),
          webServerCertificatePassword: appSettings?.webServerCertificatePassword ?? ""
        ),
        additionalDatasets: [datasetInfo],
        includeScannedDatasets: false
      )

      guard state.isRunning, state.datasets.contains(where: { $0.id == datasetInfo.id }) else {
        continue
      }

      sharePlayDatasetID = datasetInfo.id
      sharePlayAuthToken = authToken
      sharePlayServerRunning = true
      sharePlayServerPort = state.port
      return (originAddresses(port: state.port), authToken)
    }

    appModel?.logger.error("SharePlay dataset server did not start for dataset \(datasetInfo.id).")
    return ([], "")
  }

  private func stopSharePlayServer() {
    sharePlayServerHost.stop()
    sharePlayDatasetID = nil
    sharePlayAuthToken = ""
    sharePlayServerRunning = false
  }

  private func sharePlayWebPort(for serverPort: Int) -> Int {
    guard let appSettings else {
      return min(65535, max(1, serverPort + 1))
    }
    if appSettings.sharePlayWebServerPort == appSettings.sharePlayServerPort {
      return min(65535, max(1, serverPort + 1))
    }
    return appSettings.sharePlayWebServerPort
  }

  private func serverDatasetInfo(for dataset: AppModel.DatasetEntry) -> DatasetInfo? {
    switch dataset.source {
      case .local, .builtIn:
        let url = URL(fileURLWithPath: dataset.identifier)
        guard let metadata = try? BORGVRMetaData(url: url) else {
          appModel?.logger.error("SharePlay dataset server could not read metadata for \(dataset.identifier).")
          return nil
        }
        return DatasetInfo(
          id: metadata.uniqueID,
          filename: url.path,
          datasetDescription: metadata.datasetDescription.isEmpty ? dataset.description : metadata.datasetDescription
        )
      case .remote:
        return nil
    }
  }

  private func originAddresses(port: Int) -> [String] {
    let addresses = Self.localIPv4Addresses()
    var seen = Set<String>()
    let uniqueAddresses = addresses.filter { address in
      seen.insert(address).inserted
    }

    guard !uniqueAddresses.isEmpty else {
      appModel?.logger.error("SharePlay dataset server could not determine a local network address.")
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
}

private struct InitMessage {
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
      let lengthData = data[cursor..<cursor + 4]
      cursor += 4
      let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      guard cursor + Int(length) <= data.endIndex else { return nil }
      let stringData = data[cursor..<cursor + Int(length)]
      cursor += Int(length)
      return String(data: stringData, encoding: .utf8)
    }

    func readOrigins() -> [DatasetOrigin]? {
      guard cursor + 4 <= data.endIndex else { return nil }
      let countData = data[cursor..<cursor + 4]
      cursor += 4
      let count = UInt32(bigEndian: countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      var origins: [DatasetOrigin] = []
      origins.reserveCapacity(Int(count))
      for _ in 0..<count {
        guard let address = readString(), cursor + 4 <= data.endIndex else { return nil }
        let portData = data[cursor..<cursor + 4]
        cursor += 4
        let port = UInt32(bigEndian: portData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard let password = readString() else { return nil }
        origins.append(DatasetOrigin(address: address, port: Int(port), password: password))
      }
      return origins
    }

    guard let uniqueID = readString(),
          let origins = readOrigins(),
          let description = readString()
    else {
      return nil
    }

    self.uniqueID = uniqueID
    self.origins = origins
    self.description = description
  }

  func toData() -> Data {
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

private extension BORGVRMetaData {
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
