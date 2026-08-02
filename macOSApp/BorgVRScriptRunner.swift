import AppKit
import Foundation
import Metal
import SwiftUI
import simd

@MainActor
final class BorgVRScriptRunner: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var statusText = String(localized: "Kein Script aktiv")
  @Published private(set) var scriptURL: URL?

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
    panel.title = String(localized: "Script ausführen")
    panel.message = String(localized: "Wähle ein BorgVR gsc Script.")

    if panel.runModal() == .OK, let url = panel.url {
      runScript(at: url)
    }
  }

  func runScript(at url: URL) {
    stopScript()
    outputSubdirectory = ""
    logFileURL = nil
    storedAppModel?.stopAccessingDataDirectory(logFileAccessURL)
    logFileAccessURL = nil

    let result = interpreter.loadFromFile(url.path)
    guard result == .success else {
      logError("Script konnte nicht geladen werden: \(result)")
      return
    }

    scriptURL = url
    isRunning = true
    statusText = String(format: String(localized: "Script läuft: %@"), url.lastPathComponent)
    logInfo("Script gestartet: \(url.lastPathComponent)")

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
    if isRunning {
      logInfo("Script gestoppt")
    }
    isRunning = false
    statusText = String(localized: "Kein Script aktiv")
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
          logInfo("Script beendet")
          isRunning = false
          statusText = String(localized: "Kein Script aktiv")
          return
        default:
          let lineText = interpreter.lastErrorLine.map { " in Zeile \($0)" } ?? ""
          logError("Scriptfehler\(lineText): \(result)")
          isRunning = false
          statusText = String(localized: "Scriptfehler")
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

    register("logMetalInfo", []) { [weak self] _ in
      self?.logMetalInfo(includeFamilies: true) ?? .callbackError
    }

    register("logMetalInfo", [.bool]) { [weak self] args in
      self?.logMetalInfo(includeFamilies: args.bool(0)) ?? .callbackError
    }

    register("setdir", [.string]) { [weak self] args in
      self?.setOutputDirectory(args.string(0)) ?? .callbackError
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

  private func setOutputDirectory(_ path: String) -> CommandResultCode {
    outputSubdirectory = path
    let directory = outputDirectoryURL()
    do {
      let accessURL = storedAppModel?.startAccessingDataDirectory()
      defer { storedAppModel?.stopAccessingDataDirectory(accessURL) }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return logInfo("Script-Ausgabeverzeichnis: \(directory.path)")
    } catch {
      logError("Ausgabeverzeichnis konnte nicht angelegt werden: \(error.localizedDescription)")
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
            self?.logError("Screenshot fehlgeschlagen: \(error.localizedDescription)")
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
        return logInfo("Datensatz im Renderer bereit: \(description)")
      }
      if appModel?.rendererFailedActiveDataset == true {
        pendingDatasetID = nil
        pendingDatasetDescription = nil
        logError("Renderer konnte den Datensatz nicht öffnen: \(id)")
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
        await self?.completeDatasetOpen(result: .callbackError, message: "Datensatz nicht gefunden: \(id)")
        return
      }

      let openable = catalog.openableDataset(from: dataset)
      appModel.activeDataset = openable
      if self?.sharePlay?.isInSession != true {
        appModel.groupSessionHost = true
      }
      self?.docking?.resetForDatasetClose()
      appModel.currentState = .renderData
      self?.sharePlay?.datasetOpened()
      self?.pendingDatasetDescription = openable.description
      self?.logInfo("Datensatz ausgewählt: \(openable.description)")
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
      try parameters.transferFunction.load(from: url)
      sharePlay?.synchronize(kind: .full)
      return logInfo("Transferfunktion geladen: \(url.path)")
    } catch {
      logError("Transferfunktion konnte nicht geladen werden: \(error.localizedDescription)")
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
      return logInfo("Transferfunktion gespeichert: \(url.path)")
    } catch {
      logError("Transferfunktion konnte nicht gespeichert werden: \(error.localizedDescription)")
      return .callbackError
    }
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
      logError("FPS-Timer ist nicht verfügbar.")
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

  private func logMetalInfo(includeFamilies: Bool) -> CommandResultCode {
    guard let device = MTLCreateSystemDefaultDevice() else {
      logError("Kein Metal-Gerät verfügbar.")
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
      logError("Renderer konnte den aktiven Datensatz nicht laden.")
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
            "Dataset geladen: \(appModel.consecutiveEmptyBrickReadbacks) leere HashTable-Readbacks, letzter Request \(appModel.lastMissingBrickCount) Bricks"
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
      logError("Logdatei konnte nicht geöffnet werden: \(error.localizedDescription)")
      return .callbackError
    }
  }

  private func clearLogFile() -> CommandResultCode {
    guard let logFileURL else { return .success }
    do {
      try Data().write(to: logFileURL, options: .atomic)
      return .success
    } catch {
      logError("Logdatei konnte nicht geleert werden: \(error.localizedDescription)")
      return .callbackError
    }
  }

  @discardableResult
  private func logInfo(_ message: String) -> CommandResultCode {
    appModel?.logger.info(message)
    appendToLogFile(message)
    return .success
  }

  private func logError(_ message: String) {
    appModel?.logger.error(message)
    appendToLogFile("[ERROR] \(message)")
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
}
