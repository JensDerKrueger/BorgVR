import Combine
import Foundation
import GroupActivities
import LinkPresentation
import SwiftUI

private let borgVRSharePlayActivityIdentifier = "de.cgvis.borgvr.collaboration"

struct BorgVRSharePlayActivity: GroupActivity, Transferable {
  static let activityIdentifier = borgVRSharePlayActivityIdentifier

  var metadata: GroupActivityMetadata = {
    var metadata = GroupActivityMetadata()
    metadata.title = String(localized: "BorgVR macOS Live Collaboration")
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
  private var synchronizationTask: Task<Void, Never>?
  private var knownParticipants = Set<Participant>()
  private var startedActivityLocally = false
  private var localActivityStartDate: Date?
  private let localActivityStartGraceInterval: TimeInterval = 120

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
    Task {
      do {
        let activity = BorgVRSharePlayActivity()
        switch await activity.prepareForActivation() {
          case .activationPreferred:
            _ = try await activity.activate()
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
    startedActivityLocally = true
    localActivityStartDate = Date()
    appModel?.groupSessionHost = true
  }

  private func clearLocalActivityStarter() {
    startedActivityLocally = false
    localActivityStartDate = nil
    appModel?.groupSessionHost = false
  }

  private var isLocalActivityStartPending: Bool {
    guard startedActivityLocally, let localActivityStartDate else {
      return false
    }
    return Date().timeIntervalSince(localActivityStartDate) <= localActivityStartGraceInterval
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
    startedActivityLocally = false
    localActivityStartDate = nil
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

  private func configure(_ session: GroupSession<BorgVRSharePlayActivity>) {
    resetSessionReceivers()
    sessionGeneration += 1
    let generation = sessionGeneration
    subscriptions.removeAll()
    groupSession = session
    isInSession = true
    let isHost = isLocalActivityStartPending
    startedActivityLocally = isHost
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
    knownParticipants.removeAll()
  }

  private func sendInitialData(to participants: Participants = .all) async {
    guard appModel?.groupSessionHost == true else { return }

    guard let dataset = appModel?.activeDataset else {
      try? await sendData(InitMessage(uniqueID: "", origins: [], description: "").toData(), of: .initMessage, to: participants)
      return
    }

    let message = InitMessage(
      uniqueID: dataset.uniqueId,
      origins: shareOrigins(for: dataset),
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
    pendingCommonState = false
    pendingTransferFunction = false
    pendingTransform = false

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
        handleUpdate(data: payload)
      case MessageType.shutdownRequest.rawValue:
        guard appModel?.groupSessionHost != true else { return }
        appModel?.currentState = .selectData
      case MessageType.stateRequest.rawValue:
        guard appModel?.groupSessionHost == true else { return }
        Task { await sendInitialDataReliably(to: .only(Set([participant]))) }
      default:
        appModel?.logger.error("Invalid SharePlay message type: \(firstByte)")
    }
  }

  private func handleUpdate(data: Data) {
    do {
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
        sessionGeneration: generation
      )
    }
  }

  private func openFirstReachableRemoteDataset(
    uniqueID: String,
    description: String,
    origins: [(address: String, port: Int)],
    sessionGeneration generation: Int
  ) async {
    guard generation == sessionGeneration, isInSession else { return }
    guard let appModel else { return }

    guard let remoteSource = await firstReachableOrigin(origins, datasetID: uniqueID) else {
      guard generation == sessionGeneration, isInSession else { return }
      appModel.currentState = .waitingForHost
      appModel.logger.error("SharePlay dataset \(uniqueID) is not available locally and none of the host origins are reachable.")
      return
    }

    guard generation == sessionGeneration, isInSession, appModel.groupSessionHost != true else { return }
    appModel.activeDataset = AppModel.DatasetEntry(
      identifier: uniqueID,
      description: description,
      source: .remote(address: remoteSource.address, port: remoteSource.port),
      uniqueId: uniqueID
    )
    appModel.currentState = .renderData
  }

  private func firstReachableOrigin(
    _ origins: [(address: String, port: Int)],
    datasetID: String
  ) async -> (address: String, port: Int)? {
    for origin in origins {
      let isReachable = await Task.detached(priority: .userInitiated) {
        do {
          let manager = BORGVRRemoteDataManager(
            host: origin.address,
            port: UInt16(clamping: origin.port),
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

  private func shareOrigins(for dataset: AppModel.DatasetEntry) -> [String] {
    switch dataset.source {
      case .remote(let address, let port):
        return ["\(address):\(port)"]
      case .local, .builtIn:
        guard let storedAppModel, let serverController else {
          appModel?.logger.error("SharePlay dataset \(dataset.uniqueId) cannot be shared because no dataset server is configured.")
          return []
        }
        return serverController.ensureServing(dataset: dataset, using: storedAppModel)
    }
  }
}

private struct InitMessage {
  let uniqueID: String
  let origins: [String]
  let description: String

  init(uniqueID: String, origins: [String], description: String) {
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

    func writeStringArray(_ strings: [String]) {
      var count = UInt32(strings.count).bigEndian
      data.append(Data(bytes: &count, count: 4))
      strings.forEach(writeString)
    }

    writeString(uniqueID)
    writeStringArray(origins)
    writeString(description)

    return data
  }
}

private extension BORGVRMetaData {
  var summaryText: String {
    let bitsPerComponent = bytesPerComponent * 8
    let channelText = componentCount == 1
      ? String(localized: "1 Kanal")
      : String(format: String(localized: "metadata_channel_count_format"), componentCount)
    let compressionText = compression
      ? String(localized: "komprimiert")
      : String(localized: "unkomprimiert")
    let lodText = levelMetadata.count == 1
      ? String(localized: "1 LOD")
      : String(format: String(localized: "metadata_lod_count_format"), levelMetadata.count)

    return "\(width) x \(height) x \(depth) - " +
      "\(bitsPerComponent)-bit, \(channelText) - " +
      "\(String(localized: "Brick")) \(brickSize) - \(lodText) - " +
      "\(compressionText) - \(String(localized: "Werte")) \(minValue)...\(maxValue)"
  }
}
