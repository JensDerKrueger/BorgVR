import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = false
    disableWindowTabs()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeMain(_:)),
      name: NSWindow.didBecomeMainNotification,
      object: nil
    )
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  @objc private func windowDidBecomeMain(_ notification: Notification) {
    disableTabs(for: notification.object as? NSWindow)
  }

  private func disableWindowTabs() {
    NSApp.windows.forEach(disableTabs)
  }

  private func disableTabs(for window: NSWindow?) {
    guard let window else { return }
    window.tabbingMode = .disallowed
    window.tabGroup?.removeWindow(window)
  }
}

@main
struct macOSApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  @StateObject private var appModel = AppModel()
  @StateObject private var renderingParameters = RenderingParameters()
  @StateObject private var appSettings = AppSettings()
  @StateObject private var storedAppModel = StoredAppModel()
  @StateObject private var serverController = BackgroundServerController()
  @StateObject private var sharePlay = SharePlayCoordinator()
  @StateObject private var docking = DockingController()
  @StateObject private var scriptRunner = BorgVRScriptRunner()
  @StateObject private var updateChecker = AppStoreUpdateChecker()
  @AppStorage("sharePlayDisplayNameOnboardingCompleted")
  private var sharePlayDisplayNameOnboardingCompleted = false
  @State private var showsSharePlayDisplayNameOnboarding = false
  @State private var sharePlayDisplayNameDraft = ""

  var body: some Scene {
    WindowGroup("BorgVR") {
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
          isPresented: $sharePlay.showsHostDeparturePrompt
        ) {
          Button("Take Over Host Role") {
            sharePlay.takeOverHostRole()
          }
          Button("Leave Session", role: .destructive) {
            sharePlay.leaveGroupActivity()
          }
          Button("Ignore", role: .cancel) {
            sharePlay.ignoreHostDeparture()
          }
        } message: {
          Text("The SharePlay host left the session. You can take over the host role, leave the session, or continue without a host.")
        }
        .alert(item: $sharePlay.protocolCompatibilityIssue) { issue in
          Alert(
            title: Text("Incompatible SharePlay Version"),
            message: Text(issue.localizedMessage),
            dismissButton: .default(Text("OK")) {
              sharePlay.protocolCompatibilityIssue = nil
            }
          )
        }
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .environmentObject(updateChecker)
        .frame(minWidth: 980, minHeight: 680)
        .task {
          await presentSharePlayDisplayNameOnboardingIfNeeded()
        }
        .onAppear {
          sharePlay.startObservingSessions(
            appModel: appModel,
            renderingParameters: renderingParameters,
            appSettings: appSettings,
            storedAppModel: storedAppModel,
            serverController: serverController
          )
          appModel.setLogLevel(appSettings.logLevel)
          scriptRunner.configure(
            appModel: appModel,
            renderingParameters: renderingParameters,
            appSettings: appSettings,
            storedAppModel: storedAppModel,
            sharePlay: sharePlay,
            docking: docking
          )
        }
        .onChange(of: sharePlay.hasObservedGroupSession) { _, hasObservedSession in
          if hasObservedSession {
            showsSharePlayDisplayNameOnboarding = false
          }
        }
        .onChange(of: appSettings.logLevel) { _, newValue in
          appModel.setLogLevel(newValue)
        }
        .onChange(of: storedAppModel.sharePlayDisplayName) { _, _ in
          sharePlay.participantInfoChanged()
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
        .onChange(of: storedAppModel.autoStartServer) { _, enabled in
          if enabled, storedAppModel.enableDatasetServer, !serverController.isRunning {
            serverController.start(using: storedAppModel)
          }
        }
        .onOpenURL { url in
          openExternalDataset(url)
        }
        .task {
          _ = storedAppModel.activateDataDirectoryAccess()
          if storedAppModel.enableDatasetServer && storedAppModel.autoStartServer {
            serverController.start(using: storedAppModel)
          }
        }
    }
    .handlesExternalEvents(matching: [BorgVRSharePlayActivity.activityIdentifier])
    .defaultSize(width: 1200, height: 820)

    WindowGroup("Render UI", id: DockablePanelID.renderControls.windowID) {
      DetachedPanelContent(panel: .renderControls)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 720, height: 260)

    WindowGroup("Transfer Function", id: DockablePanelID.transferFunctionEditor.windowID) {
      DetachedPanelContent(panel: .transferFunctionEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 820, height: 320)

    WindowGroup("Isovalue", id: DockablePanelID.isoEditor.windowID) {
      DetachedPanelContent(panel: .isoEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 560, height: 180)

    WindowGroup("Performance", id: "PerformanceGraphView") {
      PerformanceGraphView()
        .environmentObject(appModel)
    }
    .defaultSize(width: 820, height: 360)

    Window("Script Log", id: "ScriptLogView") {
      ScriptLogView()
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 760, height: 480)
    .restorationBehavior(.disabled)

    WindowGroup("Objects", id: DockablePanelID.markerEditor.windowID) {
      DetachedPanelContent(panel: .markerEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 520, height: 560)

    WindowGroup("measurement_window_title", id: DockablePanelID.measurementEditor.windowID) {
      DetachedPanelContent(panel: .measurementEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 520, height: 600)

    WindowGroup("Lighting", id: DockablePanelID.lightingEditor.windowID) {
      DetachedPanelContent(panel: .lightingEditor)
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
    }
    .defaultSize(width: 430, height: 500)
    .commands {
      CommandMenu("Script") {
        Button("Run Script...") {
          scriptRunner.showOpenPanelAndRun()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Stop Script") {
          scriptRunner.stopScript()
        }
        .disabled(!scriptRunner.isRunning)
      }
    }
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
          !sharePlay.hasObservedGroupSession,
          !sharePlay.isInSession else { return }

    sharePlayDisplayNameDraft = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    showsSharePlayDisplayNameOnboarding = true
  }

  private func openExternalDataset(_ url: URL) {
    Task { @MainActor in
      do {
        let dataDirectoryAccessURL = storedAppModel.startAccessingDataDirectory()
        defer {
          storedAppModel.stopAccessingDataDirectory(dataDirectoryAccessURL)
        }

        let dataset = try ExternalDatasetImporter.importDataset(
          from: url,
          into: storedAppModel.resolvedDataDirectoryURL(),
          logger: appModel.logger
        )
        appModel.openDataset(dataset, asGroupSessionHost: true)
        docking.resetForDatasetClose()
        sharePlay.datasetOpened()
      } catch {
        appModel.logger.error(
          String(
            format: String(localized: "external_dataset_open_failed_format"),
            url.lastPathComponent,
            error.localizedDescription
          )
        )
      }
    }
  }
}
