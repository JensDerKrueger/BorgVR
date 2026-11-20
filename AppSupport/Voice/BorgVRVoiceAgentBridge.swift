import Foundation
import Combine
import CryptoKit
import simd

/// Supplied by the host app, never by the model. A lease holds the renderer/import gate.
struct VoiceAgentImportLease {
  let directory: URL
  let settings: BorgVRVolumeConversionSettings
  let filter: BorgVRVolumeResamplingFilter
  let release: @MainActor () -> Void

  init(directory: URL, brickSize: Int, overlap: Int, compression: Bool, borderMode: String,
       quantize: Bool, colorCompression: Int, filter: BorgVRVolumeResamplingFilter, release: @escaping @MainActor () -> Void) {
    self.directory = directory
    self.filter = filter
    self.release = release
    let borders: ExtensionStrategy = borderMode == "border" ? .clamp : borderMode == "repeat" ? .repeatValue : .fillZeroes
    self.settings = .init(brickSize: brickSize, overlap: overlap, useCompression: compression,
                          extensionStrategy: borders, quantizeTo8Bit: quantize, colorCompression: colorCompression)
  }
}

private final class VoiceAgentImportLogger: LoggerBase, @unchecked Sendable {
  private let update: @Sendable (String, Double) -> Void
  // The conversion invokes this logger on its worker queue.
  private let lock = NSLock()
  private var lastUpdate = ContinuousClock.now - .seconds(1)

  init(update: @escaping @Sendable (String, Double) -> Void) { self.update = update }
  func progress(_ message: String, _ progress: Double) {
    let publish = lock.withLock {
      let now = ContinuousClock.now
      guard now - lastUpdate >= .milliseconds(200), progress.isFinite else { return false }
      lastUpdate = now
      return true
    }
    if publish { update(message, max(0, min(1, progress))) }
  }
  func dev(_ message: String) {}
  func info(_ message: String) {}
  func warning(_ message: String) {}
  func error(_ message: String) {}
  func setMinimumLogLevel(_ level: LogLevel) {}
}

/// All knowledge of BorgVR commands, MCP routing and source attribution stays here.
@MainActor
final class BorgVRVoiceAgentBridge: VoiceAgentApplicationBridge {
  private let service: any BorgVRMCPCommandService
  private let router: BorgVRMCPToolRouter
  private let contextProvider: () -> VoiceAgentContext?
  private let readinessProvider: () -> Bool
  private let beginImport: (() throws -> VoiceAgentImportLease)?
  @Published private var importStatus: VoiceAgentImportStatus?
  private var importCancellation: BorgVRVolumeConversionCancellationToken?
  private var supportingFileReply: CheckedContinuation<URL?, Never>?
  private let origin = BorgVRCommandSource.controller(UUID().uuidString)
  private var searchResults: [String: Date] = [:]
  private var assistantExportID: UUID?
  private var deletionPreview: (value: VoiceAgentAnnotationDeletion, context: VoiceAgentContext, digest: Data, expires: Date)?
  private struct ApprovedVolumeEdit {
    let id: UUID
    let context: VoiceAgentContext
    let revision: UInt64
    let channels: [Int]
    let arguments: [String: Any]
    let expires: ContinuousClock.Instant
  }
  private var volumeEditPreview: ApprovedVolumeEdit?

  init(service: any BorgVRMCPCommandService, isReady: @escaping () -> Bool = { true },
       beginImport: (() throws -> VoiceAgentImportLease)? = nil,
       context: @escaping () -> VoiceAgentContext?) {
    self.service = service
    self.router = BorgVRMCPToolRouter(commandService: service)
    self.contextProvider = context
    self.readinessProvider = isReady
    self.beginImport = beginImport
  }

  var applicationDatasetContext: VoiceAgentContext? { contextProvider() }
  var context: VoiceAgentContext? { rendererReady ? contextProvider() : nil }
  var rendererReady: Bool { service.applicationState().rendererReady && readinessProvider() }
  var datasetID: String? { service.applicationState().dataset?.id }
  var hasTransferFunctions: Bool { service.transferFunctionCount > 0 }
  var toolDefinitions: [[String: Any]] { router.toolDefinitions + (beginImport == nil ? [] : VoiceAgentPolicy.importCatalog) }
  var importUpdates: AnyPublisher<VoiceAgentImportStatus?, Never> { $importStatus.eraseToAnyPublisher() }

  func cancelImport(id: UUID) {
    guard importStatus?.id == id, importStatus?.phase == .running else { return }
    importStatus?.phase = .cancelling
    importCancellation?.cancel()
    if let selection = importStatus?.fileSelection { resolveImportFileSelection(id: selection.id, url: nil) }
  }

  func resolveImportFileSelection(id: UUID, url: URL?) {
    guard importStatus?.fileSelection?.id == id else { return }
    importStatus?.fileSelection = nil
    let reply = supportingFileReply
    supportingFileReply = nil
    reply?.resume(returning: url)
  }

  var demonstrationActions: AnyPublisher<WorkflowDemonstrationAction, Never> {
    guard let executor = service.commandExecutor else { return Empty().eraseToAnyPublisher() }
    return executor.commandEvents.compactMap { event in
      guard case .committed = event.phase, let domain = Self.domain(event.command) else { return nil }
      return Self.isManual(event.source) ? WorkflowDemonstrationAction(rawValue: domain) : nil
    }.eraseToAnyPublisher()
  }

