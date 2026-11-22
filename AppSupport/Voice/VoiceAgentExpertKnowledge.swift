import Foundation

enum VoiceAgentExpertKnowledge {
  struct ServerFeatures {
    var typedTools = false
    var expertKnowledge = false
    var timeOnlyTurns = false
    var knowledgeBundles = false
  }

  static let bundled = load(from: .main)
  static let procedureBundle = loadProcedureBundle(from: .main)

  static func loadProcedureBundle(from bundle: Bundle) -> [String: Any]? {
    guard let url = bundle.url(forResource: "knowledge-bundle", withExtension: "json"),
          let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 128 * 1024 + 1), data.count <= 128 * 1024 else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func load(from bundle: Bundle) -> String? {
    guard let url = bundle.url(forResource: "expert-knowledge", withExtension: "toml"),
          let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 65_537), !data.isEmpty, data.count <= 65_536 else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func serverFeatures(endpoint: VoiceAgentEndpoint, session: URLSession,
                             transport: VoiceAgentTLS) async -> ServerFeatures {
    // Older servers reject unknown hello fields.
    var request = URLRequest(url: endpoint.origin.appendingPathComponent("healthz"), timeoutInterval: 3)
    request.httpMethod = "HEAD"
    guard let (_, response) = try? await session.data(for: request, delegate: transport),
          let http = response as? HTTPURLResponse, http.statusCode == 200 else { return ServerFeatures() }
    return ServerFeatures(typedTools: http.value(forHTTPHeaderField: "BorgVR-Tool-Types") == "1",
                          expertKnowledge: http.value(forHTTPHeaderField: "BorgVR-Expert-Knowledge") == "1",
                          timeOnlyTurns: http.value(forHTTPHeaderField: "BorgVR-Time-Only-Turns") == "1",
                          knowledgeBundles: http.value(forHTTPHeaderField: "BorgVR-Knowledge-Bundles") == "1")
  }
}
