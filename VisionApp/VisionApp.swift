import SwiftUI
import CompositorServices
import GroupActivities

struct ContentStageConfiguration: CompositorLayerConfiguration {

  var disableFoveation : Bool

  func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
    configuration.depthFormat = .depth32Float
    configuration.colorFormat = .bgra8Unorm_srgb

    let foveationEnabled = capabilities.supportsFoveation && !disableFoveation
    configuration.isFoveationEnabled = foveationEnabled

    let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
    let supportedLayouts = capabilities.supportedLayouts(options: options)

    configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
  }
}

@main
struct VisionApp: App {

  @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @State private var runtimeAppModel = RuntimeAppModel()
  @State private var sharedAppModel = SharedAppModel()
  @StateObject private var storedAppModel = StoredAppModel()
  @StateObject private var serverController = BackgroundServerController()
  @StateObject private var updateChecker = AppStoreUpdateChecker()
  @AppStorage("sharePlayDisplayNameOnboardingCompleted")
  private var sharePlayDisplayNameOnboardingCompleted = false
  @State private var showsSharePlayDisplayNameOnboarding = false
  @State private var sharePlayDisplayNameDraft = ""
  @State private var immersiveSpaceTransitionTask: Task<Void, Never>?

  @StateObject private var voice = VoiceCommandService()
  @StateObject private var speech = SpeechHelper()

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openImmersiveSpace) private var openImmersiveSpace
  @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

  var body: some Scene {
    WindowGroup(id: "main") {
      ContentView()
        .appStoreUpdateAlert(using: updateChecker)
        .alert(
          "Choose your SharePlay name",
          isPresented: $showsSharePlayDisplayNameOnboarding
        ) {
          TextField("Display name", text: $sharePlayDisplayNameDraft)
          Button("Continue") {
            storedAppModel.sharePlayDisplayName = sharePlayDisplayNameDraft
              .trimmingCharacters(in: .whitespacesAndNewlines)
            sharePlayDisplayNameOnboardingCompleted = true
          }
          .disabled(sharePlayDisplayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
          Text("What name should other people see for you in shared SharePlay sessions? You can change it later in Settings.")
        }
        .alert(
          "SharePlay Host Left",
          isPresented: $runtimeAppModel.showsHostDeparturePrompt
        ) {
          Button("Take Over Host Role") {
            sharedAppModel.takeOverSharePlayHostRole()
          }
          Button("Leave Session", role: .destructive) {
            sharedAppModel.leaveGroupActivity()
          }
          Button("Ignore", role: .cancel) {
            sharedAppModel.ignoreSharePlayHostDeparture()
          }
        } message: {
          Text("The SharePlay host left the session. You can take over the host role, leave the session, or continue without a host.")
        }
        .alert(item: $runtimeAppModel.protocolCompatibilityIssue) { issue in
          Alert(
            title: Text("Incompatible SharePlay Version"),
            message: Text(issue.localizedMessage),
            dismissButton: .default(Text("OK")) {
              runtimeAppModel.protocolCompatibilityIssue = nil
            }
          )
        }
        .frame(
          minWidth: runtimeAppModel.windowSize.width,
          minHeight: runtimeAppModel.windowSize.height
        )
        .trackView(name: "MainView")
        .environment(runtimeAppModel)
        .environmentObject(serverController)
        .environmentObject(updateChecker)
        .onOpenURL { url in
          Task {
            await handleOpenRequest(url:url)
          }
        }
        .task {
          GroupActivityHelper.registerGroupActivity()
          await presentSharePlayDisplayNameOnboardingIfNeeded()
        }
        .onChange(of: sharedAppModel.hasObservedGroupSession) { _, hasObservedSession in
          if hasObservedSession {
            showsSharePlayDisplayNameOnboarding = false
          }
        }
        .task {
          await NotificationHelper.requestAuthorization(storedAppModel:storedAppModel)
        }
        .task {
          await sharedAppModel.configureGroupActivities(
            runtimeAppModel: runtimeAppModel,
            storedAppModel: storedAppModel
          )
        }
        .task {
          if storedAppModel.enableDatasetServer && storedAppModel.autoStartServer {
            serverController.start(using: storedAppModel)
          }
        }
        .onChange(of: storedAppModel.enableDatasetServer) { _, enabled in
          if enabled {
            if storedAppModel.autoStartServer, !serverController.isRunning {
              serverController.start(using: storedAppModel)
            }
          } else {
            serverController.stop()
          }
        }
        .onChange(of: storedAppModel.sharePlayDisplayName) { _, _ in
          sharedAppModel.sharePlayDisplayNameChanged()
        }
        .onChange(of: storedAppModel.autoStartServer) { _, enabled in
          if enabled, storedAppModel.enableDatasetServer, !serverController.isRunning {
            serverController.start(using: storedAppModel)
          }
        }
        .onChange(of: storedAppModel.serverPort) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
        .onChange(of: storedAppModel.serverPassword) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
        .onChange(of: storedAppModel.maxBricksPerGetRequest) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
        .onChange(of: storedAppModel.enableWebServer) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
        .onChange(of: storedAppModel.webServerPort) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
        .onChange(of: storedAppModel.webServerUsesTLS) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
        .onChange(of: storedAppModel.webServerCertificateData) { _, _ in
          serverController.restartIfRunning(using: storedAppModel)
        }
    }
    .environment(runtimeAppModel)
    .environment(sharedAppModel)
    .environmentObject(storedAppModel)
    .environmentObject(serverController)
    .environmentObject(voice)
    .environmentObject(speech)
    .windowResizability(.contentSize)
    .defaultSize(width:runtimeAppModel.windowSize.width,height:runtimeAppModel.windowSize.height)
    .onChange(of: scenePhase) {
      if scenePhase == .background {
        quitApp()
      }
    }
    .onChange(of: runtimeAppModel.datasetSessionState) { _, newValue in
      queueDatasetSessionTransition(for: newValue)
    }

    // Transfer Function Editor Window
    WindowGroup(id: "TransferFunctionEditorView") {
      TransferFunctionEditorView()
        .trackView(name: "TransferFunctionEditorView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
        .frame(
          minWidth: 400, maxWidth: 600,
          minHeight: 1100, maxHeight: 1100
        )
    }
    .windowResizability(.contentSize)

    // Iso-Value Editor Window
    WindowGroup(id: "IsovalueEditorView") {
      IsovalueEditorView()
        .trackView(name: "IsovalueEditorView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)

    // PrivateRenderingParameters Window
    WindowGroup(id: "PrivateApplicationView") {
      PrivateApplicationView()
        .trackView(name: "PrivateApplicationView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(voice)
        .environmentObject(speech)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 850, height: 400)

    WindowGroup(id: "MarkerView") {
      MarkerView()
        .trackView(name: "MarkerView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 1080, height: 520)

    WindowGroup(id: "MeasurementView") {
      MeasurementView()
        .trackView(name: "MeasurementView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 680, height: 620)

    WindowGroup(id: "LightingEditorView") {
      LightingEditorView(
        renderMode: sharedAppModel.renderMode,
        lightDirection: Binding(
          get: { sharedAppModel.lightDirection },
          set: { sharedAppModel.lightDirection = $0 }
        ),
        ambientLightColor: Binding(
          get: { sharedAppModel.ambientLightColor },
          set: { sharedAppModel.ambientLightColor = $0 }
        ),
        diffuseLightColor: Binding(
          get: { sharedAppModel.diffuseLightColor },
          set: { sharedAppModel.diffuseLightColor = $0 }
        ),
        specularLightColor: Binding(
          get: { sharedAppModel.specularLightColor },
          set: { sharedAppModel.specularLightColor = $0 }
        ),
        usesPanelBackground: false,
        onChange: { sharedAppModel.synchronize(kind: .stateOnly) },
        onCommit: sharedAppModel.flushSynchronization
      )
      .padding()
      .trackView(name: "LightingEditorView")
      .environment(runtimeAppModel)
      .environment(sharedAppModel)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 440, height: 500)

    Window("Voice Commands", id: "VoiceCommandsView") {
      VoiceHelpView()
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
        .environmentObject(voice)
        .environmentObject(speech)
    }
    .windowResizability(.contentSize)
    .defaultSize(width:500,height:400)

    // Performance Window
    WindowGroup(id: "PerformanceGraphView") {
      PerformanceGraphView()
        .trackView(name: "PerformanceGraphView")
        .environment(runtimeAppModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)

    // Advanced Settings Window
    WindowGroup(id: "ProfileView") {
      ProfileView()
        .trackView(name: "ProfileView")
        .environment(runtimeAppModel)
        .environment(sharedAppModel)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
    }
    .windowResizability(.contentSize)
    .defaultSize(width:800,height:1200)

    // Logger Window
    WindowGroup(id: "LoggerView") {
      LoggerView(logger:runtimeAppModel.logger)
        .trackView(name: "LoggerView")
        .environment(runtimeAppModel)
        .frame(
          minWidth: 300,
          minHeight: 200
        )
    }
    .windowResizability(.contentSize)

    ImmersiveSpace(id: runtimeAppModel.immersiveSpaceID) {
      CompositorLayer(configuration: ContentStageConfiguration(disableFoveation: storedAppModel.disableFoveation)) {
        @MainActor layerRenderer in
        ImmersiveBootstrap.run(layerRenderer: layerRenderer,
                               runtimeAppModel: runtimeAppModel,
                               storedAppModel: storedAppModel,
                               sharedAppModel: sharedAppModel)
      }
      .upperLimbVisibility(storedAppModel.showHandsAndAccessories ? .visible : .hidden)
    }
    .immersionStyle(selection: .constant(runtimeAppModel.mixedImmersionStyle ? .mixed : .full), in: runtimeAppModel.mixedImmersionStyle ? .mixed : .full)
    .persistentSystemOverlays(.hidden)
    .handlesExternalEvents(matching: [groupActivityIdentifier])
  }

  @MainActor
  private func presentSharePlayDisplayNameOnboardingIfNeeded() async {
    guard !sharePlayDisplayNameOnboardingCompleted,
          !showsSharePlayDisplayNameOnboarding else { return }
    let configuredName = storedAppModel.sharePlayDisplayName
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !configuredName.isEmpty {
      sharePlayDisplayNameOnboardingCompleted = true
      return
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)
    guard !Task.isCancelled,
          !sharedAppModel.hasObservedGroupSession,
          !sharedAppModel.isInGroupSession else { return }

    sharePlayDisplayNameDraft = UIDevice.current.name
    showsSharePlayDisplayNameOnboarding = true
  }

  func quitApp() {
    let renderTask = runtimeAppModel.cancelRenderLoop()
    Task { @MainActor in
      if runtimeAppModel.groupSessionHost && sharedAppModel.isInGroupSession {
        await sharedAppModel.shutdownGroupsession()
      }
      if runtimeAppModel.immersiveSpaceState == .open {
        await dismissImmersiveSpace()
      }
      await renderTask?.value
      runtimeAppModel.immersiveSpaceState = .closed
      runtimeAppModel.quitApp()
    }
  }

  @MainActor
  private func queueDatasetSessionTransition(
    for state: RuntimeAppModel.DatasetSessionState
  ) {
    let precedingTask = immersiveSpaceTransitionTask
    immersiveSpaceTransitionTask = Task { @MainActor in
      await precedingTask?.value
      guard !Task.isCancelled,
            runtimeAppModel.datasetSessionState == state else { return }
      switch state {
        case .opening(_, let requestID):
          applySpatialStylusStartFunction()
          await openSpace(requestID: requestID)
        case .closing(let dataset, let requestID, let destination):
          await closeSpace(
            dataset: dataset,
            requestID: requestID,
            destination: destination
          )
        default:
          break
      }
    }
  }

  @MainActor
  private func applySpatialStylusStartFunction() {
    switch storedAppModel.stylusStartFunction {
      case .marker:
        storedAppModel.stylusTool = .marker
      case .objectPlacement:
        storedAppModel.stylusTool = .objectPlacement
      case .lengthMeasurement:
        storedAppModel.stylusTool = .lengthMeasurement
        sharedAppModel.measurementKind = .length
      case .areaMeasurement:
        storedAppModel.stylusTool = .areaMeasurement
        sharedAppModel.measurementKind = .area
      case .volumeMeasurement:
        storedAppModel.stylusTool = .volumeMeasurement
        sharedAppModel.measurementKind = .volume
      case .lastMode:
        if let kind = storedAppModel.stylusTool.measurementKind {
          sharedAppModel.measurementKind = kind
        }
    }
  }

  @MainActor
  private func openSpace(requestID: UUID) async {
    if runtimeAppModel.immersiveSpaceState == .open {
      runtimeAppModel.immersiveSpaceState = .inTransition
      let renderTask = runtimeAppModel.cancelRenderLoop()
      await renderTask?.value
      await dismissImmersiveSpace()
    }

    runtimeAppModel.immersiveSpaceState = .inTransition
    var acceptedOpen = false
    switch await openImmersiveSpace(id: runtimeAppModel.immersiveSpaceID) {
      case .opened:
        acceptedOpen = runtimeAppModel.markImmersiveSpaceOpened(requestID: requestID)
      case .userCancelled, .error:
        fallthrough
      @unknown default:
        runtimeAppModel.immersiveSpaceState = .closed
        runtimeAppModel.requestDatasetClose(
          destination: runtimeAppModel.groupSessionHost
            ? .datasetSelection
            : .sharePlayWaiting(.datasetSource)
        )
    }

    if acceptedOpen, runtimeAppModel.groupSessionHost {
      sharedAppModel.openSharedView()
    }
  }

  @MainActor
  private func closeSpace(
    dataset: RuntimeAppModel.DatasetEntry?,
    requestID: UUID,
    destination: RuntimeAppModel.DatasetCloseDestination
  ) async {
    if runtimeAppModel.groupSessionHost && sharedAppModel.isInGroupSession {
      await sharedAppModel.shutdownGroupsession()
    }

    let immersiveSpaceWasAlreadyClosed = runtimeAppModel.immersiveSpaceState == .closed
    if !immersiveSpaceWasAlreadyClosed {
      runtimeAppModel.immersiveSpaceState = .inTransition
    }
    let renderTask = runtimeAppModel.cancelRenderLoop()
    await renderTask?.value
    if !immersiveSpaceWasAlreadyClosed {
      await dismissImmersiveSpace()
    }
    runtimeAppModel.immersiveSpaceState = .closed

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    if let dataset {
      let autoURL = documentsDirectory.appendingPathComponent(dataset.uniqueId)
      if storedAppModel.autoloadTF {
        let fileURL = URL(
          fileURLWithPath: autoURL.deletingPathExtension().path() + ".tf1d"
        )
        try? sharedAppModel.transferFunction.save(to: fileURL)
      }
      if storedAppModel.autoloadTransform {
        let fileURL = URL(
          fileURLWithPath: autoURL.deletingPathExtension().path() + ".trafo"
        )
        try? sharedAppModel.modelTransform.save(to: fileURL)
      }
      sharedAppModel.saveAutomaticallyManagedDatasetState(
        datasetID: dataset.uniqueId,
        storedAppModel: storedAppModel,
        logger: runtimeAppModel.logger
      )
    }
    runtimeAppModel.completeDatasetClose(
      requestID: requestID,
      destination: destination
    )
  }

  @MainActor
  private func handleOpenRequest(url:URL) async {
    do {
      guard url.startAccessingSecurityScopedResource() else {
        throw FileError.noPermission("No Permission to access file \(url)")
      }
      defer { url.stopAccessingSecurityScopedResource() }

      let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      guard let externalMeta = try? BORGVRMetaData(url: url) else {
        throw FileError.noPermission("Invalid file \(url)")
      }

      let localURL : URL
      if let existingURL = findlocalFile(id: externalMeta.uniqueID) {
        localURL = existingURL
      } else {
        guard let copyURL = copyFile(from: url, toDir: documentsDirectory, logger: nil) else {
          throw FileError
            .noPermission(
              "Unable to copy file \(url) to document directory"
            )
        }
        localURL = copyURL
      }

      runtimeAppModel.startImmersiveSpace(identifier: localURL.path(),
                                   description: externalMeta.description,
                                   source: .local,
                                   uniqueId: externalMeta.uniqueID,
                                   asGroupSessionHost: true)
    } catch {
      runtimeAppModel.logger.error(error.localizedDescription)
    }
  }

}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
