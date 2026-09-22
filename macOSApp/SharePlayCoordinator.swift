import AppKit
import Combine
import Foundation
import GroupActivities
import LinkPresentation
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
    metadata.title = String(localized: "BorgVR Live Collaboration")
    metadata.subtitle = String(localized: "Collaborate on the same volumetric dataset.")
    metadata.type = .generic
    metadata.sceneAssociationBehavior = .content(borgVRSharePlayActivityIdentifier)
    return metadata
  }()
}

@MainActor
final class SharePlayCoordinator: ObservableObject {
  @Published private(set) var isInSession = false

  private var groupSession: GroupSession<BorgVRSharePlayActivity>?
  private var messenger: GroupSessionMessenger?
  private var messageTask: Task<Void, Never>?
  private var sessionGeneration = 0
  private var appModel: AppModel?
  private var renderingParameters: RenderingParameters?
  private var storedAppModel: StoredAppModel?
  private var serverController: BackgroundServerController?
  private var subscriptions = Set<AnyCancellable>()
  private var pendingCommonState = false
  private var pendingTransferFunction = false
  private var pendingTransform = false
  private var pendingMarkers = false
  private var synchronizationTask: Task<Void, Never>?
  private var knownParticipants = Set<Participant>()
  private let groupStateObserver = GroupStateObserver()
  private var activityActivationTask: Task<Void, Never>?

  func configure(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    storedAppModel: StoredAppModel,
    serverController: BackgroundServerController
  ) async {
    self.appModel = appModel
    self.renderingParameters = renderingParameters
    self.storedAppModel = storedAppModel
    self.serverController = serverController

    for await session in BorgVRSharePlayActivity.sessions() {
      configure(session)
    }
  }

  func registerGroupActivity() {
    // ShareLink handles activity presentation on macOS.
  }

  func startSharePlay() {
    markLocalActivityStarter()
    do {
      let controller = try GroupActivitySharingController(BorgVRSharePlayActivity())
      guard let presentingController = NSApp.keyWindow?.contentViewController else {
        clearLocalActivityStarter()
        appModel?.logger.error("Failed to start SharePlay because no active window is available.")
        return
      }

      presentingController.presentAsSheet(controller)
      Task { [weak self] in
        if await controller.result == .cancelled, self?.isInSession == false {
          self?.clearLocalActivityStarter()
        }
      }
    } catch {
      clearLocalActivityStarter()
      appModel?.logger.error("Failed to start SharePlay: \(error.localizedDescription)")
    }
  }

  func markLocalActivityStarter() {
    appModel?.groupSessionHost = true
    scheduleLocalActivityActivation()
  }

  private func clearLocalActivityStarter() {
    activityActivationTask?.cancel()
    activityActivationTask = nil
    appModel?.groupSessionHost = false
  }

