import SwiftUI

private struct StoredSyncEndpoint: Codable {
  let id: UUID
  let address: String
  let port: Int
  let credential: StoredServerCredential
  let intervalSeconds: Int

  init(_ endpoint: ServerSyncEndpoint) {
    id = endpoint.id
    address = endpoint.address
    port = endpoint.port
    credential = .init(endpoint.password)
    intervalSeconds = endpoint.intervalSeconds
  }

  var endpoint: ServerSyncEndpoint {
    .init(id: id, address: address, port: port, password: credential.value, intervalSeconds: intervalSeconds)
  }
}

final class StoredAppModel : ObservableObject {

  static let defaultBrickSize = BorgVRSharedDefaults.brickSize
  @AppStorage("brickSize") var brickSize: Int = defaultBrickSize

  static let defaultBrickOverlap = BorgVRSharedDefaults.brickOverlap
  @AppStorage("brickOverlap") var brickOverlap: Int = defaultBrickOverlap

  static let defaultEnableCompression = BorgVRSharedDefaults.compressionEnabled
  @AppStorage("enableCompression") var enableCompression: Bool = defaultEnableCompression
  @AppStorage("quantizeImportsTo8Bit") var quantizeImportsTo8Bit = false
  @AppStorage("dicomResamplingFilter") var dicomResamplingFilter = BorgVRVolumeResamplingFilter.trilinear

  static let defaultLastMinute: Bool = false
  @AppStorage("lastMinute") var lastMinute: Bool = defaultLastMinute

  static let defaultAutoStartServer: Bool = false
  @AppStorage("autoStartServer") var autoStartServer: Bool = defaultAutoStartServer

  static let defaultBorderModeString = BorgVRSharedDefaults.borderMode
  @AppStorage("borderMode") var borderModeString: String = defaultBorderModeString

  static let defaultPort = BorgVRSharedDefaults.datasetServerPort
  @AppStorage("serverPort") var port: Int = defaultPort

  static let defaultServerPassword: String = ""
  @Published private(set) var credentialStorageError: String?
  @Published var serverPassword = DatasetServerPasswordStore.load() {
    didSet { credentialStorageError = DatasetServerPasswordStore.save(serverPassword) }
  }

  static let defaultEnableWebServer: Bool = false
  @AppStorage("enableWebServer") var enableWebServer: Bool = defaultEnableWebServer

  static let defaultWebServerPort = BorgVRSharedDefaults.webServerPort
  @AppStorage("webServerPort") var webServerPort: Int = defaultWebServerPort

  static let defaultWebServerUsesTLS: Bool = true
  @AppStorage("webServerUsesTLS") var webServerUsesTLS: Bool = defaultWebServerUsesTLS

  static let defaultWebServerCertificateData = Data()
  @AppStorage("webServerCertificateData") var webServerCertificateData: Data = defaultWebServerCertificateData

  static let defaultMaxBricksPerGetRequest = BorgVRSharedDefaults.maximumBricksPerRequest
  @AppStorage("maxBricksPerGetRequest") var maxBricksPerGetRequest: Int = defaultMaxBricksPerGetRequest

  static let defaultDataDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  @AppStorage("dataDirectory") var dataDirectory: String = defaultDataDirectory

  @MainActor
  func settingsStore() -> BorgVRSettingsStore {
    let values: [String: Any] = [
      "brickSize": Self.defaultBrickSize, "brickOverlap": Self.defaultBrickOverlap,
      "enableCompression": Self.defaultEnableCompression, "quantizeImportsTo8Bit": false,
      "dicomResamplingFilter": "trilinear", "lastMinute": Self.defaultLastMinute,
      "autoStartServer": Self.defaultAutoStartServer, "borderMode": Self.defaultBorderModeString,
      "serverPort": Self.defaultPort, "enableWebServer": Self.defaultEnableWebServer,
      "webServerPort": Self.defaultWebServerPort, "webServerUsesTLS": Self.defaultWebServerUsesTLS,
      "webServerCertificateData": Self.defaultWebServerCertificateData,
      "maxBricksPerGetRequest": Self.defaultMaxBricksPerGetRequest
    ]
    let extra = BorgVRSettingsStore.Entry.credentials(serverPassword: Binding(
      get: { self.serverPassword }, set: { self.serverPassword = $0 }
    ), includeMCP: false) + [SettingsServerRecord.entry(key: "syncServers", read: {
      self.syncServers.map { .init(id: $0.id, address: $0.address, port: $0.port,
        password: $0.password, intervalSeconds: $0.intervalSeconds) }
    }, write: { records in
      let previous = self.syncServers
      self.syncServers = records.map { record in
        .init(id: record.id, address: record.address, port: record.port,
          password: record.password ?? previous.first(where: {
            $0.id == record.id || ($0.address == record.address && $0.port == record.port)
          })?.password ?? "", intervalSeconds: record.intervalSeconds ?? 300)
      }
    })]
    return BorgVRSettingsStore(defaultValues: values, overrides: extra,
      didImport: { self.objectWillChange.send() })
  }

  @AppStorage("syncServers") private var syncServersData: Data = Data()

  init() {
    guard !syncServersData.isEmpty else { return }
    do { _ = try JSONDecoder().decode([StoredSyncEndpoint].self, from: syncServersData) }
    catch is DecodingError { syncServersData = Data() }
    catch { credentialStorageError = error.localizedDescription }
  }

  var syncServers: [ServerSyncEndpoint] {
    get {
      guard !syncServersData.isEmpty,
            let servers = try? JSONDecoder().decode(
              [StoredSyncEndpoint].self,
              from: syncServersData
            ) else {
        return []
      }
      return servers.map(\.endpoint)
    }
    set {
      objectWillChange.send()
      do {
        syncServersData = try JSONEncoder().encode(newValue.map(StoredSyncEndpoint.init))
        credentialStorageError = nil
      } catch {
        credentialStorageError = error.localizedDescription
      }
    }
  }

  func resetToDefaults() {
    quantizeImportsTo8Bit = false
    dicomResamplingFilter = .trilinear
    brickSize = StoredAppModel.defaultBrickSize
    brickOverlap = StoredAppModel.defaultBrickOverlap
    enableCompression = StoredAppModel.defaultEnableCompression
    lastMinute = StoredAppModel.defaultLastMinute
    autoStartServer = StoredAppModel.defaultAutoStartServer
    borderModeString = StoredAppModel.defaultBorderModeString

    port = StoredAppModel.defaultPort
    serverPassword = StoredAppModel.defaultServerPassword
    enableWebServer = StoredAppModel.defaultEnableWebServer
    webServerPort = StoredAppModel.defaultWebServerPort
    webServerUsesTLS = StoredAppModel.defaultWebServerUsesTLS
    webServerCertificateData = StoredAppModel.defaultWebServerCertificateData
    WebServerCertificatePasswordStore.delete()
    maxBricksPerGetRequest = StoredAppModel.defaultMaxBricksPerGetRequest
    dataDirectory = StoredAppModel.defaultDataDirectory
    syncServers = []
  }

  var webServerCertificatePassword: String {
    get { WebServerCertificatePasswordStore.load() }
    set { try? WebServerCertificatePasswordStore.save(newValue) }
  }

  func setDataDirectoryURL(_ url: URL) {
    dataDirectory = url.path
  }

  func withDataDirectoryAccess<T>(_ body: (URL) throws -> T) rethrows -> T {
    try body(URL(fileURLWithPath: dataDirectory, isDirectory: true))
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
