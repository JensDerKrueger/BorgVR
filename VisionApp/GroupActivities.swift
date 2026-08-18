import Darwin
import Foundation
import GroupActivities
import SwiftUI
import LinkPresentation
import Combine

let groupActivityIdentifier = "de.cgvis.borgvr.collaboration"

struct BorgVRActivity: GroupActivity, Transferable {
  static let activityIdentifier = groupActivityIdentifier

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
  private unowned var sharedAppModel : SharedAppModel
  private weak var runtimeAppModel : RuntimeAppModel? = nil
  private weak var storedAppModel : StoredAppModel? = nil
  private var subscriptions = Set<AnyCancellable>()
  private var knownParticipants = Set<Participant>()
  private var startedActivityLocally = false
  private var localActivityStartDate: Date?
  private let localActivityStartGraceInterval: TimeInterval = 120
  private let sharePlayServerHost = BorgVRServerHost(logger: GUILogger())
  private var sharePlayDatasetID: String?
  private var sharePlayAuthToken = ""
  private var sharePlayServerRunning = false
  private var sharePlayServerPort = StoredAppModel.int("sharePlayServerPort")

  init(_ sharedAppModel: SharedAppModel) {
    self.sharedAppModel = sharedAppModel
  }

  @MainActor func markLocalActivityStarter() {
    startedActivityLocally = true
    localActivityStartDate = Date()
    runtimeAppModel?.groupSessionHost = true
  }

  @MainActor func leaveGroupActivity() {
    guard let runtimeAppModel else { return }

    stopSharePlayServer()
    if runtimeAppModel.groupSessionHost {
      self.groupSession?.end()
    } else {
      self.groupSession?.leave()
    }
    startedActivityLocally = false
    localActivityStartDate = nil
    runtimeAppModel.groupSessionHost = false
    resetSessionReceivers()
  }

  private var isLocalActivityStartPending: Bool {
    guard startedActivityLocally, let localActivityStartDate else {
      return false
    }
    return Date().timeIntervalSince(localActivityStartDate) <= localActivityStartGraceInterval
  }

