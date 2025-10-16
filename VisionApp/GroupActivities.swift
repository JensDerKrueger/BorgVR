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
  private unowned var sharedAppModel : SharedAppModel
  private weak var runtimeAppModel : RuntimeAppModel? = nil
  private var subscriptions = Set<AnyCancellable>()

  init(_ sharedAppModel: SharedAppModel) {
    self.sharedAppModel = sharedAppModel
  }

  @MainActor func leaveGroupActivity() {
    guard let runtimeAppModel else { return }

    if runtimeAppModel.groupSessionHost {
      self.groupSession?.end()
    } else {
      self.groupSession?.leave()
    }
  }

  func configureSession(runtimeAppModel:RuntimeAppModel) async {
    await runtimeAppModel.logger.dev("configure new groupSession")
    self.runtimeAppModel = runtimeAppModel
    for await session in BorgVRActivity.sessions() {
      await runtimeAppModel.logger.dev("Received groupsession")

      guard let systemCoordinator = await session.systemCoordinator else { continue }
      var config = SystemCoordinator.Configuration()
      config.spatialTemplatePreference = .sideBySide
      config.supportsGroupImmersiveSpace = true
      systemCoordinator.configuration = config

      self.groupSession = session

      session.$activeParticipants
        .sink { activeParticipants in
          let newParticipants =
          activeParticipants.subtracting(session.activeParticipants)

          if newParticipants.isEmpty { return }

          Task { @MainActor in
            runtimeAppModel.logger.dev("New Participants joined the groupsession")
          }

          Task {
            await self.sendInitialData(to: .only(newParticipants))
          }

        } .store(in: &subscriptions)

      let messenger = GroupSessionMessenger(session: session)
      self.messenger = messenger
      session.join()

      if let pose = systemCoordinator.localParticipantState.pose {
        await runtimeAppModel.logger.dev("Joined groupsession with pose \(pose)")
      } else {
        await runtimeAppModel.logger.dev("Joined groupsession no pose available")
      }

      Task.detached { [weak self] in
        for await (data, context) in messenger.messages(of: Data.self) {
          await self?.handleIncoming(data: data, from: context.source)
        }
      }
    }
  }

  func shutdownGroupsession() {
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
    let data = sharedAppModel.serialize(kind: kind)
    Task {
      do {
        try await sendData(data:data, of: .renderingUpdate)
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
      let origin = switch dataset.source {
        case .remote(let address, let port): "\(address):\(port)"
        default: ""
      }

      let initMessage = InitMessage(
        uniqueID: dataset.uniqueId,
        origin: origin,
        description:dataset.description
      )

      let data = initMessage.toData()
      do {
        try await sendData(data:data, of: .initMessage)
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    } else {
      let data = InitMessage(uniqueID: "",origin: "",description:"").toData()
      do {
        try await sendData(data:data, of: .initMessage)
      } catch {
        runtimeAppModel.logger.error("Failed to send init data to all participants: \(error)")
      }
    }

  }

  @MainActor
  private func handleIncoming(data: Data, from: Participant) {
    guard let runtimeAppModel else { return }

    if let firstByte = data.first {
      let stripped = Data(data.dropFirst())

      switch firstByte {
        case MessageType.initMessage.rawValue:
          handleInit(data: stripped, from: from)
        case MessageType.renderingUpdate.rawValue:
          handleUpdate(data: stripped, from: from)
        case MessageType.shutdownRequest.rawValue:
          handleShutdown(from: from)
        default :
          runtimeAppModel.logger.error("Invalid first byte: \(firstByte) in group message")
      }

    }
  }

  private enum MessageType: UInt8 {
    case initMessage     = 0x00
    case renderingUpdate = 0x01
    case shutdownRequest = 0x02
  }

  private func sendData(data:Data, of messageType:MessageType,
                        to participants:Participants = .all) async throws {
    guard let messenger else { return }
    try await messenger.send(Data([messageType.rawValue]) + data, to:participants)
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
    let origin: String
    let description: String

    init(uniqueID: String, origin: String, description:String) {
      self.uniqueID = uniqueID
      self.origin = origin
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

      guard let id = readString(),
            let org = readString(),
            let desc = readString() else { return nil }

      self.uniqueID = id
      self.origin = org
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

      writeString(uniqueID)
      writeString(origin)
      writeString(description)

      return data
    }
  }

  @MainActor
  func handleInit(data: Data, from: Participant) {

    func splitAddressAndPort(_ input: String) -> (address: String, port: Int)? {
      guard let idx = input.lastIndex(of: ":") else { return nil }
      let address = String(input[..<idx])
      let portPart = String(input[input.index(after: idx)...])
      guard let port = Int(portPart) else { return nil }
      return (address, port)
    }

    guard let runtimeAppModel = runtimeAppModel else { return }
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

      if initMessage.origin.isEmpty {
        // TODO: handle local data that is not found on client
      } else {
        if let source = splitAddressAndPort(initMessage.origin) {
          let dataset = RuntimeAppModel.DatasetEntry(identifier: initMessage.uniqueID,
                                              description: initMessage.description,
                                              source:.remote(address: source.address, port: source.port),
                                              uniqueId: initMessage.uniqueID)
          runtimeAppModel.startImmersiveSpace(dataset: dataset,
                                       asGroupSessionHost:false)
        } else {
          // TODO: handle invalid source
        }
      }
    }
  }

  func handleUpdate(data: Data, from: Participant) {
    do {
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
