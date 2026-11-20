import Foundation
import Combine
import ImageIO
import UniformTypeIdentifiers
import OSLog

struct VoiceAgentMessage: Identifiable {
  let id = UUID()
  let user: Bool
  let text: String
}

struct VoiceAgentQuestion: Identifiable {
  let id: String
  let text: String
}

@MainActor
final class VoiceAgentController: ObservableObject {
  enum ConnectionState { case disconnected, connecting, ready }
  let settings: VoiceAgentSettings
  let speech = VoiceAgentSpeech()
  @Published private(set) var connectionState: ConnectionState = .disconnected
  @Published private(set) var busy = false
  @Published private(set) var interrupting = false
  @Published private(set) var collaborationQuestion: VoiceAgentQuestion?
  @Published private(set) var annotationDeletion: VoiceAgentAnnotationDeletion?
  @Published private(set) var ruleProposals: [VoiceAgentQuestion] = []
  @Published private(set) var userIsInteracting = false
  @Published private(set) var model = ""
  @Published private(set) var datasetOpeningID: UUID?
  @Published private(set) var messages: [VoiceAgentMessage] = []
  @Published private(set) var status = voiceAgentText("Disconnected")
  @Published var errorText: String?
  @Published var isPresented = false
  private var bridge: (any VoiceAgentApplicationBridge)?
  private var context: VoiceAgentContext?
  private var scopeOpening: VoiceAgentContext?
  private var connectionIdentity: VoiceAgentConnectionIdentity?
  private var contextID = ""
  private var sessionID: String?
  private var requestID: String?
  private var acknowledgedRequestID: String?
  private var lastAssistantResponse: (requestID: String, messageID: UUID)?
  private var deletionReply: CheckedContinuation<Bool, Never>?
  private var declinedDeletionRequestID: String?
  private let diagnosticLog = Logger(subsystem: "de.uni-due.BorgVR", category: "VoiceAgent")
  private var catalog: [[String: Any]] = []
  private var ledger = VoiceAgentCallLedger()
  private var readState = false
  private var changesApplied = false
  private var pendingMutation = false
  private var turns = 0
  private var calls = 0
  private var events = 0
  private var maximumCalls = 24
  private var workTimeout: Double = 180
  private var queuedPrompt: String?
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
  private var commandObservation: AnyCancellable?
  private var collaborationEnabled = false
  private var viewRevision = 0
  private var changedDomains: Set<String> = []
  private var manualOperations: Set<UUID> = []
  private var interventionTask: Task<Void, Never>?
  private var collaborationSendTask: Task<Void, Never>?
  private var contextUpdateTask: Task<Void, Never>?
  private var contextAckDeadline: Task<Void, Never>?
  private var updatingContext = false
  private var openingTarget: String?
  private var openingContext: VoiceAgentContext?
  private var openingPreviousContext: VoiceAgentContext?
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
    deletionReply?.resume(returning: false)
    receiver?.cancel()
    heartbeat?.cancel()
    deadline?.cancel()
    toolDeadline?.cancel()
    toolTask?.cancel()
    interventionTask?.cancel()
    collaborationSendTask?.cancel()
    contextUpdateTask?.cancel()
    contextAckDeadline?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
  }

  func configure(bridge: any VoiceAgentApplicationBridge) {
    disconnect()
    self.bridge = bridge
    commandObservation = bridge.changes.sink { [weak self] event in
      self?.observeCommand(event)
    }
    invalidateContext()
  }

  var hasDataset: Bool { bridge?.context != nil && bridge?.rendererReady == true }
  var isAvailable: Bool { bridge != nil && settings.enabled }

  private var applicationOpeningMatches: Bool {
    switch (scopeOpening, bridge?.applicationDatasetContext) {
      case (nil, nil): return true
      case (let previous?, let current?): return previous.hasSameOpening(as: current)
      default: return false
    }
  }

  func invalidateContext() {
    let current = bridge?.context
    let editing = userIsInteracting && changedDomains.contains("volume") &&
      (current == nil || current?.openingID == context?.openingID) &&
      bridge?.datasetID == context?.datasetID
    datasetOpeningID = bridge?.rendererReady == true ? (current?.openingID ?? (editing ? context?.openingID : nil)) : nil
    if let openingContext {
      if bridge?.applicationDatasetContext?.hasSameOpening(as: openingContext) != true { disconnect(reason: VoiceAgentError.contextChanged) }
      return
    }
    if openingTarget != nil, bridge?.applicationDatasetContext != openingPreviousContext {
      disconnect(reason: VoiceAgentError.contextChanged)
      return
    }
    guard connectionIdentity != nil, context != current || !applicationOpeningMatches, !editing else { return }
    // Never carry an in-flight command or goal into another dataset opening.
    guard connectionState == .ready, !busy, pendingCallID == nil, !userIsInteracting else {
      disconnect(reason: VoiceAgentError.contextChanged)
      return
    }
    updateContext(current)
  }

  private func availableTools() -> [[String: Any]] {
    guard let bridge else { return [] }
    #if os(visionOS)
    let vision = true
    #else
    let vision = false
    #endif
    let tools = VoiceAgentPolicy.catalog(bridge.toolDefinitions, vision: vision,
      transferFunctions: bridge.hasTransferFunctions, images: settings.sharesImages, datasetReady: hasDataset)
    return !hasDataset && bridge.applicationDatasetContext != nil
      ? tools.filter { $0["name"] as? String != "open_dataset" } : tools
  }

  private var wireDatasetID: Any { context?.datasetID as Any? ?? NSNull() }

  private func updateContext(_ current: VoiceAgentContext?) {
    context = current
    scopeOpening = bridge?.applicationDatasetContext
    contextID = UUID().uuidString
    catalog = availableTools()
    readState = false
    collaborationQuestion = nil
    ruleProposals = []
    viewRevision = 0
    changedDomains = []
    updatingContext = true
    lastActivity = Date()
    connectionState = .connecting
    status = voiceAgentText("Connecting…")
    speech.cancel()
    let message: [String: Any] = ["type": "context_changed", "dataset_id": wireDatasetID,
      "context_id": contextID, "tools": catalog]
    let id = generation
    let previousSend = collaborationSendTask
    armDeadline(seconds: 15, generation: id)
    contextUpdateTask = Task { @MainActor [weak self] in
      await previousSend?.value
      guard !Task.isCancelled, let self, self.generation == id else { return }
      do { try await self.send(message) }
      catch { if self.generation == id { self.disconnect(reason: VoiceAgentError.connection) } }
    }
  }

  func disconnect(reason: Error? = nil) {
    if let annotationDeletion { resolveAnnotationDeletion(id: annotationDeletion.id, accepted: false) }
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
    scopeOpening = nil
    connectionIdentity = nil
    sessionID = nil
    requestID = nil
    queuedPrompt = nil
    interventionTask?.cancel()
    collaborationSendTask?.cancel()
    contextUpdateTask?.cancel()
    contextAckDeadline?.cancel()
    contextAckDeadline = nil
    contextUpdateTask = nil
    updatingContext = false
    openingTarget = nil
    openingContext = nil
    openingPreviousContext = nil
    interventionTask = nil
    collaborationSendTask = nil
    collaborationQuestion = nil
    ruleProposals = []
    collaborationEnabled = false
    userIsInteracting = false
    viewRevision = 0
    changedDomains = []
    manualOperations = []
    interrupting = false
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

  private func establishConnection(replacing: Bool = false) async throws {
    guard settings.enabled, let bridge else { throw VoiceAgentError.configuration }
    let captured = bridge.context
    if connectionState == .ready {
      guard context == captured else { throw VoiceAgentError.contextChanged }
      return
    }
    guard connectionState != .connecting else { throw CancellationError() }
    let endpoint = try VoiceAgentEndpoint(settings.address)
    let token = try settings.token()
    disconnect()
    interrupting = replacing
    errorText = nil
    context = captured
    scopeOpening = bridge.applicationDatasetContext
    connectionIdentity = settings.identity
    contextID = UUID().uuidString
    readState = false
    turns = 0
    calls = 0
    catalog = availableTools()
    let transport = VoiceAgentTLS(endpoint: endpoint, anchor: settings.certificate)
    let session = transport.session(resourceTimeout: Double(settings.workMinutes * 60 + 120))
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
    try await send(["type": "hello", "protocol": 1, "dataset_id": wireDatasetID, "application_session": true,
                    "dataset_opening": true,
                    "context_id": contextID, "tools": catalog,
                    "collaboration": true, "knowledge": settings.knowledgeRules.map(\.text),
                    "execution_limits": ["max_calls": settings.maximumCalls, "timeout_seconds": settings.workMinutes * 60]])
    let ready = try decode(await socket.receive())
    guard generation == id, bridge.context == captured else { throw CancellationError() }
    guard ready["application_session"] as? Bool == true, ready["dataset_opening"] as? Bool == true
    else { throw VoiceAgentError.serverUpdateRequired }
    guard ready["type"] as? String == "ready", let version = ready["protocol"] as? Int, version == 1,
          let sessionID = ready["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 128,
          let capabilities = ready["capabilities"] as? [String: Any],
          capabilities["vision"] as? Bool == true, capabilities["tool_calling"] as? Bool == true,
          let accepted = ready["tools"] as? [String], accepted.count <= 32,
          accepted.contains("get_application_state"), Set(accepted).count == accepted.count,
          Set(accepted).isSubset(of: Set(catalog.compactMap { $0["name"] as? String }))
    else { throw VoiceAgentError.protocolViolation }
    self.sessionID = sessionID
    collaborationEnabled = ready["collaboration"] as? Bool == true
    if let limits = ready["execution_limits"] as? [String: Any] {
      guard let calls = limits["max_calls"] as? Int, (24...settings.maximumCalls).contains(calls),
            let seconds = limits["timeout_seconds"] as? Double, seconds.isFinite,
            (1...Double(settings.workMinutes * 60)).contains(seconds)
      else { throw VoiceAgentError.protocolViolation }
      maximumCalls = calls
      workTimeout = seconds
    } else {
      maximumCalls = 24
      workTimeout = 180
    }
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
        self.logFailure(error, operation: "receive")
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection)
      }
    }
    heartbeat = Task { @MainActor [weak self] in
      var tick = 0
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(1))
          guard let self, self.generation == id else { return }
          self.invalidateContext()
          try self.requireContext()
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
        self.logFailure(error, operation: "heartbeat")
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection)
      }
    }
    } catch {
      guard generation == id else { throw CancellationError() }
      throw error
    }
  }

  func submit(_ text: String) async {
    guard !speech.isRecording, !interrupting else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 8192 else { return }
    if collaborationQuestion != nil {
      await answerCollaboration(trimmed)
      return
    }
    if busy {
      queuedPrompt = trimmed
      interrupting = true
      status = voiceAgentText("Interrupting…")
      speech.stopSpeaking()
      if let annotationDeletion { resolveAnnotationDeletion(id: annotationDeletion.id, accepted: false) }
      resumeQueuedPromptIfSafe()
      return
    }
    await sendPrompt(trimmed)
  }

  private func sendPrompt(_ trimmed: String, preserving transcript: [VoiceAgentMessage]? = nil) async {
    var operationGeneration: UUID?
    do {
      try await establishConnection(replacing: transcript != nil)
      operationGeneration = generation
      try requireContext()
      if let transcript { messages = transcript }
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
      interrupting = false
      status = voiceAgentText("Working…")
      append(user: true, text: trimmed)
      lastActivity = Date()
      armDeadline(seconds: workTimeout + 5, generation: generation)
      try await send(["type": "user_message", "request_id": id, "text": trimmed])
    } catch is CancellationError { }
    catch {
      if operationGeneration == nil || operationGeneration == generation {
        disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.connection)
      }
    }
  }

  private func resumeQueuedPromptIfSafe() {
    guard let prompt = queuedPrompt, pendingCallID == nil else { return }
    let expectedContext = context
    let transcript = messages + [VoiceAgentMessage(user: false, text: voiceAgentText("Previous request interrupted."))]
    // Retire the old connection only after any dispatched command has finished.
    // A fresh connection must read current state and never replays the old request.
    disconnect()
    interrupting = true
    status = voiceAgentText("Interrupting…")
    let id = generation
    Task { @MainActor [weak self] in
      guard let self, self.generation == id else { return }
      guard self.bridge?.context == expectedContext else {
        self.disconnect(reason: VoiceAgentError.contextChanged)
        return
      }
      await self.sendPrompt(prompt, preserving: transcript)
    }
  }

  func toggleMicrophone() async {
    if speech.isRecording { speech.finish(); return }
    guard !interrupting else { return }
    do {
      try await establishConnection()
      try await speech.start(onDeviceOnly: settings.onDeviceOnly)
    } catch is CancellationError { }
    catch { errorText = error.localizedDescription }
  }

  /// Closing the socket also cancels the server run; no uncertain action is retried.
  func cancel() { disconnect() }

  func resolveAnnotationDeletion(id: UUID, accepted: Bool) {
    guard annotationDeletion?.id == id else { return }
    annotationDeletion = nil
    let continuation = deletionReply
    deletionReply = nil
    if !accepted { declinedDeletionRequestID = requestID }
    status = voiceAgentText("Working…")
    continuation?.resume(returning: accepted)
  }

  private func requestAnnotationDeletion(_ preview: VoiceAgentAnnotationDeletion) async -> Bool {
    await withCheckedContinuation { continuation in
      deletionReply = continuation
      annotationDeletion = preview
      status = voiceAgentText("Waiting for deletion approval")
    }
  }

  private func requireContext() throws {
    if let openingContext {
      guard bridge?.applicationDatasetContext?.hasSameOpening(as: openingContext) == true, settings.enabled,
            connectionIdentity == settings.identity else { throw VoiceAgentError.contextChanged }
      return
    }
    if openingTarget != nil, bridge?.applicationDatasetContext != openingPreviousContext {
      throw VoiceAgentError.contextChanged
    }
    let current = bridge?.context
    let editing = userIsInteracting && changedDomains.contains("volume") &&
      datasetOpeningID == context?.openingID && bridge?.datasetID == context?.datasetID
    guard bridge != nil, applicationOpeningMatches, current == context || editing, connectionIdentity == settings.identity,
          settings.enabled, context == nil || bridge?.rendererReady == true
    else { throw VoiceAgentError.contextChanged }
  }

  private func handle(_ event: [String: Any]) async throws {
    try requireContext()
    guard event["session_id"] as? String == sessionID, let type = event["type"] as? String
    else { throw VoiceAgentError.protocolViolation }
    if updatingContext {
      guard type == "context_updated", event["context_id"] as? String == contextID,
            let accepted = event["tools"] as? [String], accepted.count <= 32,
            accepted.contains("get_application_state"), Set(accepted).count == accepted.count,
            Set(accepted).isSubset(of: Set(catalog.compactMap { $0["name"] as? String }))
      else { throw VoiceAgentError.protocolViolation }
      catalog = catalog.filter { accepted.contains($0["name"] as? String ?? "") }
      updatingContext = false
      connectionState = .ready
      contextAckDeadline?.cancel()
      contextAckDeadline = nil
      if !busy { deadline?.cancel() }
      status = voiceAgentText(busy ? "Working…" : "Ready")
      return
    }
    events += 1
    guard events <= maximumCalls * 4 + 128 else { throw VoiceAgentError.protocolViolation }
    if type == "tool_call", interrupting, pendingCallID == nil {
      resumeQueuedPromptIfSafe()
      return
    }
    if type == "tool_call", let callID = event["call_id"] as? String, ledger.entries[callID] != nil {
      try startTool(event)
      return
    }
    guard let requestID, event["request_id"] as? String == requestID else { throw VoiceAgentError.protocolViolation }
    lastActivity = Date()
    switch type {
      case "started":
        guard acknowledgedRequestID != requestID else { break }
        acknowledgedRequestID = requestID
        let text = voiceAgentText("Request is being processed.")
        append(user: false, text: text)
        if settings.speaks, !speech.isRecording, !interrupting {
          speech.speak(text, rateMultiplier: settings.speechRateMultiplier)
        }
      case "collaboration_paused":
        guard collaborationEnabled else { throw VoiceAgentError.protocolViolation }
        status = voiceAgentText("Paused for your changes")
      case "collaboration_resumed":
        guard collaborationEnabled else { throw VoiceAgentError.protocolViolation }
        status = voiceAgentText("Working…")
      case "collaboration_question":
        guard collaborationEnabled, collaborationQuestion == nil,
              let questionID = event["question_id"] as? String, !questionID.isEmpty, questionID.count <= 128,
              let text = event["text"] as? String, !text.isEmpty, text.count <= 500
        else { throw VoiceAgentError.protocolViolation }
        collaborationQuestion = .init(id: questionID, text: text)
        append(user: false, text: text)
        status = voiceAgentText("Waiting for your reply")
        if settings.speaks, !speech.isRecording { speech.speak(text, rateMultiplier: settings.speechRateMultiplier) }
      case "rule_proposal":
        guard collaborationEnabled, ruleProposals.count < 8,
              let proposalID = event["proposal_id"] as? String, !proposalID.isEmpty, proposalID.count <= 128,
              !ruleProposals.contains(where: { $0.id == proposalID }),
              let text = event["text"] as? String, !text.isEmpty, text.count <= 500
        else { throw VoiceAgentError.protocolViolation }
        ruleProposals.append(.init(id: proposalID, text: text))
      case "assistant_message":
        guard let text = event["text"] as? String, text.count <= 8192, event["final"] is Bool
        else { throw VoiceAgentError.protocolViolation }
        if let previous = lastAssistantResponse, previous.requestID == requestID,
           let last = messages.last, last.id == previous.messageID,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
          break
        }
        append(user: false, text: text)
        if let last = messages.last { lastAssistantResponse = (requestID, last.id) }
        if settings.speaks, !speech.isRecording, !interrupting {
          speech.speak(text, rateMultiplier: settings.speechRateMultiplier)
        }
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
        resumeQueuedPromptIfSafe()
      case "cancelled": disconnect()
      case "error":
        // Use local execution receipts, never a remote claim that a change succeeded.
        throw VoiceAgentPolicy.failure(code: event["code"] as? String, changesApplied: changesApplied,
                                       completionUncertain: pendingMutation)
      default: throw VoiceAgentError.protocolViolation
    }
  }

  private func startTool(_ event: [String: Any]) throws {
    guard event["dataset_id"] != nil, event["dataset_id"] as? String == context?.datasetID,
          context != nil || event["dataset_id"] is NSNull,
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
    guard pendingCallID == nil, calls < maximumCalls else { throw VoiceAgentError.protocolViolation }
    calls += 1
    let expectedRevision = event["view_revision"] as? Int
    if collaborationEnabled && (userIsInteracting || expectedRevision != viewRevision) {
      try rejectSupersededTool(callID: callID)
      return
    }
    guard VoiceAgentPolicy.reads.contains(name) || readState else { throw VoiceAgentError.protocolViolation }
    pendingCallID = callID
    let deletionTool = ["clear_annotations", "remove_object", "remove_measurement"].contains(name)
    pendingMutation = !VoiceAgentPolicy.reads.contains(name) && !deletionTool
    if name == "open_dataset" {
      openingPreviousContext = bridge?.applicationDatasetContext
      openingTarget = arguments["id"] as? String
    }
    let id = generation
    let request = requestID!
    toolDeadline = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(name == "open_dataset" ? 330 : deletionTool ? 300 : name == "search_datasets" ? 75 : 40)) } catch { return }
      if self?.generation == id { self?.disconnect(reason: VoiceAgentError.timedOut) }
    }
    toolTask = Task { @MainActor [weak self] in
      guard let self, let bridge = self.bridge else { return }
      do {
        try self.requireContext()
        try Task.checkCancellation()
        if self.collaborationEnabled, self.userIsInteracting || expectedRevision != self.viewRevision {
          self.pendingMutation = false
          self.pendingCallID = nil
          self.toolDeadline?.cancel()
          self.toolDeadline = nil
          self.toolTask = nil
          try self.rejectSupersededTool(callID: callID)
          return
        }
        let validate: () throws -> Void = {
            guard self.generation == id, self.requestID == request else { throw CancellationError() }
            try self.requireContext()
            if self.collaborationEnabled, self.userIsInteracting || expectedRevision != self.viewRevision {
              throw CancellationError()
            }
          }
        let result: [String: Any]
        if deletionTool, self.declinedDeletionRequestID == request {
          result = ["structuredContent": ["ok": false, "not_applied": true, "code": "user_declined",
            "note": "The user declined deletion in this request. Do not bypass that decision with other deletion tools."]]
        } else if deletionTool {
          let scope = name == "remove_object" ? "markers" : name == "remove_measurement" ? "measurements" : arguments["scope"] as? String ?? "all"
          if let preview = try bridge.prepareAnnotationDeletion(scope: scope, targetID: name == "clear_annotations" ? nil : arguments["id"] as? String) {
            if preview.markerCount + preview.measurementCount == 0 {
              result = ["structuredContent": ["ok": true, "not_applied": true, "code": "no_annotations"]]
            } else if !(await self.requestAnnotationDeletion(preview)) {
              result = ["structuredContent": ["ok": false, "not_applied": true, "code": "user_declined",
                "note": "The user did not approve deletion. Do not ask again or delete items individually to bypass that decision."]]
            } else {
              guard self.generation == id, self.requestID == request, !Task.isCancelled else { return }
              self.pendingMutation = true
              result = try await bridge.executeAnnotationDeletion(preview, validateContext: validate)
            }
          } else {
            self.pendingMutation = true
            result = try await bridge.executeTool(name: name, arguments: arguments, validateContext: validate)
          }
        } else if name == "open_dataset", let target = self.openingTarget {
          result = try await bridge.openDataset(id: target, validateContext: validate, didBegin: { opened in
            guard self.generation == id, self.requestID == request, self.openingTarget == opened.datasetID,
                  self.openingContext == nil || self.openingContext?.hasSameOpening(as: opened) == true else { throw VoiceAgentError.contextChanged }
            self.openingContext = opened
          })
        } else {
          result = try await bridge.executeTool(name: name, arguments: arguments, validateContext: validate)
        }
        guard result["isError"] as? Bool != true else { throw VoiceAgentError.commandFailed }
        let notApplied = (result["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true
        if self.generation == id, self.requestID == request {
          if self.pendingMutation && !notApplied { self.changesApplied = true }
          self.pendingMutation = false
        }
        try Task.checkCancellation()
        guard self.generation == id, self.requestID == request else { return }
        try self.requireContext()
        var payload: [String: Any] = ["type": "tool_result", "request_id": request,
          "call_id": callID, "dataset_id": self.wireDatasetID, "context_id": self.contextID]
        if name == "open_dataset", !notApplied {
          guard let opened = self.openingContext, bridge.context == opened else { throw VoiceAgentError.contextChanged }
          self.context = opened
          self.scopeOpening = opened
          self.datasetOpeningID = opened.openingID
          self.contextID = UUID().uuidString
          self.catalog = self.availableTools()
          self.readState = false
          self.viewRevision = 0
          self.collaborationQuestion = nil
          self.ruleProposals = []
          self.changedDomains = []
          payload["dataset_transition"] = ["dataset_id": opened.datasetID, "context_id": self.contextID, "tools": self.catalog]
          self.updatingContext = true
          self.connectionState = .connecting
          self.contextAckDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            if self?.generation == id { self?.disconnect(reason: VoiceAgentError.timedOut) }
          }
        }
        self.openingTarget = nil
        self.openingContext = nil
        self.openingPreviousContext = nil
        if self.collaborationEnabled { payload["view_revision"] = expectedRevision ?? 0 }
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
        if name == "get_application_state" { self.readState = !self.userIsInteracting && (!self.collaborationEnabled || expectedRevision == self.viewRevision) }
        self.pendingCallID = nil
        self.toolTask = nil
        self.toolDeadline?.cancel()
        self.toolDeadline = nil
        try await self.sendRaw(reply)
        self.resumeQueuedPromptIfSafe()
      } catch {
        guard self.generation == id else { return }
        self.logFailure(error, operation: name)
        // A thrown mutation may already have committed. Terminate rather than invite a retry.
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.commandFailed)
      }
    }
  }

  private func logFailure(_ error: Error, operation: String) {
    let kind = (error as? VoiceAgentError).map { String(describing: $0) } ?? String(reflecting: type(of: error))
    let code = (error as NSError).code
    diagnosticLog.error("Assistant failure: operation=\(operation, privacy: .public), kind=\(kind, privacy: .public), code=\(code), mutationPending=\(self.pendingMutation)")
  }

  private func rejectSupersededTool(callID: String) throws {
    guard let requestID else { throw VoiceAgentError.contextChanged }
    let payload: [String: Any] = ["type": "tool_result", "request_id": requestID, "call_id": callID,
      "dataset_id": wireDatasetID, "context_id": contextID, "view_revision": viewRevision,
      "result": ["ok": false, "not_applied": true, "code": "user_changed_view"]]
    let reply = try VoiceAgentPolicy.encoded(payload)
    try ledger.finish(id: callID, reply: reply)
    enqueueCollaboration(payload)
  }

  private func observeCommand(_ event: VoiceAgentApplicationChange) {
    guard collaborationEnabled, connectionState == .ready, context != nil else { return }
    let domain = event.domain
    viewRevision += 1
    if event.phase == .committed { changedDomains.insert(domain) }
    readState = false
    if event.phase == .began {
      manualOperations.insert(event.id)
    } else {
      manualOperations.remove(event.id)
    }
    if !userIsInteracting {
      userIsInteracting = true
      speech.stopSpeaking()
      if busy { status = voiceAgentText("Paused for your changes") }
      enqueueUserChange(active: true)
    }
    interventionTask?.cancel()
    let id = generation
    interventionTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      guard let self, self.generation == id, self.manualOperations.isEmpty else { return }
      self.finishUserIntervention()
    }
  }

  private func finishUserIntervention() {
    guard let current = bridge?.context, let previous = context,
          current.datasetID == previous.datasetID, current.openingID == previous.openingID else {
      disconnect(reason: VoiceAgentError.contextChanged)
      return
    }
    context = current
    userIsInteracting = false
    enqueueUserChange(active: false)
    changedDomains = []
  }

  private func enqueueUserChange(active: Bool) {
    guard let context, let bridge else { return }
    do {
      var message: [String: Any] = ["type": "user_change", "dataset_id": context.datasetID,
        "context_id": contextID, "revision": viewRevision, "active": active, "domains": changedDomains.sorted()]
      if !active {
        let state = try bridge.stateSnapshot()
        _ = try VoiceAgentPolicy.encoded(state, limit: VoiceAgentPolicy.maximumResultBytes)
        message["state"] = state
      }
      enqueueCollaboration(message)
    } catch { disconnect(reason: VoiceAgentError.protocolViolation) }
  }

  private func enqueueCollaboration(_ message: [String: Any]) {
    let previous = collaborationSendTask
    let id = generation
    collaborationSendTask = Task { @MainActor [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self, self.generation == id else { return }
      do { try await self.send(message) }
      catch { if self.generation == id { self.disconnect(reason: VoiceAgentError.connection) } }
    }
  }

  func answerCollaboration(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let question = collaborationQuestion, let requestID, !trimmed.isEmpty, trimmed.count <= 2000 else { return }
    collaborationQuestion = nil
    append(user: true, text: trimmed)
    speech.stopSpeaking()
    status = voiceAgentText("Working…")
    do {
      try await send(["type": "collaboration_feedback", "request_id": requestID,
                      "question_id": question.id, "text": trimmed])
    } catch { disconnect(reason: VoiceAgentError.connection) }
  }

  func decideRule(_ proposal: VoiceAgentQuestion, remember: Bool) async {
    guard collaborationEnabled, ruleProposals.contains(where: { $0.id == proposal.id }) else { return }
    do {
      if remember { try settings.rememberRule(proposal.text) }
      ruleProposals.removeAll { $0.id == proposal.id }
      try await send(["type": "rule_decision", "proposal_id": proposal.id, "accepted": remember])
    } catch { errorText = error.localizedDescription }
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
