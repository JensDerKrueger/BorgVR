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
  private var pendingCommonState = false
  private var pendingTransferFunction = false
  private var pendingTransform = false
  private var pendingScreenViewState: BorgVRScreenViewState?
  private var synchronizationTask: Task<Void, Never>?
  private var knownParticipants = Set<Participant>()
  private var participantInfoByID: [UUID: BorgVRSharePlayParticipantInfo] = [:]
  private var screenViewStateByParticipantID: [UUID: BorgVRScreenViewState] = [:]
  private let sharePlayServerHost = BorgVRServerHost(logger: GUILogger())
  private var sharePlayDatasetID: String?
  private var sharePlayAuthToken = ""
  private var sharePlayServerRunning = false
  private var sharePlayServerPort = StoredAppModel.int("sharePlayServerPort")
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
    if runtimeAppModel.groupSessionHost {
      Task { await sendInitialDataReliably() }
    } else {
      Task { await requestInitialStateReliably() }
    }
  }

  @MainActor func leaveGroupActivity() {
    guard let runtimeAppModel else { return }

    stopSharePlayServer()
    self.groupSession?.leave()
    runtimeAppModel.groupSessionHost = false
    resetSessionReceivers()
  }

  func configureSession(runtimeAppModel:RuntimeAppModel, storedAppModel: StoredAppModel) async {
    await runtimeAppModel.logger.dev("configure new groupSession")
    self.runtimeAppModel = runtimeAppModel
    self.storedAppModel = storedAppModel
    for await session in BorgVRActivity.sessions() {
      await runtimeAppModel.logger.dev("Received groupsession")
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
        runtimeAppModel.groupSessionHost = localUserStartedActivity
      }
      localParticipantID = session.localParticipant.id
      currentHostParticipantID = localUserStartedActivity ? session.localParticipant.id : nil
      hostElectionTerm = 0
      knownParticipants = session.activeParticipants

      session.$activeParticipants
        .sink { activeParticipants in
          guard generation == self.sessionGeneration else { return }
          let previousParticipants = self.knownParticipants
          let newParticipants = activeParticipants.subtracting(self.knownParticipants)
          let departedParticipants = previousParticipants.subtracting(activeParticipants)
          self.knownParticipants = activeParticipants
          let activeIDs = Set(activeParticipants.map(\.id))
          self.participantInfoByID = self.participantInfoByID.filter {
            activeIDs.contains($0.key)
          }
          self.screenViewStateByParticipantID = self.screenViewStateByParticipantID.filter {
            activeIDs.contains($0.key)
          }
          self.adHocOriginsByParticipantID = self.adHocOriginsByParticipantID.filter {
            activeIDs.contains($0.key)
          }
          Task { @MainActor in
            if !newParticipants.isEmpty || !departedParticipants.isEmpty {
              let joinedIDs = newParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
              let departedIDs = departedParticipants.map { $0.id.uuidString }.sorted().joined(separator: ", ")
              let hostID = self.currentHostParticipantID?.uuidString ?? "unknown"
              runtimeAppModel.logger.info(
                "SharePlay participants changed; joined: [\(joinedIDs)], departed: [\(departedIDs)], host: \(hostID), active count: \(activeIDs.count)."
              )
            }
            self.handleHostParticipantChanges(activeParticipantIDs: activeIDs)
            self.publishParticipants()
            self.applyMinimumScreenViewportAspectRatio()
          }

          if newParticipants.isEmpty { return }

          Task { @MainActor in
            runtimeAppModel.logger.dev("New Participants joined the groupsession")
          }

          Task {
            await self.sendInitialDataReliably(to: .only(newParticipants))
            await self.sendParticipantInfo(to: .only(newParticipants))
            await self.sendOriginCatalogSnapshot(to: .only(newParticipants))
            await self.advertiseCurrentLocalDataset(to: .only(newParticipants))
            await self.sendCurrentHostState(to: .only(newParticipants))
          }

        } .store(in: &subscriptions)

      session.$state
        .sink { [weak self] state in
          guard case .invalidated(let reason) = state else { return }
          Task { @MainActor in
            guard self?.sessionGeneration == generation else { return }
            self?.runtimeAppModel?.logger.warning(
              "SharePlay session invalidated by the system: \(reason.localizedDescription)"
            )
            self?.stopSharePlayServer()
            self?.resetSessionReceivers()
            self?.runtimeAppModel?.groupSessionHost = false
          }
        }
        .store(in: &subscriptions)

      let messenger = GroupSessionMessenger(session: session)
      self.messenger = messenger
      session.join()
      Task {
        await self.sendParticipantInfo()
        await self.sendOriginCatalogSnapshot()
        await self.advertiseCurrentLocalDataset()
        await self.sendCurrentHostState()
      }

      if let pose = systemCoordinator.localParticipantState.pose {
        await runtimeAppModel.logger.dev("Joined groupsession with pose \(pose)")
      } else {
        await runtimeAppModel.logger.dev("Joined groupsession no pose available")
      }

      messageTask = Task.detached { [weak self] in
        for await (data, context) in messenger.messages(of: Data.self) {
          if Task.isCancelled { return }
          await self?.handleIncoming(data: data, from: context.source, sessionGeneration: generation)
        }
      }

      let isHost = await MainActor.run {
        runtimeAppModel.groupSessionHost
      }
      if isHost {
        Task { await self.sendInitialDataReliably() }
      } else {
        Task { await self.requestInitialStateReliably() }
      }
    }
  }

  @MainActor
  func shutdownGroupsession() async {
    defer { stopSharePlayServer() }
    guard groupSession != nil else { return }

    do {
      try await sendData(data: Data(), of: .shutdownRequest)
      try? await Task.sleep(nanoseconds: 100_000_000)
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
        pendingCommonState = true
        pendingTransferFunction = true
        pendingTransform = true
      case .stateOnly:
        pendingCommonState = true
      case .transformOnly:
        pendingTransform = true
    }

    guard synchronizationTask == nil else { return }
    let delay: UInt64 = pendingTransferFunction ? 200_000_000 : 50_000_000
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

    let shouldSendCommonState = pendingCommonState
    let shouldSendTransferFunction = pendingTransferFunction
    let shouldSendTransform = pendingTransform
    let screenViewState = pendingScreenViewState
    pendingCommonState = false
    pendingTransferFunction = false
    pendingTransform = false
    pendingScreenViewState = nil

    do {
      if shouldSendCommonState {
        try await sendData(
          data: sharedAppModel.serializeCommonSharePlayState(
            includeTransferFunction: shouldSendTransferFunction
          ),
          of: .renderingUpdate
        )
      }
      if shouldSendTransform {
        try await sendData(
          data: sharedAppModel.serializeVisionSharePlayTransform(),
          of: .renderingUpdate
        )
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

  func synchronizeMarkers() {
    guard messenger != nil else { return }
    Task {
      guard let sharedAppModel else { return }
      do {
        try await sendData(
          data: sharedAppModel.serializeVolumeMarkersSharePlayState(),
          of: .renderingUpdate
        )
      } catch {
        await runtimeAppModel?.logger
          .error("Failed to send marker data to all participants: \(error)")
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
        await runtimeAppModel?.logger.error(
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

    if let dataset = runtimeAppModel.activeDataset {
      let sharedDataset = shareOrigins(for: dataset)
      let initMessage = InitMessage(
        uniqueID: dataset.uniqueId,
        origins: sharedDataset,
        description:dataset.description
      )

      let data = initMessage.toData()
      do {
        try await sendData(data:data, of: .initMessage, to: to)
        try await sendData(
          data: sharedAppModel.serializeCommonSharePlayState(includeTransferFunction: true),
          of: .renderingUpdate,
          to: to
        )
        try await sendData(
          data: sharedAppModel.serializeVisionSharePlayTransform(),
          of: .renderingUpdate,
          to: to
        )
        try await sendData(
          data: sharedAppModel.serializeVolumeMarkersSharePlayState(),
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
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    } else {
      let data = InitMessage(uniqueID: "", origins: [], description:"").toData()
      do {
        try await sendData(data:data, of: .initMessage, to: to)
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    }

  }

  @MainActor
  func sendInitialDataReliably(to:Participants = .all) async {
    await sendInitialData(to: to)
    try? await Task.sleep(nanoseconds: 250_000_000)
    await sendInitialData(to: to)
  }

  func requestInitialStateReliably() async {
    try? await sendData(data: Data(), of: .stateRequest)
    try? await Task.sleep(nanoseconds: 250_000_000)
    try? await sendData(data: Data(), of: .stateRequest)
  }

  @MainActor
  private func handleIncoming(data: Data, from: Participant, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel else { return }

    if let firstByte = data.first {
      let stripped = Data(data.dropFirst())

      switch firstByte {
        case MessageType.initMessage.rawValue:
          guard !runtimeAppModel.groupSessionHost else { return }
          handleInit(data: stripped, from: from, sessionGeneration: generation)
        case MessageType.renderingUpdate.rawValue:
          handleUpdate(data: stripped, from: from)
        case MessageType.shutdownRequest.rawValue:
          guard !runtimeAppModel.groupSessionHost else { return }
          handleShutdown(from: from)
        case MessageType.stateRequest.rawValue:
          guard runtimeAppModel.groupSessionHost else { return }
          Task { await self.sendInitialDataReliably(to: .only(Set([from]))) }
        case MessageType.participantInfo.rawValue:
          handleParticipantInfo(data: stripped, from: from)
        case MessageType.screenViewRequest.rawValue:
          guard let screenViewState = sharedAppModel?.screenSharePlayViewState else { return }
          Task {
            try? await sendData(
              data: BorgVRScreenViewStateCodec.encode(screenViewState, isShared: true),
              of: .renderingUpdate,
              to: .only(Set([from]))
            )
          }
        case MessageType.originCatalogSnapshot.rawValue:
          handleOriginCatalogSnapshot(data: stripped)
        case MessageType.datasetOriginAdvertisement.rawValue:
          handleDatasetOriginAdvertisement(data: stripped, from: from)
        case MessageType.hostClaim.rawValue:
          handleHostClaim(data: stripped)
        case MessageType.hostState.rawValue:
          handleHostState(data: stripped)
        default :
          runtimeAppModel.logger.error("Invalid first byte: \(firstByte) in group message")
      }

    }
  }

  private enum MessageType: UInt8 {
    case initMessage     = 0x00
    case renderingUpdate = 0x01
    case shutdownRequest = 0x02
    case stateRequest    = 0x03
    case participantInfo = 0x04
    case screenViewRequest = 0x05
    case originCatalogSnapshot = 0x06
    case datasetOriginAdvertisement = 0x07
    case hostClaim = 0x08
    case hostState = 0x09
  }

  private func sendData(data:Data, of messageType:MessageType,
                        to participants:Participants = .all) async throws {
    guard let messenger else { return }
    try await messenger.send(Data([messageType.rawValue]) + data, to:participants)
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
      participantInfoByID[participant.id] = info
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
    let participantSharesView = participantInfoByID[participant.id]?.sharesScreenView
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
      guard let platform = participantInfoByID[participantID]?.platform,
            platform == .iOS || platform == .macOS,
            participantInfoByID[participantID]?.sharesScreenView == true else {
        return nil
      }
      return state.viewportAspectRatio
    }.min()
  }

  @MainActor
  private func publishParticipants() {
    let participants = participantInfoByID.map {
      BorgVRSharePlayParticipant(id: $0.key, info: $0.value)
    }.sorted {
      if $0.displayName == $1.displayName {
        return $0.id.uuidString < $1.id.uuidString
      }
      return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
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
      guard let info = participantInfoByID[participantID] else { return false }
      return (info.platform == .iOS || info.platform == .macOS) && !info.sharesScreenView
    }
  }

  @MainActor
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
    pendingScreenViewState = nil
    knownParticipants.removeAll()
    participantInfoByID.removeAll()
    screenViewStateByParticipantID.removeAll()
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
    runtimeAppModel?.showsHostDeparturePrompt = false
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

  protocol DataCodable {
    init?(data: Data)
    func toData() -> Data
  }

  struct InitMessage: DataCodable {
    let uniqueID: String
    let origins: [DatasetOrigin]
    let description: String

    init(uniqueID: String, origins: [DatasetOrigin], description:String) {
      self.uniqueID = uniqueID
      self.origins = origins
      self.description = description
    }

    init?(data: Data) {
      var cursor = data.startIndex

      func readString() -> String? {
        // read length (4 Bytes)
        guard cursor + 4 <= data.endIndex else { return nil }
        let lengthData = data[cursor..<cursor+4]
        cursor += 4
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })

        // read UTF8-bytes
        guard cursor + Int(length) <= data.endIndex else { return nil }
        let stringData = data[cursor..<cursor+Int(length)]
        cursor += Int(length)

        return String(data: stringData, encoding: .utf8)
      }

      func readOrigins() -> [DatasetOrigin]? {
        guard cursor + 4 <= data.endIndex else { return nil }
        let countData = data[cursor..<cursor+4]
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

      guard let id = readString(),
            let origins = readOrigins(),
            let desc = readString() else { return nil }

      self.uniqueID = id
      self.origins = origins
      self.description = desc
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

  @MainActor
  func handleInit(data: Data, from: Participant, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel = runtimeAppModel else { return }
    guard !runtimeAppModel.groupSessionHost else { return }
    runtimeAppModel.logger.dev("Received groupsession init data")
    runtimeAppModel.groupSessionHost = false

    guard let initMessage = InitMessage(data:data) else {
      runtimeAppModel.logger.dev("Received incomplete init message, waiting for host")
      runtimeAppModel.sharePlayWaitingReason = .hostDataset
      runtimeAppModel.currentState = .waitingForHost
      return
    }

    guard initMessage.uniqueID != "" else {
      runtimeAppModel.logger.dev("Received empty dataset in init message, waiting for host")
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil
      runtimeAppModel.sharePlayWaitingReason = .hostDataset
      runtimeAppModel.currentState = .waitingForHost
      return
    }

    DatasetOriginCatalog.shared.prioritize(initMessage.origins, for: initMessage.uniqueID)
    mergeSessionOrigins(initMessage.origins, for: initMessage.uniqueID)

    if let localFile = findlocalFile(id : initMessage.uniqueID) {
      runtimeAppModel.logger.info("Found SharePlay dataset \(initMessage.uniqueID) locally at \(localFile.path()).")
      pendingDatasetLoadTask?.cancel()
      pendingDatasetLoadTask = nil
      pendingDatasetLoad = nil

      if runtimeAppModel.immersiveSpaceState == .open {
        if let dataset = runtimeAppModel.activeDataset {
          if initMessage.uniqueID == dataset.uniqueId {
            runtimeAppModel.logger.dev("Dataset is already open, ignoring new groupsession init data")
            return
          }
        }
      }

      runtimeAppModel.startImmersiveSpace(identifier: localFile.path(),
                                   description: initMessage.description,
                                   source: .local,
                                   uniqueId: initMessage.uniqueID,
                                   asGroupSessionHost: false)
      Task { await advertiseCurrentLocalDataset() }
    } else {
      runtimeAppModel.logger.info("SharePlay dataset \(initMessage.uniqueID) is not available locally; searching known network sources.")
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
    pendingDatasetLoadTask?.cancel()
    let origins = knownOrigins(for: pending.uniqueID)
    runtimeAppModel?.sharePlayWaitingReason = .datasetSource
    runtimeAppModel?.currentState = .waitingForHost
    guard !origins.isEmpty else {
      runtimeAppModel?.logger.warning("No known source currently provides SharePlay dataset \(pending.uniqueID); waiting for participant sources.")
      pendingDatasetLoadTask = nil
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
      guard generation == sessionGeneration, groupSession != nil else { return }
      runtimeAppModel.currentState = .waitingForHost
      runtimeAppModel.logger.warning("None of the currently known sources provides SharePlay dataset \(uniqueID); waiting for additional participant sources.")
      pendingDatasetLoadTask = nil
      return
    }

    guard generation == sessionGeneration, groupSession != nil, !runtimeAppModel.groupSessionHost else { return }
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

  private func firstReachableOrigin(
    _ origins: [DatasetOrigin],
    datasetID: String
  ) async -> DatasetOrigin? {
    for origin in origins {
      await logInfo("Checking \(origin.address):\(origin.port) for SharePlay dataset \(datasetID).")
      let result = await Task.detached(priority: .userInitiated) {
        do {
          let manager = BORGVRRemoteDataManager(
            host: origin.address,
            port: UInt16(clamping: origin.port),
            authSecret: origin.password,
            logger: nil,
            notifier: nil
          )
          try manager.connect(timeout: 2)
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
        await logInfo("Found SharePlay dataset \(datasetID) at \(origin.address):\(origin.port).")
        return origin
      }
      if result.1.isEmpty {
        await logInfo("Source \(origin.address):\(origin.port) is reachable but does not provide dataset \(datasetID).")
      } else {
        await logWarning("Could not query \(origin.address):\(origin.port): \(result.1)")
      }
    }

    return nil
  }

  @MainActor
  private func logInfo(_ message: String) {
    runtimeAppModel?.logger.info(message)
  }

  @MainActor
  private func logWarning(_ message: String) {
    runtimeAppModel?.logger.warning(message)
  }

  @MainActor
  private func shareOrigins(for dataset: RuntimeAppModel.DatasetEntry) -> [DatasetOrigin] {
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

  @MainActor
  private func knownOrigins(for datasetID: String) -> [DatasetOrigin] {
    let advertised = adHocOriginsByParticipantID.values.flatMap { $0[datasetID] ?? [] }
    return DatasetOriginCatalog.deduplicated(
      advertised + (sessionOriginsByDatasetID[datasetID] ?? [])
        + DatasetOriginCatalog.shared.origins(for: datasetID)
    )
  }

  @MainActor
  private func mergeSessionOrigins(_ origins: [DatasetOrigin], for datasetID: String) {
    guard !datasetID.isEmpty else { return }
    sessionOriginsByDatasetID[datasetID] = DatasetOriginCatalog.deduplicated(
      origins + (sessionOriginsByDatasetID[datasetID] ?? [])
    )
  }

  @MainActor
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
    try? await sendData(data: data, of: .originCatalogSnapshot, to: participants)
  }

  @MainActor
  private func handleOriginCatalogSnapshot(data: Data) {
    do {
      let snapshot = try DatasetOriginSharePlayCodec.decode(DatasetOriginSnapshot.self, from: data)
      DatasetOriginCatalog.shared.mergeRemoteSnapshot(snapshot)
      for (datasetID, origins) in snapshot.originsByDatasetID() {
        mergeSessionOrigins(origins, for: datasetID)
      }
      runtimeAppModel?.logger.info("Received a SharePlay source catalog with \(snapshot.entries.count) server(s).")
      retryPendingDatasetLoad()
    } catch {
      runtimeAppModel?.logger.warning("Could not decode SharePlay source catalog: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func advertiseCurrentLocalDataset(to participants: Participants = .all) async {
    guard groupSession != nil, let dataset = runtimeAppModel?.activeDataset else { return }
    guard dataset.source == .local || dataset.source == .builtIn else { return }
    let served = ensureServing(dataset: dataset)
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
  private func handleDatasetOriginAdvertisement(data: Data, from participant: Participant) {
    do {
      let advertisement = try DatasetOriginSharePlayCodec.decode(
        DatasetOriginAdvertisement.self,
        from: data
      )
      adHocOriginsByParticipantID[participant.id, default: [:]][advertisement.datasetID] =
        DatasetOriginCatalog.deduplicated(advertisement.origins)
      runtimeAppModel?.logger.info("Received \(advertisement.origins.count) participant source(s) for dataset \(advertisement.datasetID).")
      retryPendingDatasetLoad()
    } catch {
      runtimeAppModel?.logger.warning("Could not decode SharePlay participant source: \(error.localizedDescription)")
    }
  }

  @MainActor
  func takeOverHostRole() {
    guard groupSession != nil,
          currentHostParticipantID == nil,
          let localParticipantID else { return }
    runtimeAppModel?.showsHostDeparturePrompt = false
    let claim = BorgVRSharePlayHostClaim(
      term: hostElectionTerm,
      candidateID: localParticipantID
    )
    registerHostClaim(claim)
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
  private func handleHostParticipantChanges(activeParticipantIDs: Set<UUID>) {
    guard let currentHostParticipantID,
          currentHostParticipantID != localParticipantID,
          !activeParticipantIDs.contains(currentHostParticipantID) else { return }
    self.currentHostParticipantID = nil
    hostElectionTerm &+= 1
    hostClaims = [hostElectionTerm: []]
    runtimeAppModel?.groupSessionHost = false
    runtimeAppModel?.showsHostDeparturePrompt = true
    runtimeAppModel?.logger.warning("The SharePlay host left the session; waiting for a new host.")
  }

  @MainActor
  private func sendCurrentHostState(to participants: Participants = .all) async {
    guard let currentHostParticipantID else { return }
    let state = BorgVRSharePlayHostState(
      term: hostElectionTerm,
      hostID: currentHostParticipantID
    )
    guard let data = try? BorgVRSharePlayHostCodec.encode(state) else { return }
    try? await sendData(data: data, of: .hostState, to: participants)
  }

  @MainActor
  private func handleHostClaim(data: Data) {
    guard let claim = try? BorgVRSharePlayHostCodec.decode(
      BorgVRSharePlayHostClaim.self,
      from: data
    ) else { return }
    registerHostClaim(claim)
  }

  @MainActor
  private func registerHostClaim(_ claim: BorgVRSharePlayHostClaim) {
    guard claim.term >= hostElectionTerm, isParticipantActive(claim.candidateID) else { return }
    if claim.term > hostElectionTerm {
      hostElectionTerm = claim.term
      currentHostParticipantID = nil
      runtimeAppModel?.groupSessionHost = false
      hostClaims.removeAll()
    }
    hostClaims[claim.term, default: []].insert(claim.candidateID)
    scheduleHostElectionResolution(term: claim.term)
  }

  @MainActor
  private func scheduleHostElectionResolution(term: UInt64) {
    hostElectionTask?.cancel()
    hostElectionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled else { return }
      self?.resolveHostElection(term: term)
    }
  }

  @MainActor
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

  @MainActor
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

  @MainActor
  private func applyHostState(_ state: BorgVRSharePlayHostState) {
    hostElectionTerm = state.term
    currentHostParticipantID = state.hostID
    hostClaims = [state.term: [state.hostID]]
    hostElectionTask?.cancel()
    hostElectionTask = nil
    runtimeAppModel?.showsHostDeparturePrompt = false
    let isLocalHost = state.hostID == localParticipantID
    runtimeAppModel?.groupSessionHost = isLocalHost
    runtimeAppModel?.logger.info(isLocalHost
      ? "This device took over the SharePlay host role."
      : "A participant took over the SharePlay host role.")
  }

  @MainActor
  private func isParticipantActive(_ participantID: UUID) -> Bool {
    participantID == localParticipantID || knownParticipants.contains { $0.id == participantID }
  }

  private func splitAddressAndPort(_ input: String) -> (address: String, port: Int)? {
    guard let idx = input.lastIndex(of: ":"),
          let port = Int(input[input.index(after: idx)...]) else { return nil }
    return (String(input[..<idx]), port)
  }

  @MainActor
  private func ensureServing(dataset: RuntimeAppModel.DatasetEntry) -> (origins: [String], authToken: String) {
    guard let datasetInfo = serverDatasetInfo(for: dataset) else {
      return ([], "")
    }

    if sharePlayServerRunning,
       sharePlayDatasetID == datasetInfo.id {
      return (originAddresses(port: sharePlayServerPort), sharePlayAuthToken)
    }

    stopSharePlayServer()
    let authToken = BorgVRServerAuthentication.randomToken()
    for port in sharePlayCandidatePorts(preferredPort: storedAppModel?.sharePlayServerPort ?? sharePlayServerPort) {
      let state = sharePlayServerHost.start(
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

    runtimeAppModel?.logger.error("SharePlay dataset server did not start for dataset \(datasetInfo.id).")
    return ([], "")
  }

  @MainActor
  private func stopSharePlayServer() {
    sharePlayServerHost.stop()
    sharePlayDatasetID = nil
    sharePlayAuthToken = ""
    sharePlayServerRunning = false
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
    switch dataset.source {
      case .local, .builtIn:
        let url = URL(fileURLWithPath: dataset.identifier)
        guard let metadata = try? BORGVRMetaData(url: url) else {
          runtimeAppModel?.logger.error("SharePlay dataset server could not read metadata for \(dataset.identifier).")
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
      if let previews = try SpatialToolPreviewSharePlayCodec.decodeIfPresent(data) {
        sharedAppModel.updateRemoteSpatialToolPreviews(
          previews,
          participantID: from.id
        )
        return
      }
      if let screenViewUpdate = try BorgVRScreenViewStateCodec.decodeUpdateIfPresent(data) {
        applyScreenViewUpdate(screenViewUpdate, from: from)
        return
      }
      if try sharedAppModel.applySharePlayUpdate(from: data) {
        return
      }
      try sharedAppModel.applyUpdate(from: data)
    } catch {
      print("Failed to apply update: \(error)")
    }
  }

  @MainActor
  func handleShutdown(from: Participant) {
    runtimeAppModel?.sharePlayWaitingReason = .hostDataset
    runtimeAppModel?.currentState = .waitingForHost
    runtimeAppModel?.immersiveSpaceIntent = .close
  }
}
