import Foundation
import Security

protocol ServerCredentialVault: AnyObject {
  func reference(for secret: String) throws -> UUID
  func secret(for reference: UUID) throws -> String
}

extension CodingUserInfoKey {
  static let serverCredentialVault = CodingUserInfoKey(rawValue: "serverCredentialVault")!
}

final class KeychainServerCredentialVault: ServerCredentialVault {
  static let shared = KeychainServerCredentialVault()
  private let lock = NSLock()
  private var references: [String: UUID] = [:]
  func reference(for secret: String) throws -> UUID {
    try lock.withLock {
      if let id = references[secret] { return id }
      let id = UUID()
      try KeychainSecretStore.setString(secret, account: "server-credential.\(id.uuidString)")
      references[secret] = id
      return id
    }
  }
  func secret(for reference: UUID) throws -> String {
    guard
      let secret = try KeychainSecretStore.string(
        account: "server-credential.\(reference.uuidString)")
    else {
      throw KeychainSecretError.invalidData
    }
    lock.withLock { references[secret] = reference }
    return secret
  }
}

struct StoredServerCredential: Codable, Equatable, Sendable {
  var value: String
  init(_ value: String = "") { self.value = value }
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let vault =
      decoder.userInfo[.serverCredentialVault] as? ServerCredentialVault
      ?? KeychainServerCredentialVault.shared
    if container.decodeNil() {
      value = ""
    } else {
      value = try vault.secret(for: container.decode(UUID.self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    if value.isEmpty { try container.encodeNil(); return }
    let vault =
      encoder.userInfo[.serverCredentialVault] as? ServerCredentialVault
      ?? KeychainServerCredentialVault.shared
    try container.encode(vault.reference(for: value))
  }
}

struct StoredDatasetOrigin: Codable {
  let address: String
  let port: Int
  let credential: StoredServerCredential
  init(_ origin: DatasetOrigin) {
    address = origin.address; port = origin.port; credential = .init(origin.password)
  }
  var origin: DatasetOrigin { .init(address: address, port: port, password: credential.value) }
}

struct StoredServer: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var address: String
  var port: Int
  private var credential: StoredServerCredential
  var password: String {
    get { credential.value }
    set { credential.value = newValue }
  }
  var shareViaSharePlay: Bool
  init(
    id: UUID = UUID(), address: String, port: Int, password: String = "",
    shareViaSharePlay: Bool = false
  ) {
    self.id = id; self.address = address; self.port = port
    credential = .init(password); self.shareViaSharePlay = shareViaSharePlay
  }
}

enum DatasetServerPasswordStore {
  private static let account = "dataset-server-password"
  static func load() -> String {
    UserDefaults.standard.removeObject(forKey: "serverPassword")
    return (try? KeychainSecretStore.string(account: account)) ?? ""
  }
  static func save(_ password: String) -> String? {
    do {
      if password.isEmpty {
        try KeychainSecretStore.delete(account: account)
      } else {
        try KeychainSecretStore.setString(password, account: account)
      }
      return nil
    } catch { return error.localizedDescription }
  }
}

enum KeychainSecretStore {
  static func string(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainSecretError.unexpectedStatus(status)
    }
    guard let data = item as? Data else {
      throw KeychainSecretError.invalidData
    }
    return String(data: data, encoding: .utf8)
  }

  static func setString(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    var query = baseQuery(account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainSecretError.unexpectedStatus(updateStatus)
    }

    query[kSecValueData as String] = data
    let addStatus = SecItemAdd(query as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainSecretError.unexpectedStatus(addStatus)
    }
  }

  static func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainSecretError.unexpectedStatus(status)
    }
  }

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
  }

  private static var service: String {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "de.uni-due.BorgVR"
    return "\(bundleIdentifier).keychain"
  }
}

enum WebServerCertificatePasswordStore {
  private static let account = "webServerCertificatePassword"
  private static let legacyDefaultsKey = "webServerCertificatePassword"

  static func load() -> String {
    UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    return (try? KeychainSecretStore.string(account: account)) ?? ""
  }

  static func save(_ password: String) throws {
    if password.isEmpty {
      try KeychainSecretStore.delete(account: account)
    } else {
      try KeychainSecretStore.setString(password, account: account)
    }
    UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
  }

  static func delete() {
    try? KeychainSecretStore.delete(account: account)
    UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
  }
}

enum MCPServerCertificatePasswordStore {
  private static let account = "mcpServerCertificatePassword"

  static func load() -> String {
    (try? KeychainSecretStore.string(account: account)) ?? ""
  }

  static func save(_ password: String) throws {
    if password.isEmpty {
      try KeychainSecretStore.delete(account: account)
    } else {
      try KeychainSecretStore.setString(password, account: account)
    }
  }

  static func delete() {
    try? KeychainSecretStore.delete(account: account)
  }
}

private enum KeychainSecretError: LocalizedError {
  case invalidData
  case unexpectedStatus(OSStatus)

  var errorDescription: String? {
    switch self {
      case .invalidData:
        return "Keychain item did not contain UTF-8 data."
      case .unexpectedStatus(let status):
        let message = SecCopyErrorMessageString(status, nil) as String?
        return message ?? "Keychain operation failed with OSStatus \(status)."
    }
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
