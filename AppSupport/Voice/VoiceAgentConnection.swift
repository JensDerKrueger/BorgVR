import Foundation
import Combine
import Security
import CryptoKit

func voiceAgentText(_ key: String) -> String {
  NSLocalizedString(key, tableName: "VoiceAgent", comment: "")
}

struct VoiceAgentConnectionIdentity: Equatable {
  let provider: VoiceAgentModelProvider
  let model: String
  let address: String
  let revision: UUID
  let enabled: Bool
  let images: Bool
  let workMinutes: Int
}

@MainActor
final class VoiceAgentSettings: ObservableObject {
  static let workMinutesRange = 5...180
  static let defaultWorkMinutes = 60

  private let defaults: UserDefaults
  private let tokenAccount: String
  @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "voiceAgent.enabled") } }
  @Published var provider: VoiceAgentModelProvider {
    didSet {
      defaults.set(provider.rawValue, forKey: "assistant.provider")
      if provider != oldValue { changeArchiveOwner(); refreshTokenState() }
    }
  }
  @Published var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "assistant.openAIModel") } }
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
  @Published var sharesOpenAIImages: Bool { didSet { defaults.set(sharesOpenAIImages, forKey: "assistant.openAIImages") } }
  var sharesProviderImages: Bool { provider == .openAI ? sharesOpenAIImages : sharesImages }
  @Published var savesConversation: Bool { didSet { defaults.set(savesConversation, forKey: "voiceAgent.saveConversation") } }
  @Published var confirmsVolumeEdits: Bool { didSet { defaults.set(confirmsVolumeEdits, forKey: "voiceAgent.confirmVolumeEdits") } }
  @Published var onDeviceOnly: Bool { didSet { defaults.set(onDeviceOnly, forKey: "voiceAgent.onDeviceOnly") } }
  @Published var workMinutes: Int {
    didSet {
      let value = Self.normalizedWorkMinutes(workMinutes)
      if workMinutes != value { workMinutes = value }
      defaults.set(value, forKey: "voiceAgent.workMinutes")
    }
  }
  @Published private(set) var certificate: Data
  @Published private(set) var customKnowledge: Data?
  @Published private(set) var hasToken: Bool
  @Published private(set) var revision = UUID()
  private(set) var archiveOwnerID: UUID

  var identity: VoiceAgentConnectionIdentity {
    .init(provider: provider, model: provider == .openAI ? openAIModel : "", address: address, revision: revision,
          enabled: enabled, images: sharesProviderImages, workMinutes: workMinutes)
  }

  init(defaults: UserDefaults = .standard, tokenAccount: String = "assistant-vllm-token") {
    self.defaults = defaults
    self.tokenAccount = tokenAccount
    enabled = defaults.bool(forKey: "voiceAgent.enabled")
    let initialProvider = defaults.string(forKey: "assistant.provider").flatMap(VoiceAgentModelProvider.init(rawValue:)) ?? .vllm
    provider = initialProvider
    openAIModel = defaults.string(forKey: "assistant.openAIModel") ?? "gpt-6.2-sol"
    address = defaults.string(forKey: "voiceAgent.address") ?? ""
    speaks = defaults.object(forKey: "voiceAgent.speaks") as? Bool ?? true
    speechRateMultiplier = VoiceAgentSpeechRate.normalized(
      defaults.object(forKey: "voiceAgent.speechRateMultiplier") as? Double ?? VoiceAgentSpeechRate.defaultMultiplier)
    sharesImages = defaults.object(forKey: "voiceAgent.images") as? Bool ?? true
    sharesOpenAIImages = defaults.bool(forKey: "assistant.openAIImages")
    savesConversation = defaults.bool(forKey: "voiceAgent.saveConversation")
    confirmsVolumeEdits = defaults.object(forKey: "voiceAgent.confirmVolumeEdits") as? Bool ?? true
    archiveOwnerID = defaults.string(forKey: "voiceAgent.archiveOwner").flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(archiveOwnerID.uuidString, forKey: "voiceAgent.archiveOwner")
    onDeviceOnly = defaults.object(forKey: "voiceAgent.onDeviceOnly") as? Bool ?? true
    workMinutes = Self.normalizedWorkMinutes(defaults.object(forKey: "voiceAgent.workMinutes") as? Int ?? Self.defaultWorkMinutes)
    customKnowledge = defaults.data(forKey: "assistant.knowledgePack").flatMap {
      (try? AssistantKnowledge.load($0)) == nil ? nil : $0
    }
    certificate = defaults.data(forKey: "voiceAgent.certificate") ?? Data()
    let account = initialProvider == .openAI ? tokenAccount + "-openai" : tokenAccount
    hasToken = ((try? KeychainSecretStore.string(account: account)) ?? "").isEmpty == false
  }

  private static func normalizedWorkMinutes(_ value: Int) -> Int {
    min(max(value, workMinutesRange.lowerBound), workMinutesRange.upperBound)
  }

  func token() throws -> String {
    guard let value = try KeychainSecretStore.string(account: activeTokenAccount) else {
      throw VoiceAgentError.configuration
    }
    try VoiceAgentEndpoint.validateToken(value)
    return value
  }

  private var activeTokenAccount: String { provider == .openAI ? tokenAccount + "-openai" : tokenAccount }

  private func refreshTokenState() {
    hasToken = ((try? KeychainSecretStore.string(account: activeTokenAccount)) ?? "").isEmpty == false
  }

  func selectKnowledge(_ data: Data?) throws {
    if let data { _ = try AssistantKnowledge.load(data) }
    customKnowledge = data
    defaults.set(data, forKey: "assistant.knowledgePack")
  }

  func knowledge() throws -> AssistantKnowledge {
    if let customKnowledge { return try AssistantKnowledge.load(customKnowledge) }
    guard let url = Bundle.main.url(forResource: "assistant-knowledge", withExtension: "json") else {
      throw VoiceAgentError.configuration
    }
    return try AssistantKnowledge.load(Data(contentsOf: url))
  }

  func setToken(_ value: String) throws {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty {
      try KeychainSecretStore.delete(account: activeTokenAccount)
    } else {
      try VoiceAgentEndpoint.validateToken(token)
      try KeychainSecretStore.setString(token, account: activeTokenAccount)
    }
    hasToken = !token.isEmpty
    revision = UUID()
    changeArchiveOwner()
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
    configuration.timeoutIntervalForRequest = 180
    configuration.timeoutIntervalForResource = resourceTimeout
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }
}
