import SwiftUI

final class AppSettings : ObservableObject {
  @AppStorage("brickSize") var brickSize: Int = 64
  @AppStorage("brickOverlap") var brickOverlap: Int = 2
  @AppStorage("enableCompression") var enableCompression: Bool = true
  @AppStorage("lastMinute") var lastMinute: Bool = false
  @AppStorage("autoStartServer") var autoStartServer: Bool = false
  @AppStorage("borderMode") var borderModeString: String = "zeroes"

  @AppStorage("serverPort") var port: Int = 12345
  @AppStorage("dataDirectory") var dataDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
}
