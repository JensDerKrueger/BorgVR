import Combine
import Foundation

struct VoiceAgentMessage: Identifiable {
  let id = UUID()
  let user: Bool
  let text: String
  var confirmedChanges: Int? = nil
}

/// UI, speech and human consent. Planning and model context live in the assistant core.
@MainActor
final class VoiceAgentController: ObservableObject, AssistantWorkspace {
  enum ConnectionState { case disconnected, connecting, ready }
  let settings: VoiceAgentSettings
  let speech = VoiceAgentSpeech()
  @Published private(set) var connectionState: ConnectionState = .disconnected
  @Published private(set) var busy = false
  @Published private(set) var annotationDeletion: VoiceAgentAnnotationDeletion?
  @Published private(set) var editStateDeletion: VoiceAgentEditStateDeletion?
  @Published private(set) var volumeEditApproval: VoiceAgentVolumeEdit?
  @Published private(set) var volumeBrickStatus: VoiceAgentVolumeBrickStatus?
  @Published private(set) var importStatus: VoiceAgentImportStatus?
  @Published private(set) var fileSelection: VoiceAgentFileSelection?
  @Published private(set) var model = ""
  @Published private(set) var messages: [VoiceAgentMessage] = []
  @Published private(set) var status = voiceAgentText("Disconnected")
  @Published private(set) var conversationStorageError: String?
  @Published var errorText: String?
  @Published var isPresented = false

  private var bridge: (any VoiceAgentApplicationBridge)?
  private var observedContext: VoiceAgentContext?
  private var revision: UInt64 = 0
  private var manualOperations = Set<UUID>()
  private var scopeTransition = false
  private var settingsIdentity: VoiceAgentConnectionIdentity?
  private var subscriptions = Set<AnyCancellable>()
  private var settingsSubscription: AnyCancellable?
  private var running: Task<Void, Never>?
  private var runningID: UUID?
  private var deadline: Task<Void, Never>?
  private var bricks: Task<Void, Never>?
  private var generation = UUID()
  private var declined: Set<String> = []
  private var approval: CheckedContinuation<Bool, Never>?
  private var selectedFile: CheckedContinuation<URL?, Never>?
  private var continuationGoal: String?
  private var continuationCore: BorgVRAssistantCore?
  private var history = VoiceAgentCommandHistory<VoiceAgentContext?>()
  private var storeOwner: UUID
  private let conversationStore: VoiceAgentConversationStore

