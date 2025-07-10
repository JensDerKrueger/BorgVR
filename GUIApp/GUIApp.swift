//
//  GUIAppApp.swift
//  GUIApp
//
//  Created by Jens Krüger on 01.02.25.
//

import SwiftUI

@main
struct GUIAppApp: App {
  @State private var appModel = AppModel()
  @StateObject private var appSettings = AppSettings()
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup("BorgVR Dataset Companion Application") {
      ContentView()
    }
    .environment(appModel)
    .environmentObject(appSettings)
  }
}
