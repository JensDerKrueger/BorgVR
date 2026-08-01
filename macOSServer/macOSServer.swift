import SwiftUI


class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

@main
struct macOSServerApp: App {
  @State private var runtimeAppModel = RuntimeAppModel()
  @StateObject private var storedAppModel = StoredAppModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  @State private var showingAbout = false

  var body: some Scene {
    WindowGroup("macosserver_window_title") {
      ContentView()
        .onAppear {
          NSWindow.allowsAutomaticWindowTabbing = false
        }
        .sheet(isPresented: $showingAbout) {
          InfoView()
        }

    }
    .environment(runtimeAppModel)
    .environmentObject(storedAppModel)
    .defaultSize(width: 600, height: 300)

    .commands {
      CommandGroup(replacing: .newItem) {}

      CommandGroup(replacing: .appTermination) {
        Button("macosserver_menu_quit") {
          NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
        }
      }

      CommandGroup(replacing: .appInfo) {
        Button("macosserver_menu_about") {
          showingAbout = true
        }
      }
    }
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in the
 Software without restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
 Software, and to permit persons to whom the Software is furnished to do so, subject
 to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