  var demonstrationEvidenceInvalidations: AnyPublisher<Void, Never> {
    guard let executor = service.commandExecutor else { return Empty().eraseToAnyPublisher() }
    return executor.commandEvents.compactMap { event in
      guard !Self.isManual(event.source), Self.domain(event.command) != nil else { return nil }
      return ()
    }.eraseToAnyPublisher()
  }

  private static func isManual(_ source: BorgVRCommandSource) -> Bool {
    switch source {
      case .userInterface, .mouse, .touch, .hand, .muse: return true
      default: return false
    }
  }

  func workflowViewEvidence() -> WorkflowViewEvidence? {
    let state = service.applicationState()
    guard state.rendererReady, readinessProvider() else { return nil }
    return WorkflowViewEvidence(clipMinimum: state.clipMinimum, clipMaximum: state.clipMaximum,
                                rotation: state.transform.rotation)
  }

  func captureWorkflowScreenshot(in context: VoiceAgentContext) async throws -> Data {
    guard self.context == context else { throw VoiceAgentError.contextChanged }
    var viewChanged = false
    let observation = service.commandExecutor?.commandEvents.sink { event in
      if Self.domain(event.command) != nil { viewChanged = true }
    }
    defer { observation?.cancel() }
    let startingFrame = service.applicationState().completedFrame
    try await service.waitUntilRendered(after: startingFrame, timeout: 3)
    try Task.checkCancellation()
    guard !viewChanged, self.context == context else { throw VoiceAgentError.contextChanged }
    let image = try await service.captureScreenshot(includeAlpha: true)
    try Task.checkCancellation()
    guard !viewChanged, self.context == context, image.renderedFrame > startingFrame else {
      throw VoiceAgentError.contextChanged
    }
    return image.pngData
  }

  var changes: AnyPublisher<VoiceAgentApplicationChange, Never> {
    guard let executor = service.commandExecutor else { return Empty().eraseToAnyPublisher() }
    return executor.commandEvents.compactMap { [origin] event in
      guard event.source != origin, event.source != .stateRestore,
            let domain = Self.domain(event.command) else { return nil }
      let phase: VoiceAgentApplicationChange.Phase
      switch event.phase {
        case .began: phase = .began
        case .committed: phase = .committed
        case .failed: phase = .failed
      }
      return VoiceAgentApplicationChange(id: event.id, domain: domain, phase: phase)
    }.eraseToAnyPublisher()
  }

