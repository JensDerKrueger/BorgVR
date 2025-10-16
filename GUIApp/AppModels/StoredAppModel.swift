import SwiftUI

final class StoredAppModel : ObservableObject {

  static let defaultBrickSize: Int = 64
  @AppStorage("brickSize") var brickSize: Int = defaultBrickSize

  static let defaultBrickOverlap: Int = 2
  @AppStorage("brickOverlap") var brickOverlap: Int = defaultBrickOverlap

  static let defaultEnableCompression: Bool = true
  @AppStorage("enableCompression") var enableCompression: Bool = defaultEnableCompression

  static let defaultLastMinute: Bool = false
  @AppStorage("lastMinute") var lastMinute: Bool = defaultLastMinute

  static let defaultAutoStartServer: Bool = false
  @AppStorage("autoStartServer") var autoStartServer: Bool = defaultAutoStartServer

  static let defaultBorderModeString: String = "zeroes"
  @AppStorage("borderMode") var borderModeString: String = defaultBorderModeString

  static let defaultPort: Int = 12345
  @AppStorage("serverPort") var port: Int = defaultPort

  static let defaultMaxBricksPerGetRequest: Int = 20
  @AppStorage("maxBricksPerGetRequest") var maxBricksPerGetRequest: Int = defaultMaxBricksPerGetRequest

  static let defaultDataDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  @AppStorage("dataDirectory") var dataDirectory: String = defaultDataDirectory

  func resetToDefaults() {
    brickSize = StoredAppModel.defaultBrickSize
    brickOverlap = StoredAppModel.defaultBrickOverlap
    enableCompression = StoredAppModel.defaultEnableCompression
    lastMinute = StoredAppModel.defaultLastMinute
    autoStartServer = StoredAppModel.defaultAutoStartServer
    borderModeString = StoredAppModel.defaultBorderModeString

    port = StoredAppModel.defaultPort
    maxBricksPerGetRequest = StoredAppModel.defaultMaxBricksPerGetRequest
    dataDirectory = StoredAppModel.defaultDataDirectory
  }
}
