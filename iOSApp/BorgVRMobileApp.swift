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
