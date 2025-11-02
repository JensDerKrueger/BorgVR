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

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
