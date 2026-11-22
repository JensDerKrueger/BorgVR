import CryptoKit
import Foundation

/// Observer state stays scoped to the configured credentials. Migration is explicit.
@MainActor
struct VoiceAgentLearnerStore {
  struct Entry: Identifiable {
    let id: String
    let data: [String: Any]
    var goal: String { data["goal"] as? String ?? id }
    var situation: String { data["situation"] as? String ?? "" }
    var guidance: String? { (data["guidance"] as? [String: Any])?["text"] as? String }
    var program: String? {
      guard let payload = data["procedure"] as? [String: Any],
            let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      else { return nil }
      return String(decoding: bytes, as: UTF8.self)
    }
  }

  enum Part: String { case guidance, procedure }
  enum Failure: LocalizedError {
    case profileMissing, invalid, conflict
    var errorDescription: String? {
      switch self {
        case .profileMissing: return voiceAgentText("Set an observer token for this server first.")
        case .invalid: return voiceAgentText("The learning checkpoint is invalid or too large.")
        case .conflict: return voiceAgentText("The destination learner already has state. Nothing was overwritten.")
      }
    }
  }

  static let maximumBytes = 16 * 1024 * 1024
  var directory = URL.applicationSupportDirectory.appending(path: "BorgVR/Learner", directoryHint: .isDirectory)

  nonisolated static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private struct Identity: Equatable {
    let endpoint: VoiceAgentEndpoint
    let certificate: Data
    let bearer: String
    let observer: String

    var fileKey: String {
      VoiceAgentLearnerStore.digest(Data((endpoint.origin.absoluteString + "\n" + bearer + "\n" + observer + "\n").utf8) + certificate)
    }
  }

  private func identity(_ settings: VoiceAgentSettings) throws -> Identity {
    guard let observer = settings.observerToken() else { throw Failure.profileMissing }
    return .init(endpoint: try VoiceAgentEndpoint(settings.address), certificate: settings.certificate,
                 bearer: try settings.token(), observer: observer)
  }

  private func file(_ identity: Identity, _ suffix: String) -> URL {
    directory.appending(path: identity.fileKey + suffix)
  }

