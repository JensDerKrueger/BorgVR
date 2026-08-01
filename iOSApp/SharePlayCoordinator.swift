import Combine
import Darwin
import Foundation
import GroupActivities
import LinkPresentation
import SwiftUI
import UIKit

private let borgVRSharePlayActivityIdentifier = "de.cgvis.borgvr.collaboration"

struct BorgVRSharePlayActivity: GroupActivity, Transferable {
  static let activityIdentifier = borgVRSharePlayActivityIdentifier

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

  private var groupSession: GroupSession<BorgVRSharePlayActivity>?
  private var messenger: GroupSessionMessenger?
  private var messageTask: Task<Void, Never>?
  private var sessionGeneration = 0
  private var appModel: AppModel?
  private var renderingParameters: RenderingParameters?
  private var appSettings: AppSettings?
  private var subscriptions = Set<AnyCancellable>()
  private var pendingCommonState = false
  private var pendingTransferFunction = false
  private var pendingTransform = false
  private var synchronizationTask: Task<Void, Never>?
  private var knownParticipants = Set<Participant>()
  private var startedActivityLocally = false
  private var localActivityStartDate: Date?
  private let localActivityStartGraceInterval: TimeInterval = 120
  private let sharePlayServerHost = BorgVRServerHost(logger: GUILogger())
  private var sharePlayDatasetID: String?
  private var sharePlayServerRunning = false
  private var sharePlayServerPort = AppSettings.int("sharePlayServerPort")

  func configure(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    appSettings: AppSettings
  ) async {
    self.appModel = appModel
    self.renderingParameters = renderingParameters
    self.appSettings = appSettings

    for await session in BorgVRSharePlayActivity.sessions() {
      configure(session)
    }
  }

  func registerGroupActivity() {
    let activity = BorgVRSharePlayActivity()
    let itemProvider = NSItemProvider()
    itemProvider.registerGroupActivity(activity)

    let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider])
    configuration.metadataProvider = { key in
      guard key == .linkPresentationMetadata else { return nil }
      let metadata = LPLinkMetadata()
      metadata.title = activity.metadata.title
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
      stopSharePlayServer()
      Task { try? await sendData(Data(), of: .shutdownRequest) }
    } else {
      groupSession?.leave()
    }
  }

  func leaveGroupActivity() {
    stopSharePlayServer()
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
        Task { @MainActor in
          guard self?.sessionGeneration == generation else { return }
          self?.stopSharePlayServer()
          self?.resetSessionReceivers()
          self?.isInSession = false
          self?.appModel?.groupSessionHost = false
        }
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
        return ensureServing(dataset: dataset)
    }
  }

  private func ensureServing(dataset: AppModel.DatasetEntry) -> [String] {
    guard let datasetInfo = serverDatasetInfo(for: dataset) else {
      return []
    }

    if sharePlayServerRunning,
       sharePlayDatasetID == datasetInfo.id {
      return originAddresses(port: sharePlayServerPort)
    }

    stopSharePlayServer()
    for port in sharePlayCandidatePorts(preferredPort: appSettings?.sharePlayServerPort ?? sharePlayServerPort) {
      let state = sharePlayServerHost.start(
        configuration: BorgVRServerConfiguration(
          dataDirectory: "",
          port: port,
          maxBricksPerGetRequest: appSettings?.maxBricksPerGetRequest ?? 20
        ),
        additionalDatasets: [datasetInfo],
        includeScannedDatasets: false
      )

      guard state.isRunning, state.datasets.contains(where: { $0.id == datasetInfo.id }) else {
        continue
      }

      sharePlayDatasetID = datasetInfo.id
      sharePlayServerRunning = true
      sharePlayServerPort = state.port
      return originAddresses(port: state.port)
    }

    appModel?.logger.error("SharePlay dataset server did not start for dataset \(datasetInfo.id).")
    return []
  }

  private func stopSharePlayServer() {
    sharePlayServerHost.stop()
    sharePlayDatasetID = nil
    sharePlayServerRunning = false
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
