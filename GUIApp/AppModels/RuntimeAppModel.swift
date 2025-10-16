import SwiftUI

@MainActor
@Observable
class RuntimeAppModel {
  enum ContentViewState {
    case start
    case importData
    case serveData
    case settings
  }

  var currentState: ContentViewState = .start
}

extension Bundle {
  var appVersion: String {
    return infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
  }

  var appBuild: String {
    return infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
  }
}
