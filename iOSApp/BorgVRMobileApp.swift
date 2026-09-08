import SwiftUI

@main
struct BorgVRMobileApp: App {
  @State private var appModel = AppModel()
  @State private var renderingParameters = RenderingParameters()
  @StateObject private var appSettings = AppSettings()
  @StateObject private var sharePlay = SharePlayCoordinator()
  @StateObject private var serverController = BackgroundServerController()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(appModel)
        .environmentObject(renderingParameters)
        .environmentObject(appSettings)
        .environmentObject(sharePlay)
        .environmentObject(serverController)
        .task {
          sharePlay.registerGroupActivity()
        }
        .onAppear {
          appModel.setLogLevel(appSettings.logLevel)
        }
        .onChange(of: appSettings.logLevel) { _, newValue in
          appModel.setLogLevel(newValue)
        }
        .onChange(of: appSettings.autoStartServer) { _, enabled in
          if enabled, appSettings.enableDatasetServer, !serverController.isRunning {
            serverController.start(using: appSettings)
          }
        }
        .onChange(of: appSettings.enableDatasetServer) { _, enabled in
          if enabled {
            if appSettings.autoStartServer, !serverController.isRunning {
              serverController.start(using: appSettings)
            }
          } else {
            serverController.stop()
          }
        }
        .onChange(of: appSettings.serverPort) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.serverPassword) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.maxBricksPerGetRequest) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.enableWebServer) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.webServerPort) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.webServerUsesTLS) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .onChange(of: appSettings.webServerCertificateData) { _, _ in
          serverController.restartIfRunning(using: appSettings)
        }
        .task {
          if appSettings.enableDatasetServer && appSettings.autoStartServer {
            serverController.start(using: appSettings)
          }
        }
        .onOpenURL { url in
          openExternalDataset(url)
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

  private func openExternalDataset(_ url: URL) {
    Task { @MainActor in
      do {
        guard let documentsDirectory = FileManager.default.urls(
          for: .documentDirectory,
          in: .userDomainMask
        ).first else {
          throw ExternalDatasetImportError.destinationUnavailable
        }

        let dataset = try ExternalDatasetImporter.importDataset(
          from: url,
          into: documentsDirectory,
          logger: appModel.logger
        )
        appModel.activeDataset = dataset
        appModel.groupSessionHost = true
        appModel.currentState = .renderData
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
