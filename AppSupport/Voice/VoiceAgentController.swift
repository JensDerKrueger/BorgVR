import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers

struct VoiceAgentContext: Equatable {
  let datasetID: String
  let openingID: UUID
  let editStateID: UUID?
}

struct VoiceAgentMessage: Identifiable {
  let id = UUID()
  let user: Bool
  let text: String
}

@MainActor
final class VoiceAgentController: ObservableObject {
  enum ConnectionState { case disconnected, connecting, ready }
  let settings: VoiceAgentSettings
  let speech = VoiceAgentSpeech()
  @Published private(set) var connectionState: ConnectionState = .disconnected
  @Published private(set) var busy = false
  @Published private(set) var model = ""
  @Published private(set) var messages: [VoiceAgentMessage] = []
  @Published private(set) var status = voiceAgentText("Disconnected")
  @Published var errorText: String?
  private var service: (any BorgVRMCPCommandService)?
  private var router: BorgVRMCPToolRouter?
  private var contextProvider: (() -> VoiceAgentContext?)?
  private var context: VoiceAgentContext?
  private var connectionIdentity: VoiceAgentConnectionIdentity?
  private var contextID = ""
  private var sessionID: String?
  private var requestID: String?
  private var catalog: [[String: Any]] = []
  private var ledger = VoiceAgentCallLedger()
  private var readState = false
  private var changesApplied = false
  private var pendingMutation = false
  private var turns = 0
  private var calls = 0
  private var events = 0
  private var pendingCallID: String?
  private var generation = UUID()
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var receiver: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var deadline: Task<Void, Never>?
  private var toolTask: Task<Void, Never>?
  private var toolDeadline: Task<Void, Never>?
  private var settingsObservation: AnyCancellable?
  private var lastActivity = Date()

