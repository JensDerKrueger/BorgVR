import Foundation
import Combine
import Security

func voiceAgentText(_ key: String) -> String {
  NSLocalizedString(key, tableName: "VoiceAgent", comment: "")
}

struct VoiceAgentConnectionIdentity: Equatable {
  let profileID: UUID?
  let provider: VoiceAgentModelProvider
  let model: String
  let address: String
  let revision: UUID
  let enabled: Bool
  let images: Bool
  let workMinutes: Int
}

struct VoiceAgentProfile: Codable, Identifiable {
  var id = UUID()
  var provider: VoiceAgentModelProvider
  var name: String
  var address = ""
  var model = "gpt-6.2-sol"
  var sharesImages = false
  var certificate = Data()
  var certificateOrigin: String?
  var tokenOrigin: String?
  var usesLegacyCredential = false

  var title: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if provider == .openAI { return model.isEmpty ? "OpenAI" : model }
    return (try? VoiceAgentEndpoint(address))?.host ?? "vLLM"
  }

  var isConfigured: Bool {
    if provider == .vllm { return origin != nil }
    return VoiceAgentModelClient.isValidOpenAIModelID(model.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  var trustedCertificate: Data {
    guard provider == .vllm, let origin, origin == certificateOrigin else { return Data() }
    return certificate
  }

  var origin: String? {
    if provider == .openAI { return "https://api.openai.com" }
    return (try? VoiceAgentEndpoint(address))?.origin.absoluteString
  }
}

@MainActor
final class VoiceAgentSettings: ObservableObject {
  static let workMinutesRange = 5...180
  static let defaultWorkMinutes = 60
  static let maximumProfiles = 32

  private struct ProfileStore: Codable {
    var profiles: [VoiceAgentProfile]
    var selected: UUID?
  }

  private let defaults: UserDefaults
  private let tokenAccount: String
  @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "voiceAgent.enabled") } }
  @Published private(set) var profiles: [VoiceAgentProfile]
  @Published private(set) var selectedProfileID: UUID?
  @Published var speaks: Bool { didSet { defaults.set(speaks, forKey: "voiceAgent.speaks") } }
  @Published var responseLength: VoiceAgentResponseLength {
    didSet { defaults.set(responseLength.rawValue, forKey: "voiceAgent.responseLength") }
  }
  @Published var speechRateMultiplier: Double {
    didSet {
      let value = VoiceAgentSpeechRate.normalized(speechRateMultiplier)
      if speechRateMultiplier != value { speechRateMultiplier = value }
      defaults.set(value, forKey: "voiceAgent.speechRateMultiplier")
    }
  }
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
  @Published private(set) var customKnowledge: Data?
  @Published private(set) var hasToken: Bool
  @Published private(set) var revision = UUID()
  private(set) var archiveOwnerID: UUID

  var selectedProfile: VoiceAgentProfile? { profiles.first { $0.id == selectedProfileID } }
  var sharesProviderImages: Bool { selectedProfile?.sharesImages ?? false }

  var identity: VoiceAgentConnectionIdentity {
    .init(profileID: selectedProfileID, provider: selectedProfile?.provider ?? .vllm,
          model: selectedProfile?.model ?? "", address: selectedProfile?.address ?? "", revision: revision,
          enabled: enabled, images: sharesProviderImages, workMinutes: workMinutes)
  }

  init(defaults: UserDefaults = .standard, tokenAccount: String = "assistant-vllm-token") {
    self.defaults = defaults
    self.tokenAccount = tokenAccount
    enabled = defaults.bool(forKey: "voiceAgent.enabled")
    let stored = Self.loadProfiles(defaults, tokenAccount: tokenAccount)
    profiles = stored.profiles
    selectedProfileID = stored.selected
    speaks = defaults.object(forKey: "voiceAgent.speaks") as? Bool ?? true
    responseLength = defaults.string(forKey: "voiceAgent.responseLength").flatMap(VoiceAgentResponseLength.init(rawValue:)) ?? .standard
    speechRateMultiplier = VoiceAgentSpeechRate.normalized(
      defaults.object(forKey: "voiceAgent.speechRateMultiplier") as? Double ?? VoiceAgentSpeechRate.defaultMultiplier)
    savesConversation = defaults.bool(forKey: "voiceAgent.saveConversation")
    confirmsVolumeEdits = defaults.object(forKey: "voiceAgent.confirmVolumeEdits") as? Bool ?? true
    archiveOwnerID = defaults.string(forKey: "voiceAgent.archiveOwner").flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(archiveOwnerID.uuidString, forKey: "voiceAgent.archiveOwner")
    onDeviceOnly = defaults.object(forKey: "voiceAgent.onDeviceOnly") as? Bool ?? true
    workMinutes = Self.normalizedWorkMinutes(defaults.object(forKey: "voiceAgent.workMinutes") as? Int ?? Self.defaultWorkMinutes)
    customKnowledge = defaults.data(forKey: "assistant.knowledgePack").flatMap {
      (try? AssistantKnowledge.load($0)) == nil ? nil : $0
    }
    hasToken = false
    refreshTokenState()
    saveProfiles()
  }

  private static func loadProfiles(_ defaults: UserDefaults, tokenAccount: String) -> ProfileStore {
    if let data = defaults.data(forKey: "assistant.modelProfiles"), data.count <= 4 * 1024 * 1024,
       let store = try? JSONDecoder().decode(ProfileStore.self, from: data),
       store.profiles.count <= maximumProfiles,
       Set(store.profiles.map(\.id)).count == store.profiles.count,
       (store.profiles.isEmpty ? store.selected == nil : store.profiles.contains(where: { $0.id == store.selected })),
       Set(store.profiles.filter(\.usesLegacyCredential).map(\.provider)).count == store.profiles.filter(\.usesLegacyCredential).count {
      return store
    }
    // The two existing Keychain accounts remain attached to their migrated profiles only.
    var local = VoiceAgentProfile(provider: .vllm, name: "vLLM")
    local.address = defaults.string(forKey: "voiceAgent.address") ?? ""
    local.sharesImages = defaults.object(forKey: "voiceAgent.images") as? Bool ?? true
    local.certificate = defaults.data(forKey: "voiceAgent.certificate") ?? Data()
    local.certificateOrigin = local.origin
    local.tokenOrigin = local.origin
    local.usesLegacyCredential = !local.address.isEmpty || ((try? KeychainSecretStore.string(account: tokenAccount)) ?? "") != ""
    var cloud = VoiceAgentProfile(provider: .openAI, name: "OpenAI")
    cloud.model = defaults.string(forKey: "assistant.openAIModel") ?? cloud.model
    cloud.sharesImages = defaults.bool(forKey: "assistant.openAIImages")
    cloud.tokenOrigin = cloud.origin
    let cloudWasSelected = defaults.string(forKey: "assistant.provider") == VoiceAgentModelProvider.openAI.rawValue
    cloud.usesLegacyCredential = cloudWasSelected || defaults.object(forKey: "assistant.openAIModel") != nil ||
      ((try? KeychainSecretStore.string(account: tokenAccount + "-openai")) ?? "") != ""
    let profiles = [local, cloud].filter(\.usesLegacyCredential)
    return .init(profiles: profiles, selected: cloudWasSelected ? cloud.id : profiles.first?.id)
  }

  private func saveProfiles() {
    defaults.set(try? JSONEncoder().encode(ProfileStore(profiles: profiles, selected: selectedProfileID)),
                 forKey: "assistant.modelProfiles")
  }

  func selectProfile(_ id: UUID) {
    guard id != selectedProfileID, profiles.contains(where: { $0.id == id }) else { return }
    selectedProfileID = id
    changeArchiveOwner()
    refreshTokenState()
    saveProfiles()
  }

  func saveProfile(_ draft: VoiceAgentProfile, token newToken: String?) throws {
    var profile = draft
    profile.name = String(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    profile.address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard profile.isConfigured, let origin = profile.origin else { throw VoiceAgentError.configuration }
    let index = profiles.firstIndex { $0.id == profile.id }
    let previous = index.map { profiles[$0] }
    guard previous.map({ $0.provider == profile.provider }) ?? (profiles.count < Self.maximumProfiles) else {
      throw VoiceAgentError.configuration
    }
    profile.usesLegacyCredential = previous?.usesLegacyCredential ?? false
    profile.tokenOrigin = previous?.tokenOrigin
    if profile.certificateOrigin != origin || profile.provider != .vllm {
      profile.certificateOrigin = nil
      profile.certificate = Data()
    }
    let account = keychainAccount(for: profile)
    if let token = newToken?.trimmingCharacters(in: .whitespacesAndNewlines) {
      if token.isEmpty {
        try KeychainSecretStore.delete(account: account)
        profile.tokenOrigin = nil
      } else {
        try VoiceAgentEndpoint.validateToken(token)
        try KeychainSecretStore.setString(token, account: account)
        profile.tokenOrigin = origin
      }
    } else if profile.tokenOrigin != nil && profile.tokenOrigin != origin {
      try KeychainSecretStore.delete(account: account)
      profile.tokenOrigin = nil
    }
    if let index { profiles[index] = profile } else { profiles.append(profile) }
    if selectedProfileID == nil { selectedProfileID = profile.id }
    if selectedProfileID == profile.id {
      if previous?.origin != origin || previous?.model != profile.model || previous?.certificate != profile.certificate || newToken != nil {
        changeArchiveOwner()
        revision = UUID()
      }
      refreshTokenState()
    }
    saveProfiles()
  }

  func removeProfile(_ id: UUID) throws {
    guard let profile = profiles.first(where: { $0.id == id }) else { return }
    try KeychainSecretStore.delete(account: keychainAccount(for: profile))
    profiles.removeAll { $0.id == id }
    if selectedProfileID == id {
      selectedProfileID = profiles.first?.id
      changeArchiveOwner()
      refreshTokenState()
    }
    saveProfiles()
  }

  private static func normalizedWorkMinutes(_ value: Int) -> Int {
    min(max(value, workMinutesRange.lowerBound), workMinutesRange.upperBound)
  }

  private func keychainAccount(for profile: VoiceAgentProfile) -> String {
    if profile.usesLegacyCredential { return profile.provider == .openAI ? tokenAccount + "-openai" : tokenAccount }
    return tokenAccount + "-profile-" + profile.id.uuidString
  }

  private func storedToken(for draft: VoiceAgentProfile) throws -> String {
    guard let profile = profiles.first(where: { $0.id == draft.id && $0.provider == draft.provider }),
          let origin = draft.origin, profile.tokenOrigin == origin,
          let value = try KeychainSecretStore.string(account: keychainAccount(for: profile)) else {
      throw VoiceAgentError.configuration
    }
    try VoiceAgentEndpoint.validateToken(value)
    return value
  }

  func hasSavedToken(for draft: VoiceAgentProfile) -> Bool { (try? storedToken(for: draft)) != nil }

  private func refreshTokenState() { hasToken = selectedProfile.map { hasSavedToken(for: $0) } ?? false }

  func modelClient(for draft: VoiceAgentProfile? = nil, tokenOverride: String? = nil) throws -> VoiceAgentModelClient {
    guard let profile = draft ?? selectedProfile, profile.isConfigured else { throw VoiceAgentError.configuration }
    return try makeModelClient(for: profile, tokenOverride: tokenOverride)
  }

  func openAIModels(for draft: VoiceAgentProfile, tokenOverride: String?) async throws -> [String] {
    guard draft.provider == .openAI else { throw VoiceAgentError.configuration }
    let client = try makeModelClient(for: draft, tokenOverride: tokenOverride)
    return try await client.listOpenAIModels()
  }

  private func makeModelClient(for profile: VoiceAgentProfile, tokenOverride: String?) throws -> VoiceAgentModelClient {
    guard let origin = profile.origin else { throw VoiceAgentError.configuration }
    let endpoint = try VoiceAgentEndpoint(origin)
    let token = try tokenOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? storedToken(for: profile)
    try VoiceAgentEndpoint.validateToken(token)
    let tls = VoiceAgentTLS(endpoint: endpoint, anchor: profile.trustedCertificate)
    return VoiceAgentModelClient(endpoint: endpoint, token: token, session: tls.session(), provider: profile.provider,
      configuredModel: profile.provider == .openAI ? profile.model.trimmingCharacters(in: .whitespacesAndNewlines) : "")
  }

  func selectKnowledge(_ data: Data?) throws {
    if let data { _ = try AssistantKnowledge.load(data) }
    customKnowledge = data
    defaults.set(data, forKey: "assistant.knowledgePack")
  }

  func knowledge() throws -> AssistantKnowledge {
    if let customKnowledge {
      do { return try AssistantKnowledge.load(customKnowledge) }
      catch { throw AssistantRunFailure.knowledgeInvalid }
    }
    guard let url = Bundle.main.url(forResource: "assistant-knowledge", withExtension: "json") else {
      throw AssistantRunFailure.knowledgeMissing
    }
    do { return try AssistantKnowledge.load(Data(contentsOf: url)) }
    catch { throw AssistantRunFailure.knowledgeInvalid }
  }

  private func changeArchiveOwner() {
    archiveOwnerID = UUID()
    defaults.set(archiveOwnerID.uuidString, forKey: "voiceAgent.archiveOwner")
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
