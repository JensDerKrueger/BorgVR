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

  var body: some Scene {
    WindowGroup("BorgVR") {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .environmentObject(docking)
        .environmentObject(scriptRunner)
        .frame(minWidth: 980, minHeight: 680)
        .task {
          sharePlay.registerGroupActivity()
        }
        .onAppear {
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
        .onChange(of: appSettings.logLevel) { _, newValue in
          appModel.setLogLevel(newValue)
        }
        .onOpenURL { url in
          openExternalDataset(url)
        }
        .task {
          await sharePlay.configure(
            appModel: appModel,
            renderingParameters: renderingParameters,
            storedAppModel: storedAppModel,
            serverController: serverController
          )
        }
        .task {
          _ = storedAppModel.activateDataDirectoryAccess()
          if storedAppModel.autoStartServer {
            serverController.start(using: storedAppModel)
          }
        }
    }
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

    WindowGroup("Isowert", id: DockablePanelID.isoEditor.windowID) {
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
    .commands {
      CommandMenu("Script") {
        Button("Script ausführen...") {
          scriptRunner.showOpenPanelAndRun()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Script stoppen") {
          scriptRunner.stopScript()
        }
        .disabled(!scriptRunner.isRunning)
      }
    }
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
        appModel.activeDataset = dataset
        appModel.groupSessionHost = true
        appModel.currentState = .renderData
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