  init(settings: VoiceAgentSettings? = nil) {
    self.settings = settings ?? VoiceAgentSettings()
    speech.onFinal = { [weak self] text in
      Task { @MainActor [weak self] in await self?.submit(text) }
    }
    speech.onFailure = { [weak self] error in self?.errorText = error.localizedDescription }
    settingsObservation = self.settings.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if !self.settings.speaks { self.speech.stopSpeaking() }
        if let identity = self.connectionIdentity, identity != self.settings.identity { self.disconnect() }
      }
    }
  }

  deinit {
    receiver?.cancel()
    heartbeat?.cancel()
    deadline?.cancel()
    toolDeadline?.cancel()
    toolTask?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
  }

  func configure(service: any BorgVRMCPCommandService, context: @escaping () -> VoiceAgentContext?) {
    disconnect()
    self.service = service
    router = BorgVRMCPToolRouter(commandService: service)
    contextProvider = context
  }

  var hasDataset: Bool { contextProvider?() != nil && service?.applicationState().rendererReady == true }

  func invalidateContext() {
    if context != nil, context != contextProvider?() { disconnect(reason: VoiceAgentError.contextChanged) }
  }

  func disconnect(reason: Error? = nil) {
    var reportedReason = reason
    if busy, let error = reason as? VoiceAgentError,
       [.connection, .timedOut, .commandFailed].contains(error), changesApplied || pendingMutation {
      reportedReason = VoiceAgentPolicy.failure(code: nil, changesApplied: changesApplied,
                                                completionUncertain: pendingMutation)
    }
    generation = UUID()
    receiver?.cancel()
    heartbeat?.cancel()
    deadline?.cancel()
    toolTask?.cancel()
    toolDeadline?.cancel()
    receiver = nil
    heartbeat = nil
    deadline = nil
    toolTask = nil
    toolDeadline = nil
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
    socket = nil
    session = nil
    context = nil
    connectionIdentity = nil
    sessionID = nil
    requestID = nil
    pendingCallID = nil
    changesApplied = false
    pendingMutation = false
    catalog = []
    ledger = VoiceAgentCallLedger()
    busy = false
    connectionState = .disconnected
    status = voiceAgentText("Disconnected")
    speech.cancel()
    if let reportedReason { errorText = reportedReason.localizedDescription }
  }

  func newConversation() {
    disconnect()
    messages = []
    errorText = nil
    model = ""
  }

  func connect() async {
    do { try await establishConnection() }
    catch is CancellationError { }
    catch { disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection) }
  }

  func testServer() async throws {
    var transportSession: URLSession?
    var timeout: Task<Void, Never>?
    defer { timeout?.cancel(); transportSession?.invalidateAndCancel() }
    do {
      let endpoint = try VoiceAgentEndpoint(settings.address)
      let token = try settings.token()
      let transport = VoiceAgentTLS(endpoint: endpoint, anchor: settings.certificate)
      let session = transport.session()
      transportSession = session
      var request = URLRequest(url: endpoint.origin.appendingPathComponent("readyz"))
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      timeout = Task {
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        session.invalidateAndCancel()
      }
      let (bytes, response) = try await session.bytes(for: request, delegate: transport)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceAgentError.connection }
      var body = Data()
      for try await byte in bytes {
        guard body.count < 65536 else { throw VoiceAgentError.protocolViolation }
        body.append(byte)
      }
      let ready = try VoiceAgentPolicy.decode(String(decoding: body, as: UTF8.self))
      guard ready["status"] as? String == "ready", let capabilities = ready["capabilities"] as? [String: Any],
            capabilities["vision"] as? Bool == true, capabilities["tool_calling"] as? Bool == true
      else { throw VoiceAgentError.protocolViolation }
      status = voiceAgentText("Server ready")
      model = String((ready["model"] as? String ?? "").prefix(256))
      errorText = nil
    } catch {
      errorText = VoiceAgentError.connection.localizedDescription
      throw error
    }
  }

  private func establishConnection() async throws {
    guard settings.enabled, let service, let router, let captured = contextProvider?(),
          service.applicationState().rendererReady else { throw VoiceAgentError.configuration }
    if connectionState == .ready {
      guard context == captured else { throw VoiceAgentError.contextChanged }
      return
    }
    guard connectionState != .connecting else { throw CancellationError() }
    let endpoint = try VoiceAgentEndpoint(settings.address)
    let token = try settings.token()
    disconnect()
    errorText = nil
    messages = []
    context = captured
    connectionIdentity = settings.identity
    contextID = UUID().uuidString
    readState = false
    turns = 0
    calls = 0
    #if os(visionOS)
    let vision = true
    #else
    let vision = false
    #endif
    catalog = VoiceAgentPolicy.catalog(router.toolDefinitions, vision: vision,
      transferFunctions: service.transferFunctionCount > 0, images: settings.sharesImages)
    let transport = VoiceAgentTLS(endpoint: endpoint, anchor: settings.certificate)
    let session = transport.session()
    self.session = session
    var request = URLRequest(url: endpoint.socket)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15
    let socket = session.webSocketTask(with: request)
    socket.delegate = transport
    socket.maximumMessageSize = VoiceAgentPolicy.maximumFrameBytes
    self.socket = socket
    let id = generation
    connectionState = .connecting
    status = voiceAgentText("Connecting…")
    socket.resume()
    armDeadline(seconds: 15, generation: id)
    do {
    try await send(["type": "hello", "protocol": 1, "dataset_id": captured.datasetID,
                    "context_id": contextID, "tools": catalog])
    let ready = try decode(await socket.receive())
    guard generation == id, contextProvider?() == captured else { throw CancellationError() }
    guard ready["type"] as? String == "ready", let version = ready["protocol"] as? Int, version == 1,
          let sessionID = ready["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 128,
          let capabilities = ready["capabilities"] as? [String: Any],
          capabilities["vision"] as? Bool == true, capabilities["tool_calling"] as? Bool == true,
          let accepted = ready["tools"] as? [String], accepted.count <= 32,
          accepted.contains("get_application_state"), Set(accepted).count == accepted.count,
          Set(accepted).isSubset(of: Set(catalog.compactMap { $0["name"] as? String }))
    else { throw VoiceAgentError.protocolViolation }
    self.sessionID = sessionID
    catalog = catalog.filter { accepted.contains($0["name"] as? String ?? "") }
    model = String((ready["model"] as? String ?? "").prefix(256))
    deadline?.cancel()
    connectionState = .ready
    status = voiceAgentText("Ready")
    lastActivity = Date()
    receiver = Task { @MainActor [weak self] in
      do {
        while !Task.isCancelled {
          let frame = try await socket.receive()
          guard let self, self.generation == id else { return }
          try await self.handle(self.decode(frame))
        }
      } catch {
        guard let self, self.generation == id else { return }
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection)
      }
    }
    heartbeat = Task { @MainActor [weak self] in
      var tick = 0
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(1))
          guard let self, self.generation == id else { return }
          guard self.contextProvider?() == captured else { throw VoiceAgentError.contextChanged }
          if self.requestID == nil, Date().timeIntervalSince(self.lastActivity) > 240 { self.disconnect(); return }
          tick += 1
          if tick % 20 == 0 {
            try await Self.withSocketDeadline(socket, seconds: 10) {
              try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.sendPing { error in
                  if let error { continuation.resume(throwing: error) }
                  else { continuation.resume() }
                }
              }
            }
          }
        }
      } catch {
        guard let self, self.generation == id else { return }
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection)
      }
    }
    } catch {
      guard generation == id else { throw CancellationError() }
      throw error
    }
  }

  func submit(_ text: String) async {
    guard !busy, !speech.isRecording else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 8192 else { return }
    var operationGeneration: UUID?
    do {
      try await establishConnection()
      operationGeneration = generation
      try requireContext()
      guard turns < 64 else { throw VoiceAgentError.protocolViolation }
      turns += 1
      calls = 0
      events = 0
      readState = false
      changesApplied = false
      pendingMutation = false
      let id = UUID().uuidString
      requestID = id
      busy = true
      status = voiceAgentText("Working…")
      append(user: true, text: trimmed)
      lastActivity = Date()
      armDeadline(seconds: 185, generation: generation)
      try await send(["type": "user_message", "request_id": id, "text": trimmed])
    } catch is CancellationError { }
    catch {
      if operationGeneration == nil || operationGeneration == generation {
        disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection)
      }
    }
  }

  func toggleMicrophone() async {
    if speech.isRecording { speech.finish(); return }
    guard !busy else { return }
    do {
      try await establishConnection()
      try await speech.start(onDeviceOnly: settings.onDeviceOnly)
    } catch is CancellationError { }
    catch { errorText = error.localizedDescription }
  }

  /// Closing the socket also cancels the server run; no uncertain action is retried.
  func cancel() { disconnect() }

  private func requireContext() throws {
    guard let context, contextProvider?() == context, connectionIdentity == settings.identity,
          settings.enabled, service?.applicationState().rendererReady == true
    else { throw VoiceAgentError.contextChanged }
  }

  private func handle(_ event: [String: Any]) async throws {
    try requireContext()
    guard event["session_id"] as? String == sessionID, let type = event["type"] as? String
    else { throw VoiceAgentError.protocolViolation }
    events += 1
    guard events <= 128 else { throw VoiceAgentError.protocolViolation }
    if type == "tool_call", let callID = event["call_id"] as? String, ledger.entries[callID] != nil {
      try startTool(event)
      return
    }
    guard let requestID, event["request_id"] as? String == requestID else { throw VoiceAgentError.protocolViolation }
    lastActivity = Date()
    switch type {
      case "started": break
      case "assistant_message":
        guard let text = event["text"] as? String, text.count <= 8192, event["final"] is Bool
        else { throw VoiceAgentError.protocolViolation }
        append(user: false, text: text)
        if settings.speaks { speech.speak(text) }
      case "tool_call": try startTool(event)
      case "tool_cancel":
        guard event["call_id"] as? String == pendingCallID else { throw VoiceAgentError.protocolViolation }
        throw VoiceAgentPolicy.failure(code: nil, changesApplied: changesApplied,
                                       completionUncertain: pendingMutation)
      case "completed":
        guard pendingCallID == nil else { throw VoiceAgentError.protocolViolation }
        self.requestID = nil
        busy = false
        deadline?.cancel()
        status = voiceAgentText("Ready")
      case "cancelled": disconnect()
      case "error":
        // Use local execution receipts, never a remote claim that a change succeeded.
        throw VoiceAgentPolicy.failure(code: event["code"] as? String, changesApplied: changesApplied,
                                       completionUncertain: pendingMutation)
      default: throw VoiceAgentError.protocolViolation
    }
  }

  private func startTool(_ event: [String: Any]) throws {
    guard let context, event["dataset_id"] as? String == context.datasetID,
          event["context_id"] as? String == contextID,
          let callID = event["call_id"] as? String, let name = event["name"] as? String,
          let arguments = event["arguments"] as? [String: Any],
          let definition = catalog.first(where: { $0["name"] as? String == name }),
          let schema = definition["inputSchema"] as? [String: Any]
    else { throw VoiceAgentError.protocolViolation }
    _ = try VoiceAgentPolicy.encoded(arguments, limit: VoiceAgentPolicy.maximumResultBytes)
    try VoiceAgentPolicy.validate(arguments, schema: schema)
    let signature = try VoiceAgentPolicy.encoded(event)
    if let previous = try ledger.begin(id: callID, signature: signature) {
      if let reply = previous.reply {
        let id = generation
        Task { @MainActor [weak self] in
          guard let self, self.generation == id else { return }
          do { try await self.sendRaw(reply) }
          catch { if self.generation == id { self.disconnect(reason: VoiceAgentError.connection) } }
        }
      }
      return
    }
    guard pendingCallID == nil, calls < 24,
          VoiceAgentPolicy.reads.contains(name) || readState else { throw VoiceAgentError.protocolViolation }
    calls += 1
    pendingCallID = callID
    pendingMutation = !VoiceAgentPolicy.reads.contains(name)
    let id = generation
    let request = requestID!
    toolDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(40)) } catch { return }
      if self?.generation == id { self?.disconnect(reason: VoiceAgentError.timedOut) }
    }
    toolTask = Task { @MainActor [weak self] in
      guard let self, let router = self.router else { return }
      do {
        try self.requireContext()
        try Task.checkCancellation()
        let result = try await router.callTool(name: name, arguments: arguments, validateContext: {
          guard self.generation == id, self.requestID == request else { throw CancellationError() }
          try self.requireContext()
        })
        guard result["isError"] as? Bool != true else { throw VoiceAgentError.commandFailed }
        if self.generation == id, self.requestID == request {
          if self.pendingMutation { self.changesApplied = true }
          self.pendingMutation = false
        }
        try Task.checkCancellation()
        guard self.generation == id, self.requestID == request else { return }
        try self.requireContext()
        var payload: [String: Any] = ["type": "tool_result", "request_id": request,
          "call_id": callID, "dataset_id": context.datasetID, "context_id": self.contextID]
        if name == "capture_screenshot" {
          guard let contents = result["content"] as? [[String: Any]],
                let encoded = contents.first?["data"] as? String,
                let png = Data(base64Encoded: encoded) else { throw VoiceAgentError.imageTooLarge }
          let image = try Self.agentImage(png)
          payload["image_png_base64"] = image.data.base64EncodedString()
          payload["result"] = ["width": image.width, "height": image.height,
                               "renderedFrame": (result["structuredContent"] as? [String: Any])?["renderedFrame"] ?? 0]
        } else {
          let state = VoiceAgentPolicy.compactResult(result["structuredContent"] as? [String: Any] ?? [:], tool: name)
          _ = try VoiceAgentPolicy.encoded(state, limit: VoiceAgentPolicy.maximumResultBytes)
          payload["result"] = state
        }
        let reply = try VoiceAgentPolicy.encoded(payload)
        try self.ledger.finish(id: callID, reply: reply)
        if name == "get_application_state" { self.readState = true }
        self.pendingCallID = nil
        self.toolTask = nil
        self.toolDeadline?.cancel()
        self.toolDeadline = nil
        try await self.sendRaw(reply)
      } catch {
        guard self.generation == id else { return }
        // A thrown mutation may already have committed. Terminate rather than invite a retry.
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.commandFailed)
      }
    }
  }

  static func agentImage(_ png: Data) throws -> (data: Data, width: Int, height: Int) {
    guard png.count <= 64 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1
    else { throw VoiceAgentError.imageTooLarge }
    for size in [1024, 768, 512, 256] {
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw VoiceAgentError.imageTooLarge
      }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { throw VoiceAgentError.imageTooLarge }
      CGImageDestinationAddImage(destination, image, nil)
      if CGImageDestinationFinalize(destination), data.length <= 2 * 1024 * 1024 {
        return (data as Data, image.width, image.height)
      }
    }
    throw VoiceAgentError.imageTooLarge
  }

  private func append(user: Bool, text: String) {
    messages.append(VoiceAgentMessage(user: user, text: text))
    if messages.count > 100 { messages.removeFirst(messages.count - 100) }
  }

  private func decode(_ frame: URLSessionWebSocketTask.Message) throws -> [String: Any] {
    guard case .string(let string) = frame else { throw VoiceAgentError.protocolViolation }
    return try VoiceAgentPolicy.decode(string)
  }

  private func send(_ value: [String: Any]) async throws { try await sendRaw(VoiceAgentPolicy.encoded(value)) }

  private func sendRaw(_ string: String) async throws {
    guard let socket else { throw CancellationError() }
    try await Self.withSocketDeadline(socket, seconds: 10) { try await socket.send(.string(string)) }
  }

  private nonisolated static func withSocketDeadline(_ socket: URLSessionWebSocketTask, seconds: Double,
    operation: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        socket.cancel(with: .goingAway, reason: nil)
        throw VoiceAgentError.timedOut
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  private func armDeadline(seconds: Double, generation id: UUID) {
    deadline?.cancel()
    deadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      if self?.generation == id { self?.disconnect(reason: VoiceAgentError.timedOut) }
    }
  }
}