  init(settings: VoiceAgentSettings? = nil, conversationStore: VoiceAgentConversationStore = .init()) {
    let settings = settings ?? VoiceAgentSettings()
    self.settings = settings
    self.conversationStore = conversationStore
    storeOwner = settings.archiveOwnerID
    if settings.savesConversation {
      do {
        if let archive = try conversationStore.load(owner: storeOwner) {
          history = archive
          messages = archive.transcript.map { .init(user: $0.user, text: $0.text) }
        }
      } catch { conversationStorageError = voiceAgentText("Could not save or restore the local conversation.") }
    }
    speech.onFinal = { [weak self] text in Task { @MainActor in await self?.submit(text) } }
    speech.onFailure = { [weak self] error in self?.errorText = error.localizedDescription }
    settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.settingsChanged() }
    }
  }

  var isAvailable: Bool { bridge != nil && settings.enabled && settings.selectedProfileID != nil }
  var evidenceVersion: AssistantEvidenceVersion { .init(opening: bridge?.applicationDatasetContext?.openingID, revision: revision) }

  func configure(bridge: any VoiceAgentApplicationBridge) {
    disconnect()
    subscriptions.removeAll()
    self.bridge = bridge
    observedContext = bridge.applicationDatasetContext
    bridge.importUpdates.sink { [weak self] in self?.importStatus = $0 }.store(in: &subscriptions)
    bridge.changes.sink { [weak self] event in
      guard let self else { return }
      self.revision &+= 1
      if event.phase == .began { self.manualOperations.insert(event.id) }
      else { self.manualOperations.remove(event.id) }
      if self.approval != nil { self.resolveApproval(false) }
    }.store(in: &subscriptions)
  }

  func invalidateContext() {
    let next = bridge?.applicationDatasetContext
    guard observedContext != next else { return }
    observedContext = next
    guard !scopeTransition else { return }
    revision &+= 1
    manualOperations.removeAll()
    bricks?.cancel()
    volumeBrickStatus = nil
    if busy { cancel() }
  }

  func waitForUser() async throws {
    while !manualOperations.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
    try Task.checkCancellation()
    guard settingsIdentity == settings.identity else { throw CancellationError() }
  }

  func snapshot() throws -> [String: Any] { try bridge?.stateSnapshot() ?? [:] }

  func operations() -> [[String: Any]] {
    guard let bridge else { return [] }
    #if os(visionOS)
    let vision = true
    #else
    let vision = false
    #endif
    return VoiceAgentPolicy.catalog(bridge.toolDefinitions, vision: vision, transferFunctions: bridge.hasTransferFunctions,
      images: settings.sharesProviderImages, datasetReady: bridge.rendererReady && bridge.context != nil)
  }

  func connect() async {
    guard isAvailable, settings.hasToken, connectionState == .disconnected, !busy else { return }
    let identity = settings.identity
    settingsIdentity = identity
    connectionState = .connecting
    do {
      let client = try settings.modelClient()
      let name = try await client.verifyConnection()
      guard identity == settings.identity, settingsIdentity == identity else { throw CancellationError() }
      model = name
      connectionState = .ready
      if !busy { status = voiceAgentText("Connected") }
      errorText = nil
    } catch {
      if settingsIdentity == identity && settings.identity == identity {
        connectionState = .disconnected
        status = voiceAgentText("Disconnected")
        if !(error is CancellationError) { errorText = error.localizedDescription }
      }
    }
  }

  func submit(_ raw: String) async {
    let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isAvailable, !prompt.isEmpty, prompt.utf8.count <= 8192 else { return }
    if let old = running {
      cancel()
      let wait = generation
      await old.value
      guard generation == wait else { return }
    }
    // A provider switch must discard the old transcript before building any network request.
    reconcileArchiveOwner()
    let id = UUID()
    generation = id
    runningID = id
    declined.removeAll()
    settingsIdentity = settings.identity
    let background = messages.suffix(6).map { ($0.user ? "User: " : "Assistant: ") + String($0.text.prefix(1200)) }
    let request = continuationGoal.map { "Previous objective: \($0)\nUser reply: \(prompt)" } ?? prompt
    let previousGoal = continuationGoal ?? prompt
    let previousCore = continuationCore
    continuationGoal = nil
    continuationCore = nil
    append(prompt, user: true)
    busy = true
    errorText = nil
    status = voiceAgentText("Working…")
    running = Task { @MainActor [weak self] in
      guard let self else { return }
      var core: BorgVRAssistantCore?
      do {
        let client = try self.settings.modelClient()
        let knowledge = try self.settings.knowledge()
        let assistant = previousCore ?? BorgVRAssistantCore(workspace: self, model: client, knowledge: knowledge,
                                                             imagesAllowed: self.settings.sharesProviderImages)
        core = assistant
        let result = try await assistant.run(request, history: background, timeLimit: .seconds(self.settings.workMinutes * 60)) { _ in
          self.status = voiceAgentText("Comparing volume previews…")
        }
        guard self.generation == id, !Task.isCancelled else { return }
        if !client.model.isEmpty { self.model = client.model }
        self.connectionState = .ready
        if result.awaitingAnswer {
          self.continuationGoal = previousGoal
          self.continuationCore = assistant
        }
        self.append(result.text, user: false, confirmedChanges: result.applied)
        if self.settings.speaks { self.speech.speak(result.text, rateMultiplier: self.settings.speechRateMultiplier) }
      } catch is CancellationError { }
      catch {
        guard self.generation == id else { return }
        if core?.effectInFlight == true { self.errorText = VoiceAgentError.completionUncertain.localizedDescription }
        else if (core?.applied ?? 0) > 0 { self.errorText = VoiceAgentError.changesAppliedVerificationFailed.localizedDescription }
        else { self.errorText = (error as? VoiceAgentError ?? .connection).localizedDescription }
      }
    }
    let task = running
    deadline = Task { @MainActor [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: .seconds(self.settings.workMinutes * 60)) } catch { return }
      guard self.generation == id else { return }
      self.cancel()
      self.errorText = VoiceAgentError.timedOut.localizedDescription
    }
    await task?.value
    // A replacement request waits for this task to give up its local command slot.
    guard runningID == id else { return }
    runningID = nil
    deadline?.cancel()
    deadline = nil
    running = nil
    busy = false
    if generation == id { status = voiceAgentText(connectionState == .ready ? "Connected" : "Disconnected") }
  }

  func execute(_ name: String, arguments: [String: Any], at version: AssistantEvidenceVersion) async throws -> [String: Any] {
    guard let bridge else { throw VoiceAgentError.commandFailed }
    let id = generation
    var scope = bridge.applicationDatasetContext
    let transitions = VoiceAgentPolicy.datasetTransitions.contains(name)
    try check(id, version)
    if transitions { scopeTransition = true }
    defer {
      if transitions {
        scopeTransition = false
        observedContext = bridge.applicationDatasetContext
        revision &+= 1
        manualOperations.removeAll()
      }
    }
    let validate = {
      try Task.checkCancellation()
      guard self.generation == id, self.settingsIdentity == self.settings.identity,
            self.manualOperations.isEmpty, self.revision == version.revision else { throw VoiceAgentError.contextChanged }
      let now = bridge.applicationDatasetContext
      if name == "close_dataset", now == nil { return }
      if ["select_edit_state", "create_edit_state"].contains(name), let scope, now?.hasSameOpening(as: scope) == true { return }
      guard now == scope else { throw VoiceAgentError.contextChanged }
    }
    let result: [String: Any]
    if name == "open_dataset", let destination = arguments["id"] as? String {
      result = try await bridge.openDataset(id: destination, validateContext: validate, didBegin: { opened in
        try Task.checkCancellation()
        guard self.generation == id else { throw CancellationError() }
        scope = opened
      })
    } else if name == VoiceAgentPolicy.commandHistoryTool {
      result = ["structuredContent": history.lookup(scope: bridge.context, query: arguments)]
    } else if VoiceAgentPolicy.fileTools.contains(name) {
      guard !declined.contains("file") else { return Self.notApplied("user_declined") }
      result = try await bridge.executeFileTool(name: name, arguments: arguments, select: { selection in
        let url = await self.requestFile(selection)
        if url == nil { self.declined.insert("file") }
        return url
      }, validateContext: validate, willCommit: {})
    } else if name == "delete_edit_state" {
      guard !declined.contains("edit_state") else { return Self.notApplied("user_declined") }
      guard let state = (arguments["id"] as? String).flatMap(UUID.init(uuidString:)),
            let preview = bridge.prepareEditStateDeletion(id: state) else { return Self.notApplied("edit_state_unavailable") }
      guard await requestApproval(status: "Waiting for deletion approval", show: { self.editStateDeletion = preview }) else {
        declined.insert("edit_state")
        return Self.notApplied("user_declined")
      }
      try validate()
      result = try await bridge.executeEditStateDeletion(preview, validateContext: validate)
    } else if name == "edit_volume" {
      guard !declined.contains("volume_edit") else { return Self.notApplied("user_declined") }
      let preview = try bridge.prepareVolumeEdit(arguments: arguments)
      if settings.confirmsVolumeEdits {
        guard await requestApproval(status: "Waiting for volume edit approval", show: { self.volumeEditApproval = preview }) else {
          declined.insert("volume_edit")
          return Self.notApplied("user_declined")
        }
      }
      try validate()
      result = try await bridge.executeVolumeEdit(preview, validateContext: validate)
      if (result["structuredContent"] as? [String: Any])?["not_applied"] as? Bool != true { trackBricks() }
    } else if ["remove_object", "remove_measurement", "clear_annotations"].contains(name) {
      guard !declined.contains("annotations") else { return Self.notApplied("user_declined") }
      let target = name == "remove_object" ? "markers" : name == "remove_measurement" ? "measurements" : arguments["scope"] as? String ?? "all"
      if let preview = try bridge.prepareAnnotationDeletion(scope: target, targetID: name == "clear_annotations" ? nil : arguments["id"] as? String) {
        guard preview.markerCount + preview.measurementCount > 0 else { return Self.notApplied("no_annotations") }
        guard await requestApproval(status: "Waiting for deletion approval", show: { self.annotationDeletion = preview }) else {
          declined.insert("annotations")
          return Self.notApplied("user_declined")
        }
        try validate()
        result = try await bridge.executeAnnotationDeletion(preview, validateContext: validate)
      } else {
        result = try await bridge.executeTool(name: name, arguments: arguments, validateContext: validate)
      }
    } else {
      result = try await bridge.executeTool(name: name, arguments: arguments, validateContext: validate)
    }
    if name != VoiceAgentPolicy.commandHistoryTool, result["isError"] as? Bool != true,
       let summary = result["structuredContent"] as? [String: Any], summary["not_applied"] as? Bool != true,
       summary["ok"] as? Bool != false {
      history.append(scope: bridge.context, tool: name, arguments: arguments, result: VoiceAgentPolicy.compactResult(summary, tool: name))
      saveConversation()
    }
    if !Task.isCancelled { status = voiceAgentText("Working…") }
    return result
  }

  private func check(_ id: UUID, _ version: AssistantEvidenceVersion) throws {
    try Task.checkCancellation()
    guard generation == id, settingsIdentity == settings.identity, manualOperations.isEmpty, evidenceVersion == version else {
      throw VoiceAgentError.contextChanged
    }
  }

  private static func notApplied(_ code: String) -> [String: Any] {
    ["structuredContent": ["ok": false, "not_applied": true, "code": code]]
  }

  private func requestApproval(status: String, show: () -> Void) async -> Bool {
    guard !Task.isCancelled else { return false }
    return await withCheckedContinuation { reply in
      approval = reply
      self.status = voiceAgentText(status)
      show()
    }
  }

  private func resolveApproval(_ accepted: Bool) {
    let reply = approval
    approval = nil
    annotationDeletion = nil; editStateDeletion = nil; volumeEditApproval = nil
    reply?.resume(returning: accepted)
  }

  func resolveAnnotationDeletion(id: UUID, accepted: Bool) {
    if annotationDeletion?.id == id { resolveApproval(accepted) }
  }

  func resolveEditStateDeletion(id: UUID, accepted: Bool) {
    if editStateDeletion?.id == id { resolveApproval(accepted) }
  }

  func resolveVolumeEditApproval(id: UUID, accepted: Bool, alwaysApprove: Bool = false) {
    guard volumeEditApproval?.id == id else { return }
    if accepted && alwaysApprove { settings.confirmsVolumeEdits = false }
    resolveApproval(accepted)
  }

  var presentedFileSelection: VoiceAgentFileSelection? { fileSelection ?? importStatus?.fileSelection }

  private func requestFile(_ selection: VoiceAgentFileSelection) async -> URL? {
    guard !Task.isCancelled else { return nil }
    return await withCheckedContinuation { reply in
      selectedFile = reply
      fileSelection = selection
      status = voiceAgentText("Waiting for file selection")
    }
  }

  func resolveFileSelection(id: UUID, url: URL?) {
    guard fileSelection?.id == id else { return }
    fileSelection = nil
    let reply = selectedFile
    selectedFile = nil
    reply?.resume(returning: url)
  }

  func resolvePresentedFileSelection(id: UUID, url: URL?) {
    if fileSelection?.id == id { resolveFileSelection(id: id, url: url) }
    else { bridge?.resolveImportFileSelection(id: id, url: url) }
  }

  func cancelImport(id: UUID) { bridge?.cancelImport(id: id) }

  private func trackBricks() {
    bricks?.cancel()
    bricks = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        self.volumeBrickStatus = self.bridge?.volumeBrickStatus()
        guard case .pending = self.volumeBrickStatus else { return }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      }
    }
  }

  func cancel() {
    generation = UUID()
    running?.cancel()
    deadline?.cancel()
    resolveApproval(false)
    if let selection = fileSelection { resolveFileSelection(id: selection.id, url: nil) }
    if let job = importStatus, job.active { bridge?.cancelImport(id: job.id) }
    speech.cancel()
    continuationGoal = nil
    continuationCore = nil
    status = voiceAgentText(connectionState == .ready ? "Connected" : "Disconnected")
  }

  func disconnect() {
    cancel()
    settingsIdentity = nil
    connectionState = .disconnected
    model = ""
    status = voiceAgentText("Disconnected")
  }

  func newConversation() {
    cancel()
    messages.removeAll()
    history.clear()
    errorText = nil
    removeConversation()
  }

  func toggleMicrophone() async {
    if speech.isRecording { speech.finish(); return }
    do { try await speech.start(onDeviceOnly: settings.onDeviceOnly) }
    catch { errorText = error.localizedDescription }
  }

  private func append(_ text: String, user: Bool, confirmedChanges: Int? = nil) {
    messages.append(.init(user: user, text: text, confirmedChanges: confirmedChanges))
    if messages.count > 128 { messages.removeFirst() }
    history.appendMessage(scope: bridge?.context, user: user, text: text)
    saveConversation()
  }

  private func settingsChanged() {
    if let identity = settingsIdentity, identity != settings.identity { disconnect() }
    if !settings.speaks { speech.stopSpeaking() }
    reconcileArchiveOwner()
    if !settings.savesConversation, FileManager.default.fileExists(atPath: conversationStore.file.path) {
      removeConversation()
    }
  }

  private func reconcileArchiveOwner() {
    guard storeOwner != settings.archiveOwnerID else { return }
    storeOwner = settings.archiveOwnerID
    messages.removeAll(); history.clear(); removeConversation()
    continuationCore = nil
    continuationGoal = nil
  }

  private func saveConversation() {
    guard settings.savesConversation else { return }
    do { try conversationStore.save(history, owner: storeOwner); conversationStorageError = nil }
    catch { conversationStorageError = voiceAgentText("Could not save or restore the local conversation.") }
  }

  private func removeConversation() {
    do { try conversationStore.remove(); conversationStorageError = nil }
    catch { conversationStorageError = voiceAgentText("Could not remove the local conversation.") }
  }
}