  private func scheduleLocalActivityActivation() {
    activityActivationTask?.cancel()
    let activity = BorgVRSharePlayActivity()
    activityActivationTask = Task { [weak self] in
      guard let self else { return }

      // The sharing controller can establish FaceTime before it activates the
      // GroupActivity. Give it the first opportunity, then cover that gap.
      for _ in 0..<1_500 {
        guard !Task.isCancelled, !isInSession else { return }
        if groupStateObserver.isEligibleForGroupSession {
          break
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }

      guard
        !Task.isCancelled,
        !isInSession,
        groupStateObserver.isEligibleForGroupSession
      else { return }

      try? await Task.sleep(nanoseconds: 750_000_000)
      guard !Task.isCancelled, !isInSession else { return }

      do {
        _ = try await activity.activate()
      } catch {
        clearLocalActivityStarter()
        appModel?.logger.error("Failed to start SharePlay: \(error.localizedDescription)")
      }
    }
  }

  func datasetOpened() {
    if appModel?.groupSessionHost == true {
      Task { await sendInitialData() }
    }
  }

  func closeSharedDataset() {
    guard isInSession else { return }
    if appModel?.groupSessionHost == true {
      serverController?.stopSharePlayServer()
      Task { try? await sendData(Data(), of: .shutdownRequest) }
    } else {
      groupSession?.leave()
    }
  }

  func leaveGroupActivity() {
    serverController?.stopSharePlayServer()
    if appModel?.groupSessionHost == true {
      groupSession?.end()
    } else {
      groupSession?.leave()
    }
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
    synchronizationTask = nil
    Task { await flushPendingSynchronization() }
  }

  func synchronizeMarkers() {
    guard isInSession else { return }
    pendingMarkers = true
    guard synchronizationTask == nil else { return }
    synchronizationTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000)
      await self?.flushPendingSynchronization()
    }
  }

  private func configure(_ session: GroupSession<BorgVRSharePlayActivity>) {
    activityActivationTask?.cancel()
    activityActivationTask = nil
    resetSessionReceivers()
    sessionGeneration += 1
    let generation = sessionGeneration
    subscriptions.removeAll()
    groupSession = session
    isInSession = true
    let isHost = session.activity.initiatorID == localBorgVRSharePlayInitiatorID
    appModel?.groupSessionHost = isHost
    knownParticipants = session.activeParticipants

    session.$activeParticipants
      .sink { [weak self] activeParticipants in
        guard let self else { return }
        let newParticipants = activeParticipants.subtracting(self.knownParticipants)
        self.knownParticipants = activeParticipants
        guard !newParticipants.isEmpty else { return }
        Task { await self.sendInitialDataReliably(to: .only(newParticipants)) }
      }
      .store(in: &subscriptions)

    session.$state
      .sink { [weak self] state in
        guard case .invalidated = state else { return }
        guard self?.sessionGeneration == generation else { return }
        self?.serverController?.stopSharePlayServer()
        self?.resetSessionReceivers()
        self?.isInSession = false
        self?.appModel?.groupSessionHost = false
      }
      .store(in: &subscriptions)

    let messenger = GroupSessionMessenger(session: session)
    self.messenger = messenger
    session.join()

    messageTask = Task.detached { [weak self] in
      for await (data, context) in messenger.messages(of: Data.self) {
        if Task.isCancelled { return }
        await self?.handleIncoming(data: data, from: context.source, sessionGeneration: generation)
      }
    }

    if appModel?.groupSessionHost == true {
      Task { await sendInitialDataReliably() }
    } else {
      Task { await requestInitialStateReliably() }
    }
  }

  private enum MessageType: UInt8 {
    case initMessage = 0x00
    case renderingUpdate = 0x01
    case shutdownRequest = 0x02
    case stateRequest = 0x03
  }

  private func sendData(
    _ data: Data,
    of messageType: MessageType,
    to participants: Participants = .all
  ) async throws {
    guard let messenger else { return }
    try await messenger.send(Data([messageType.rawValue]) + data, to: participants)
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
    knownParticipants.removeAll()
    appModel?.clearRemoteSpatialStylusPreviews()
  }

  private func sendInitialData(to participants: Participants = .all) async {
    guard appModel?.groupSessionHost == true else { return }

    guard let dataset = appModel?.activeDataset else {
      try? await sendData(InitMessage(uniqueID: "", origins: [], authToken: "", description: "").toData(), of: .initMessage, to: participants)
      return
    }

    let sharedDataset = shareOrigins(for: dataset)
    let message = InitMessage(
      uniqueID: dataset.uniqueId,
      origins: sharedDataset.origins,
      authToken: sharedDataset.authToken,
      description: dataset.description
    )
    try? await sendData(message.toData(), of: .initMessage, to: participants)
    if let renderingParameters {
      try? await sendData(
        renderingParameters.serializeCommonSharePlayState(includeTransferFunction: true),
        of: .renderingUpdate,
        to: participants
      )
      try? await sendData(
        renderingParameters.serializeScreenSharePlayTransform(),
        of: .renderingUpdate,
        to: participants
      )
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

  private func requestInitialStateReliably() async {
    try? await sendData(Data(), of: .stateRequest)
    try? await Task.sleep(nanoseconds: 250_000_000)
    try? await sendData(Data(), of: .stateRequest)
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
        try await sendData(renderingParameters.serializeScreenSharePlayTransform(), of: .renderingUpdate)
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

    switch firstByte {
      case MessageType.initMessage.rawValue:
        guard appModel?.groupSessionHost != true else { return }
        handleInit(data: payload, sessionGeneration: generation)
      case MessageType.renderingUpdate.rawValue:
        handleUpdate(data: payload, from: participant)
      case MessageType.shutdownRequest.rawValue:
        guard appModel?.groupSessionHost != true else { return }
        appModel?.volumeMarkers.removeAll()
        appModel?.selectedVolumeMarkerID = nil
        appModel?.currentState = .waitingForHost
      case MessageType.stateRequest.rawValue:
        guard appModel?.groupSessionHost == true else { return }
        Task { await sendInitialDataReliably(to: .only(Set([participant]))) }
      default:
        appModel?.logger.error("Invalid SharePlay message type: \(firstByte)")
    }
  }

  private func handleUpdate(data: Data, from participant: Participant) {
    do {
      if let preview = try SpatialStylusPreviewSharePlayCodec.decodeIfPresent(data) {
        appModel?.updateRemoteSpatialStylusPreview(
          preview,
          participantID: participant.id
        )
        return
      }
      if let markers = try VolumeMarkerSharePlayCodec.decodeIfPresent(data) {
        appModel?.replaceVolumeMarkers(markers)
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

  private func handleInit(data: Data, sessionGeneration generation: Int) {
    guard generation == sessionGeneration, isInSession else { return }
    guard let appModel else { return }
    guard appModel.groupSessionHost != true else { return }
    appModel.groupSessionHost = false

    guard let message = InitMessage(data: data), !message.uniqueID.isEmpty else {
      appModel.currentState = .waitingForHost
      return
    }

    if appModel.activeDataset?.uniqueId == message.uniqueID,
       appModel.currentState == .renderData {
      return
    }

    if let localDataset = findLocalDataset(id: message.uniqueID, description: message.description) {
      appModel.activeDataset = localDataset
      appModel.currentState = .renderData
      return
    }

    let remoteOrigins = message.origins.compactMap(splitAddressAndPort)
    guard !remoteOrigins.isEmpty else {
      appModel.currentState = .waitingForHost
      appModel.logger.error("SharePlay dataset \(message.uniqueID) is not available locally and has no remote origins.")
      return
    }

    appModel.currentState = .waitingForHost
    Task {
      await openFirstReachableRemoteDataset(
        uniqueID: message.uniqueID,
        description: message.description,
        origins: remoteOrigins,
        authToken: message.authToken,
        sessionGeneration: generation
      )
    }
  }

  private func openFirstReachableRemoteDataset(
    uniqueID: String,
    description: String,
    origins: [(address: String, port: Int)],
    authToken: String,
    sessionGeneration generation: Int
  ) async {
    guard generation == sessionGeneration, isInSession else { return }
    guard let appModel else { return }

    guard let remoteSource = await firstReachableOrigin(origins, datasetID: uniqueID, authToken: authToken) else {
      guard generation == sessionGeneration, isInSession else { return }
      appModel.currentState = .waitingForHost
      appModel.logger.error("SharePlay dataset \(uniqueID) is not available locally and none of the host origins are reachable.")
      return
    }

    guard generation == sessionGeneration, isInSession, appModel.groupSessionHost != true else { return }
    appModel.activeDataset = AppModel.DatasetEntry(
      identifier: uniqueID,
      description: description,
      source: .remote(address: remoteSource.address, port: remoteSource.port, password: authToken),
      uniqueId: uniqueID
    )
    appModel.currentState = .renderData
  }

  private func firstReachableOrigin(
    _ origins: [(address: String, port: Int)],
    datasetID: String,
    authToken: String
  ) async -> (address: String, port: Int)? {
    for origin in origins {
      let isReachable = await Task.detached(priority: .userInitiated) {
        do {
          let manager = BORGVRRemoteDataManager(
            host: origin.address,
            port: UInt16(clamping: origin.port),
            authSecret: authToken,
            logger: nil,
            notifier: nil
          )
          try manager.connect(timeout: 2)
          return try manager.requestDatasetList().contains { $0.id == datasetID }
        } catch {
          return false
        }
      }.value

      if isReachable {
        return origin
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

    guard let storedAppModel else {
      return nil
    }

    let fileManager = FileManager.default
    let accessURL = storedAppModel.startAccessingDataDirectory()
    defer {
      storedAppModel.stopAccessingDataDirectory(accessURL)
    }

    let dataDirectoryURL = storedAppModel.resolvedDataDirectoryURL()
    guard let files = try? fileManager.contentsOfDirectory(at: dataDirectoryURL, includingPropertiesForKeys: nil) else {
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

  private func splitAddressAndPort(_ input: String) -> (address: String, port: Int)? {
    guard let idx = input.lastIndex(of: ":") else { return nil }
    let address = String(input[..<idx])
    let portPart = String(input[input.index(after: idx)...])
    guard let port = Int(portPart) else { return nil }
    return (address, port)
  }

  private func shareOrigins(for dataset: AppModel.DatasetEntry) -> (origins: [String], authToken: String) {
    switch dataset.source {
      case .remote(let address, let port, let password):
        return (["\(address):\(port)"], password)
      case .local, .builtIn:
        guard let storedAppModel, let serverController else {
          appModel?.logger.error("SharePlay dataset \(dataset.uniqueId) cannot be shared because no dataset server is configured.")
          return ([], "")
        }
        return serverController.ensureServing(dataset: dataset, using: storedAppModel)
    }
  }
}

private struct InitMessage {
  let uniqueID: String
  let origins: [String]
  let authToken: String
  let description: String

  init(uniqueID: String, origins: [String], authToken: String, description: String) {
    self.uniqueID = uniqueID
    self.origins = origins
    self.authToken = authToken
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

    func readStringArray() -> [String]? {
      guard cursor + 4 <= data.endIndex else { return nil }
      let countData = data[cursor..<cursor + 4]
      cursor += 4
      let count = UInt32(bigEndian: countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
      var strings: [String] = []
      strings.reserveCapacity(Int(count))
      for _ in 0..<count {
        guard let string = readString() else { return nil }
        strings.append(string)
      }
      return strings
    }

    guard let uniqueID = readString(),
          let origins = readStringArray(),
          let authToken = readString(),
          let description = readString()
    else {
      return nil
    }

    self.uniqueID = uniqueID
    self.origins = origins
    self.authToken = authToken
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

    func writeStringArray(_ strings: [String]) {
      var count = UInt32(strings.count).bigEndian
      data.append(Data(bytes: &count, count: 4))
      strings.forEach(writeString)
    }

    writeString(uniqueID)
    writeStringArray(origins)
    writeString(authToken)
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
