import Combine
import CryptoKit
import Foundation

struct WorkflowDestination: Codable, Equatable {
  let origin: URL
  let certificateDigest: Data
  let profileID: UUID
  let corpusID: UUID

  func isSameProfile(as other: Self) -> Bool {
    origin == other.origin && certificateDigest == other.certificateDigest && profileID == other.profileID
  }
}

struct PendingWorkflowUpload: Codable {
  let destination: WorkflowDestination
  let episode: WorkflowDemonstration
}

struct WorkflowAnalysisReport: Decodable {
  enum Status: String, Decodable { case empty, queued, ready }
  struct Summary: Decodable {
    struct Pattern: Decodable {
      let goal: WorkflowDemonstrationGoal
      let openingSequence: [WorkflowDemonstrationAction]
      let support: Int
      let total: Int
      enum CodingKeys: String, CodingKey { case goal, support, total, openingSequence = "opening_sequence" }
    }
    let episodes: Int
    let patterns: [Pattern]
  }
  let status: Status
  let corpusID: UUID
  let report: Summary?
  enum CodingKeys: String, CodingKey { case status, report, corpusID = "corpus_id" }
}

struct WorkflowOutbox {
  static let maximumEntries = 64
  private static let maximumBytes = 512 * 1024
  let file: URL

  func load() throws -> [PendingWorkflowUpload] {
    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      return []
    }
    guard data.count <= Self.maximumBytes else { throw VoiceAgentError.protocolViolation }
    let items = try JSONDecoder().decode([PendingWorkflowUpload].self, from: data)
    guard items.count <= Self.maximumEntries else { throw VoiceAgentError.protocolViolation }
    return items
  }

  func enqueue(_ episode: WorkflowDemonstration, for destination: WorkflowDestination) throws {
    var items = try load()
    if let existing = items.first(where: { $0.episode.id == episode.id }) {
      guard existing.destination == destination else { throw VoiceAgentError.contextChanged }
      return
    }
    guard items.count < Self.maximumEntries else { throw WorkflowUploadError.full }
    items.append(.init(destination: destination, episode: episode))
    try save(items)
  }

  func remove(id: UUID, for destination: WorkflowDestination) throws {
    let items = try load()
    try save(items.filter { $0.episode.id != id || $0.destination != destination })
  }

  func pending(for destination: WorkflowDestination) throws -> [PendingWorkflowUpload] {
    try load().filter { $0.destination == destination }
  }

  func clear(for destination: WorkflowDestination) throws {
    try save(load().filter { !$0.destination.isSameProfile(as: destination) })
  }

  private func save(_ items: [PendingWorkflowUpload]) throws {
    let data = try JSONEncoder().encode(items)
    guard data.count <= Self.maximumBytes else { throw WorkflowUploadError.full }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
  }
}

enum WorkflowUploadError: LocalizedError {
  case notLinked, full, corpusChanged, analysisQueued

  var errorDescription: String? {
    switch self {
      case .notLinked: return voiceAgentText("Link a workflow profile for this server first.")
      case .full: return voiceAgentText("The demonstration queue is full.")
      case .corpusChanged: return voiceAgentText("The server collection changed. Queued demonstrations were not moved.")
      case .analysisQueued: return voiceAgentText("Analysis queued")
    }
  }
}

@MainActor
final class WorkflowUpload: ObservableObject {
  private struct Enrollment: Codable, Equatable {
    let destination: WorkflowDestination
    let token: String
  }

  private struct Identity: Decodable {
    let profileID: UUID
    let corpusID: UUID
    enum CodingKeys: String, CodingKey { case profileID = "profile_id", corpusID = "corpus_id" }
  }

  private struct Receipt: Decodable {
    let accepted: Bool
    let episodeID: UUID
    enum CodingKeys: String, CodingKey { case accepted, episodeID = "episode_id" }
  }

  private let keychainAccount: String
  private let outbox: WorkflowOutbox
  @Published private var enrollment: Enrollment?
  @Published private(set) var pendingCount = 0
  @Published private(set) var staleCount = 0
  @Published private(set) var busy = false
  @Published private(set) var errorText: String?
  @Published private(set) var analysis: WorkflowAnalysisReport?

  var profileChanges: AnyPublisher<WorkflowDestination?, Never> {
    $enrollment.map { $0?.destination }.removeDuplicates().eraseToAnyPublisher()
  }