  func configureSession(runtimeAppModel:RuntimeAppModel, storedAppModel: StoredAppModel) async {
    await runtimeAppModel.logger.dev("configure new groupSession")
    self.runtimeAppModel = runtimeAppModel
    self.storedAppModel = storedAppModel
    for await session in BorgVRActivity.sessions() {
      await runtimeAppModel.logger.dev("Received groupsession")
      resetSessionReceivers()
      sessionGeneration += 1
      let generation = sessionGeneration

      guard let systemCoordinator = await session.systemCoordinator else { continue }
      var config = SystemCoordinator.Configuration()
      config.spatialTemplatePreference = .sideBySide
      config.supportsGroupImmersiveSpace = true
      systemCoordinator.configuration = config

      self.groupSession = session
      let localUserStartedActivity = isLocalActivityStartPending
      startedActivityLocally = localUserStartedActivity
      await MainActor.run {
        runtimeAppModel.groupSessionHost = localUserStartedActivity
      }
      knownParticipants = session.activeParticipants

      session.$activeParticipants
        .sink { activeParticipants in
          guard generation == self.sessionGeneration else { return }
          let newParticipants = activeParticipants.subtracting(self.knownParticipants)
          self.knownParticipants = activeParticipants

          if newParticipants.isEmpty { return }

          Task { @MainActor in
            runtimeAppModel.logger.dev("New Participants joined the groupsession")
          }

          Task {
            await self.sendInitialDataReliably(to: .only(newParticipants))
          }

        } .store(in: &subscriptions)

      session.$state
        .sink { [weak self] state in
          guard case .invalidated = state else { return }
          Task { @MainActor in
            guard self?.sessionGeneration == generation else { return }
            self?.stopSharePlayServer()
            self?.resetSessionReceivers()
            self?.runtimeAppModel?.groupSessionHost = false
          }
        }
        .store(in: &subscriptions)

      let messenger = GroupSessionMessenger(session: session)
      self.messenger = messenger
      session.join()

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

  func shutdownGroupsession() {
    Task { @MainActor in
      stopSharePlayServer()
    }
    Task {
      do {
        try await sendData(data:Data(), of: .shutdownRequest)
      } catch {
        await runtimeAppModel?.logger
          .error("Failed to send shutdown data to all participants: \(error)")
      }
    }
  }

  func synchronize(kind: SharedAppModel.UpdateKind) {
    Task {
      do {
        switch kind {
          case .full:
            try await sendData(
              data: sharedAppModel.serializeCommonSharePlayState(includeTransferFunction: true),
              of: .renderingUpdate
            )
            try await sendData(data: sharedAppModel.serializeVisionSharePlayTransform(), of: .renderingUpdate)
          case .stateOnly:
            try await sendData(
              data: sharedAppModel.serializeCommonSharePlayState(includeTransferFunction: false),
              of: .renderingUpdate
            )
          case .transformOnly:
            try await sendData(data: sharedAppModel.serializeVisionSharePlayTransform(), of: .renderingUpdate)
        }
      } catch {
        await runtimeAppModel?.logger
          .error("Failed to send synchronize data to all participants: \(error)")
      }
    }
  }

  @MainActor
  func sendInitialData(to:Participants = .all) async  {
    guard let runtimeAppModel else { return }
    guard runtimeAppModel.groupSessionHost else { return }

    runtimeAppModel.logger.dev("sendInitialData")

    if let dataset = runtimeAppModel.activeDataset {
      let sharedDataset = shareOrigins(for: dataset)
      let initMessage = InitMessage(
        uniqueID: dataset.uniqueId,
        origins: sharedDataset.origins,
        authToken: sharedDataset.authToken,
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
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    } else {
      let data = InitMessage(uniqueID: "", origins: [], authToken: "", description:"").toData()
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
  }

  private func sendData(data:Data, of messageType:MessageType,
                        to participants:Participants = .all) async throws {
    guard let messenger else { return }
    try await messenger.send(Data([messageType.rawValue]) + data, to:participants)
  }

  private func resetSessionReceivers() {
    messageTask?.cancel()
    messageTask = nil
    groupSession = nil
    messenger = nil
    subscriptions.removeAll()
    knownParticipants.removeAll()
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
    let origins: [String]
    let authToken: String
    let description: String

    init(uniqueID: String, origins: [String], authToken: String, description:String) {
      self.uniqueID = uniqueID
      self.origins = origins
      self.authToken = authToken
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

      func readStringArray() -> [String]? {
        guard cursor + 4 <= data.endIndex else { return nil }
        let countData = data[cursor..<cursor+4]
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

      guard let id = readString(),
            let origins = readStringArray(),
            let authToken = readString(),
            let desc = readString() else { return nil }

      self.uniqueID = id
      self.origins = origins
      self.authToken = authToken
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

  @MainActor
  func handleInit(data: Data, from: Participant, sessionGeneration generation: Int) {

    func splitAddressAndPort(_ input: String) -> (address: String, port: Int)? {
      guard let idx = input.lastIndex(of: ":") else { return nil }
      let address = String(input[..<idx])
      let portPart = String(input[input.index(after: idx)...])
      guard let port = Int(portPart) else { return nil }
      return (address, port)
    }

    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel = runtimeAppModel else { return }
    guard !runtimeAppModel.groupSessionHost else { return }
    runtimeAppModel.logger.dev("Received groupsession init data")
    runtimeAppModel.groupSessionHost = false

    guard let initMessage = InitMessage(data:data) else {
      runtimeAppModel.logger.dev("Received incomplete init message, waiting for host")
      runtimeAppModel.currentState = .waitingForHost
      return
    }

    guard initMessage.uniqueID != "" else {
      runtimeAppModel.logger.dev("Received empty dataset in init message, waiting for host")
      runtimeAppModel.currentState = .waitingForHost
      return
    }

    if let localFile = findlocalFile(id : initMessage.uniqueID) {

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
    } else {

      let remoteOrigins = initMessage.origins.compactMap(splitAddressAndPort)
      if remoteOrigins.isEmpty {
        // TODO: handle local data that is not found on client
      } else {
        runtimeAppModel.currentState = .waitingForHost
        Task {
          await self.openFirstReachableRemoteDataset(
            uniqueID: initMessage.uniqueID,
            description: initMessage.description,
            origins: remoteOrigins,
            authToken: initMessage.authToken,
            sessionGeneration: generation
          )
        }
      }
    }
  }

  @MainActor
  private func openFirstReachableRemoteDataset(
    uniqueID: String,
    description: String,
    origins: [(address: String, port: Int)],
    authToken: String,
    sessionGeneration generation: Int
  ) async {
    guard generation == sessionGeneration, groupSession != nil else { return }
    guard let runtimeAppModel else { return }

    guard let remoteSource = await firstReachableOrigin(origins, datasetID: uniqueID, authToken: authToken) else {
      guard generation == sessionGeneration, groupSession != nil else { return }
      runtimeAppModel.currentState = .waitingForHost
      runtimeAppModel.logger.error("SharePlay dataset \(uniqueID) is not available locally and none of the host origins are reachable.")
      return
    }

    guard generation == sessionGeneration, groupSession != nil, !runtimeAppModel.groupSessionHost else { return }
    let dataset = RuntimeAppModel.DatasetEntry(
      identifier: uniqueID,
      description: description,
      source:.remote(address: remoteSource.address, port: remoteSource.port, password: authToken),
      uniqueId: uniqueID
    )
    runtimeAppModel.startImmersiveSpace(dataset: dataset, asGroupSessionHost:false)
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

  @MainActor
  private func shareOrigins(for dataset: RuntimeAppModel.DatasetEntry) -> (origins: [String], authToken: String) {
    switch dataset.source {
      case .remote(let address, let port, let password):
        return (["\(address):\(port)"], password)
      case .local, .builtIn:
        return ensureServing(dataset: dataset)
    }
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
          maxBricksPerGetRequest: 20,
          authSecret: authToken
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

  func handleUpdate(data: Data, from: Participant) {
    do {
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
    runtimeAppModel?.immersiveSpaceIntent = .close
  }
}
