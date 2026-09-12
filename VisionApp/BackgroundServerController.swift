import Foundation

@MainActor
final class BackgroundServerController: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var statusText = String(localized: "Server is not started.")
  @Published private(set) var datasets: [DatasetInfo] = []
  @Published private(set) var shareableWebServerURL: URL?

  private let serverHost = BorgVRServerHost(logger: GUILogger())

  func start(using settings: StoredAppModel) {
    guard settings.enableDatasetServer else {
      stop()
      return
    }

    let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    let dataDirectory = documentsDirectory?.path ?? ""
    let state = serverHost.start(
      configuration: BorgVRServerConfiguration(
        dataDirectory: dataDirectory,
        port: settings.serverPort,
        maxBricksPerGetRequest: settings.maxBricksPerGetRequest,
        authSecret: settings.serverPassword,
        startDatasetServer: true,
        enableWebServer: settings.enableWebServer,
        webPort: settings.webServerPort,
        useWebServerTLS: settings.webServerUsesTLS,
        webServerCertificateData: settings.webServerCertificateData,
        webServerCertificatePassword: settings.webServerCertificatePassword
      ),
      additionalDatasets: Self.builtInDatasets(),
      includeScannedDatasets: documentsDirectory != nil
    )

    datasets = state.datasets
    isRunning = state.isRunning
    shareableWebServerURL = state.isWebServerRunning && state.webServerUsesTLS
      ? WebGPUShareLink.serverBaseURL(port: state.webPort)
      : nil

    let webStatus: String
    if state.isWebServerRunning {
      webStatus = ", WebGPU \(state.webServerUsesTLS ? "HTTPS" : "HTTP") \(state.webPort)"
    } else if settings.enableWebServer {
      let reason = state.webServerError.map { ": \($0)" } ?? ""
      let failedStatus = String(
        format: String(localized: "WebGPU %@ %@ failed%@"),
        state.webServerUsesTLS ? "HTTPS" : "HTTP",
        "\(state.webPort)",
        reason
      )
      webStatus = ", \(failedStatus)"
    } else {
      webStatus = ""
    }

    if state.isRunning {
      statusText = String(
        format: String(localized: "Port %@%@, %@ datasets"),
        "\(state.port)",
        webStatus,
        "\(state.datasets.count)"
      )
    } else {
      let reason = state.serverError.map { ": \($0)" } ?? ""
      statusText = "Server could not be started\(reason)"
    }
  }

  func restartIfRunning(using settings: StoredAppModel) {
    guard isRunning else { return }
    start(using: settings)
  }

  func stop() {
    serverHost.stop()
    datasets = []
    shareableWebServerURL = nil
    isRunning = false
    statusText = String(localized: "Server is not started.")
  }

  private static func builtInDatasets() -> [DatasetInfo] {
    guard let urls = Bundle.main.urls(forResourcesWithExtension: "data", subdirectory: nil) else {
      return []
    }

    return urls.compactMap { url in
      guard let metadata = try? BORGVRMetaData(url: url) else { return nil }
      return DatasetInfo(
        id: metadata.uniqueID,
        filename: url.path,
        datasetDescription: metadata.datasetDescription
      )
    }
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 IN THE SOFTWARE.
 */
