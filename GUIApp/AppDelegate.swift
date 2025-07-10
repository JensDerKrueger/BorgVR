import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true // Beendet die App, wenn das letzte Fenster geschlossen wird
  }
}
