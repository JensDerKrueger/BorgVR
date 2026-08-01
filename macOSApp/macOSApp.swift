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

  var body: some Scene {
    WindowGroup("BorgVR macOS") {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(storedAppModel)
        .environmentObject(serverController)
        .environmentObject(sharePlay)
        .frame(minWidth: 980, minHeight: 680)
        .task {
          sharePlay.registerGroupActivity()
        }
        .onAppear {
          appModel.setLogLevel(appSettings.logLevel)
        }
        .onChange(of: appSettings.logLevel) { _, newValue in
          appModel.setLogLevel(newValue)
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
  }
}
