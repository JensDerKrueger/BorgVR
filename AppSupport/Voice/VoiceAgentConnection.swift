import Foundation
import Combine
import Security
import CryptoKit

func voiceAgentText(_ key: String) -> String {
  NSLocalizedString(key, tableName: "VoiceAgent", comment: "")
}

struct VoiceAgentConnectionIdentity: Equatable {
  let address: String
  let revision: UUID
  let enabled: Bool
  let images: Bool
  let workMinutes: Int
  let maximumCalls: Int
}

struct VoiceAgentRule: Codable, Identifiable, Equatable {
  let id: UUID
  let text: String
}

@MainActor
final class VoiceAgentSettings: ObservableObject {
  private let defaults: UserDefaults
  private let tokenAccount: String
  @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "voiceAgent.enabled") } }
  @Published var address: String {
    didSet {
      defaults.set(address, forKey: "voiceAgent.address")
      if address != oldValue { changeArchiveOwner() }
    }
  }
  @Published var speaks: Bool { didSet { defaults.set(speaks, forKey: "voiceAgent.speaks") } }
  @Published var speechRateMultiplier: Double {
    didSet {
      let value = VoiceAgentSpeechRate.normalized(speechRateMultiplier)
      if speechRateMultiplier != value { speechRateMultiplier = value }
      defaults.set(value, forKey: "voiceAgent.speechRateMultiplier")
    }
  }
  @Published var sharesImages: Bool { didSet { defaults.set(sharesImages, forKey: "voiceAgent.images") } }
  @Published var savesConversation: Bool { didSet { defaults.set(savesConversation, forKey: "voiceAgent.saveConversation") } }
  @Published var confirmsVolumeEdits: Bool { didSet { defaults.set(confirmsVolumeEdits, forKey: "voiceAgent.confirmVolumeEdits") } }
  @Published var onDeviceOnly: Bool { didSet { defaults.set(onDeviceOnly, forKey: "voiceAgent.onDeviceOnly") } }
  @Published var workMinutes: Int {
    didSet {
      let value = min(max(workMinutes, 1), 120)
      if workMinutes != value { workMinutes = value }
      defaults.set(value, forKey: "voiceAgent.workMinutes")
    }
  }
  @Published var maximumCalls: Int {
    didSet {
      let value = min(max(maximumCalls, 24), 1024)
      if maximumCalls != value { maximumCalls = value }
      defaults.set(value, forKey: "voiceAgent.maximumCalls")
    }
  }
  @Published private(set) var certificate: Data
  @Published private(set) var knowledgeRules: [VoiceAgentRule]
  @Published private(set) var hasToken: Bool
  @Published private(set) var revision = UUID()
  private(set) var archiveOwnerID: UUID

  var identity: VoiceAgentConnectionIdentity {
    .init(address: address, revision: revision, enabled: enabled, images: sharesImages,
          workMinutes: workMinutes, maximumCalls: maximumCalls)
  }

  init(defaults: UserDefaults = .standard, tokenAccount: String = "voice-agent-token") {
    self.defaults = defaults
    self.tokenAccount = tokenAccount
    enabled = defaults.bool(forKey: "voiceAgent.enabled")
    address = defaults.string(forKey: "voiceAgent.address") ?? "https://ai1:8766"
    speaks = defaults.object(forKey: "voiceAgent.speaks") as? Bool ?? true
    speechRateMultiplier = VoiceAgentSpeechRate.normalized(
      defaults.object(forKey: "voiceAgent.speechRateMultiplier") as? Double ?? VoiceAgentSpeechRate.defaultMultiplier)
    sharesImages = defaults.object(forKey: "voiceAgent.images") as? Bool ?? true
    savesConversation = defaults.bool(forKey: "voiceAgent.saveConversation")
    confirmsVolumeEdits = defaults.object(forKey: "voiceAgent.confirmVolumeEdits") as? Bool ?? true
    archiveOwnerID = defaults.string(forKey: "voiceAgent.archiveOwner").flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(archiveOwnerID.uuidString, forKey: "voiceAgent.archiveOwner")
    onDeviceOnly = defaults.object(forKey: "voiceAgent.onDeviceOnly") as? Bool ?? true
    workMinutes = min(max(defaults.object(forKey: "voiceAgent.workMinutes") as? Int ?? 30, 1), 120)
    maximumCalls = min(max(defaults.object(forKey: "voiceAgent.maximumCalls") as? Int ?? 256, 24), 1024)
    if let data = defaults.data(forKey: "voiceAgent.knowledge"), data.count <= 64 * 1024,
       let rules = try? JSONDecoder().decode([VoiceAgentRule].self, from: data) {
      knowledgeRules = Array(rules.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 500 }.prefix(16))
    } else { knowledgeRules = [] }
    certificate = defaults.data(forKey: "voiceAgent.certificate") ?? Data()
    hasToken = ((try? KeychainSecretStore.string(account: tokenAccount)) ?? "").isEmpty == false
  }

  func token() throws -> String {
    guard let value = try KeychainSecretStore.string(account: tokenAccount) else {
      throw VoiceAgentError.configuration
    }
    try VoiceAgentEndpoint.validateToken(value)
    return value
  }

  func setToken(_ value: String) throws {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
      try KeychainSecretStore.delete(account: tokenAccount)
    } else {
      try VoiceAgentEndpoint.validateToken(token)
      try KeychainSecretStore.setString(token, account: tokenAccount)
    }
    hasToken = !token.isEmpty
    revision = UUID()
    changeArchiveOwner()
  }

  func rememberRule(_ text: String) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 500 else { throw VoiceAgentError.protocolViolation }
    guard !knowledgeRules.contains(where: { $0.text == trimmed }) else { return }
    guard knowledgeRules.count < 16 else { throw VoiceAgentError.configuration }
    knowledgeRules.append(.init(id: UUID(), text: trimmed))
    defaults.set(try JSONEncoder().encode(knowledgeRules), forKey: "voiceAgent.knowledge")
  }

  func forgetRule(id: UUID) {
    knowledgeRules.removeAll { $0.id == id }
    defaults.set(try? JSONEncoder().encode(knowledgeRules), forKey: "voiceAgent.knowledge")
  }

  func importCertificate(_ data: Data) throws {
    let der = try VoiceAgentTLS.certificateData(data)
    certificate = der
    defaults.set(der, forKey: "voiceAgent.certificate")
    revision = UUID()
    changeArchiveOwner()
  }

  func removeCertificate() {
    certificate = Data()
    defaults.removeObject(forKey: "voiceAgent.certificate")
    revision = UUID()
    changeArchiveOwner()
  }

  private func changeArchiveOwner() {
    archiveOwnerID = UUID()
    defaults.set(archiveOwnerID.uuidString, forKey: "voiceAgent.archiveOwner")
  }

  var fingerprint: String {
    guard !certificate.isEmpty else { return "" }
    return SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined(separator: ":")
  }
}