  init(keychainAccount: String = "voice-agent-workflow-device", outbox: WorkflowOutbox? = nil) {
    self.keychainAccount = keychainAccount
    self.outbox = outbox ?? WorkflowOutbox(file: URL.applicationSupportDirectory
      .appending(path: "BorgVR/Workflow/pending.json"))
    if let raw = try? KeychainSecretStore.string(account: keychainAccount),
       let data = Data(base64Encoded: raw) {
      enrollment = try? JSONDecoder().decode(Enrollment.self, from: data)
    }
    updateCount()
  }

  func destination(for settings: VoiceAgentSettings) -> WorkflowDestination? {
    guard let saved = enrollment?.destination, let endpoint = try? VoiceAgentEndpoint(settings.address),
          endpoint.origin == saved.origin, Data(SHA256.hash(data: settings.certificate)) == saved.certificateDigest
    else { return nil }
    return saved
  }

  func link(_ rawToken: String, settings: VoiceAgentSettings) async {
    guard !busy else { return }
    busy = true
    errorText = nil
    defer { busy = false }
    do {
      let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
      guard token.hasPrefix("wv1_"), token.utf8.count == 68,
            token.utf8.dropFirst(4).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw VoiceAgentError.configuration }
      let endpoint = try VoiceAgentEndpoint(settings.address)
      let certificate = settings.certificate
      let data = try await request("profile", endpoint: endpoint, certificate: certificate, token: token)
      let identity = try JSONDecoder().decode(Identity.self, from: data)
      guard (try? VoiceAgentEndpoint(settings.address).origin) == endpoint.origin, settings.certificate == certificate
      else { throw VoiceAgentError.contextChanged }
      let destination = WorkflowDestination(origin: endpoint.origin, certificateDigest: Data(SHA256.hash(data: certificate)),
                                            profileID: identity.profileID, corpusID: identity.corpusID)
      let value = Enrollment(destination: destination, token: token)
      try KeychainSecretStore.setString(try JSONEncoder().encode(value).base64EncodedString(), account: keychainAccount)
      enrollment = value
      analysis = nil
      updateCount()
    } catch { show(error) }
  }

  func unlink() {
    guard !busy else { return }
    do {
      try KeychainSecretStore.delete(account: keychainAccount)
      enrollment = nil
      analysis = nil
      errorText = nil
      updateCount()
    } catch { show(error) }
  }

  func enqueue(_ episode: WorkflowDemonstration, capturedFor owner: WorkflowDestination,
               settings: VoiceAgentSettings) -> Bool {
    do {
      guard destination(for: settings) == owner else { throw WorkflowUploadError.notLinked }
      try outbox.enqueue(episode, for: owner)
      analysis = nil
      errorText = nil
      updateCount()
      return true
    } catch {
      show(error)
      return false
    }
  }

  func sync(settings: VoiceAgentSettings) async {
    guard !busy else { return }
    busy = true
    errorText = nil
    defer { updateCount(); busy = false }
    do {
      guard let saved = enrollment, destination(for: settings) == saved.destination
      else { throw WorkflowUploadError.notLinked }
      let endpoint = try VoiceAgentEndpoint(settings.address)
      let certificate = settings.certificate
      for item in try outbox.pending(for: saved.destination) {
        try Task.checkCancellation()
        guard enrollment == saved, destination(for: settings) == saved.destination else { throw VoiceAgentError.contextChanged }
        let data = try await request("episodes", endpoint: endpoint, certificate: certificate, token: saved.token,
                                     episode: item.episode, corpusID: saved.destination.corpusID)
        let ack = try JSONDecoder().decode(Receipt.self, from: data)
        guard ack.accepted, ack.episodeID == item.episode.id else { throw VoiceAgentError.protocolViolation }
        try outbox.remove(id: ack.episodeID, for: saved.destination)
      }
    } catch { show(error) }
  }

  func clearPending(settings: VoiceAgentSettings) {
    guard !busy, let owner = destination(for: settings) else { return }
    do {
      try outbox.clear(for: owner)
      errorText = nil
      updateCount()
    } catch { show(error) }
  }

  func refreshReport(settings: VoiceAgentSettings) async {
    guard !busy else { return }
    busy = true
    errorText = nil
    analysis = nil
    defer { busy = false }
    do {
      guard let saved = enrollment, destination(for: settings) == saved.destination
      else { throw WorkflowUploadError.notLinked }
      let endpoint = try VoiceAgentEndpoint(settings.address)
      let data = try await request("report", endpoint: endpoint, certificate: settings.certificate, token: saved.token)
      guard enrollment == saved, destination(for: settings) == saved.destination else { throw VoiceAgentError.contextChanged }
      let value = try JSONDecoder().decode(WorkflowAnalysisReport.self, from: data)
      guard value.corpusID == saved.destination.corpusID else { throw WorkflowUploadError.corpusChanged }
      analysis = value
    } catch { show(error) }
  }

  func exportState(settings: VoiceAgentSettings) async -> Data? {
    guard !busy else { return nil }
    busy = true
    errorText = nil
    defer { busy = false }
    do {
      guard let saved = enrollment, destination(for: settings) == saved.destination else {
        throw WorkflowUploadError.notLinked
      }
      let endpoint = try VoiceAgentEndpoint(settings.address)
      let data = try await request("state", endpoint: endpoint, certificate: settings.certificate, token: saved.token)
      guard enrollment == saved, destination(for: settings) == saved.destination else { throw VoiceAgentError.contextChanged }
      let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard (value?["corpus_id"] as? String).flatMap(UUID.init(uuidString:)) == saved.destination.corpusID else {
        throw WorkflowUploadError.corpusChanged
      }
      if value?["status"] as? String == "queued" { throw WorkflowUploadError.analysisQueued }
      guard let state = value?["state"] as? [String: Any] else { throw VoiceAgentError.protocolViolation }
      return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    } catch {
      show(error)
      return nil
    }
  }

  func importState(_ url: URL, capturedFor owner: WorkflowDestination, settings: VoiceAgentSettings) async {
    guard !busy else { return }
    busy = true
    errorText = nil
    defer { busy = false }
    do {
      guard let saved = enrollment, saved.destination == owner, destination(for: settings) == owner else {
        throw VoiceAgentError.contextChanged
      }
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        throw VoiceAgentError.protocolViolation
      }
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      let data = try file.read(upToCount: Self.stateLimit + 1) ?? Data()
      guard !data.isEmpty, data.count <= Self.stateLimit else { throw VoiceAgentError.protocolViolation }
      let endpoint = try VoiceAgentEndpoint(settings.address)
      _ = try await request("state", endpoint: endpoint, certificate: settings.certificate, token: saved.token,
                            state: data, corpusID: saved.destination.corpusID)
      guard enrollment == saved, destination(for: settings) == owner else { throw VoiceAgentError.contextChanged }
      analysis = nil
    } catch { show(error) }
  }

  private func updateCount() {
    pendingCount = 0
    staleCount = 0
    guard let owner = enrollment?.destination else { return }
    do {
      let entries = try outbox.load()
      pendingCount = entries.filter { $0.destination == owner }.count
      staleCount = entries.filter { $0.destination != owner && $0.destination.isSameProfile(as: owner) }.count
    } catch { show(error) }
  }

  private func show(_ error: Error) {
    errorText = (error as? WorkflowUploadError)?.localizedDescription ??
      (error as? VoiceAgentError)?.localizedDescription ?? VoiceAgentError.connection.localizedDescription
  }

  private static let stateLimit = 2 * 1024 * 1024

  private func request(_ component: String, endpoint: VoiceAgentEndpoint, certificate: Data, token: String,
                       episode: WorkflowDemonstration? = nil, state: Data? = nil, corpusID: UUID? = nil) async throws -> Data {
    let url = endpoint.origin.appending(path: "v1/workflow").appending(path: component)
    var request = URLRequest(url: url)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body = try episode.map({ try JSONEncoder().encode($0) }) ?? state, let corpusID {
      request.httpMethod = state == nil ? "POST" : "PUT"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(corpusID.uuidString.lowercased(), forHTTPHeaderField: "X-BorgVR-Corpus")
      request.httpBody = body
    }
    let session = VoiceAgentTLS(endpoint: endpoint, anchor: certificate).session(resourceTimeout: 15)
    defer { session.invalidateAndCancel() }
    let (stream, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw VoiceAgentError.connection }
    var data = Data()
    let limit = component == "state" ? Self.stateLimit + 4096 : component == "report" ? 64 * 1024 : 4096
    for try await byte in stream {
      guard data.count < limit else { throw VoiceAgentError.protocolViolation }
      data.append(byte)
    }
    if http.statusCode == 409,
       (try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "corpus_changed" {
      throw WorkflowUploadError.corpusChanged
    }
    guard (200...299).contains(http.statusCode) else { throw VoiceAgentError.connection }
    return data
  }
}
