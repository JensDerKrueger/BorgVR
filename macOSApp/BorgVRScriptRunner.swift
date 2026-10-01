import AppKit
import Foundation
import Metal
import SwiftUI
import simd

@MainActor
final class BorgVRScriptRunner: ObservableObject {
  private enum ScriptInputKind: Equatable {
    case text
    case file
    case directory
  }

  private struct ScriptInputRequest: Equatable {
    let kind: ScriptInputKind
    let prompt: String
  }

  private enum ScriptImportKind: Equatable {
    case file
    case dicomDirectory
  }

  private struct ScriptImportRequest: Equatable {
    let id: UUID
    let kind: ScriptImportKind
    let source: String
    let destination: String
    let datasetDescription: String

    static func == (lhs: ScriptImportRequest, rhs: ScriptImportRequest) -> Bool {
      lhs.kind == rhs.kind &&
      lhs.source == rhs.source &&
      lhs.destination == rhs.destination &&
      lhs.datasetDescription == rhs.datasetDescription
    }
  }

  @Published private(set) var isRunning = false
  @Published private(set) var statusText = String(localized: "No script active")
  @Published private(set) var scriptURL: URL?
  @Published private(set) var scriptLogText = ""
  @Published private(set) var scriptProgressText = ""
  @Published private(set) var scriptProgressValue: Double?
  @Published private(set) var scriptLogWindowRequest = 0

  private let interpreter = CommandInterpreter()
  private var executionTask: Task<Void, Never>?
  private var commandsRegistered = false

  private weak var appModel: AppModel?
  private weak var renderingParameters: RenderingParameters?
  private weak var appSettings: AppSettings?
  private weak var storedAppModel: StoredAppModel?
  private weak var sharePlay: SharePlayCoordinator?
  private weak var docking: DockingController?

  private var outputSubdirectory = ""
  private var logFileURL: URL?
  private var logFileAccessURL: URL?

  private var pendingDatasetID: String?
  private var pendingDatasetDescription: String?
  private var pendingDatasetResult: CommandResultCode?
  private var pendingScreenshotKey: String?
  private var pendingScreenshotResult: CommandResultCode?
  private var pendingWaitFrameTarget: UInt64?
  private var pendingWaitLoadedStartReadback: UInt64?
  private var pendingWaitLoadedRequiredEmptyReadbacks: UInt64 = 3
  private var pendingWaitLoadedFrameTarget: UInt64?
  private var pendingWaitLoadedDatasetKey: String?
  private var pendingScriptInput: ScriptInputRequest?
  private var pendingScriptInputValue: String?
  private var scriptInputURLs: [String: URL] = [:]
  private var pendingScriptImport: ScriptImportRequest?
  private var pendingScriptImportResult: CommandResultCode?
  private var importBrickSizeOverride: Int?
  private var importOverlapOverride: Int?
  private var importBorderModeOverride: ExtensionStrategy?
  private var initialRenderDisplaySyncEnabled: Bool?

  deinit {
    executionTask?.cancel()
    storedAppModel?.stopAccessingDataDirectory(logFileAccessURL)
  }

  func configure(
    appModel: AppModel,
    renderingParameters: RenderingParameters,
    appSettings: AppSettings,
    storedAppModel: StoredAppModel,
    sharePlay: SharePlayCoordinator,
    docking: DockingController
  ) {
    self.appModel = appModel
    self.renderingParameters = renderingParameters
    self.appSettings = appSettings
    self.storedAppModel = storedAppModel
    self.sharePlay = sharePlay
    self.docking = docking

    if !commandsRegistered {
      registerCommands()
      commandsRegistered = true
    }
  }

  func showOpenPanelAndRun() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.title = String(localized: "Run Script")
    panel.message = String(localized: "Choose a BorgVR gsc script.")

