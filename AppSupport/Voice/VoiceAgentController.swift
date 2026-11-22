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
  private let expertKnowledgeSource: String?
  private var sendsTypedTools = false
  let speech = VoiceAgentSpeech()
  let demonstrations = WorkflowDemonstrationRecorder()
  let workflowUpload = WorkflowUpload()
  @Published private(set) var connectionState: ConnectionState = .disconnected
  @Published private(set) var busy = false
  @Published private(set) var canResume = false
  @Published private(set) var interrupting = false
  @Published private(set) var collaborationQuestion: VoiceAgentQuestion?
  @Published private(set) var annotationDeletion: VoiceAgentAnnotationDeletion?
  @Published private(set) var editStateDeletion: VoiceAgentEditStateDeletion?
  @Published private(set) var volumeEditApproval: VoiceAgentVolumeEdit?
  @Published private(set) var volumeBrickStatus: VoiceAgentVolumeBrickStatus?
  @Published private(set) var ruleProposals: [VoiceAgentQuestion] = []
  @Published private(set) var userIsInteracting = false
  @Published private(set) var model = ""
  @Published private(set) var datasetOpeningID: UUID?
  @Published private(set) var messages: [VoiceAgentMessage] = []
  @Published private(set) var status = voiceAgentText("Disconnected")
  @Published var errorText: String?
  @Published var isPresented = false
  @Published private(set) var capturingDemonstrationScreenshot = false
  @Published var demonstrationScreenshotFailed = false
  @Published private(set) var conversationStorageError: String?
  private var bridge: (any VoiceAgentApplicationBridge)?
  private var context: VoiceAgentContext?
  private var scopeOpening: VoiceAgentContext?
  private var connectionIdentity: VoiceAgentConnectionIdentity?
  private var contextID = ""
  private var sessionID: String?
  private var requestID: String?
  private var acknowledgedRequestID: String?
  private var lastAssistantResponse: (requestID: String, messageID: UUID)?
  private var approvalReply: CheckedContinuation<Bool, Never>?
  @Published private(set) var fileSelection: VoiceAgentFileSelection?
  @Published private(set) var importStatus: VoiceAgentImportStatus?
  private var importObservation: AnyCancellable?
  private var fileSelectionReply: CheckedContinuation<URL?, Never>?
  private var declinedFileRequestID: String?
  private var declinedDeletionRequestID: String?
  private var declinedEditStateDeletionRequestID: String?
  private var declinedVolumeEditRequestID: String?
  private var volumeBrickMonitor: Task<Void, Never>?
  private var volumeBrickContext: VoiceAgentContext?
  private let diagnosticLog = Logger(subsystem: "de.uni-due.BorgVR", category: "VoiceAgent")
  private var catalog: [[String: Any]] = []
  private var ledger = VoiceAgentCallLedger()
  private var commandHistory = VoiceAgentCommandHistory<VoiceAgentContext?>()
  private var historyOwner: (address: String, revision: UUID)?
  private let conversationStore: VoiceAgentConversationStore
  private var archiveOwner: UUID
  private var savingConversation: Bool
  private var restoredHistoryScopes: Set<VoiceAgentContext> = []
  private var conversationDirty = false
  private var conversationSaveTask: Task<Void, Never>?
  private var readState = false
  private var changesApplied = false
  private var pendingMutation = false
  private static let maximumTurnsPerConnection = 64
  private var turns = 0
  private var calls = 0
  private var events = 0
  private var maximumCalls: Int? = 24
  private var workTimeout: Double = 180
  private var queuedPrompt: String?
  private var pendingCallID: String?
  private var cancellableReadID: String?
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
  private var demonstrationObservation: AnyCancellable?
  private var demonstrationEvidenceObservation: AnyCancellable?
  private var demonstrationCaptureID: UUID?
  private var demonstrationImageTask: Task<Data, Error>?
  private var demonstrationCaptureChanged = false
  private var workflowProfileObservation: AnyCancellable?
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
  private var datasetChange: DatasetChange?

  private enum DatasetChange {
    case close(VoiceAgentContext)
    case select(VoiceAgentContext, UUID?)
    case create(VoiceAgentContext)

    func permits(_ current: VoiceAgentContext?) -> Bool {
      switch self {
        case .close(let old): return current == nil || current == old
        case .select(let old, let wanted):
          guard let current, current.hasSameOpening(as: old) else { return false }
          return current == old || wanted == nil || current.editStateID == wanted
        case .create(let old): return current?.hasSameOpening(as: old) == true
      }
    }
  }
  private var lastActivity = Date()

  init(settings: VoiceAgentSettings? = nil, conversationStore: VoiceAgentConversationStore = .init(),
       expertKnowledgeSource: String? = VoiceAgentExpertKnowledge.bundled) {
    let settings = settings ?? VoiceAgentSettings()
    self.settings = settings
    self.conversationStore = conversationStore
    self.expertKnowledgeSource = expertKnowledgeSource
    archiveOwner = settings.archiveOwnerID
    savingConversation = settings.savesConversation
    if savingConversation {
      do {
        if let saved = try conversationStore.load(owner: archiveOwner) {
          commandHistory = saved
          restoredHistoryScopes = Set(saved.scopes.compactMap { $0 })
          historyOwner = (settings.address, settings.revision)
          messages = saved.transcript.map { VoiceAgentMessage(user: $0.user, text: $0.text) }
        }
      } catch { conversationStorageError = voiceAgentText("Could not save or restore the local conversation.") }
    } else if FileManager.default.fileExists(atPath: conversationStore.file.path) {
      // Finish any pending deletion if the app stopped right after the preference changed.
      do { try conversationStore.remove() }
      catch { conversationStorageError = voiceAgentText("Could not remove the local conversation.") }
    }
    speech.onFinal = { [weak self] text in
      Task { @MainActor [weak self] in await self?.submit(text) }
    }
    speech.onFailure = { [weak self] error in self?.errorText = error.localizedDescription }
    workflowProfileObservation = workflowUpload.profileChanges.sink { [weak self] current in
      self?.clearDemonstrationCapture()
      self?.demonstrations.checkDestination(current)
    }
    settingsObservation = self.settings.objectWillChange.sink { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if !self.settings.speaks { self.speech.stopSpeaking() }
        if !self.settings.enabled { self.pauseDemonstration() }
        self.checkCommandHistoryOwner()
        self.updateConversationStoragePreference()
        self.demonstrations.checkDestination(self.workflowUpload.destination(for: self.settings))
        if let identity = self.connectionIdentity, identity != self.settings.identity { self.disconnect() }
      }
    }
  }

  deinit {
    approvalReply?.resume(returning: false)
    volumeBrickMonitor?.cancel()
    receiver?.cancel()
    heartbeat?.cancel()
    conversationSaveTask?.cancel()
    deadline?.cancel()
    toolDeadline?.cancel()
    toolTask?.cancel()
    demonstrationImageTask?.cancel()
    interventionTask?.cancel()
    collaborationSendTask?.cancel()
    contextUpdateTask?.cancel()
    contextAckDeadline?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()
  }

  func configure(bridge: any VoiceAgentApplicationBridge) {
    pauseDemonstration()
    if self.bridge != nil && !settings.savesConversation { commandHistory.clear() }
    clearVolumeBrickStatus()
    disconnect()
    self.bridge = bridge
    importObservation = bridge.importUpdates.sink { [weak self] in self?.importStatus = $0 }
    commandObservation = bridge.changes.sink { [weak self] event in
      self?.observeCommand(event)
    }
    demonstrationObservation = bridge.demonstrationActions.sink { [weak self] action in
      guard let self else { return }
      if self.capturingDemonstrationScreenshot { self.demonstrationCaptureChanged = true }
      guard self.demonstrations.active else { return }
      self.demonstrations.checkDestination(self.workflowUpload.destination(for: self.settings))
      self.demonstrations.record(action, context: self.bridge?.applicationDatasetContext)
    }
    demonstrationEvidenceObservation = bridge.demonstrationEvidenceInvalidations.sink { [weak self] _ in
      if self?.capturingDemonstrationScreenshot == true { self?.demonstrationCaptureChanged = true }
      self?.demonstrations.invalidateEvidence()
    }
    invalidateContext()
  }

  var canStartDemonstration: Bool {
    settings.enabled && !busy && !speech.isRecording && !capturingDemonstrationScreenshot &&
      !demonstrations.active && demonstrations.completed == nil && bridge?.context != nil
  }

  func startDemonstration(goal: WorkflowDemonstrationGoal, includeViewSettings: Bool = false) {
    guard canStartDemonstration, let context = bridge?.context else { return }
    let before = includeViewSettings ? bridge?.workflowViewEvidence() : nil
    demonstrations.start(goal: goal, context: context, destination: workflowUpload.destination(for: settings), before: before)
  }

  func startScreenshotDemonstration(goal: WorkflowDemonstrationGoal) async {
    guard canStartDemonstration, let bridge, let context = bridge.context,
          let before = bridge.workflowViewEvidence() else {
      demonstrationScreenshotFailed = true
      return
    }
    let destination = workflowUpload.destination(for: settings)
    let capture = beginDemonstrationCapture()
    defer { endDemonstrationCapture(capture) }
    do {
      let image = try await captureDemonstrationImage(bridge, in: context)
      guard capture == demonstrationCaptureID else { return }
      guard !demonstrationCaptureChanged, settings.enabled, !busy, !speech.isRecording, bridge.context == context,
            destination == workflowUpload.destination(for: settings) else { throw VoiceAgentError.contextChanged }
      demonstrations.start(goal: goal, context: context, destination: destination, before: before, beforeImage: image)
    } catch {
      if capture == demonstrationCaptureID { demonstrationScreenshotFailed = true }
    }
  }

  func pauseDemonstration() {
    clearDemonstrationCapture()
    demonstrations.finish(end: .interrupted)
  }

  func finishDemonstration(outcome: WorkflowDemonstration.Outcome = .unknown) async {
    guard !capturingDemonstrationScreenshot else { return }
    demonstrations.checkDestination(workflowUpload.destination(for: settings))
    demonstrations.checkContext(bridge?.applicationDatasetContext)
    var after = demonstrations.capturingEvidence ? bridge?.workflowViewEvidence() : nil
    var image: Data?
    if demonstrations.capturingScreenshots, let bridge, let context = bridge.context {
      let capture = beginDemonstrationCapture()
      defer { endDemonstrationCapture(capture) }
      do {
        guard after != nil else { throw VoiceAgentError.commandFailed }
        let captured = try await captureDemonstrationImage(bridge, in: context)
        guard !demonstrationCaptureChanged else { throw VoiceAgentError.contextChanged }
        image = captured
      } catch {
        if capture == demonstrationCaptureID { demonstrationScreenshotFailed = true }
        // A command during the screenshot can also make the numeric end state stale.
        after = demonstrations.capturingEvidence ? bridge.workflowViewEvidence() : nil
      }
      guard capture == demonstrationCaptureID else { return }
      demonstrations.checkDestination(workflowUpload.destination(for: settings))
      demonstrations.checkContext(bridge.applicationDatasetContext)
    } else if demonstrations.requestedScreenshots {
      demonstrationScreenshotFailed = true
    }
    demonstrations.finish(outcome: outcome, after: after, afterImage: image)
  }

  private func beginDemonstrationCapture() -> UUID {
    let capture = UUID()
    demonstrationCaptureID = capture
    demonstrationCaptureChanged = false
    capturingDemonstrationScreenshot = true
    return capture
  }

  private func endDemonstrationCapture(_ capture: UUID) {
    if capture == demonstrationCaptureID { clearDemonstrationCapture() }
  }

  private func clearDemonstrationCapture() {
    guard demonstrationCaptureID != nil else { return }
    demonstrationCaptureID = nil
    demonstrationImageTask?.cancel()
    demonstrationImageTask = nil
    capturingDemonstrationScreenshot = false
  }

  private func captureDemonstrationImage(_ bridge: any VoiceAgentApplicationBridge, in context: VoiceAgentContext) async throws -> Data {
    let task = Task {
      let png = try await bridge.captureWorkflowScreenshot(in: context)
      try Task.checkCancellation()
      return try Self.agentImage(png, sizes: [768, 512, 256], maximumBytes: 512 * 1024).data
    }
    demonstrationImageTask = task
    return try await task.value
  }

  func queueDemonstration(_ episode: WorkflowDemonstration) async {
    guard demonstrations.screenshotExport == nil, episode.id == demonstrations.completed?.id,
          let owner = demonstrations.destination,
          workflowUpload.enqueue(episode, capturedFor: owner, settings: settings)
    else { return }
    demonstrations.discard(id: episode.id)
    await workflowUpload.sync(settings: settings)
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
    demonstrations.checkContext(bridge?.applicationDatasetContext)
    if let tracked = volumeBrickContext, bridge?.applicationDatasetContext != tracked { clearVolumeBrickStatus() }
    let current = bridge?.context
    rebindStoredHistory(to: current)
    let editing = userIsInteracting && changedDomains.contains("volume") &&
      (current == nil || current?.openingID == context?.openingID) &&
      bridge?.datasetID == context?.datasetID
    datasetOpeningID = bridge?.rendererReady == true ? (current?.openingID ?? (editing ? context?.openingID : nil)) : nil
    if let datasetChange {
      if !datasetChange.permits(bridge?.applicationDatasetContext) { disconnect(reason: VoiceAgentError.contextChanged) }
      return
    }
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
    let available = !hasDataset && bridge.applicationDatasetContext != nil
      ? tools.filter { $0["name"] as? String != "open_dataset" } : tools
    return VoiceAgentPolicy.wireCatalog(available, typed: sendsTypedTools)
  }

  private var wireDatasetID: Any { context?.datasetID as Any? ?? NSNull() }

  private func updateContext(_ current: VoiceAgentContext?) {
    canResume = false
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
    flushConversationSave()
    if let annotationDeletion { resolveAnnotationDeletion(id: annotationDeletion.id, accepted: false) }
    if let editStateDeletion { resolveEditStateDeletion(id: editStateDeletion.id, accepted: false) }
    if let volumeEditApproval { resolveVolumeEditApproval(id: volumeEditApproval.id, accepted: false) }
    if let fileSelection { resolveFileSelection(id: fileSelection.id, url: nil) }
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
    datasetChange = nil
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
    cancellableReadID = nil
    changesApplied = false
    pendingMutation = false
    canResume = false
    catalog = []
    sendsTypedTools = false
    ledger = VoiceAgentCallLedger()
    busy = false
    connectionState = .disconnected
    status = voiceAgentText("Disconnected")
    speech.cancel()
    if let reportedReason { errorText = reportedReason.localizedDescription }
  }

  func newConversation() {
    disconnect()
    commandHistory.clear()
    restoredHistoryScopes.removeAll()
    removeSavedConversation()
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
    checkCommandHistoryOwner()
    updateConversationStoragePreference()
    historyOwner = (settings.address, settings.revision)
    rebindStoredHistory(to: captured)
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
    // The socket can outlive a turn. Only the per-turn timer should enforce its work budget.
    let resourceTimeout = 60 + Self.maximumTurnsPerConnection * (settings.workMinutes * 60 + 300)
    let session = transport.session(resourceTimeout: Double(resourceTimeout))
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
    let features = await VoiceAgentExpertKnowledge.serverFeatures(endpoint: endpoint, session: session, transport: transport)
    guard generation == id, bridge.context == captured else { throw CancellationError() }
    sendsTypedTools = features.typedTools
    catalog = availableTools()
    let requestedSeconds = (features.timeOnlyTurns ? settings.workMinutes : min(settings.workMinutes, 120)) * 60
    var executionLimits = ["timeout_seconds": requestedSeconds]
    if !features.timeOnlyTurns { executionLimits["max_calls"] = settings.maximumCalls }
    var hello: [String: Any] = ["type": "hello", "protocol": 1, "dataset_id": wireDatasetID, "application_session": true,
                               "dataset_opening": true,
                               "context_id": contextID, "tools": catalog,
                               "collaboration": true, "knowledge": settings.knowledgeRules.map(\.text),
                               "execution_limits": executionLimits]
    if features.expertKnowledge, let expertKnowledge = expertKnowledgeSource {
      hello["expert_knowledge_toml"] = expertKnowledge
    }
    try await send(hello)
    let ready = try decode(await socket.receive())
    guard generation == id, bridge.context == captured else { throw CancellationError() }
    guard ready["application_session"] as? Bool == true, ready["dataset_opening"] as? Bool == true
    else { throw VoiceAgentError.serverUpdateRequired }
    guard ready["type"] as? String == "ready", let version = ready["protocol"] as? Int, version == 1,
          let sessionID = ready["session_id"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 128,
          let capabilities = ready["capabilities"] as? [String: Any],
          capabilities["vision"] as? Bool == true, capabilities["tool_calling"] as? Bool == true,
          let accepted = ready["tools"] as? [String], accepted.count <= VoiceAgentPolicy.maximumTools,
          accepted.contains("get_application_state"), Set(accepted).count == accepted.count,
          Set(accepted).isSubset(of: Set(catalog.compactMap { $0["name"] as? String }))
    else { throw VoiceAgentError.protocolViolation }
    self.sessionID = sessionID
    collaborationEnabled = ready["collaboration"] as? Bool == true
    if let limits = ready["execution_limits"] as? [String: Any] {
      guard let seconds = limits["timeout_seconds"] as? Double, seconds.isFinite,
            (1...Double(requestedSeconds)).contains(seconds)
      else { throw VoiceAgentError.protocolViolation }
      if features.timeOnlyTurns {
        guard limits["max_calls"] == nil else { throw VoiceAgentError.protocolViolation }
        maximumCalls = nil
      } else {
        guard let calls = limits["max_calls"] as? Int, (24...settings.maximumCalls).contains(calls)
        else { throw VoiceAgentError.protocolViolation }
        maximumCalls = calls
      }
      workTimeout = seconds
    } else {
      guard !features.timeOnlyTurns else { throw VoiceAgentError.protocolViolation }
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
    pauseDemonstration()
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
      if let editStateDeletion { resolveEditStateDeletion(id: editStateDeletion.id, accepted: false) }
      if let volumeEditApproval { resolveVolumeEditApproval(id: volumeEditApproval.id, accepted: false) }
      if let fileSelection { resolveFileSelection(id: fileSelection.id, url: nil) }
      resumeQueuedPromptIfSafe()
      return
    }
    await sendPrompt(trimmed)
  }

  func resumePartialTask() async {
    guard canResume, !busy, connectionState == .ready else { return }
    await submit(voiceAgentText("Continue"))
  }

  private func sendPrompt(_ trimmed: String, preserving transcript: [VoiceAgentMessage]? = nil) async {
    var operationGeneration: UUID?
    do {
      try await establishConnection(replacing: transcript != nil)
      operationGeneration = generation
      try requireContext()
      pauseDemonstration()
      if let transcript { messages = transcript }
      guard turns < Self.maximumTurnsPerConnection else { throw VoiceAgentError.protocolViolation }
      turns += 1
      calls = 0
      events = 0
      readState = false
      changesApplied = false
      pendingMutation = false
      let id = UUID().uuidString
      requestID = id
      busy = true
      canResume = false
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
    if !accepted { declinedDeletionRequestID = requestID }
    finishLocalApproval(accepted)
  }

  private func requestAnnotationDeletion(_ preview: VoiceAgentAnnotationDeletion) async -> Bool {
    await withCheckedContinuation { continuation in
      approvalReply = continuation
      annotationDeletion = preview
      status = voiceAgentText("Waiting for deletion approval")
    }
  }

  func resolveVolumeEditApproval(id: UUID, accepted: Bool, alwaysApprove: Bool = false) {
    guard volumeEditApproval?.id == id else { return }
    if accepted && alwaysApprove { settings.confirmsVolumeEdits = false }
    volumeEditApproval = nil
    if !accepted { declinedVolumeEditRequestID = requestID }
    finishLocalApproval(accepted)
  }

  private func requestVolumeEditApproval(_ preview: VoiceAgentVolumeEdit) async -> Bool {
    await withCheckedContinuation { continuation in
      approvalReply = continuation
      volumeEditApproval = preview
      status = voiceAgentText("Waiting for volume edit approval")
    }
  }

  private func finishLocalApproval(_ accepted: Bool) {
    let continuation = approvalReply
    approvalReply = nil
    status = voiceAgentText("Working…")
    continuation?.resume(returning: accepted)
  }

  func resolveEditStateDeletion(id: UUID, accepted: Bool) {
    guard editStateDeletion?.id == id else { return }
    editStateDeletion = nil
    if !accepted { declinedEditStateDeletionRequestID = requestID }
    finishLocalApproval(accepted)
  }

  private func requestEditStateDeletion(_ preview: VoiceAgentEditStateDeletion) async -> Bool {
    await withCheckedContinuation { continuation in
      approvalReply = continuation
      editStateDeletion = preview
      status = voiceAgentText("Waiting for deletion approval")
    }
  }

  func resolveFileSelection(id: UUID, url: URL?) {
    guard fileSelection?.id == id else { return }
    fileSelection = nil
    if url == nil { declinedFileRequestID = requestID }
    let continuation = fileSelectionReply
    fileSelectionReply = nil
    status = voiceAgentText("Working…")
    continuation?.resume(returning: url)
  }

  func cancelImport(id: UUID) { bridge?.cancelImport(id: id) }

  var presentedFileSelection: VoiceAgentFileSelection? { fileSelection ?? importStatus?.fileSelection }

  func resolvePresentedFileSelection(id: UUID, url: URL?) {
    if fileSelection?.id == id { resolveFileSelection(id: id, url: url) }
    else { bridge?.resolveImportFileSelection(id: id, url: url) }
  }

  private func requestFileSelection(_ selection: VoiceAgentFileSelection) async -> URL? {
    guard !Task.isCancelled, declinedFileRequestID != requestID else { return nil }
    return await withCheckedContinuation { continuation in
      fileSelectionReply = continuation
      fileSelection = selection
      status = voiceAgentText("Waiting for file selection")
    }
  }

  private func trackVolumeBricks() {
    clearVolumeBrickStatus()
    guard let expected = bridge?.context, let initial = bridge?.volumeBrickStatus() else { return }
    volumeBrickContext = expected
    volumeBrickStatus = initial
    guard initial != .ready else { return }
    volumeBrickMonitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        guard let self else { return }
        guard self.bridge?.applicationDatasetContext == expected else { self.clearVolumeBrickStatus(); return }
        guard let current = self.bridge?.volumeBrickStatus() else { continue }
        if self.volumeBrickStatus != current { self.volumeBrickStatus = current }
        if current == .ready { self.volumeBrickMonitor = nil; return }
      }
    }
  }

  private func clearVolumeBrickStatus() {
    volumeBrickMonitor?.cancel()
    volumeBrickMonitor = nil
    volumeBrickContext = nil
    volumeBrickStatus = nil
  }

  private func requireContext() throws {
    if let datasetChange {
      guard datasetChange.permits(bridge?.applicationDatasetContext), settings.enabled,
            connectionIdentity == settings.identity else { throw VoiceAgentError.contextChanged }
      return
    }
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
            let accepted = event["tools"] as? [String], accepted.count <= VoiceAgentPolicy.maximumTools,
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
    if let maximumCalls {
      events += 1
      guard events <= maximumCalls * 4 + 128 else { throw VoiceAgentError.protocolViolation }
    }
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
        collaborationQuestion = nil
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
        guard var text = event["text"] as? String, text.count <= 8192, let final = event["final"] as? Bool
        else { throw VoiceAgentError.protocolViolation }
        if let partial = event["partial"] as? [String: Any], final,
           let count = partial["confirmed_volume_edits"] as? Int, (0...65536).contains(count) {
          canResume = true
          text = voiceAgentText("I completed part of the task, but couldn't finish or check the whole result.")
          if count > 0 {
            text += " " + String(format: voiceAgentText("Confirmed volume edit commands: %lld."), Int64(count))
          }
          text += "\n\n" + voiceAgentText("Would you like me to continue?")
        } else if final, event["resume_unavailable"] as? Bool == true {
          text = voiceAgentText("There is no paused task in this session. Tell me what you would like me to do next.")
        }
        if final {
          commandHistory.appendMessage(scope: context, user: false, text: text)
          scheduleConversationSave()
        }
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
        guard let callID = event["call_id"] as? String else { throw VoiceAgentError.protocolViolation }
        if ledger.entries[callID]?.completed == true { return }
        guard callID == pendingCallID else { throw VoiceAgentError.protocolViolation }
        if cancellableReadID == callID {
          try await retireRead(callID, sendResult: false)
        } else {
          showTurnFailure(uncertain: pendingMutation)
        }
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
        showTurnFailure(uncertain: pendingMutation || (changesApplied && event["requires_reconnect"] as? Bool == true))
      default: throw VoiceAgentError.protocolViolation
    }
  }

  private func showTurnFailure(uncertain: Bool) {
    let failedContext = context
    let text: String
    if uncertain {
      text = voiceAgentText("I can't tell whether the last change was fully applied. Please check the view before continuing.")
    } else if changesApplied {
      text = voiceAgentText("I made some changes, but can't safely continue. Please check the view.")
    } else {
      text = voiceAgentText("I couldn't complete the task and didn't make any changes. Try asking for one step at a time.")
    }
    disconnect()
    commandHistory.appendMessage(scope: failedContext, user: false, text: text)
    scheduleConversationSave()
    append(user: false, text: text)
    if settings.speaks { speech.speak(text, rateMultiplier: settings.speechRateMultiplier) }
  }

  private func retireRead(_ callID: String, sendResult: Bool) async throws {
    guard callID == pendingCallID, callID == cancellableReadID, let requestID else { return }
    let payload: [String: Any] = ["type": "tool_result", "request_id": requestID,
      "call_id": callID, "dataset_id": wireDatasetID, "context_id": contextID,
      "view_revision": viewRevision,
      "result": ["ok": false, "not_applied": true, "code": "read_timeout"]]
    let encoded = try VoiceAgentPolicy.encoded(payload)
    try ledger.finish(id: callID, reply: encoded)
    toolTask?.cancel()
    toolTask = nil
    toolDeadline?.cancel()
    toolDeadline = nil
    cancellableReadID = nil
    pendingCallID = nil
    if sendResult { try await sendRaw(encoded) }
    resumeQueuedPromptIfSafe()
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
    guard pendingCallID == nil else { throw VoiceAgentError.protocolViolation }
    if let maximumCalls {
      guard calls < maximumCalls else { throw VoiceAgentError.protocolViolation }
      calls += 1
    }
    let expectedRevision = event["view_revision"] as? Int
    if collaborationEnabled && (userIsInteracting || expectedRevision != viewRevision) {
      try rejectSupersededTool(callID: callID)
      return
    }
    guard VoiceAgentPolicy.reads.contains(name) || readState else { throw VoiceAgentError.protocolViolation }
    pendingCallID = callID
    let read = VoiceAgentPolicy.reads.contains(name)
    cancellableReadID = read ? callID : nil
    let deletionTool = ["clear_annotations", "remove_object", "remove_measurement"].contains(name)
    let editStateDeletionTool = name == "delete_edit_state"
    let volumeEditTool = name == "edit_volume"
    let fileTool = VoiceAgentPolicy.fileTools.contains(name)
    pendingMutation = !VoiceAgentPolicy.reads.contains(name) && !deletionTool && !editStateDeletionTool && !volumeEditTool && !fileTool
    if name == "open_dataset" {
      openingPreviousContext = bridge?.applicationDatasetContext
      openingTarget = arguments["id"] as? String
    }
    let id = generation
    let request = requestID!
    toolDeadline = Task { @MainActor [weak self] in
      let seconds = name == "open_dataset" ? 330 : deletionTool || editStateDeletionTool || fileTool ? 300 : volumeEditTool ? 125 : name == "search_datasets" ? 75 : name == "create_edit_state" ? 135 : 40
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      guard let self, self.generation == id, self.pendingCallID == callID else { return }
      self.toolDeadline = nil
      if read {
        do { try await self.retireRead(callID, sendResult: true) }
        catch { if self.generation == id { self.disconnect(reason: VoiceAgentError.connection) } }
      } else {
        self.disconnect(reason: VoiceAgentError.timedOut)
      }
    }
    toolTask = Task { @MainActor [weak self] in
      guard let self, let bridge = self.bridge else { return }
      do {
        try self.requireContext()
        try Task.checkCancellation()
        if self.collaborationEnabled, self.userIsInteracting || expectedRevision != self.viewRevision {
          self.pendingMutation = false
          self.pendingCallID = nil
          self.cancellableReadID = nil
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
        if name == VoiceAgentPolicy.commandHistoryTool {
          try validate()
          self.checkCommandHistoryOwner()
          result = ["structuredContent": self.commandHistory.lookup(scope: self.context, query: arguments)]
        } else if deletionTool, self.declinedDeletionRequestID == request {
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
        } else if editStateDeletionTool {
          if self.declinedEditStateDeletionRequestID == request {
            result = self.rejectedVolumeEdit("user_declined", "The user declined deletion of an edit state in this request.")
          } else if let stateID = (arguments["id"] as? String).flatMap(UUID.init(uuidString:)),
                    let preview = bridge.prepareEditStateDeletion(id: stateID) {
            if await self.requestEditStateDeletion(preview) {
              guard self.generation == id, self.requestID == request, !Task.isCancelled else { return }
              self.pendingMutation = true
              result = try await bridge.executeEditStateDeletion(preview, validateContext: validate)
            } else {
              result = self.rejectedVolumeEdit("user_declined", "The user did not approve deletion. Do not ask again in this request.")
            }
          } else {
            result = self.rejectedVolumeEdit("edit_state_unavailable", "Only an inactive personal saved edit state may be deleted.")
          }
        } else if volumeEditTool {
          if self.declinedVolumeEditRequestID == request {
            result = self.rejectedVolumeEdit("user_declined", "The user declined a volume edit in this request.")
          } else {
            let preview: VoiceAgentVolumeEdit?
            do { preview = try bridge.prepareVolumeEdit(arguments: arguments) }
            catch { preview = nil }
            if let preview {
              let approved = self.settings.confirmsVolumeEdits ? await self.requestVolumeEditApproval(preview) : true
              if approved {
                guard self.generation == id, self.requestID == request, !Task.isCancelled else { return }
                self.pendingMutation = true
                result = try await bridge.executeVolumeEdit(preview, validateContext: validate)
              } else {
                result = self.rejectedVolumeEdit("user_declined", "The user did not approve this volume edit. Do not ask again in this request.")
              }
            } else {
              result = self.rejectedVolumeEdit("volume_edit_unavailable",
                "No edit was applied. Check edit availability, SharePlay, active export, and sample bounds in physical meters.")
            }
          }
        } else if name == "open_dataset", let target = self.openingTarget {
          result = try await bridge.openDataset(id: target, validateContext: validate, didBegin: { opened in
            guard self.generation == id, self.requestID == request, self.openingTarget == opened.datasetID,
                  self.openingContext == nil || self.openingContext?.hasSameOpening(as: opened) == true else { throw VoiceAgentError.contextChanged }
            self.openingContext = opened
          })
        } else if fileTool {
          result = try await bridge.executeFileTool(name: name, arguments: arguments, select: { selection in
            await self.requestFileSelection(selection)
          }, validateContext: validate, willCommit: { self.pendingMutation = true })
        } else {
          if let previous = self.context {
            if name == "close_dataset" { self.datasetChange = .close(previous) }
            if name == "select_edit_state" {
              self.datasetChange = .select(previous, (arguments["id"] as? String).flatMap(UUID.init(uuidString:)))
            }
            if name == "create_edit_state" { self.datasetChange = .create(previous) }
          }
          result = try await bridge.executeTool(name: name, arguments: arguments, validateContext: validate)
        }
        if read { try Task.checkCancellation() }
        guard result["isError"] as? Bool != true else { throw VoiceAgentError.commandFailed }
        let notApplied = (result["structuredContent"] as? [String: Any])?["not_applied"] as? Bool == true
        if self.generation == id, self.requestID == request {
          if volumeEditTool && !notApplied { self.trackVolumeBricks() }
          if self.pendingMutation && !notApplied { self.changesApplied = true }
          self.pendingMutation = false
        }
        try Task.checkCancellation()
        guard self.generation == id, self.requestID == request else { return }
        try self.requireContext()
        var payload: [String: Any] = ["type": "tool_result", "request_id": request,
          "call_id": callID, "dataset_id": self.wireDatasetID, "context_id": self.contextID]
        let previousScope = self.context
        if VoiceAgentPolicy.datasetTransitions.contains(name), !notApplied {
          let next = bridge.context
          switch name {
            case "open_dataset":
              guard let opened = self.openingContext, next == opened else { throw VoiceAgentError.contextChanged }
            case "close_dataset":
              guard next == nil, bridge.applicationDatasetContext == nil, bridge.datasetID == nil else { throw VoiceAgentError.contextChanged }
            case "select_edit_state":
              let receipt = result["structuredContent"] as? [String: Any]
              let wanted = (arguments["id"] as? String).flatMap(UUID.init(uuidString:))
              guard let next, let previousScope, next.hasSameOpening(as: previousScope), next != previousScope,
                    (receipt?["activeStateID"] as? String).flatMap(UUID.init(uuidString:)) == wanted else {
                throw VoiceAgentError.contextChanged
              }
            case "create_edit_state":
              let receipt = result["structuredContent"] as? [String: Any]
              guard let next, let previousScope, next.hasSameOpening(as: previousScope),
                    let created = (receipt?["createdStateID"] as? String).flatMap(UUID.init(uuidString:)),
                    created != previousScope.editStateID, next.editStateID == created,
                    (receipt?["activeStateID"] as? String).flatMap(UUID.init(uuidString:)) == created else {
                throw VoiceAgentError.contextChanged
              }
            default: throw VoiceAgentError.protocolViolation
          }
          self.context = next
          self.scopeOpening = next
          self.datasetOpeningID = next?.openingID
          self.contextID = UUID().uuidString
          self.catalog = self.availableTools()
          self.readState = false
          self.viewRevision = 0
          self.collaborationQuestion = nil
          self.ruleProposals = []
          self.changedDomains = []
          payload["dataset_transition"] = ["dataset_id": self.wireDatasetID, "context_id": self.contextID, "tools": self.catalog]
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
        self.datasetChange = nil
        if self.collaborationEnabled { payload["view_revision"] = expectedRevision ?? 0 }
        if name == "capture_screenshot" {
          guard let contents = result["content"] as? [[String: Any]],
                let encoded = contents.first?["data"] as? String,
                let png = Data(base64Encoded: encoded) else { throw VoiceAgentError.imageTooLarge }
          let image = try Self.agentImage(png)
          payload["image_png_base64"] = image.data.base64EncodedString()
          let metadata = result["structuredContent"] as? [String: Any]
          var imageResult: [String: Any] = ["width": image.width, "height": image.height,
                                            "renderedFrame": metadata?["renderedFrame"] ?? 0]
          if let screenshotID = metadata?["screenshotId"] as? String {
            imageResult["screenshotId"] = screenshotID
          }
          payload["result"] = imageResult
        } else {
          let state = VoiceAgentPolicy.compactResult(result["structuredContent"] as? [String: Any] ?? [:], tool: name)
          _ = try VoiceAgentPolicy.encoded(state, limit: VoiceAgentPolicy.maximumResultBytes)
          payload["result"] = state
        }
        let reply = try VoiceAgentPolicy.encoded(payload)
        try self.ledger.finish(id: callID, reply: reply)
        if !notApplied, let output = payload["result"] as? [String: Any] {
          // A confirmed local result still exists if sending its reply loses the socket.
          // Image bytes are on a separate wire field and are deliberately never retained.
          self.commandHistory.append(scope: self.context, tool: name, arguments: arguments, result: output)
          if name == "close_dataset", previousScope != self.context {
            self.commandHistory.append(scope: previousScope, tool: name, arguments: arguments, result: output)
          }
          if name != VoiceAgentPolicy.commandHistoryTool { self.scheduleConversationSave() }
        }
        if name == "get_application_state" { self.readState = !self.userIsInteracting && (!self.collaborationEnabled || expectedRevision == self.viewRevision) }
        self.pendingCallID = nil
        self.cancellableReadID = nil
        self.toolTask = nil
        self.toolDeadline?.cancel()
        self.toolDeadline = nil
        try await self.sendRaw(reply)
        self.resumeQueuedPromptIfSafe()
      } catch {
        guard self.generation == id else { return }
        if read, Task.isCancelled, self.ledger.entries[callID]?.completed == true { return }
        self.logFailure(error, operation: name)
        // A thrown mutation may already have committed. Terminate rather than invite a retry.
        self.disconnect(reason: error is VoiceAgentError ? error : VoiceAgentError.commandFailed)
      }
    }
  }

  private func rejectedVolumeEdit(_ code: String, _ note: String) -> [String: Any] {
    ["structuredContent": ["ok": false, "not_applied": true, "code": code, "note": note]]
  }

  private func checkCommandHistoryOwner() {
    if let owner = historyOwner,
       (!settings.enabled && !settings.savesConversation) || owner.address != settings.address || owner.revision != settings.revision {
      commandHistory.clear()
      restoredHistoryScopes.removeAll()
      historyOwner = nil
    }
  }

  private func rebindStoredHistory(to current: VoiceAgentContext?) {
    guard let current, let editState = current.editStateID, !restoredHistoryScopes.isEmpty else { return }
    let matching = restoredHistoryScopes.filter { $0.datasetID == current.datasetID && $0.editStateID == editState }
    guard !matching.isEmpty else { return }
    // Only a saved, matching edit state may see history from a previous application opening.
    commandHistory.rebindScopes { $0.map(matching.contains) == true ? current : $0 }
    restoredHistoryScopes.subtract(matching)
    scheduleConversationSave()
  }

  private func updateConversationStoragePreference() {
    let ownerChanged = archiveOwner != settings.archiveOwnerID
    if ownerChanged || (savingConversation && !settings.savesConversation) { removeSavedConversation() }
    archiveOwner = settings.archiveOwnerID
    if !savingConversation && settings.savesConversation { scheduleConversationSave() }
    savingConversation = settings.savesConversation
  }

  private func scheduleConversationSave() {
    guard settings.savesConversation, !commandHistory.isEmpty else { return }
    conversationDirty = true
    guard conversationSaveTask == nil else { return }
    conversationSaveTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      self?.flushConversationSave()
    }
  }

  private func flushConversationSave() {
    conversationSaveTask?.cancel()
    conversationSaveTask = nil
    guard conversationDirty, settings.savesConversation, archiveOwner == settings.archiveOwnerID else { return }
    do {
      try conversationStore.save(commandHistory, owner: archiveOwner)
      conversationDirty = false
      conversationStorageError = nil
    } catch { conversationStorageError = voiceAgentText("Could not save or restore the local conversation.") }
  }

  private func removeSavedConversation() {
    conversationSaveTask?.cancel()
    conversationSaveTask = nil
    conversationDirty = false
    do {
      try conversationStore.remove()
      conversationStorageError = nil
    } catch { conversationStorageError = voiceAgentText("Could not remove the local conversation.") }
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

  static func agentImage(_ png: Data, sizes: [Int] = [1024, 768, 512, 256],
                         maximumBytes: Int = 2 * 1024 * 1024) throws -> (data: Data, width: Int, height: Int) {
    guard png.count <= 64 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1
    else { throw VoiceAgentError.imageTooLarge }
    for size in sizes {
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw VoiceAgentError.imageTooLarge
      }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { throw VoiceAgentError.imageTooLarge }
      CGImageDestinationAddImage(destination, image, nil)
      if CGImageDestinationFinalize(destination), data.length <= maximumBytes {
        return (data as Data, image.width, image.height)
      }
    }
    throw VoiceAgentError.imageTooLarge
  }

  private func append(user: Bool, text: String) {
    if user {
      commandHistory.appendMessage(scope: context, user: true, text: text)
      scheduleConversationSave()
    }
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
