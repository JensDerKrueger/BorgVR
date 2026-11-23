import Foundation

enum VoiceAgentModelProvider: String, CaseIterable, Identifiable {
  case vllm, openAI
  var id: Self { self }
}

@MainActor
final class VoiceAgentModelClient: AssistantDecisionModel {
  private let endpoint: VoiceAgentEndpoint
  private let token: String
  private let session: URLSession
  private let provider: VoiceAgentModelProvider
  private(set) var model = ""

  init(endpoint: VoiceAgentEndpoint, token: String, session: URLSession, provider: VoiceAgentModelProvider = .vllm,
       configuredModel: String = "") {
    self.endpoint = endpoint
    self.token = token
    self.session = session
    self.provider = provider
    self.model = configuredModel
  }

  deinit { session.invalidateAndCancel() }

  func discover() async throws -> String {
    struct Models: Decodable {
      struct Item: Decodable { let id: String }
      let data: [Item]
    }
    if !model.isEmpty { return model }
    let response = try JSONDecoder().decode(Models.self, from: try await request("models"))
    guard let id = response.data.first?.id, !id.isEmpty, id.utf8.count <= 256 else { throw VoiceAgentError.connection }
    model = id
    return id
  }

  func verifyConnection() async throws -> String {
    let id = try await discover()
    if provider == .openAI { _ = try await request("models/" + id) }
    return id
  }

  static func body(_ input: AssistantModelInput, model: String, provider: VoiceAgentModelProvider = .vllm) throws -> Data {
    let cloud = provider == .openAI
    let textType = cloud ? "input_text" : "text"
    var content: [[String: Any]] = [["type": textType, "text": input.context]]
    guard input.images.count <= 2 else { throw VoiceAgentError.imageTooLarge }
    for (id, png) in input.images {
      guard png.count <= 2 * 1024 * 1024 else { throw VoiceAgentError.imageTooLarge }
      let url = "data:image/png;base64," + png.base64EncodedString()
      content.append(["type": textType, "text": "Image ID: \(id)"])
      content.append(cloud ? ["type": "input_image", "image_url": url, "detail": "auto"] :
                             ["type": "image_url", "image_url": ["url": url]])
    }
    if cloud {
      var schema = AssistantDecision.schema
      var properties = schema["properties"] as? [String: [String: Any]] ?? [:]
      for name in ["operation", "arguments", "focus", "text"] {
        properties[name]?["type"] = ["string", "null"]
        properties[name]?.removeValue(forKey: "maxLength")
      }
      schema["properties"] = properties
      schema["required"] = properties.keys.sorted()
      return try JSONSerialization.data(withJSONObject: [
        "model": model, "store": false, "instructions": input.system, "max_output_tokens": 4096,
        "input": [["role": "user", "content": content]],
        "text": ["format": ["type": "json_schema", "name": "borgvr_assistant_decision", "strict": true, "schema": schema]],
      ])
    }
    return try JSONSerialization.data(withJSONObject: [
      "model": model, "temperature": 0, "stream": false, "max_tokens": 4096,
      "messages": [["role": "system", "content": input.system], ["role": "user", "content": content]],
      "response_format": ["type": "json_schema", "json_schema": ["name": "borgvr_assistant_decision", "schema": AssistantDecision.schema]],
    ])
  }

  func decide(_ input: AssistantModelInput) async throws -> AssistantDecision {
    let id = try await discover()
    let path = provider == .openAI ? "responses" : "chat/completions"
    let data = try await request(path, body: Self.body(input, model: id, provider: provider))
    return try Self.decision(from: data, provider: provider)
  }

  static func decision(from data: Data, provider: VoiceAgentModelProvider) throws -> AssistantDecision {
    let content: String?
    if provider == .openAI {
      struct Response: Decodable {
        struct Item: Decodable {
          struct Content: Decodable { let type: String; let text: String? }
          let type: String
          let content: [Content]?
        }
        let status: String
        let output: [Item]
      }
      let reply = try JSONDecoder().decode(Response.self, from: data)
      let message = reply.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
      if message.contains(where: { $0.type == "refusal" }) { throw VoiceAgentError.modelDeclined }
      guard reply.status == "completed" else { throw VoiceAgentError.protocolViolation }
      content = message.filter { $0.type == "output_text" }.compactMap(\.text).joined()
    } else {
      struct Reply: Decodable {
        struct Choice: Decodable {
          struct Message: Decodable { let content: String? }
          let message: Message
          let finish_reason: String?
        }
        let choices: [Choice]
      }
      let reply = try JSONDecoder().decode(Reply.self, from: data)
      guard let choice = reply.choices.first, choice.finish_reason != "length" else { throw VoiceAgentError.protocolViolation }
      content = choice.message.content
    }
    guard let content, !content.isEmpty, content.utf8.count <= 128 * 1024 else { throw VoiceAgentError.protocolViolation }
    return try JSONDecoder().decode(AssistantDecision.self, from: Data(content.utf8))
  }

  private func request(_ path: String, body: Data? = nil) async throws -> Data {
    let url = endpoint.origin.appending(path: "v1/" + path)
    var request = URLRequest(url: url, timeoutInterval: 180)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1024 * 1024 else {
      throw VoiceAgentError.connection
    }
    return data
  }
}