    if panel.runModal() == .OK, let url = panel.url {
      runScript(at: url)
    }
  }

  func runScript(at url: URL) {
    stopScript()
    scriptURL = url
    scriptLogText = ""
    scriptProgressText = ""
    scriptProgressValue = nil
    scriptLogWindowRequest &+= 1
    outputSubdirectory = ""
    scriptInputURLs.removeAll()
    importBrickSizeOverride = nil
    importOverlapOverride = nil
    importBorderModeOverride = nil
    logFileURL = nil
    storedAppModel?.stopAccessingDataDirectory(logFileAccessURL)
    logFileAccessURL = nil

    let hasSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let result = interpreter.loadFromFile(url.path)
    guard result == .success else {
      logError("Script could not be loaded: \(result)")
      return
    }

    initialRenderDisplaySyncEnabled = appModel?.renderDisplaySyncEnabled
    isRunning = true
    statusText = String(format: String(localized: "Script running: %@"), url.lastPathComponent)
    logInfo("Script started: \(url.lastPathComponent)")

    executionTask = Task { [weak self] in
      await self?.runLoop()
    }
  }

  func stopScript() {
    executionTask?.cancel()
    executionTask = nil
    pendingDatasetID = nil
    pendingDatasetDescription = nil
    pendingDatasetResult = nil
    pendingScreenshotKey = nil
    pendingScreenshotResult = nil
    pendingWaitFrameTarget = nil
    pendingWaitLoadedStartReadback = nil
    pendingWaitLoadedFrameTarget = nil
    pendingWaitLoadedDatasetKey = nil
    pendingScriptInput = nil
    pendingScriptInputValue = nil
    scriptInputURLs.removeAll()
    pendingScriptImport = nil
    pendingScriptImportResult = nil
    scriptProgressText = ""
    scriptProgressValue = nil
    if isRunning {
      logInfo("Script stopped")
    }
    restoreRenderDisplaySync()
    isRunning = false
    statusText = String(localized: "No script active")
  }

  private func runLoop() async {
    while !Task.isCancelled, isRunning {
      let result = interpreter.runBatch()
      switch result {
        case .success, .triggerLoop:
          await Task.yield()
        case .waitingNoop:
          try? await Task.sleep(nanoseconds: 16_000_000)
        case .finished:
          logInfo("Script finished")
          restoreRenderDisplaySync()
          isRunning = false
          statusText = String(localized: "No script active")
          return
        default:
          let lineText = interpreter.lastErrorLine.map { " in Zeile \($0)" } ?? ""
          logError("Script error\(lineText): \(result)")
          restoreRenderDisplaySync()
          isRunning = false
          statusText = String(localized: "Script error")
          return
      }
    }
  }

  private func registerCommands() {
    register("log", [.restString]) { [weak self] args in
      self?.logInfo(args.restString) ?? .callbackError
    }

    register("logfile", [.string]) { [weak self] args in
      self?.setLogFile(args.string(0)) ?? .callbackError
    }

    register("clearlog", []) { [weak self] _ in
      self?.clearLogFile() ?? .callbackError
    }

    register("logtime", []) { [weak self] _ in
      let formatter = ISO8601DateFormatter()
      return self?.logInfo(formatter.string(from: Date())) ?? .callbackError
    }

    register("logGPUInfo", []) { [weak self] _ in
      self?.logGPUInfo(includeFamilies: true) ?? .callbackError
    }

    register("logGPUInfo", [.bool]) { [weak self] args in
      self?.logGPUInfo(includeFamilies: args.bool(0)) ?? .callbackError
    }

    register("setdir", [.string]) { [weak self] args in
      self?.setOutputDirectory(args.string(0)) ?? .callbackError
    }

    registerValue("input", [.restString]) { [weak self] args in
      self?.requestScriptInput(.text, prompt: args.restString) ?? .status(.callbackError)
    }

    registerValue("fileinput", [.restString]) { [weak self] args in
      self?.requestScriptInput(.file, prompt: args.restString) ?? .status(.callbackError)
    }

    registerValue("dirinput", [.restString]) { [weak self] args in
      self?.requestScriptInput(.directory, prompt: args.restString) ?? .status(.callbackError)
    }

    register("importfile", [.string, .string, .string]) { [weak self] args in
      self?.importDataset(
        kind: .file,
        source: args.string(0),
        destination: args.string(1),
        datasetDescription: args.string(2)
      ) ?? .callbackError
    }

    register("importdirectory", [.string, .string, .string]) { [weak self] args in
      self?.importDataset(
        kind: .dicomDirectory,
        source: args.string(0),
        destination: args.string(1),
        datasetDescription: args.string(2)
      ) ?? .callbackError
    }

    register("setimportbricksize", [.int]) { [weak self] args in
      self?.setImportBrickSize(args.int(0)) ?? .callbackError
    }
    register("setimportbrickssize", [.int]) { [weak self] args in
      self?.setImportBrickSize(args.int(0)) ?? .callbackError
    }

    register("setimportoverlap", [.int]) { [weak self] args in
      self?.setImportOverlap(args.int(0)) ?? .callbackError
    }

    register("setbordermode", [.int]) { [weak self] args in
      self?.setImportBorderMode(args.int(0)) ?? .callbackError
    }
    register("setbaordermode", [.int]) { [weak self] args in
      self?.setImportBorderMode(args.int(0)) ?? .callbackError
    }

    register("screenshot", []) { [weak self] _ in
      self?.takeScreenshot(filename: nil) ?? .callbackError
    }

    register("screenshot", [.string]) { [weak self] args in
      self?.takeScreenshot(filename: args.string(0)) ?? .callbackError
    }

    register("resize", [.int, .int]) { [weak self] args in
      self?.resize(width: args.int(0), height: args.int(1)) ?? .callbackError
    }

    register("quit", []) { _ in
      NSApp.terminate(nil)
      return .success
    }

    register("opendataset", [.string]) { [weak self] args in
      self?.openDataset(id: args.string(0)) ?? .callbackError
    }

    register("reset", []) { [weak self] _ in
      self?.resetRendering() ?? .callbackError
    }

    register("resetrotation", []) { [weak self] _ in
      guard let parameters = self?.renderingParameters else { return .callbackError }
      parameters.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
      self?.synchronizeTransform()
      return .success
    }

    register("addrotationx", [.float]) { [weak self] args in
      self?.addRotation(axis: SIMD3<Float>(1, 0, 0), degrees: args.float(0)) ?? .callbackError
    }

    register("addrotationy", [.float]) { [weak self] args in
      self?.addRotation(axis: SIMD3<Float>(0, 1, 0), degrees: args.float(0)) ?? .callbackError
    }

    register("addrotationz", [.float]) { [weak self] args in
      self?.addRotation(axis: SIMD3<Float>(0, 0, 1), degrees: args.float(0)) ?? .callbackError
    }

    register("settranslation", [.float, .float]) { [weak self] args in
      guard let parameters = self?.renderingParameters else { return .callbackError }
      parameters.pan = SIMD2<Float>(args.float(0), args.float(1))
      self?.synchronizeTransform()
      return .success
    }

    register("zoom", [.float]) { [weak self] args in
      self?.setScale(args.float(0)) ?? .callbackError
    }

    register("setscale", [.float]) { [weak self] args in
      self?.setScale(args.float(0)) ?? .callbackError
    }

    register("rendermode", [.string]) { [weak self] args in
      self?.setRenderMode(args.string(0)) ?? .callbackError
    }

    register("setmethod", [.int]) { [weak self] args in
      self?.setRenderMethod(args.int(0)) ?? .callbackError
    }

    register("clip", [.float, .float, .float, .float, .float, .float]) { [weak self] args in
      self?.setClip(args) ?? .callbackError
    }

    register("resetclip", []) { [weak self] _ in
      guard let parameters = self?.renderingParameters else { return .callbackError }
      parameters.clipMin = SIMD3<Float>(0, 0, 0)
      parameters.clipMax = SIMD3<Float>(1, 1, 1)
      parameters.clippingTranslation = SIMD3<Float>(0, 0, 0)
      self?.synchronizeState()
      return .success
    }

    register("isovalue", [.float]) { [weak self] args in
      self?.setIsoValue(rawValue: args.float(0)) ?? .callbackError
    }

    register("isovalueNormalized", [.float]) { [weak self] args in
      self?.setIsoValue(normalizedValue: args.float(0)) ?? .callbackError
    }

    register("settffile", [.string]) { [weak self] args in
      self?.loadTransferFunction(filename: args.string(0)) ?? .callbackError
    }

    register("loadtf", [.string]) { [weak self] args in
      self?.loadTransferFunction(filename: args.string(0)) ?? .callbackError
    }

    register("savetffile", [.string]) { [weak self] args in
      self?.saveTransferFunction(filename: args.string(0)) ?? .callbackError
    }

    register("savetf", [.string]) { [weak self] args in
      self?.saveTransferFunction(filename: args.string(0)) ?? .callbackError
    }

    register("setlightdirection", [.float, .float, .float]) { [weak self] args in
      self?.setLightDirection(args) ?? .callbackError
    }

    register("setambientlight", [.float, .float, .float]) { [weak self] args in
      self?.setLightColor(\.ambientLightColor, arguments: args) ?? .callbackError
    }

    register("setdiffuselight", [.float, .float, .float]) { [weak self] args in
      self?.setLightColor(\.diffuseLightColor, arguments: args) ?? .callbackError
    }

    register("setspecularlight", [.float, .float, .float]) { [weak self] args in
      self?.setLightColor(\.specularLightColor, arguments: args) ?? .callbackError
    }

    register("resetlighting", []) { [weak self] _ in
      self?.resetLighting() ?? .callbackError
    }

    register("addspheremarker", [.string, .float, .float, .float, .float, .float, .float, .float]) { [weak self] args in
      self?.addSphereMarker(args, directional: false) ?? .callbackError
    }

    register(
      "adddirectionalmarker",
      [.string, .float, .float, .float, .float, .float, .float, .float, .float, .float, .float]
    ) { [weak self] args in
      self?.addSphereMarker(args, directional: true) ?? .callbackError
    }

    register("addstrokemarker", [.string, .float, .float, .float, .float, .restString]) { [weak self] args in
      self?.addStrokeMarker(args) ?? .callbackError
    }

    register("removemarker", [.string]) { [weak self] args in
      self?.removeMarker(identifier: args.string(0)) ?? .callbackError
    }

    register("clearmarkers", []) { [weak self] _ in
      self?.clearMarkers() ?? .callbackError
    }

    register("loadmarkers", [.string]) { [weak self] args in
      self?.loadMarkers(filename: args.string(0), replacingExisting: true) ?? .callbackError
    }

    register("loadmarkers", [.string, .bool]) { [weak self] args in
      self?.loadMarkers(filename: args.string(0), replacingExisting: args.bool(1)) ?? .callbackError
    }

    register("savemarkers", [.string]) { [weak self] args in
      self?.saveMarkers(filename: args.string(0)) ?? .callbackError
    }

    register("setbackground", [.double, .double, .double, .double]) { [weak self] args in
      self?.setSolidBackground(red: args.double(0), green: args.double(1), blue: args.double(2), alpha: args.double(3)) ?? .callbackError
    }

    register("background", [.string]) { [weak self] args in
      self?.setBackgroundMode(args.string(0)) ?? .callbackError
    }

    register("background", [.string, .double, .double, .double]) { [weak self] args in
      guard args.string(0).lowercased() == "solid" else { return .invalidArguments }
      return self?.setSolidBackground(red: args.double(1), green: args.double(2), blue: args.double(3), alpha: 1) ?? .callbackError
    }

    register("background", [.string, .double, .double, .double, .double, .double, .double]) { [weak self] args in
      guard args.string(0).lowercased() == "gradient" else { return .invalidArguments }
      return self?.setGradientBackground(args) ?? .callbackError
    }

    register("resetfps", []) { [weak self] _ in
      self?.appModel?.timer?.reset()
      return .success
    }

    register("setfpswindow", [.double]) { [weak self] args in
      self?.appModel?.timer?.historyDuration = args.double(0)
      return .success
    }

    register("setDisplaySync", [.bool]) { [weak self] args in
      self?.setDisplaySyncEnabled(args.bool(0)) ?? .callbackError
    }

    register("logfps", []) { [weak self] _ in
      self?.logFPS() ?? .callbackError
    }

    register("waitframes", [.int]) { [weak self] args in
      self?.waitFrames(args.int(0)) ?? .callbackError
    }

    register("waitloaded", []) { [weak self] _ in
      self?.waitLoaded(requiredEmptyReadbacks: 3) ?? .callbackError
    }

    register("waitloaded", [.int]) { [weak self] args in
      self?.waitLoaded(requiredEmptyReadbacks: args.int(0)) ?? .callbackError
    }

    register("waitidle", []) { [weak self] _ in
      self?.waitLoaded(requiredEmptyReadbacks: 3) ?? .callbackError
    }

    register("waitidle", [.int]) { [weak self] args in
      self?.waitLoaded(requiredEmptyReadbacks: args.int(0)) ?? .callbackError
    }
  }

  private func register(
    _ name: String,
    _ signature: [ArgType],
    _ callback: @escaping CommandInterpreter.CommandCallback
  ) {
    interpreter.registerCommand(name, signature, callback)
  }

  private func registerValue(
    _ name: String,
    _ signature: [ArgType],
    _ callback: @escaping CommandInterpreter.ValueCommandCallback
  ) {
    interpreter.registerValueCommand(name, signature, callback)
  }

  private func requestScriptInput(
    _ kind: ScriptInputKind,
    prompt: String
  ) -> CommandValueResult {
    let request = ScriptInputRequest(kind: kind, prompt: prompt)
    if pendingScriptInput == request {
      guard let value = pendingScriptInputValue else {
        return .status(.waitingNoop)
      }
      pendingScriptInput = nil
      pendingScriptInputValue = nil
      return .value(value)
    }

    guard pendingScriptInput == nil else {
      return .status(.callbackError)
    }
    pendingScriptInput = request
    pendingScriptInputValue = nil

    switch kind {
      case .text:
        presentTextInput(for: request)
      case .file:
        presentFileInput(for: request, choosesDirectories: false)
      case .directory:
        presentFileInput(for: request, choosesDirectories: true)
    }
    return .status(.waitingNoop)
  }

  private func presentTextInput(for request: ScriptInputRequest) {
    let alert = NSAlert()
    alert.messageText = request.prompt
    alert.addButton(withTitle: String(localized: "OK"))
    alert.addButton(withTitle: String(localized: "Cancel"))

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    alert.accessoryView = textField
    alert.window.initialFirstResponder = textField

    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      Task { @MainActor in
        if response == .alertFirstButtonReturn {
          self?.completeScriptInput(request, value: textField.stringValue)
        } else {
          self?.cancelScriptInput(request)
        }
      }
    }

    if let window = scriptDialogWindow {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  private func presentFileInput(
    for request: ScriptInputRequest,
    choosesDirectories: Bool
  ) {
    let panel = NSOpenPanel()
    panel.title = request.prompt
    panel.message = request.prompt
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = choosesDirectories
    panel.canChooseFiles = !choosesDirectories
    panel.canCreateDirectories = choosesDirectories

    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      Task { @MainActor in
        if response == .OK, let url = panel.url {
          self?.rememberScriptInputURL(url)
          self?.completeScriptInput(request, value: url.path)
        } else {
          self?.cancelScriptInput(request)
        }
      }
    }

    if let window = scriptDialogWindow {
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  private var scriptDialogWindow: NSWindow? {
    NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
  }

  private func completeScriptInput(
    _ request: ScriptInputRequest,
    value: String
  ) {
    guard isRunning, pendingScriptInput == request else { return }
    pendingScriptInputValue = value
  }

  private func cancelScriptInput(_ request: ScriptInputRequest) {
    guard pendingScriptInput == request else { return }
    pendingScriptInput = nil
    pendingScriptInputValue = nil
    logInfo("Script input cancelled")
    stopScript()
  }

  private func rememberScriptInputURL(_ url: URL) {
    scriptInputURLs[url.standardizedFileURL.path] = url
  }

  private func setImportBrickSize(_ value: Int) -> CommandResultCode {
    guard value >= 1 else { return .invalidArguments }
    importBrickSizeOverride = value
    return logInfo("Script import brick size: \(value)")
  }

  private func setImportOverlap(_ value: Int) -> CommandResultCode {
    guard value >= 1 else { return .invalidArguments }
    importOverlapOverride = value
    return logInfo("Script import overlap: \(value)")
  }

  private func setImportBorderMode(_ value: Int) -> CommandResultCode {
    switch value {
      case 0:
        importBorderModeOverride = .fillZeroes
      case 1:
        importBorderModeOverride = .clamp
      case 2:
        importBorderModeOverride = .repeatValue
      default:
        return .invalidArguments
    }
    return logInfo("Script import border mode: \(value)")
  }

  private func importDataset(
    kind: ScriptImportKind,
    source: String,
    destination: String,
    datasetDescription: String
  ) -> CommandResultCode {
    if let pendingScriptImport,
       pendingScriptImport.kind == kind,
       pendingScriptImport.source == source,
       pendingScriptImport.destination == destination,
       pendingScriptImport.datasetDescription == datasetDescription {
      guard let result = pendingScriptImportResult else {
        return .waitingNoop
      }
      self.pendingScriptImport = nil
      pendingScriptImportResult = nil
      return result
    }

    guard pendingScriptImport == nil,
          let storedAppModel,
          let logger = appModel?.logger,
          !source.isEmpty,
          !destination.isEmpty else {
      return .callbackError
    }

    let settings = ScriptDatasetConverter.Settings(
      brickSize: importBrickSizeOverride ?? storedAppModel.brickSize,
      overlap: importOverlapOverride ?? storedAppModel.brickOverlap,
      useCompression: storedAppModel.enableCompression,
      extensionStrategy: importBorderModeOverride ?? Self.extensionStrategy(
        for: storedAppModel.borderModeString
      )
    )
    guard settings.isValid else {
      logError(
        "Invalid import settings: brick size \(settings.brickSize), overlap \(settings.overlap)"
      )
      return .invalidArguments
    }

    let sourceURL = scriptPathURL(source, isDirectory: kind == .dicomDirectory)
    let destinationURL = scriptOutputURL(destination, defaultExtension: "data")
    let request = ScriptImportRequest(
      id: UUID(),
      kind: kind,
      source: source,
      destination: destination,
      datasetDescription: datasetDescription
    )
    pendingScriptImport = request
    pendingScriptImportResult = nil

    let dataDirectoryAccessURL = storedAppModel.startAccessingDataDirectory()
    let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
    let destinationDirectory = destinationURL.deletingLastPathComponent()
    let destinationAccess = destinationDirectory.startAccessingSecurityScopedResource()
    let scriptLogger = ScriptExecutionLogger(
      destination: logger,
      onMessage: { [weak self] level, message in
        Task { @MainActor in
          self?.appendScriptLog(level: level, message: message)
        }
      },
      onProgress: { [weak self] message, progress in
        Task { @MainActor in
          self?.scriptProgressText = message
          self?.scriptProgressValue = progress
        }
      }
    )
    let importContext = ScriptDatasetConverter.Context(settings: settings, logger: scriptLogger)
    logInfo("Import started: \(sourceURL.path) -> \(destinationURL.path)")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result: Result<Void, Error>
      do {
        switch kind {
          case .file:
            try ScriptDatasetConverter.importFile(
              from: sourceURL,
              to: destinationURL,
              datasetDescription: datasetDescription,
              settings: importContext.settings,
              logger: importContext.logger
            )
          case .dicomDirectory:
            try ScriptDatasetConverter.importDICOMDirectory(
              from: sourceURL,
              to: destinationURL,
              datasetDescription: datasetDescription,
              settings: importContext.settings,
              logger: importContext.logger
            )
        }
        result = .success(())
      } catch {
        result = .failure(error)
      }

      if sourceAccess {
        sourceURL.stopAccessingSecurityScopedResource()
      }
      if destinationAccess {
        destinationDirectory.stopAccessingSecurityScopedResource()
      }

      Task { @MainActor in
        self?.storedAppModel?.stopAccessingDataDirectory(dataDirectoryAccessURL)
        self?.completeScriptImport(requestID: request.id, destinationURL: destinationURL, result: result)
      }
    }

    return .waitingNoop
  }

  private func completeScriptImport(
    requestID: UUID,
    destinationURL: URL,
    result: Result<Void, Error>
  ) {
    guard pendingScriptImport?.id == requestID else { return }
    switch result {
      case .success:
        scriptProgressText = ""
        scriptProgressValue = nil
        logInfo("Import completed: \(destinationURL.path)")
        pendingScriptImportResult = .success
      case let .failure(error):
        scriptProgressText = ""
        scriptProgressValue = nil
        logError("Import failed: \(error.localizedDescription)")
        pendingScriptImportResult = .callbackError
    }
  }

  private func scriptPathURL(_ path: String, isDirectory: Bool) -> URL {
    if NSString(string: path).isAbsolutePath {
      let standardizedPath = URL(fileURLWithPath: path, isDirectory: isDirectory)
        .standardizedFileURL.path
      return scriptInputURLs[standardizedPath]
        ?? URL(fileURLWithPath: path, isDirectory: isDirectory)
    }
    return outputDirectoryURL().appendingPathComponent(path, isDirectory: isDirectory)
  }

  private func scriptOutputURL(_ path: String, defaultExtension: String) -> URL {
    var url = scriptPathURL(path, isDirectory: false)
    if url.pathExtension.isEmpty {
      url.appendPathExtension(defaultExtension)
    }
    return url
  }

  private static func extensionStrategy(for value: String) -> ExtensionStrategy {
    switch value {
      case "border": return .clamp
      case "repeat": return .repeatValue
      default: return .fillZeroes
    }
  }

  private func setOutputDirectory(_ path: String) -> CommandResultCode {
    outputSubdirectory = path
    let directory = outputDirectoryURL()
    do {
      let accessURL = storedAppModel?.startAccessingDataDirectory()
      defer { storedAppModel?.stopAccessingDataDirectory(accessURL) }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return logInfo("Script output directory: \(directory.path)")
    } catch {
      logError("Output directory could not be created: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func takeScreenshot(filename: String?) -> CommandResultCode {
    let key = filename ?? "<default>"
    if pendingScreenshotKey == key {
      if let result = pendingScreenshotResult {
        pendingScreenshotKey = nil
        pendingScreenshotResult = nil
        return result
      }
      return .waitingNoop
    }

    let url = screenshotURL(filename: filename)
    let accessURL = storedAppModel?.startAccessingDataDirectory()
    pendingScreenshotKey = key
    pendingScreenshotResult = nil
    appModel?.requestRenderScreenshot(to: url, accessURL: accessURL) { [weak self] result in
      Task { @MainActor in
        switch result {
          case let .success(url):
            self?.logInfo("Screenshot gespeichert: \(url.path)")
            self?.pendingScreenshotResult = .success
          case let .failure(error):
            self?.logError("Screenshot failed: \(error.localizedDescription)")
            self?.pendingScreenshotResult = .callbackError
        }
      }
    }
    return .waitingNoop
  }

  private func resize(width: Int, height: Int) -> CommandResultCode {
    guard width > 0, height > 0 else { return .invalidArguments }
    let size = NSSize(width: width, height: height)
    let window = NSApp.keyWindow ?? NSApp.windows.first { $0.title.contains("BorgVR") }
    window?.setContentSize(size)
    return .success
  }

  private func openDataset(id: String) -> CommandResultCode {
    if pendingDatasetID == id {
      if let result = pendingDatasetResult {
        pendingDatasetID = nil
        pendingDatasetDescription = nil
        pendingDatasetResult = nil
        return result
      }
      if appModel?.rendererHasActiveDataset == true {
        let description = pendingDatasetDescription ?? id
        pendingDatasetID = nil
        pendingDatasetDescription = nil
        return logInfo("Dataset ready in renderer: \(description)")
      }
      if appModel?.rendererFailedActiveDataset == true {
        pendingDatasetID = nil
        pendingDatasetDescription = nil
        logError("Renderer could not open dataset: \(id)")
        return .callbackError
      }
      return .waitingNoop
    }

    guard let appSettings, let storedAppModel, let appModel else { return .callbackError }
    pendingDatasetID = id
    pendingDatasetDescription = nil
    pendingDatasetResult = nil

    Task { [weak self] in
      let catalog = DatasetCatalogService(
        appSettings: appSettings,
        storedAppModel: storedAppModel,
        logger: appModel.logger
      )
      guard let dataset = await catalog.dataset(matchingID: id) else {
        await self?.completeDatasetOpen(result: .callbackError, message: "Dataset not found: \(id)")
        return
      }

      let openable = catalog.openableDataset(from: dataset)
      appModel.openDataset(
        openable,
        asGroupSessionHost: self?.sharePlay?.isInSession == true ? nil : true
      )
      self?.docking?.resetForDatasetClose()
      self?.sharePlay?.datasetOpened()
      self?.pendingDatasetDescription = openable.description
      self?.logInfo("Dataset selected: \(openable.description)")
    }

    return .waitingNoop
  }

  private func completeDatasetOpen(result: CommandResultCode, message: String) async {
    if result == .success {
      logInfo(message)
    } else {
      logError(message)
    }
    pendingDatasetResult = result
  }

  private func resetRendering() -> CommandResultCode {
    renderingParameters?.reset()
    sharePlay?.synchronize(kind: .full)
    return .success
  }

  private func addRotation(axis: SIMD3<Float>, degrees: Float) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let radians = degrees * .pi / 180
    let rotation = simd_quatf(angle: radians, axis: axis)
    parameters.orientation = simd_normalize(rotation * parameters.orientation)
    synchronizeTransform()
    return .success
  }

  private func setScale(_ scale: Float) -> CommandResultCode {
    guard scale > 0, let parameters = renderingParameters else { return .invalidArguments }
    parameters.scale = scale
    synchronizeTransform()
    return .success
  }

  private func setRenderMode(_ value: String) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    switch value.lowercased() {
      case "tf", "transfer", "transferfunction", "transferfunction1d":
        parameters.renderMode = .transferFunction1D
      case "tflighting", "tfillum", "illum", "lighting":
        parameters.renderMode = .transferFunction1DLighting
      case "iso", "isovalue":
        parameters.renderMode = .isoValue
      default:
        return .invalidArguments
    }
    docking?.hideIncompatibleEditor(for: parameters.renderMode)
    synchronizeState()
    return .success
  }

  private func setRenderMethod(_ index: Int) -> CommandResultCode {
    switch index {
      case 0: return setRenderMode("tf")
      case 1: return setRenderMode("tflighting")
      case 2: return setRenderMode("iso")
      default: return .invalidArguments
    }
  }

  private func setClip(_ args: [CommandArg]) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let minValues = SIMD3<Float>(
      clamp(args.float(0)),
      clamp(args.float(2)),
      clamp(args.float(4))
    )
    let maxValues = SIMD3<Float>(
      clamp(args.float(1)),
      clamp(args.float(3)),
      clamp(args.float(5))
    )
    guard minValues.x <= maxValues.x,
          minValues.y <= maxValues.y,
          minValues.z <= maxValues.z else {
      return .invalidArguments
    }
    parameters.clipMin = minValues
    parameters.clipMax = maxValues
    parameters.clippingTranslation = SIMD3<Float>(0, 0, 0)
    synchronizeState()
    return .success
  }

  private func setIsoValue(rawValue: Float) -> CommandResultCode {
    guard let parameters = renderingParameters,
          parameters.maxValue > 0 else {
      return .callbackError
    }
    parameters.normIsoValue = clamp(rawValue * Float(max(parameters.rangeMax, 1)) / Float(parameters.maxValue))
    synchronizeState()
    return .success
  }

  private func setIsoValue(normalizedValue: Float) -> CommandResultCode {
    renderingParameters?.normIsoValue = clamp(normalizedValue)
    synchronizeState()
    return .success
  }

  private func loadTransferFunction(filename: String) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let url = scriptFileURL(filename: filename, defaultExtension: "tf1d")
    do {
      parameters.objectWillChange.send()
      try parameters.loadTransferFunction(from: url)
      sharePlay?.synchronize(kind: .full)
      return logInfo("Transfer function loaded: \(url.path)")
    } catch {
      logError("Transfer function could not be loaded: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func saveTransferFunction(filename: String) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let url = scriptFileURL(filename: filename, defaultExtension: "tf1d")
    do {
      let accessURL = storedAppModel?.startAccessingDataDirectory()
      defer { storedAppModel?.stopAccessingDataDirectory(accessURL) }
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try parameters.transferFunction.save(to: url)
      return logInfo("Transfer function saved: \(url.path)")
    } catch {
      logError("Transfer function could not be saved: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func setLightDirection(_ args: [CommandArg]) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let direction = SIMD3<Float>(args.float(0), args.float(1), args.float(2))
    guard isFinite(direction), simd_length_squared(direction) > 0.000_001 else {
      return .invalidArguments
    }
    parameters.lightDirection = simd_normalize(direction)
    synchronizeLighting()
    return .success
  }

  private func setLightColor(
    _ keyPath: ReferenceWritableKeyPath<RenderingParameters, SIMD3<Float>>,
    arguments: [CommandArg]
  ) -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let color = SIMD3<Float>(arguments.float(0), arguments.float(1), arguments.float(2))
    guard isFinite(color),
          color.x >= 0, color.x <= 1,
          color.y >= 0, color.y <= 1,
          color.z >= 0, color.z <= 1 else {
      return .invalidArguments
    }
    parameters[keyPath: keyPath] = color
    synchronizeLighting()
    return .success
  }

  private func resetLighting() -> CommandResultCode {
    guard let parameters = renderingParameters else { return .callbackError }
    let defaults = BorgVRLightingState.default
    parameters.lightDirection = defaults.direction
    parameters.ambientLightColor = defaults.ambientColor
    parameters.diffuseLightColor = defaults.diffuseColor
    parameters.specularLightColor = defaults.specularColor
    synchronizeLighting()
    return .success
  }

  private func addSphereMarker(
    _ args: [CommandArg],
    directional: Bool
  ) -> CommandResultCode {
    guard let appModel else { return .callbackError }
    let name = markerName(args.string(0))
    let position = SIMD3<Float>(args.float(1), args.float(2), args.float(3))
    let radius = args.float(4)
    let color = SIMD4<Float>(args.float(5), args.float(6), args.float(7), 1)
    guard !name.isEmpty,
          isFinite(position),
          radius.isFinite,
          isFinite(color),
          validColor(color),
          VolumeMarkerRadius.sphereRange.contains(radius) else {
      return .invalidArguments
    }

    let marker: VolumeMarker
    if directional {
      let origin = SIMD3<Float>(args.float(8), args.float(9), args.float(10))
      guard isFinite(origin) else { return .invalidArguments }
      marker = VolumeMarker(
        id: UUID(),
        name: name,
        position: position,
        radius: radius,
        color: color,
        directionOrigin: origin,
        showsDirection: true
      )
    } else {
      marker = VolumeMarker(
        id: UUID(),
        name: name,
        color: color,
        geometry: .sphere(VolumeMarkerPoint(position: position, radius: radius))
      )
    }

    appModel.volumeMarkers.append(marker)
    synchronizeMarkers()
    return logInfo("Marker added: \(name) [\(marker.id.uuidString)]")
  }

  private func addStrokeMarker(_ args: [CommandArg]) -> CommandResultCode {
    guard let appModel else { return .callbackError }
    let name = markerName(args.string(0))
    let radius = args.float(1)
    let color = SIMD4<Float>(args.float(2), args.float(3), args.float(4), 1)
    let coordinateTokens = args.strings(5)
    guard !name.isEmpty,
          radius.isFinite,
          VolumeMarkerRadius.strokeRange.contains(radius),
          isFinite(color),
          validColor(color),
          !coordinateTokens.isEmpty,
          coordinateTokens.count.isMultiple(of: 3) else {
      return .invalidArguments
    }

    var points: [VolumeMarkerPoint] = []
    points.reserveCapacity(coordinateTokens.count / 3)
    for index in stride(from: 0, to: coordinateTokens.count, by: 3) {
      guard let x = Float(coordinateTokens[index]),
            let y = Float(coordinateTokens[index + 1]),
            let z = Float(coordinateTokens[index + 2]) else {
        return .invalidArguments
      }
      let position = SIMD3<Float>(x, y, z)
      guard isFinite(position) else { return .invalidArguments }
      points.append(VolumeMarkerPoint(position: position, radius: radius))
    }

    guard points.count <= VolumeMarker.maximumInteractiveStrokePointCount else {
      return .invalidArguments
    }
    let marker = VolumeMarker(
      id: UUID(),
      name: name,
      color: color,
      geometry: .stroke(points)
    )
    appModel.volumeMarkers.append(marker)
    synchronizeMarkers()
    return logInfo("Stroke marker added: \(name) [\(marker.id.uuidString)]")
  }

  private func removeMarker(identifier: String) -> CommandResultCode {
    guard let appModel else { return .callbackError }
    let index: Int?
    if let id = UUID(uuidString: identifier) {
      index = appModel.volumeMarkers.firstIndex { $0.id == id }
    } else {
      index = appModel.volumeMarkers.firstIndex {
        $0.name.caseInsensitiveCompare(identifier) == .orderedSame
      }
    }
    guard let index else { return .invalidArguments }
    let marker = appModel.volumeMarkers[index]
    guard appModel.removeVolumeMarkers(withIDs: [marker.id]) else {
      return .callbackError
    }
    synchronizeMarkers()
    return logInfo("Marker removed: \(marker.name) [\(marker.id.uuidString)]")
  }

  private func clearMarkers() -> CommandResultCode {
    guard let appModel else { return .callbackError }
    if appModel.removeAllVolumeMarkers() {
      synchronizeMarkers()
    }
    return .success
  }

  private func loadMarkers(
    filename: String,
    replacingExisting: Bool
  ) -> CommandResultCode {
    guard let appModel else { return .callbackError }
    let url = scriptFileURL(filename: filename, defaultExtension: "marker")
    do {
      let contents = try VolumeMarkerDocument.decode(
        from: Data(contentsOf: url, options: .mappedIfSafe)
      )
      if let datasetID = appModel.activeDataset?.uniqueId,
         contents.datasetID.caseInsensitiveCompare(datasetID) != .orderedSame {
        logInfo(
          "Marker dataset mismatch: file=\(contents.datasetID), active=\(datasetID); loading as requested."
        )
      }
      if replacingExisting {
        appModel.volumeMarkers = contents.markers
      } else {
        appModel.volumeMarkers.append(contentsOf: markersWithUniqueIDs(contents.markers))
      }
      appModel.clearVolumeMarkerSelection()
      synchronizeMarkers()
      return logInfo("Markers loaded: \(url.path)")
    } catch {
      logError("Markers could not be loaded: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func saveMarkers(filename: String) -> CommandResultCode {
    guard let appModel, let datasetID = appModel.activeDataset?.uniqueId else {
      return .callbackError
    }
    let url = scriptFileURL(filename: filename, defaultExtension: "marker")
    do {
      let accessURL = storedAppModel?.startAccessingDataDirectory()
      defer { storedAppModel?.stopAccessingDataDirectory(accessURL) }
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try VolumeMarkerDocument.encode(
        datasetID: datasetID,
        markers: appModel.volumeMarkers
      )
      try data.write(to: url, options: .atomic)
      return logInfo("Markers saved: \(url.path)")
    } catch {
      logError("Markers could not be saved: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func markersWithUniqueIDs(_ markers: [VolumeMarker]) -> [VolumeMarker] {
    var usedIDs = Set(appModel?.volumeMarkers.map(\.id) ?? [])
    return markers.map { marker in
      var marker = marker
      if usedIDs.contains(marker.id) {
        marker.id = UUID()
      }
      usedIDs.insert(marker.id)
      return marker
    }
  }

  private func markerName(_ name: String) -> String {
    String(name.prefix(BorgVRMarkerFormat.maximumNameCharacterCount))
  }

  private func validColor(_ color: SIMD4<Float>) -> Bool {
    color.x >= 0 && color.x <= 1 &&
      color.y >= 0 && color.y <= 1 &&
      color.z >= 0 && color.z <= 1
  }

  private func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
  }

  private func isFinite(_ value: SIMD4<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
  }

  private func synchronizeLighting() {
    synchronizeState()
    sharePlay?.flushSynchronization()
  }

  private func synchronizeMarkers() {
    sharePlay?.synchronizeMarkers()
    sharePlay?.flushSynchronization()
  }

  private func setSolidBackground(red: Double, green: Double, blue: Double, alpha: Double) -> CommandResultCode {
    guard let appSettings else { return .callbackError }
    appSettings.renderBackgroundMode = RenderBackgroundMode.solid.rawValue
    appSettings.renderBackgroundPrimaryColor = Color(
      red: clamp(red),
      green: clamp(green),
      blue: clamp(blue),
      opacity: clamp(alpha)
    )
    return .success
  }

  private func setBackgroundMode(_ mode: String) -> CommandResultCode {
    guard let appSettings else { return .callbackError }
    guard let backgroundMode = RenderBackgroundMode(rawValue: mode.lowercased()) else {
      return .invalidArguments
    }
    appSettings.renderBackgroundMode = backgroundMode.rawValue
    return .success
  }

  private func setGradientBackground(_ args: [CommandArg]) -> CommandResultCode {
    guard let appSettings else { return .callbackError }
    appSettings.renderBackgroundMode = RenderBackgroundMode.gradient.rawValue
    appSettings.renderBackgroundPrimaryColor = Color(
      red: clamp(args.double(1)),
      green: clamp(args.double(2)),
      blue: clamp(args.double(3))
    )
    appSettings.renderBackgroundSecondaryColor = Color(
      red: clamp(args.double(4)),
      green: clamp(args.double(5)),
      blue: clamp(args.double(6))
    )
    return .success
  }

  private func logFPS() -> CommandResultCode {
    guard let timer = appModel?.timer else {
      logError("FPS timer is not available.")
      return .callbackError
    }

    guard timer.hasCompleteMeasurementWindow else {
      return .waitingNoop
    }

    let model = appModel
    return logInfo(
      String(
        format: "FPS window=%.2fs measured=%.2fs last=%.2f avg=%.2f smooth=%.2f min=%.2f max=%.2f frames=%llu brickReadbacks=%llu missing=%d emptyReadbacks=%llu",
        timer.historyDuration,
        timer.measurementDuration,
        timer.lastFPS,
        timer.averageFPS,
        timer.smoothedFPS,
        timer.minFPS,
        timer.maxFPS,
        timer.renderedFrameCount,
        model?.brickReadbackCount ?? 0,
        model?.lastMissingBrickCount ?? 0,
        model?.consecutiveEmptyBrickReadbacks ?? 0
      )
    )
  }

  private func setDisplaySyncEnabled(_ enabled: Bool) -> CommandResultCode {
    guard let appModel else {
      return .callbackError
    }

    appModel.setRenderDisplaySyncEnabled(enabled)
    return logInfo(enabled ? "Display Sync eingeschaltet" : "Display Sync ausgeschaltet")
  }

  private func restoreRenderDisplaySync() {
    guard let initialRenderDisplaySyncEnabled else { return }
    self.initialRenderDisplaySyncEnabled = nil
    appModel?.setRenderDisplaySyncEnabled(initialRenderDisplaySyncEnabled)
  }

  private func logGPUInfo(includeFamilies: Bool) -> CommandResultCode {
    guard let device = MTLCreateSystemDefaultDevice() else {
      logError("No Metal device available.")
      return .callbackError
    }

    logInfo("Metal device: \(device.name)")
    logInfo("Metal registryID: \(device.registryID)")
    logInfo("Metal lowPower: \(device.isLowPower)")
    logInfo("Metal headless: \(device.isHeadless)")
    logInfo("Metal removable: \(device.isRemovable)")
    logInfo("Metal unifiedMemory: \(device.hasUnifiedMemory)")
    logInfo("Metal recommendedMaxWorkingSetSize: \(device.recommendedMaxWorkingSetSize) bytes")
    logInfo(
      "Metal maxThreadsPerThreadgroup: \(device.maxThreadsPerThreadgroup.width)x\(device.maxThreadsPerThreadgroup.height)x\(device.maxThreadsPerThreadgroup.depth)"
    )

    if includeFamilies {
      let families: [(String, MTLGPUFamily)] = [
        ("common1", .common1),
        ("common2", .common2),
        ("common3", .common3),
        ("mac2", .mac2),
        ("apple1", .apple1),
        ("apple2", .apple2),
        ("apple3", .apple3),
        ("apple4", .apple4),
        ("apple5", .apple5),
        ("apple6", .apple6),
        ("apple7", .apple7),
        ("apple8", .apple8),
        ("apple9", .apple9)
      ]
      let supported = families
        .filter { device.supportsFamily($0.1) }
        .map(\.0)
        .joined(separator: ", ")
      logInfo("Metal supportedFamilies: \(supported.isEmpty ? "none" : supported)")
    }

    return .success
  }

  private func waitFrames(_ count: Int) -> CommandResultCode {
    guard count >= 0 else { return .invalidArguments }
    let current = appModel?.timer?.renderedFrameCount ?? 0
    if let target = pendingWaitFrameTarget {
      if current >= target {
        pendingWaitFrameTarget = nil
        return .success
      }
      return .waitingNoop
    }

    pendingWaitFrameTarget = current + UInt64(count)
    return count == 0 ? .success : .waitingNoop
  }

  private func waitLoaded(requiredEmptyReadbacks: Int) -> CommandResultCode {
    guard requiredEmptyReadbacks >= 0 else { return .invalidArguments }
    guard let appModel, appModel.activeDataset != nil else { return .callbackError }
    let datasetKey = appModel.activeDatasetRenderKey

    if appModel.rendererFailedActiveDataset {
      clearPendingWaitLoaded()
      logError("Renderer could not load the active dataset.")
      return .callbackError
    }

    guard appModel.rendererHasActiveDataset else {
      return .waitingNoop
    }

    if pendingWaitLoadedDatasetKey != datasetKey {
      pendingWaitLoadedDatasetKey = datasetKey
      pendingWaitLoadedStartReadback = nil
      pendingWaitLoadedFrameTarget = nil
    }

    if let startReadback = pendingWaitLoadedStartReadback {
      if appModel.brickReadbackCount > startReadback &&
          appModel.consecutiveEmptyBrickReadbacks >= pendingWaitLoadedRequiredEmptyReadbacks {
        if pendingWaitLoadedFrameTarget == nil {
          pendingWaitLoadedFrameTarget = appModel.completedRenderFrameCount + 1
          return .waitingNoop
        }

        if let frameTarget = pendingWaitLoadedFrameTarget,
           appModel.completedRenderFrameCount >= frameTarget,
           appModel.lastCompletedFrameDatasetKey == datasetKey {
          clearPendingWaitLoaded()
          logInfo(
            "Dataset loaded: \(appModel.consecutiveEmptyBrickReadbacks) empty hash table readbacks, last request \(appModel.lastMissingBrickCount) bricks"
          )
          return .success
        }
      }
      return .waitingNoop
    }

    pendingWaitLoadedRequiredEmptyReadbacks = UInt64(max(1, requiredEmptyReadbacks))
    pendingWaitLoadedStartReadback = appModel.brickReadbackCount
    pendingWaitLoadedFrameTarget = nil
    return .waitingNoop
  }

  private func clearPendingWaitLoaded() {
    pendingWaitLoadedStartReadback = nil
    pendingWaitLoadedFrameTarget = nil
    pendingWaitLoadedDatasetKey = nil
  }

  private func synchronizeTransform() {
    sharePlay?.synchronize(kind: .transformOnly)
  }

  private func synchronizeState() {
    sharePlay?.synchronize(kind: .stateOnly)
  }

  private func datasetDirectoryURL() -> URL {
    if let dataset = appModel?.activeDataset {
      switch dataset.source {
        case .local, .builtIn:
          return URL(fileURLWithPath: dataset.identifier).deletingLastPathComponent()
        case .remote:
          break
      }
    }
    return storedAppModel?.resolvedDataDirectoryURL() ?? FileManager.default.homeDirectoryForCurrentUser
  }

  private func outputDirectoryURL() -> URL {
    let base = datasetDirectoryURL()
    guard !outputSubdirectory.isEmpty else { return base }
    return base.appendingPathComponent(outputSubdirectory, isDirectory: true)
  }

  private func screenshotURL(filename: String?) -> URL {
    if let filename, !filename.isEmpty {
      return scriptFileURL(filename: filename, defaultExtension: "png")
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return outputDirectoryURL()
      .appendingPathComponent("BorgVR-\(formatter.string(from: Date()))")
      .appendingPathExtension("png")
  }

  private func scriptFileURL(filename: String, defaultExtension: String) -> URL {
    var url = outputDirectoryURL().appendingPathComponent(filename)
    if url.pathExtension.isEmpty {
      url.appendPathExtension(defaultExtension)
    }
    return url
  }

  private func setLogFile(_ filename: String) -> CommandResultCode {
    let url = scriptFileURL(filename: filename, defaultExtension: "log")
    do {
      storedAppModel?.stopAccessingDataDirectory(logFileAccessURL)
      logFileAccessURL = storedAppModel?.startAccessingDataDirectory()
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: url, options: .atomic)
      logFileURL = url
      return logInfo("Logdatei: \(url.path)")
    } catch {
      logError("Log file could not be opened: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func clearLogFile() -> CommandResultCode {
    guard let logFileURL else { return .success }
    do {
      try Data().write(to: logFileURL, options: .atomic)
      return .success
    } catch {
      logError("Log file could not be cleared: \(error.localizedDescription)")
      return .callbackError
    }
  }

  @discardableResult
  private func logInfo(_ message: String) -> CommandResultCode {
    appModel?.logger.info(message)
    appendScriptLog(level: .info, message: message)
    appendToLogFile(message)
    return .success
  }

  private func logError(_ message: String) {
    appModel?.logger.error(message)
    appendScriptLog(level: .error, message: message)
    appendToLogFile("[ERROR] \(message)")
  }

  private func appendScriptLog(level: LogLevel, message: String) {
    let levelName: String
    switch level {
      case .dev: levelName = "DEV"
      case .progress: levelName = "PROGRESS"
      case .info: levelName = "INFO"
      case .warning: levelName = "WARNING"
      case .error: levelName = "ERROR"
    }
    if !scriptLogText.isEmpty {
      scriptLogText.append("\n")
    }
    scriptLogText.append("[\(levelName)] \(message)")
  }

  func clearScriptExecutionLog() {
    scriptLogText = ""
  }

  private func appendToLogFile(_ message: String) {
    guard let logFileURL,
          let data = (message + "\n").data(using: .utf8),
          let fileHandle = try? FileHandle(forWritingTo: logFileURL) else {
      return
    }
    defer { try? fileHandle.close() }
    _ = try? fileHandle.seekToEnd()
    try? fileHandle.write(contentsOf: data)
  }

  private func clamp(_ value: Float, _ lowerBound: Float = 0, _ upperBound: Float = 1) -> Float {
    min(upperBound, max(lowerBound, value))
  }

  private func clamp(_ value: Double, _ lowerBound: Double = 0, _ upperBound: Double = 1) -> Double {
    min(upperBound, max(lowerBound, value))
  }
}

private final class ScriptExecutionLogger: LoggerBase, @unchecked Sendable {
  private let destination: LoggerBase
  private let onMessage: @Sendable (LogLevel, String) -> Void
  private let onProgress: @Sendable (String, Double) -> Void
  private let lock = NSLock()
  private var minimumLogLevel: LogLevel = .dev

  init(
    destination: LoggerBase,
    onMessage: @escaping @Sendable (LogLevel, String) -> Void,
    onProgress: @escaping @Sendable (String, Double) -> Void
  ) {
    self.destination = destination
    self.onMessage = onMessage
    self.onProgress = onProgress
  }

  func dev(_ message: String) {
    destination.dev(message)
    emit(.dev, message)
  }

  func info(_ message: String) {
    destination.info(message)
    emit(.info, message)
  }

  func warning(_ message: String) {
    destination.warning(message)
    emit(.warning, message)
  }

  func error(_ message: String) {
    destination.error(message)
    emit(.error, message)
  }

  func progress(_ message: String, _ progress: Double) {
    destination.progress(message, progress)
    guard shouldEmit(.progress) else { return }
    onProgress(message, progress)
  }

  func setMinimumLogLevel(_ level: LogLevel) {
    lock.lock()
    minimumLogLevel = level
    lock.unlock()
    destination.setMinimumLogLevel(level)
  }

  private func emit(_ level: LogLevel, _ message: String) {
    guard shouldEmit(level) else { return }
    onMessage(level, message)
  }

  private func shouldEmit(_ level: LogLevel) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return minimumLogLevel <= level
  }
}

private enum ScriptDatasetConverter {
  struct Settings: @unchecked Sendable {
    let brickSize: Int
    let overlap: Int
    let useCompression: Bool
    let extensionStrategy: ExtensionStrategy

    var isValid: Bool {
      brickSize >= 1 && overlap >= 1 && brickSize - 2 * overlap >= 1
    }
  }

  final class Context: @unchecked Sendable {
    let settings: Settings
    let logger: LoggerBase

    init(settings: Settings, logger: LoggerBase) {
      self.settings = settings
      self.logger = logger
    }
  }

  enum ImportError: LocalizedError {
    case unsupportedFileType(String)
    case noDICOMFiles

    var errorDescription: String? {
      switch self {
        case let .unsupportedFileType(pathExtension):
          return "Unsupported import file type: \(pathExtension)"
        case .noDICOMFiles:
          return "The directory does not contain any DICOM files."
      }
    }
  }

  static func importFile(
    from sourceURL: URL,
    to destinationURL: URL,
    datasetDescription: String,
    settings: Settings,
    logger: LoggerBase
  ) throws {
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let sourceName = sourceURL.deletingPathExtension().lastPathComponent
    let description = datasetDescription.isEmpty ? "Imported from \(sourceName)" : datasetDescription
    switch sourceURL.pathExtension.lowercased() {
      case "dat":
        let parser = try QVISParser(filename: sourceURL.path)
        try convertRawVolume(
          inputFilename: parser.absoluteFilename,
          offset: 0,
          size: parser.size,
          bytesPerComponent: parser.bytesPerComponent,
          componentCount: parser.components,
          voxelSpacing: parser.voxelSpacing,
          destinationURL: destinationURL,
          datasetDescription: description,
          metaDescription: "Imported from QVIS volume \(sourceName)",
          settings: settings,
          logger: logger
        )

      case "nrrd", "nhdr":
        let parser = try NRRDParser(filename: sourceURL.path)
        defer {
          if parser.dataIsTempCopy {
            try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
          }
        }
        try convertRawVolume(
          inputFilename: parser.absoluteFilename,
          offset: parser.offset,
          size: parser.size,
          bytesPerComponent: parser.bytesPerComponent,
          componentCount: parser.components,
          voxelSpacing: parser.voxelSpacing,
          destinationURL: destinationURL,
          datasetDescription: description,
          metaDescription: "Imported from NRRD volume \(sourceName)",
          settings: settings,
          logger: logger
        )

      default:
        throw ImportError.unsupportedFileType(sourceURL.pathExtension)
    }
  }

  static func importDICOMDirectory(
    from sourceURL: URL,
    to destinationURL: URL,
    datasetDescription: String,
    settings: Settings,
    logger: LoggerBase
  ) throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: sourceURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    guard !files.isEmpty else { throw ImportError.noDICOMFiles }

    logger.info("Scanning DICOM directory: \(sourceURL.path)")
    let volume = try DicomParser.decodeVolume(from: files)
    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try volume.voxelData.withUnsafeBytes { bytes in
      try Data(bytes).write(to: temporaryURL)
    }

    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let directoryName = sourceURL.lastPathComponent
    try convertRawVolume(
      inputFilename: temporaryURL.path,
      offset: 0,
      size: Vec3<Int>(x: volume.width, y: volume.height, z: volume.depth),
      bytesPerComponent: volume.bytesPerVoxel,
      componentCount: 1,
      voxelSpacing: Vec3<Float>(
        x: volume.voxelSpacing.x,
        y: volume.voxelSpacing.y,
        z: volume.voxelSpacing.z
      ),
      destinationURL: destinationURL,
      datasetDescription: datasetDescription.isEmpty
        ? "Imported from DICOM directory \(directoryName)"
        : datasetDescription,
      metaDescription: "Imported from DICOM directory \(directoryName)",
      settings: settings,
      logger: logger
    )
  }

  private static func convertRawVolume(
    inputFilename: String,
    offset: Int,
    size: Vec3<Int>,
    bytesPerComponent: Int,
    componentCount: Int,
    voxelSpacing: Vec3<Float>,
    destinationURL: URL,
    datasetDescription: String,
    metaDescription: String,
    settings: Settings,
    logger: LoggerBase
  ) throws {
    let volume = try RawFileAccessor(
      filename: inputFilename,
      size: size,
      bytesPerComponent: bytesPerComponent,
      componentCount: componentCount,
      voxelSpacing: voxelSpacing,
      offset: offset,
      readOnly: true
    )
    let reorganizer = BrickedVolumeReorganizer(
      inputVolume: volume,
      brickSize: settings.brickSize,
      overlap: settings.overlap,
      extensionStrategy: settings.extensionStrategy
    )
    try reorganizer.reorganize(
      to: destinationURL.path,
      datasetDescription: datasetDescription,
      metaDescription: metaDescription,
      useCompressor: settings.useCompression,
      logger: logger
    )
  }
}

private extension Array where Element == CommandArg {
  var restString: String {
    guard case let .strings(values) = self.first else { return "" }
    return values.joined(separator: " ")
  }

  func int(_ index: Int) -> Int {
    guard case let .int(value) = self[index] else { return 0 }
    return value
  }

  func float(_ index: Int) -> Float {
    guard case let .float(value) = self[index] else { return 0 }
    return value
  }

  func double(_ index: Int) -> Double {
    guard case let .double(value) = self[index] else { return 0 }
    return value
  }

  func bool(_ index: Int) -> Bool {
    guard case let .bool(value) = self[index] else { return false }
    return value
  }

  func string(_ index: Int) -> String {
    guard case let .string(value) = self[index] else { return "" }
    return value
  }

  func strings(_ index: Int) -> [String] {
    guard case let .strings(values) = self[index] else { return [] }
    return values
  }
}