/// A private session: no cookies, credential persistence, redirects or invalid-certificate bypass.
final class VoiceAgentTLS: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let endpoint: VoiceAgentEndpoint
  let anchor: Data

  init(endpoint: VoiceAgentEndpoint, anchor: Data) {
    self.endpoint = endpoint
    self.anchor = anchor
  }

  static func certificateData(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= 64 * 1024 else { throw VoiceAgentError.configuration }
    var der = data
    if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
      guard text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 2,
            let start = text.range(of: "-----BEGIN CERTIFICATE-----"),
            let end = text.range(of: "-----END CERTIFICATE-----"), start.upperBound < end.lowerBound,
            let decoded = Data(base64Encoded: text[start.upperBound..<end.lowerBound]
              .components(separatedBy: .whitespacesAndNewlines).joined())
      else { throw VoiceAgentError.configuration }
      der = decoded
    }
    guard SecCertificateCreateWithData(nil, der as CFData) != nil else { throw VoiceAgentError.configuration }
    return der
  }

  func accepts(_ trust: SecTrust, host: String) -> Bool {
    guard host.caseInsensitiveCompare(endpoint.host) == .orderedSame else { return false }
    guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, endpoint.host as CFString)) == errSecSuccess
    else { return false }
    if !anchor.isEmpty {
      guard let certificate = SecCertificateCreateWithData(nil, anchor as CFData),
            SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
      SecTrustSetNetworkFetchAllowed(trust, false)
    }
    return SecTrustEvaluateWithError(trust, nil)
  }

  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust,
          accepts(trust, host: challenge.protectionSpace.host) else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    urlSession(session, didReceive: challenge, completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func session(resourceTimeout: TimeInterval = 300) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = resourceTimeout
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }
}