  func stateSnapshot() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(service.applicationState())) as? [String: Any] ?? [:]
    return VoiceAgentPolicy.compactResult(object, tool: "get_application_state")
  }

  func executeTool(name: String, arguments: [String: Any], validateContext: @escaping () throws -> Void) async throws -> [String: Any] {
    try validateContext()
    switch name {
      case "get_import_status":
        if let seconds = arguments["wait_seconds"] as? Double, seconds > 0,
           let job = importStatus, job.active {
          let deadline = ContinuousClock.now + .seconds(min(seconds, 10))
          while importStatus?.id == job.id, importStatus?.active == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            try validateContext()
          }
        }
        return ["structuredContent": importResult()]
      case "cancel_import":
        guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw),
              id == importStatus?.id, importStatus?.active == true else {
          return volumeEditRejection("unknown_import", "There is no matching active import or fusion.")
        }
        cancelImport(id: id)
        return ["structuredContent": importResult()]
      case "close_dataset":
        guard service.volumeEditing.volumeEditingState().export?.isActive != true else {
          return volumeEditRejection("export_running", "Wait for the running export or cancel it before closing the dataset.")
        }
        _ = try await callMCP(name, arguments, validateContext: validateContext)
        let deadline = ContinuousClock.now + .seconds(30)
        while datasetID != nil || applicationDatasetContext != nil {
          try validateContext()
          guard ContinuousClock.now < deadline else { throw VoiceAgentError.timedOut }
          try await Task.sleep(for: .milliseconds(100))
        }
        return ["structuredContent": try stateSnapshot()]
      case "select_edit_state":
        let rawID = arguments["id"] as? String
        let state = service.volumeEditing.volumeEditingState()
        guard state.available, !state.shared, state.export?.isActive != true,
              rawID == "original" || state.savedStates.contains(where: { $0.id == rawID.flatMap(UUID.init(uuidString:)) }) else {
          return volumeEditRejection("edit_state_unavailable", "Read the saved edit states again. Selection requires an available personal state and no active export.")
        }
        let wanted = rawID.flatMap(UUID.init(uuidString:))
        if state.activeStateID == wanted {
          return volumeEditRejection("already_selected", "The requested edit state is already active.")
        }
        _ = try await callMCP(name, arguments, validateContext: validateContext)
        return ["structuredContent": volumeEditStatus()]
      case "configure_volume_brush":
        let state = service.volumeEditing.volumeEditingState()
        guard state.available, !state.shared, state.export?.isActive != true,
              let channels = arguments["channels"] as? [Int], !channels.isEmpty,
              Set(channels).count == channels.count, channels.allSatisfy({ $0 > 0 && $0 <= state.componentCount }) else {
          return volumeEditRejection("channels_unavailable", "Read the current editable channels and use distinct, valid one-based channel numbers.")
        }
        _ = try await callMCP(name, ["channels": channels], validateContext: validateContext)
        return ["structuredContent": volumeEditStatus()]
      case "cancel_volume_export":
        guard let job = service.volumeEditing.volumeEditingState().export, job.isActive, job.id == assistantExportID,
              (arguments["id"] as? String).flatMap(UUID.init(uuidString:)) == job.id else {
          return volumeEditRejection("unknown_export", "There is no matching active export started by the assistant.")
        }
        _ = try await callMCP(name, arguments, validateContext: validateContext)
        return ["structuredContent": volumeEditStatus()]
      case _ where VoiceAgentPolicy.fileTools.contains(name):
        return volumeEditRejection("local_file_selection_required", "This operation requires a local file selection.")
      case "edit_volume":
        return volumeEditRejection("confirmation_required", "Volume edits require a fresh local approval.")
      case "get_volume_edit_state":
        return ["structuredContent": volumeEditStatus()]
      case "wait_volume_edits":
        let timeout = try arguments["timeout_seconds"].map { try BorgVRVolumeEditingArguments.number($0) } ?? 5
        guard (0.1...10).contains(timeout) else { throw VoiceAgentError.protocolViolation }
        var timedOut = false
        do {
          _ = try await router.callTool(name: name, arguments: ["timeout_seconds": timeout], validateContext: validateContext)
        } catch BorgVRVolumeEditingCommandError.timeout {
          timedOut = true
        } catch BorgVRVolumeEditingCommandError.unavailable {
          // Status can become temporarily unavailable while switching edit states.
        }
        var status = volumeEditStatus()
        status["timedOut"] = timedOut
        return ["structuredContent": status]
      default: break
    }
    if name == "clear_annotations" {
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "confirmation_required",
        "note": "Bulk annotation deletion requires a fresh local human approval; confirm: true alone is insufficient."]]
    }
    if let error = VoiceAgentAnnotationPolicy.validationError(name: name, arguments: arguments) {
      return annotationRejection(error)
    }
    if name == "list_objects" {
      return try annotationList(service.listObjects(), key: "objects", arguments: arguments, encode: annotationJSON)
    }
    if name == "list_measurements" {
      return try annotationList(service.listMeasurements(), key: "measurements", arguments: arguments, encode: measurementResult)
    }
    if name == "remove_object" {
      guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID),
            let object = service.listObjects().first(where: { $0.id == id }), case .marker = object else {
        return annotationRejection("The marker ID is not present in this dataset. Mesh deletion is not available; list objects again.")
      }
      if annotationDeletionCounts(scope: "markers").0 == 1 {
        return ["structuredContent": ["ok": false, "not_applied": true, "code": "confirmation_required"]]
      }
    }
    if name == "remove_measurement" {
      guard let rawID = arguments["id"] as? String, let id = UUID(uuidString: rawID),
            service.listMeasurements().contains(where: { $0.id == id }) else {
        return annotationRejection("The measurement ID is not present in this dataset. List measurements again.")
      }
      if service.listMeasurements().count == 1 {
        return ["structuredContent": ["ok": false, "not_applied": true, "code": "confirmation_required"]]
      }
    }
    if ["upsert_sphere_marker", "upsert_stroke_marker"].contains(name), let rawID = arguments["id"] as? String {
      guard let id = UUID(uuidString: rawID), let object = service.listObjects().first(where: { $0.id == id }),
            case .marker(let marker) = object,
            (name == "upsert_sphere_marker" ? marker.kind == .sphere : marker.kind == .stroke) else {
        return annotationRejection("The marker ID/kind is not present in the current dataset. List objects again; omit id only for a new marker.")
      }
      guard marker.points.count <= VoiceAgentAnnotationPolicy.maximumPoints, marker.name.count <= 128,
            try JSONEncoder().encode(object).count <= 64 * 1024 else {
        return annotationRejection("This marker exceeds the agent's editable detail budget. Edit it manually; a summary must not replace it.")
      }
    }
    if name == "upsert_measurement" {
      if let rawID = arguments["id"] as? String {
        guard let existing = service.listMeasurements().first(where: { $0.id == UUID(uuidString: rawID) }) else {
          return annotationRejection("The measurement ID is not present in the current dataset. List measurements again; omit id only for a new measurement.")
        }
        guard existing.points.count <= VoiceAgentAnnotationPolicy.maximumPoints, existing.name.count <= 128,
              try JSONEncoder().encode(existing).count <= 64 * 1024 else {
          return annotationRejection("This measurement exceeds the agent's editable detail budget. Edit it manually; a summary must not replace it.")
        }
      }
      let rows = arguments["points"] as! [[String: Any]]
      let state = BorgVRMeasurementCommandState(id: UUID(), name: "Validation",
        kind: VolumeMeasurementKind(rawValue: arguments["kind"] as! String)!,
        points: rows.map { row in
          let position = row["position"] as! [NSNumber]
          return BorgVRMeasurementPointCommandState(id: UUID(), position: SIMD3(position[0].floatValue, position[1].floatValue, position[2].floatValue))
        })
      let geometry = try state.measurement(physicalExtent: measurementExtent ?? .one).geometry
      guard let value = geometry.value, value.isFinite, value > 0 else {
        return annotationRejection("The points do not form a nondegenerate measurement. Area points must be coplanar and volume points non-coplanar; no change was applied.")
      }
    }
    let result: [String: Any]
    do {
      result = try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
        try await router.callTool(name: name, arguments: arguments, validateContext: validateContext)
      }
    } catch BorgVRSessionCommandError.invalidClipping where name == "set_clipping" {
      // This validation rejects the command before changing any clipping state.
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "invalid_clipping",
        "error": "Clipping bounds were not changed. Each minimum must be less than or equal to its maximum, and all bounds must be between zero and one."]]
    } catch BorgVRSessionCommandError.invalidAnnotation where ["upsert_sphere_marker", "upsert_stroke_marker", "upsert_measurement"].contains(name) {
      return annotationRejection("The annotation failed validation before being applied. Check coordinates, radius, colors and geometry.")
    }
    if name == "upsert_measurement", let content = result["structuredContent"] as? [String: Any],
       let rawID = content["id"] as? String, let id = UUID(uuidString: rawID),
       let state = service.listMeasurements().first(where: { $0.id == id }) {
      return ["structuredContent": try measurementResult(state)]
    }
    if name == "remove_object" {
      return try annotationList(service.listObjects(), key: "objects", arguments: [:], encode: annotationJSON)
    }
    if name == "remove_measurement" {
      return try annotationList(service.listMeasurements(), key: "measurements", arguments: [:], encode: measurementResult)
    }
    if name == "search_datasets", let payload = result["structuredContent"] as? [String: Any],
       let matches = payload["matches"] as? [[String: Any]] {
      searchResults = searchResults.filter { $0.value > Date() }
      for match in matches {
        if let id = match["id"] as? String {
          if searchResults.count >= 2000, let oldest = searchResults.min(by: { $0.value < $1.value })?.key {
            searchResults.removeValue(forKey: oldest)
          }
          searchResults[id] = Date().addingTimeInterval(300)
        }
      }
    }
    return result
  }

  private func callMCP(_ name: String, _ arguments: [String: Any], validateContext: @escaping () throws -> Void) async throws -> [String: Any] {
    try validateContext()
    try Task.checkCancellation()
    return try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
      try await router.callTool(name: name, arguments: arguments, validateContext: validateContext)
    }
  }

  func executeFileTool(name: String, arguments: [String: Any], select: (VoiceAgentFileSelection) async -> URL?,
                       validateContext: @escaping () throws -> Void, willCommit: () -> Void) async throws -> [String: Any] {
    guard VoiceAgentPolicy.fileTools.contains(name) else { throw VoiceAgentError.protocolViolation }
    if VoiceAgentPolicy.conversionTools.contains(name) {
      return try await executeImport(name: name, arguments: arguments, select: select,
                                     validateContext: validateContext, willCommit: willCommit)
    }
    let exporting = name == "export_edited_dataset"
    guard let filename = VoiceAgentPolicy.outputName(arguments["filename"], extension: exporting ? "data" : "json") else {
      return volumeEditRejection("invalid_filename", "Supply a plain filename without folders, control characters or a leading dot.")
    }
    func available() -> Bool {
      let state = service.volumeEditing.volumeEditingState()
      return !exporting || (state.available && !state.shared && state.export?.isActive != true)
    }
    try validateContext()
    guard available() else { return volumeEditRejection("export_unavailable", "A personal edit state with no active export is required.") }
    let title = String(format: voiceAgentText(exporting ? "Choose export folder for %@" : "Choose save folder for %@"), filename)
    guard let folder = await select(.init(title: title, kind: .folder)) else {
      return volumeEditRejection("user_declined", "The user did not choose a destination. Do not ask again in this request.")
    }
    try validateContext()
    guard available() else { return volumeEditRejection("export_unavailable", "The export is no longer available.") }
    let destinationAccess = VolumeImportSourceAccess(url: folder, selectedURLs: [folder])
    defer { withExtendedLifetime(destinationAccess) {} }
    let url = folder.appendingPathComponent(filename, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: url.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
      return volumeEditRejection("destination_exists", "The destination already exists and has not been overwritten.")
    }
    do {
      willCommit()
      _ = try await callMCP(name, ["output_path": url.path], validateContext: validateContext)
    } catch BorgVRVolumeEditingCommandError.busy {
      return volumeEditRejection("export_unavailable", "Another operation is using the volume.")
    }
    if exporting, let job = service.volumeEditing.volumeEditingState().export {
      assistantExportID = job.id
      let editing = service.volumeEditing
      // MCP receives an ordinary path; keep the original picker grant until the writer finishes.
      Task { @MainActor in
        defer { withExtendedLifetime(destinationAccess) {} }
        _ = try? await editing.waitForVolumeExport(id: job.id)
      }
      return ["structuredContent": ["filename": filename, "export": exportStatus(job)]]
    }
    return ["structuredContent": ["filename": filename, "saved": true]]
  }

  private enum ImportKind: String {
    case file, zarr, dicom, images
    var pickerKind: VoiceAgentFileSelection.Kind { self == .file ? .file : .folder }
    func input(at url: URL) -> BorgVRVolumeInput { self == .dicom ? .dicomDirectory(url) : .file(url) }
    func source(at url: URL) -> BorgVRVolumeConversionSource {
      switch self {
        case .dicom: return .dicomDirectory(url)
        case .images: return .imageSequence(url)
        case .zarr: return .file(url)
        case .file: return url.pathExtension.lowercased() == "data" ? .borgVR(url) : .file(url)
      }
    }

    func accepts(_ url: URL) -> Bool {
      guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return false }
      if self == .file {
        return values.isRegularFile == true &&
          (VolumeFileParserFactory.supportedExtensions + ["data"]).contains(url.pathExtension.lowercased())
      }
      return values.isDirectory == true
    }
  }

  private func importResult() -> [String: Any] {
    guard let job = importStatus else { return ["status": "idle"] }
    return ["id": job.id.uuidString, "filename": job.filename, "status": job.phase.rawValue,
            "progress": job.progress, "waitingForLocalFile": job.fileSelection != nil]
  }

  private func executeImport(name: String, arguments: [String: Any], select: (VoiceAgentFileSelection) async -> URL?,
                             validateContext: @escaping () throws -> Void, willCommit: () -> Void) async throws -> [String: Any] {
    try validateContext()
    guard let beginImport, datasetID == nil, applicationDatasetContext == nil, importStatus?.active != true else {
      return volumeEditRejection("import_unavailable", "Close the dataset or wait for the existing import or fusion to finish.")
    }
    let fusion = name == "fuse_volumes"
    guard let filename = VoiceAgentPolicy.outputName(arguments["filename"], extension: "data"),
          let first = (arguments[fusion ? "reference_kind" : "source_kind"] as? String).flatMap(ImportKind.init) else {
      return volumeEditRejection("invalid_import", "Supply a supported source kind and plain output filename.")
    }
    let second = (arguments["moving_kind"] as? String).flatMap(ImportKind.init)
    if fusion && (first == .images || second == nil || second == .images) {
      return volumeEditRejection("invalid_import", "Fusion requires a reference and a moving volume, not image sequences.")
    }
    var extent: Vec3<Float>?
    if first == .images {
      guard let sizes = arguments["size_meters"] as? [Double], sizes.count == 3,
            sizes.allSatisfy({ Float($0).isFinite && Float($0) > 0 }) else {
        return volumeEditRejection("image_size_required", "Specify positive X, Y and Z extents in meters before importing an image sequence.")
      }
      extent = Vec3<Float>(Float(sizes[0]), Float(sizes[1]), Float(sizes[2]))
    }
    let lease: VoiceAgentImportLease
    do { lease = try beginImport() }
    catch { return volumeEditRejection("import_unavailable", "Close the renderer or finish the other import first.") }
    var handedOff = false
    defer { if !handedOff { lease.release() } }
    let firstTitle = String(format: voiceAgentText(fusion ? "Choose reference volume for %@" : "Choose source for %@"), filename)
    guard let reference = await select(.init(title: firstTitle, kind: first.pickerKind)) else {
      return volumeEditRejection("user_declined", "No source was selected. Do not ask again in this request.")
    }
    try validateContext()
    let firstAccess = VolumeImportSourceAccess(url: reference, selectedURLs: [reference])
    guard first.accepts(reference) else {
      return volumeEditRejection("invalid_source", "The locally selected item does not match the requested source type.")
    }
    var secondAccess: VolumeImportSourceAccess?
    var source = first.source(at: reference)
    if let second, fusion {
      let title = String(format: voiceAgentText("Choose moving volume for %@"), filename)
      guard let moving = await select(.init(title: title, kind: second.pickerKind)) else {
        return volumeEditRejection("user_declined", "No moving volume was selected. Do not ask again in this request.")
      }
      try validateContext()
      secondAccess = .init(url: moving, selectedURLs: [moving])
      guard second.accepts(moving),
            moving.resolvingSymlinksInPath().standardizedFileURL != reference.resolvingSymlinksInPath().standardizedFileURL else {
        return volumeEditRejection("invalid_source", "The moving volume must be a different item of the requested source type.")
      }
      source = .registeredPair(reference: first.input(at: reference), moving: second.input(at: moving), filter: lease.filter)
    }
    let directoryAccess = VolumeImportSourceAccess(url: lease.directory, selectedURLs: [lease.directory])
    let output = lease.directory.appendingPathComponent(filename, isDirectory: false)
    guard !FileManager.default.fileExists(atPath: output.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: output.path)) == nil else {
      return volumeEditRejection("destination_exists", "A dataset with this filename already exists and has not been overwritten.")
    }
    let description = (arguments["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = BorgVRVolumeConversionRequest(source: source, destinationURL: output,
      datasetDescription: (description?.isEmpty == false ? description : nil) ?? output.deletingPathExtension().lastPathComponent,
      metaDescription: voiceAgentText("Imported with BorgVR"), settings: lease.settings,
      physicalSizeMeters: extent, replaceExisting: false)
    try validateContext()
    try Task.checkCancellation()
    let id = UUID()
    let token = BorgVRVolumeConversionCancellationToken()
    let logger = VoiceAgentImportLogger { [weak self] message, progress in
      Task { @MainActor in
        guard let self, self.importStatus?.id == id, self.importStatus?.phase == .running else { return }
        self.importStatus?.detail = message
        self.importStatus?.progress = max(self.importStatus?.progress ?? 0, min(progress, 0.99))
      }
    }
    willCommit()
    importStatus = .init(id: id, filename: filename, phase: .running, progress: 0)
    importCancellation = token
    handedOff = true
    Task { @MainActor in
      defer { lease.release() }
      let inputs = [firstAccess, secondAccess, directoryAccess].compactMap { $0 }
      let result = await runImport(request, token: token, logger: logger, grants: inputs)
      guard var status = importStatus, status.id == id else { return }
      importCancellation = nil
      switch result {
        case .success:
          status.phase = .completed
          status.progress = 1
          status.detail = nil
        case .failure(let error):
          status.phase = error is CancellationError ? .cancelled : .failed
          status.detail = status.phase == .failed ? error.localizedDescription : nil
      }
      importStatus = status
    }
    return ["structuredContent": importResult()]
  }

  private func runImport(_ request: BorgVRVolumeConversionRequest, token: BorgVRVolumeConversionCancellationToken,
                         logger: VoiceAgentImportLogger, grants: [VolumeImportSourceAccess]) async -> Result<Void, Error> {
    var accesses = grants
    var requested = Set<URL>()
    while !token.isCancelled {
      let result: Result<Void, Error> = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { [accesses] in
          defer { withExtendedLifetime(accesses) {} }
          continuation.resume(returning: Result {
            try BorgVRVolumeConversionService.convert(request, logger: logger, cancellationToken: token)
          })
        }
      }
      guard case .failure(BorgVRImportFileAccess.Error.permissionRequired(let required)) = result,
            !token.isCancelled else { return result }
      let key = required.resolvingSymlinksInPath().standardizedFileURL
      guard requested.count < 8, requested.insert(key).inserted else { return result }
      let title = String(format: voiceAgentText("Choose the referenced file %@"), required.lastPathComponent)
      let selection = VoiceAgentFileSelection(title: title, kind: .file)
      let timeout = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(300)) } catch { return }
        resolveImportFileSelection(id: selection.id, url: nil)
      }
      let selected = await withCheckedContinuation { continuation in
        supportingFileReply = continuation
        importStatus?.fileSelection = selection
      }
      timeout.cancel()
      guard !token.isCancelled, let selected else { return .failure(CancellationError()) }
      let access = VolumeImportSourceAccess(url: selected, selectedURLs: [selected])
      guard BorgVRImportFileAccess.matchesSupportingFile(selected, required: required) else { return result }
      accesses.append(access)
    }
    return .failure(CancellationError())
  }

  private func annotationRejection(_ message: String) -> [String: Any] {
    ["structuredContent": ["ok": false, "not_applied": true, "code": "invalid_annotation", "error": message]]
  }

  func prepareAnnotationDeletion(scope: String, targetID: String?) throws -> VoiceAgentAnnotationDeletion? {
    guard ["all", "markers", "measurements"].contains(scope), let context else { throw VoiceAgentError.contextChanged }
    let counts = annotationDeletionCounts(scope: scope)
    if let targetID {
      guard let id = UUID(uuidString: targetID) else { return nil }
      if scope == "markers" {
        guard counts.0 == 1, service.listObjects().contains(where: { object in
          if case .marker(let marker) = object { return marker.id == id }; return false
        }) else { return nil }
      } else {
        guard counts.1 == 1, service.listMeasurements().contains(where: { $0.id == id }) else { return nil }
      }
    }
    let preview = VoiceAgentAnnotationDeletion(id: UUID(), scope: scope, markerCount: counts.0, measurementCount: counts.1)
    deletionPreview = (preview, context, try annotationDeletionDigest(scope: scope), Date().addingTimeInterval(300))
    return preview
  }

  func executeAnnotationDeletion(_ confirmation: VoiceAgentAnnotationDeletion,
                                validateContext: @escaping () throws -> Void) async throws -> [String: Any] {
    guard let preview = deletionPreview, preview.value.id == confirmation.id else {
      return annotationRejection("Deletion approval is missing or has already been consumed.")
    }
    deletionPreview = nil
    guard preview.context == context, preview.expires > Date() else {
      return annotationRejection("The dataset changed or deletion approval expired; nothing was deleted.")
    }
    do {
      return try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
        try await router.callTool(name: "clear_annotations", arguments: ["scope": preview.value.scope, "confirm": true],
          validateContext: {
            do {
              try validateContext()
              guard preview.context == self.context,
                    try self.annotationDeletionDigest(scope: preview.value.scope) == preview.digest else { throw DeletionPreviewChanged() }
            } catch { throw DeletionPreviewChanged() }
          })
      }
    } catch is DeletionPreviewChanged {
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "user_changed_view",
        "note": "The context or annotation snapshot changed after the question; nothing was deleted."]]
    }
  }

  private struct DeletionPreviewChanged: Error {}

  func prepareVolumeEdit(arguments: [String: Any]) throws -> VoiceAgentVolumeEdit {
    volumeEditPreview = nil
    guard let context, let physicalExtent = measurementExtent else { throw BorgVRVolumeEditingCommandError.unavailable }
    let extent = SIMD3<Double>(physicalExtent)
    let status = service.volumeEditing.volumeEditingState()
    guard status.available, !status.shared, !status.waitingForSharedState, !status.channels.isEmpty,
          status.export?.isActive != true, let revision = service.volumeEditing.editRevision
    else { throw BorgVRVolumeEditingCommandError.busy }
    guard Set(arguments.keys) == ["mode", "samples"], let rawMode = arguments["mode"] as? String,
          let mode = BorgVRVolumeBrushMode(rawValue: rawMode), let rows = arguments["samples"] as? [[String: Any]],
          rows.count <= VoiceAgentPolicy.maximumVolumeEditSamples,
          rows.allSatisfy({ Set($0.keys) == ["center_meters", "radius_meters"] })
    else { throw VoiceAgentError.protocolViolation }
    let samples = try BorgVRVolumeEditingArguments.samples(rows)
    let edge = max(extent.x, max(extent.y, extent.z))
    var lower = extent, upper = SIMD3<Double>.zero
    for sample in samples {
      for axis in 0..<3 where sample.center[axis] < 0 || sample.center[axis] > extent[axis] {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Brush center must be inside the dataset extent.")
      }
      guard sample.radius <= edge else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Brush radius cannot exceed the largest dataset extent.")
      }
      lower = simd_min(lower, sample.center - SIMD3(repeating: sample.radius))
      upper = simd_max(upper, sample.center + SIMD3(repeating: sample.radius))
    }
    let id = UUID()
    volumeEditPreview = .init(id: id, context: context, revision: revision, channels: status.channels,
                              arguments: arguments, expires: .now + .seconds(90))
    return .init(id: id, erase: mode == .erase, sampleCount: samples.count,
                 boundsMinimumMeters: simd_max(.zero, lower), boundsMaximumMeters: simd_min(extent, upper),
                 channels: status.channels)
  }

  func executeVolumeEdit(_ confirmation: VoiceAgentVolumeEdit,
                         validateContext: @escaping () throws -> Void) async throws -> [String: Any] {
    guard let preview = volumeEditPreview, preview.id == confirmation.id else {
      return volumeEditRejection("confirmation_required", "Approval is missing or already used.")
    }
    volumeEditPreview = nil
    do {
      _ = try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
        try await router.callTool(name: "edit_volume", arguments: preview.arguments, validateContext: {
          do { try validateContext() } catch { throw VolumeEditPreviewChanged() }
          let state = self.service.volumeEditing.volumeEditingState()
          guard self.context == preview.context, ContinuousClock.now < preview.expires,
                self.service.volumeEditing.editRevision == preview.revision,
                state.available, !state.shared, !state.waitingForSharedState, state.channels == preview.channels,
                state.export?.isActive != true else { throw VolumeEditPreviewChanged() }
        })
      }
    } catch is VolumeEditPreviewChanged {
      return volumeEditRejection("volume_edit_stale", "Edit state, channels, or approval changed; no edit was applied.")
    } catch BorgVRVolumeEditingCommandError.busy {
      return volumeEditRejection("volume_edit_busy", "The edit state now has a conflicting operation; no edit was applied.")
    } catch BorgVRVolumeEditingCommandError.unavailable {
      return volumeEditRejection("volume_edit_unavailable", "The edit state is unavailable; no edit was applied.")
    }
    guard context == preview.context, let revision = service.volumeEditing.editRevision else {
      throw VoiceAgentError.contextChanged
    }
    var status = volumeEditStatus()
    if revision == preview.revision {
      status["not_applied"] = true
      status["code"] = "no_bricks_changed"
    }
    return ["structuredContent": status]
  }

  private struct VolumeEditPreviewChanged: Error {}

  private func volumeEditRejection(_ code: String, _ note: String) -> [String: Any] {
    ["structuredContent": ["ok": false, "not_applied": true, "code": code, "note": note]]
  }

  func volumeBrickStatus() -> VoiceAgentVolumeBrickStatus? {
    brickStatus(service.volumeEditing.volumeEditingState())
  }

  private func brickStatus(_ snapshot: BorgVRVolumeEditingState) -> VoiceAgentVolumeBrickStatus? {
    guard snapshot.available, !snapshot.waitingForSharedState else { return nil }
    return snapshot.isUpdatingBricks || snapshot.pendingBrickCount > 0 ? .pending(snapshot.pendingBrickCount) : .ready
  }

  private func volumeEditStatus() -> [String: Any] {
    let snapshot = service.volumeEditing.volumeEditingState()
    var result: [String: Any] = [
      "available": snapshot.available, "hasEdits": snapshot.hasEdits,
      "isUpdatingBricks": snapshot.isUpdatingBricks, "pendingBrickCount": snapshot.pendingBrickCount,
      "bricksReady": brickStatus(snapshot) == .ready,
      "mode": snapshot.mode.rawValue, "radiusFraction": snapshot.radiusFraction, "radiusMeters": snapshot.radiusMeters,
      "projectsOntoVolume": snapshot.projectsOntoVolume, "shared": snapshot.shared,
      "waitingForSharedState": snapshot.waitingForSharedState, "componentCount": snapshot.componentCount,
      "channels": snapshot.channels,
      "savedStates": snapshot.savedStates.prefix(128).map { ["id": $0.id.uuidString, "name": String($0.name.prefix(120))] },
      "moreSavedStates": snapshot.savedStates.count > 128,
    ]
    if let extent = measurementExtent { result["physicalExtentMeters"] = [extent.x, extent.y, extent.z] }
    if let id = snapshot.activeStateID { result["activeStateID"] = id.uuidString }
    if let export = snapshot.export {
      result["export"] = exportStatus(export)
    }
    return result
  }

  private func exportStatus(_ export: BorgVRVolumeExportJob) -> [String: Any] {
    ["id": export.id.uuidString, "status": export.status.rawValue, "progress": export.progress,
     "startedByAssistant": export.id == assistantExportID]
  }

  private func annotationDeletionCounts(scope: String) -> (Int, Int) {
    let markers = scope == "measurements" ? 0 : service.listObjects().filter { if case .marker = $0 { return true }; return false }.count
    return (markers, scope == "markers" ? 0 : service.listMeasurements().count)
  }

  private func annotationDeletionDigest(scope: String) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = Data(scope.utf8)
    if scope != "measurements" {
      data.append(try encoder.encode(service.listObjects().filter { if case .marker = $0 { return true }; return false }))
    }
    if scope != "markers" { data.append(try encoder.encode(service.listMeasurements())) }
    return Data(SHA256.hash(data: data))
  }

  private var measurementExtent: SIMD3<Float>? {
    guard let extent = service.applicationState().dataset?.physicalExtentMeters, extent.count == 3,
          extent.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
    return SIMD3(extent[0], extent[1], extent[2])
  }

  private func annotationJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
  }

  private func measurementResult(_ state: BorgVRMeasurementCommandState) throws -> [String: Any] {
    var result = try annotationJSON(state)
    let extent = measurementExtent
    let value = try state.measurement(physicalExtent: extent).geometry.value
    result["value"] = value.map { $0 as Any } ?? NSNull()
    result["unit"] = state.kind == .length ? "m" : state.kind == .area ? "m^2" : "m^3"
    result["physicalExtentAvailable"] = extent != nil
    result["geometry"] = state.kind == .length ? "polyline" : state.kind == .area ? "planar_polygon" : "convex_hull"
    return result
  }

  private func annotationList<T>(_ rows: [T], key: String, arguments: [String: Any],
                                 encode: (T) throws -> [String: Any]) throws -> [String: Any] {
    let offset = arguments["offset"] as? Int ?? 0
    let limit = arguments["limit"] as? Int ?? 32
    var page: [[String: Any]] = [], bytes = 0
    for value in rows.dropFirst(offset).prefix(limit) {
      let row = try encode(value)
      var item = row
      var data = try JSONSerialization.data(withJSONObject: item)
      if data.count > 64 * 1024 {
        let nested = row["marker"] as? [String: Any] ?? row["mesh"] as? [String: Any] ?? row
        item = ["id": nested["id"] ?? NSNull(), "detailsOmitted": true,
                "note": "Annotation exceeds the detail budget; do not replace it using this summary."]
        data = try JSONSerialization.data(withJSONObject: item)
      }
      if bytes + data.count > 200 * 1024 { break }
      page.append(item)
      bytes += data.count
    }
    let next = min(offset, rows.count) + page.count
    return ["structuredContent": [key: page, "totalCount": rows.count, "returnedCount": page.count,
      "truncated": next < rows.count, "nextOffset": next < rows.count ? next as Any : NSNull()]]
  }

  func openDataset(id: String, validateContext: @escaping () throws -> Void,
                   didBegin: @escaping (VoiceAgentContext) throws -> Void) async throws -> [String: Any] {
    guard importStatus?.active != true else {
      return volumeEditRejection("import_running", "Wait for the active import or fusion before opening a dataset.")
    }
    guard let expiry = searchResults[id], expiry > Date() else {
      return ["structuredContent": ["ok": false, "not_applied": true, "code": "search_required",
        "note": "Search the catalog again and use an ID returned to this client within five minutes."]]
    }
    var expected: VoiceAgentContext?
    _ = try await BorgVRCommandExecutionContext.$originOverride.withValue(origin) {
      try await router.callTool(name: "open_dataset", arguments: ["id": id], validateContext: validateContext,
        datasetDidBegin: { [self] in
          guard let opened = applicationDatasetContext, opened.datasetID == id else { throw VoiceAgentError.contextChanged }
          try didBegin(opened)
          expected = opened
        })
    }
    guard let expected else { throw VoiceAgentError.contextChanged }
    let deadline = ContinuousClock.now + .seconds(300)
    while true {
      try Task.checkCancellation()
      try validateContext()
      guard let current = applicationDatasetContext, current.hasSameOpening(as: expected) else { throw VoiceAgentError.contextChanged }
      if let ready = context, ready.hasSameOpening(as: expected) {
        try didBegin(ready)
        return ["structuredContent": try stateSnapshot()]
      }
      guard ContinuousClock.now < deadline else { throw VoiceAgentError.timedOut }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private static func domain(_ command: BorgVRCommand) -> String? {
    switch command {
      case .setTransform, .rotate: return "transform"
      case .setClipping: return "clipping"
      case .setTransferFunction: return "transfer_function"
      case .setLighting: return "lighting"
      case .setRenderMode, .setNormalizedIsoValue, .setBackground, .setScreenProjection,
           .setBoundingBox, .setRenderOptimizations, .restoreDatasetViewState: return "rendering"
      case .setAnnotationVisibility, .upsertObject, .removeObject, .clearObjects,
           .upsertMeasurement, .removeMeasurement, .clearMeasurements: return "annotations"
      case .reset(let scope):
        switch scope {
          case .transform: return "transform"
          case .clipping: return "clipping"
          case .transferFunction: return "transfer_function"
          case .lighting: return "lighting"
          case .all: return "rendering"
        }
      case .mutation(let domain):
        switch domain {
          case .transferFunction: return "transfer_function"
          case .objects, .measurements: return "annotations"
          case .visualization: return "rendering"
          case .interaction: return nil
        }
      case .action(let action):
        switch action {
          case .editVolume, .discardVolumeEdits: return "volume"
          default: return nil
        }
      default: return nil
    }
  }
}

extension VoiceAgentController {
  func configure(service: any BorgVRMCPCommandService, isReady: @escaping () -> Bool = { true },
                 beginImport: (() throws -> VoiceAgentImportLease)? = nil,
                 context: @escaping () -> VoiceAgentContext?) {
    configure(bridge: BorgVRVoiceAgentBridge(service: service, isReady: isReady, beginImport: beginImport, context: context))
  }
}
