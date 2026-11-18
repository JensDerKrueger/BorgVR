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
}

@MainActor
final class VoiceAgentSettings: ObservableObject {
  private let defaults: UserDefaults
  private let tokenAccount: String
  @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "voiceAgent.enabled") } }
  @Published var address: String { didSet { defaults.set(address, forKey: "voiceAgent.address") } }
  @Published var speaks: Bool { didSet { defaults.set(speaks, forKey: "voiceAgent.speaks") } }
  @Published var sharesImages: Bool { didSet { defaults.set(sharesImages, forKey: "voiceAgent.images") } }
  @Published var onDeviceOnly: Bool { didSet { defaults.set(onDeviceOnly, forKey: "voiceAgent.onDeviceOnly") } }
  @Published private(set) var certificate: Data
  @Published private(set) var hasToken: Bool
  @Published private(set) var revision = UUID()

  var identity: VoiceAgentConnectionIdentity {
    .init(address: address, revision: revision, enabled: enabled, images: sharesImages)
  }

  init(defaults: UserDefaults = .standard, tokenAccount: String = "voice-agent-token") {
    self.defaults = defaults
    self.tokenAccount = tokenAccount
    enabled = defaults.bool(forKey: "voiceAgent.enabled")
    address = defaults.string(forKey: "voiceAgent.address") ?? "https://ai1:8766"
    speaks = defaults.object(forKey: "voiceAgent.speaks") as? Bool ?? true
    sharesImages = defaults.object(forKey: "voiceAgent.images") as? Bool ?? true
    onDeviceOnly = defaults.object(forKey: "voiceAgent.onDeviceOnly") as? Bool ?? true
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
  }

  func importCertificate(_ data: Data) throws {
    let der = try VoiceAgentTLS.certificateData(data)
    certificate = der
    defaults.set(der, forKey: "voiceAgent.certificate")
    revision = UUID()
  }

  func removeCertificate() {
    certificate = Data()
    defaults.removeObject(forKey: "voiceAgent.certificate")
    revision = UUID()
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

  func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 300
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }
}
