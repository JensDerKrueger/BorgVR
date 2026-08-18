import SwiftUI

final class StoredAppModel : ObservableObject {
  private static let dataDirectoryBookmarkKey = "dataDirectoryBookmark"
  private var activeDataDirectoryAccessURL: URL?
  private(set) var lastDataDirectoryAccessError: String?

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

  static let defaultServerPassword: String = ""
  @AppStorage("serverPassword") var serverPassword: String = defaultServerPassword

  static let defaultSharePlayServerPort: Int = 12346
  @AppStorage("sharePlayServerPort") var sharePlayServerPort: Int = defaultSharePlayServerPort

  static let defaultMaxBricksPerGetRequest: Int = 20
  @AppStorage("maxBricksPerGetRequest") var maxBricksPerGetRequest: Int = defaultMaxBricksPerGetRequest

  static let defaultDataDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  @AppStorage("dataDirectory") var dataDirectory: String = defaultDataDirectory

  func resetImportDefaults() {
    brickSize = StoredAppModel.defaultBrickSize
    brickOverlap = StoredAppModel.defaultBrickOverlap
    enableCompression = StoredAppModel.defaultEnableCompression
    borderModeString = StoredAppModel.defaultBorderModeString
  }

  func resetBackgroundServerDefaults() {
    deactivateDataDirectoryAccess()
    lastMinute = StoredAppModel.defaultLastMinute
    autoStartServer = StoredAppModel.defaultAutoStartServer
    port = StoredAppModel.defaultPort
    serverPassword = StoredAppModel.defaultServerPassword
    sharePlayServerPort = StoredAppModel.defaultSharePlayServerPort
    maxBricksPerGetRequest = StoredAppModel.defaultMaxBricksPerGetRequest
    dataDirectory = StoredAppModel.defaultDataDirectory
    clearDataDirectoryBookmark()
    lastDataDirectoryAccessError = nil
  }

  func resetToDefaults() {
    resetImportDefaults()
    resetBackgroundServerDefaults()
  }

  func setDataDirectoryURL(_ url: URL) {
    deactivateDataDirectoryAccess()
    lastDataDirectoryAccessError = nil

    dataDirectory = url.path
    let isAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }

    refreshDataDirectoryBookmark(for: url)
    activateDataDirectoryAccess()
  }

  func resolvedDataDirectoryURL() -> URL {
    guard let bookmarkData = dataDirectoryBookmarkData,
          !bookmarkData.isEmpty else {
      return URL(fileURLWithPath: dataDirectory, isDirectory: true)
    }

    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      if isStale {
        refreshDataDirectoryBookmark(for: url)
      }
      return url
    } catch {
      lastDataDirectoryAccessError = "Bookmark konnte nicht aufgelöst werden: \(error.localizedDescription)"
      return URL(fileURLWithPath: dataDirectory, isDirectory: true)
    }
  }

  @discardableResult
  func activateDataDirectoryAccess() -> Bool {
    let url = resolvedDataDirectoryURL()
    if activeDataDirectoryAccessURL == url {
      return true
    }

    deactivateDataDirectoryAccess()
    if url.startAccessingSecurityScopedResource() {
      activeDataDirectoryAccessURL = url
      lastDataDirectoryAccessError = nil
      return true
    }

    activeDataDirectoryAccessURL = nil
    if dataDirectoryBookmarkData != nil {
      lastDataDirectoryAccessError = "Zugriff auf den gespeicherten Datenordner wurde verweigert."
    }
    return false
  }

  func deactivateDataDirectoryAccess() {
    activeDataDirectoryAccessURL?.stopAccessingSecurityScopedResource()
    activeDataDirectoryAccessURL = nil
  }

  @discardableResult
  func startAccessingDataDirectory() -> URL? {
    _ = activateDataDirectoryAccess()
    let url = resolvedDataDirectoryURL()
    return url.startAccessingSecurityScopedResource() ? url : nil
  }

  func stopAccessingDataDirectory(_ url: URL?) {
    url?.stopAccessingSecurityScopedResource()
  }

  func withDataDirectoryAccess<T>(_ body: (URL) throws -> T) rethrows -> T {
    let url = resolvedDataDirectoryURL()
    let isAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if isAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return try body(url)
  }

  private func refreshDataDirectoryBookmark(for url: URL) {
    dataDirectory = url.path
    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(bookmark, forKey: StoredAppModel.dataDirectoryBookmarkKey)
    } catch {
      lastDataDirectoryAccessError = "Bookmark konnte nicht erzeugt werden: \(error.localizedDescription)"
      clearDataDirectoryBookmark()
    }
  }

  private var dataDirectoryBookmarkData: Data? {
    if let data = UserDefaults.standard.data(forKey: StoredAppModel.dataDirectoryBookmarkKey) {
      return data
    }
    if let legacyString = UserDefaults.standard.string(forKey: StoredAppModel.dataDirectoryBookmarkKey),
       let data = Data(base64Encoded: legacyString) {
      UserDefaults.standard.set(data, forKey: StoredAppModel.dataDirectoryBookmarkKey)
      return data
    }
    return nil
  }

  private func clearDataDirectoryBookmark() {
    UserDefaults.standard.removeObject(forKey: StoredAppModel.dataDirectoryBookmarkKey)
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
