import CryptoKit
import Foundation

/// One opt-in local conversation. The encryption key is not backed up or shared.
struct VoiceAgentConversationStore {
  typealias History = VoiceAgentCommandHistory<VoiceAgentContext?>
  private struct Archive: Codable {
    let version: Int
    let owner: UUID
    let history: History
  }

  let file: URL
  private let keyAccount: String
  private static let maximumBytes = 3 * 1024 * 1024

  init(file: URL = URL.applicationSupportDirectory.appending(path: "BorgVR/AssistantConversation/conversation.sealed"),
       keyAccount: String = "voice-agent-conversation-key") {
    self.file = file
    self.keyAccount = keyAccount
  }

  func load(owner: UUID) throws -> History? {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      return nil
    }
    defer { try? handle.close() }
    let sealed = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
    guard sealed.count <= Self.maximumBytes, let key = try encryptionKey(create: false) else {
      throw VoiceAgentError.protocolViolation
    }
    let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    let archive = try JSONDecoder().decode(Archive.self, from: plaintext)
    guard archive.version == 1 else { throw VoiceAgentError.protocolViolation }
    return archive.owner == owner ? archive.history : nil
  }

  func save(_ history: History, owner: UUID) throws {
    guard !history.isEmpty else { return }
    let data = try JSONEncoder().encode(Archive(version: 1, owner: owner, history: history))
    guard let key = try encryptionKey(create: true),
          let sealed = try AES.GCM.seal(data, using: key).combined,
          sealed.count <= Self.maximumBytes else { throw VoiceAgentError.protocolViolation }
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    var excluded = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
    try sealed.write(to: file, options: .atomic)
  }

  func remove() throws {
    do { try FileManager.default.removeItem(at: file) }
    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    // A dormant key does not retain conversation data, but rotate it with the archive.
    try KeychainSecretStore.delete(account: keyAccount)
  }

  private func encryptionKey(create: Bool) throws -> SymmetricKey? {
    if let saved = try KeychainSecretStore.string(account: keyAccount) {
      guard let data = Data(base64Encoded: saved), data.count == 32 else { throw VoiceAgentError.protocolViolation }
      return SymmetricKey(data: data)
    }
    guard create else { return nil }
    let key = SymmetricKey(size: .bits256)
    let raw = key.withUnsafeBytes { Data($0).base64EncodedString() }
    try KeychainSecretStore.setString(raw, account: keyAccount)
    return key
  }
}
