import Foundation
import Security

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
    if let password = try? KeychainSecretStore.string(account: account) {
      return password
    }

    let legacyPassword = UserDefaults.standard.string(forKey: legacyDefaultsKey) ?? ""
    guard !legacyPassword.isEmpty else {
      return ""
    }

    try? save(legacyPassword)
    return legacyPassword
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