  private func read(_ url: URL, limit: Int) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw Failure.invalid }
    return data
  }

  private func write(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func decode(_ data: Data) throws -> [String: Any] {
    guard data.count <= Self.maximumBytes,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["kind"] as? String == "learner_checkpoint", value["version"] as? Int == 1,
          let lineage = value["lineage_id"] as? String, !lineage.isEmpty,
          let revision = value["revision"] as? Int, revision > 0,
          let entries = value["entries"] as? [[String: Any]], entries.count <= 64,
          let hypotheses = value["hypotheses"] as? [[String: Any]], hypotheses.count <= 64,
          let evidence = value["evidence"] as? [[String: Any]], evidence.count <= 256
    else { throw Failure.invalid }
    return value
  }

  func cached(_ settings: VoiceAgentSettings) -> [String: Any]? {
    guard let data = try? exportCheckpoint(settings) else { return nil }
    return try? decode(data)
  }

  func exportCheckpoint(_ settings: VoiceAgentSettings) throws -> Data {
    try read(file(identity(settings), ".checkpoint.json"), limit: Self.maximumBytes)
  }

  func entries(_ settings: VoiceAgentSettings) -> [Entry] {
    entries(in: cached(settings))
  }

  func entries(in checkpoint: [String: Any]?) -> [Entry] {
    (checkpoint?["entries"] as? [[String: Any]] ?? []).compactMap { data in
      guard let id = data["id"] as? String, !id.isEmpty else { return nil }
      return .init(id: id, data: data)
    }
  }

  private func approvalKey(_ entry: Entry, part: Part) -> String? {
    guard var body = entry.data[part.rawValue] as? [String: Any] else { return nil }
    body.removeValue(forKey: "review")
    let metadata = entry.data.filter { ["id", "source", "situation", "goal", "contexts", "keywords"].contains($0.key) }
    guard let bytes = try? JSONSerialization.data(withJSONObject: ["entry": metadata, "part": part.rawValue, "body": body],
                                                   options: [.sortedKeys]) else { return nil }
    return Self.digest(bytes)
  }

  private func approvals(_ owner: Identity) -> Set<String> {
    guard let data = try? read(file(owner, ".approvals.json"), limit: 64 * 1024),
          let keys = try? JSONDecoder().decode(Set<String>.self, from: data) else { return [] }
    return keys
  }

  func approval(_ entry: Entry, _ part: Part, settings: VoiceAgentSettings) -> Bool {
    guard let owner = try? identity(settings), let key = approvalKey(entry, part: part) else { return false }
    return approvals(owner).contains(key)
  }

  func setApproval(_ approved: Bool, entry: Entry, part: Part, settings: VoiceAgentSettings) throws {
    let owner = try identity(settings)
    guard let key = approvalKey(entry, part: part) else { throw Failure.invalid }
    var keys = approvals(owner)
    if approved { keys.insert(key) } else { keys.remove(key) }
    let valid = entries(settings).flatMap { candidate in [Part.guidance, .procedure].compactMap { approvalKey(candidate, part: $0) } }
    try write(try JSONEncoder().encode(keys.intersection(valid)), to: file(owner, ".approvals.json"))
    settings.refreshKnowledge()
  }

  func offer(_ settings: VoiceAgentSettings, bundled: [String: Any]?) -> [String: Any]? {
    var rows = bundled?["entries"] as? [[String: Any]] ?? []
    var ids = Set(rows.compactMap { $0["id"] as? String })
    if let owner = try? identity(settings) {
      let approved = approvals(owner)
      for entry in entries(settings) where rows.count < 64 && !ids.contains(entry.id) {
        var copy = entry.data
        var included = false
        for part in [Part.guidance, .procedure] {
          guard let key = approvalKey(entry, part: part), approved.contains(key),
                var body = copy[part.rawValue] as? [String: Any] else {
            copy.removeValue(forKey: part.rawValue)
            continue
          }
          body["review"] = "approved"
          copy[part.rawValue] = body
          included = true
        }
        if included {
          let trial: [String: Any] = ["kind": "knowledge_bundle", "version": 1, "entries": rows + [copy]]
          guard (try? VoiceAgentPolicy.encoded(trial, limit: 128 * 1024)) != nil else { continue }
          ids.insert(entry.id)
          rows.append(copy)
        }
      }
    }
    return rows.isEmpty ? nil : ["kind": "knowledge_bundle", "version": 1, "entries": rows]
  }

  func fetch(_ settings: VoiceAgentSettings) async throws -> Data {
    let owner = try identity(settings)
    let data = try await request(owner)
    let next = try decode(data)
    guard try identity(settings) == owner else { throw VoiceAgentError.contextChanged }
    if let old = cached(settings), old["lineage_id"] as? String == next["lineage_id"] as? String,
       (old["revision"] as? Int ?? 0) > (next["revision"] as? Int ?? 0) { throw Failure.conflict }
    try write(data, to: file(owner, ".checkpoint.json"))
    settings.refreshKnowledge()
    return data
  }

  func importCheckpoint(_ url: URL, settings: VoiceAgentSettings) async throws {
    let owner = try identity(settings)
    let granted = url.startAccessingSecurityScopedResource()
    defer { if granted { url.stopAccessingSecurityScopedResource() } }
    let data = try read(url, limit: Self.maximumBytes)
    _ = try decode(data)
    _ = try await request(owner, body: data)
    guard try identity(settings) == owner else { throw VoiceAgentError.contextChanged }
    _ = try await fetch(settings)
  }

  private func request(_ owner: Identity, body: Data? = nil) async throws -> Data {
    let endpoint = owner.endpoint.origin.appending(path: "v1/observer/checkpoint")
    var request = URLRequest(url: body == nil ? endpoint : endpoint.appending(path: "import"))
    request.setValue("Bearer " + owner.bearer, forHTTPHeaderField: "Authorization")
    request.setValue(owner.observer, forHTTPHeaderField: "X-BorgVR-Observer")
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let session = VoiceAgentTLS(endpoint: owner.endpoint, anchor: owner.certificate).session(resourceTimeout: 60)
    defer { session.invalidateAndCancel() }
    let (stream, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw VoiceAgentError.connection }
    if http.statusCode == 409 { throw Failure.conflict }
    guard http.statusCode == 200 else { throw VoiceAgentError.connection }
    var data = Data()
    for try await byte in stream {
      guard data.count < Self.maximumBytes else { throw Failure.invalid }
      data.append(byte)
    }
    return data
  }
}
