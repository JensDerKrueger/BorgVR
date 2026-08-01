import SwiftUI

@main
struct BorgVRMobileApp: App {
  @State private var appModel = AppModel()
  @State private var renderingParameters = RenderingParameters()
  @StateObject private var appSettings = AppSettings()
  @StateObject private var sharePlay = SharePlayCoordinator()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(sharePlay)
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
            appSettings: appSettings
          )
        }
    }
  }
}
