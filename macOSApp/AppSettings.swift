import AppKit
import SwiftUI

enum OversamplingMode: String {
  case staticMode = "static"
  case dynamicMode = "dynamic"
}

enum RenderBackgroundMode: String, CaseIterable, Identifiable {
  case system
  case solid
  case gradient

  var id: String { rawValue }

  var label: String {
    switch self {
      case .system: return "Systemfarbe"
      case .solid: return "Eigene Farbe"
      case .gradient: return "Vertikaler Verlauf"
    }
  }
}

enum AppLogLevel: String, CaseIterable, Identifiable {
  case dev
  case progress
  case info
  case warning
  case error

  var id: String { rawValue }

  var level: LogLevel {
    switch self {
      case .dev: return .dev
      case .progress: return .progress
      case .info: return .info
      case .warning: return .warning
      case .error: return .error
    }
  }

  var label: LocalizedStringKey {
    switch self {
      case .dev: return "log_level_dev"
      case .progress: return "log_level_progress"
      case .info: return "log_level_info"
      case .warning: return "log_level_warning"
      case .error: return "log_level_error"
    }
  }
}

struct StoredServer: Identifiable, Codable, Equatable {
  var id: UUID = UUID()
  var address: String
  var port: Int
}

final class AppSettings: ObservableObject {
  static let values: [String: Any] = [
    "timeout": 2.0,
    "makeLocalCopy": true,
    "progressiveLoading": true,
    "brickSize": 64,
    "brickOverlap": 2,
    "enableCompression": true,
    "borderMode": "zeroes",
    "screenSpaceError": 1.0,
    "initialBricks": 4000,
    "minHashTableSize": 16,
    "maxProbingAttempts": 32,
    "atlasSizeMB": 1500,
    "oversampling": 1.0,
    "oversamplingMode": OversamplingMode.dynamicMode.rawValue,
    "dropFPS": 20,
    "recoveryFPS": 50,
    "autoloadTF": false,
    "autoloadTransform": false,
    "requestLowResLOD": true,
    "stopOnMiss": false,
    "renderBackgroundMode": RenderBackgroundMode.system.rawValue,
    "renderBackgroundPrimaryRed": 0.0,
    "renderBackgroundPrimaryGreen": 0.0,
    "renderBackgroundPrimaryBlue": 0.0,
    "renderBackgroundPrimaryAlpha": 1.0,
    "renderBackgroundSecondaryRed": 0.16,
    "renderBackgroundSecondaryGreen": 0.18,
    "renderBackgroundSecondaryBlue": 0.22,
    "renderBackgroundSecondaryAlpha": 1.0,
    "logLevel": AppLogLevel.warning.rawValue
  ]

  @AppStorage("serversData") private var serversData: Data = Data()

  @Published var servers: [StoredServer] = [] {
    didSet { saveServers() }
  }

  @AppStorage("timeout") var timeout: Double = AppSettings.double("timeout")
  @AppStorage("makeLocalCopy") var makeLocalCopy: Bool = AppSettings.bool("makeLocalCopy")
  @AppStorage("progressiveLoading") var progressiveLoading: Bool = AppSettings.bool("progressiveLoading")
  @AppStorage("brickSize") var brickSize: Int = AppSettings.int("brickSize")
  @AppStorage("brickOverlap") var brickOverlap: Int = AppSettings.int("brickOverlap")
  @AppStorage("enableCompression") var enableCompression: Bool = AppSettings.bool("enableCompression")
  @AppStorage("borderMode") var borderMode: String = AppSettings.string("borderMode")
  @AppStorage("screenSpaceError") var screenSpaceError: Double = AppSettings.double("screenSpaceError")
  @AppStorage("initialBricks") var initialBricks: Int = AppSettings.int("initialBricks")
  @AppStorage("minHashTableSize") var minHashTableSize: Int = AppSettings.int("minHashTableSize")
  @AppStorage("maxProbingAttempts") var maxProbingAttempts: Int = AppSettings.int("maxProbingAttempts")
  @AppStorage("atlasSizeMB") var atlasSizeMB: Int = AppSettings.int("atlasSizeMB")
  @AppStorage("oversampling") var oversampling: Double = AppSettings.double("oversampling")
  @AppStorage("oversamplingMode") var oversamplingMode: String = AppSettings.string("oversamplingMode")
  @AppStorage("dropFPS") var dropFPS: Int = AppSettings.int("dropFPS")
  @AppStorage("recoveryFPS") var recoveryFPS: Int = AppSettings.int("recoveryFPS")
  @AppStorage("autoloadTF") var autoloadTF: Bool = AppSettings.bool("autoloadTF")
  @AppStorage("autoloadTransform") var autoloadTransform: Bool = AppSettings.bool("autoloadTransform")
  @AppStorage("requestLowResLOD") var requestLowResLOD: Bool = AppSettings.bool("requestLowResLOD")
  @AppStorage("stopOnMiss") var stopOnMiss: Bool = AppSettings.bool("stopOnMiss")
  @AppStorage("renderBackgroundMode") var renderBackgroundMode: String = AppSettings.string("renderBackgroundMode")
  @AppStorage("renderBackgroundPrimaryRed") private var renderBackgroundPrimaryRed: Double = AppSettings.double("renderBackgroundPrimaryRed")
  @AppStorage("renderBackgroundPrimaryGreen") private var renderBackgroundPrimaryGreen: Double = AppSettings.double("renderBackgroundPrimaryGreen")
  @AppStorage("renderBackgroundPrimaryBlue") private var renderBackgroundPrimaryBlue: Double = AppSettings.double("renderBackgroundPrimaryBlue")
  @AppStorage("renderBackgroundPrimaryAlpha") private var renderBackgroundPrimaryAlpha: Double = AppSettings.double("renderBackgroundPrimaryAlpha")
  @AppStorage("renderBackgroundSecondaryRed") private var renderBackgroundSecondaryRed: Double = AppSettings.double("renderBackgroundSecondaryRed")
  @AppStorage("renderBackgroundSecondaryGreen") private var renderBackgroundSecondaryGreen: Double = AppSettings.double("renderBackgroundSecondaryGreen")
  @AppStorage("renderBackgroundSecondaryBlue") private var renderBackgroundSecondaryBlue: Double = AppSettings.double("renderBackgroundSecondaryBlue")
  @AppStorage("renderBackgroundSecondaryAlpha") private var renderBackgroundSecondaryAlpha: Double = AppSettings.double("renderBackgroundSecondaryAlpha")
  @AppStorage("logLevel") var logLevel: String = AppSettings.string("logLevel")

  var selectedLogLevel: AppLogLevel {
    AppLogLevel(rawValue: logLevel) ?? .warning
  }

  var renderBackgroundPrimaryColor: Color {
    get {
      Color(
        red: renderBackgroundPrimaryRed,
        green: renderBackgroundPrimaryGreen,
        blue: renderBackgroundPrimaryBlue,
        opacity: renderBackgroundPrimaryAlpha
      )
    }
    set {
      setPrimaryBackgroundColor(newValue)
    }
  }

  var renderBackgroundSecondaryColor: Color {
    get {
      Color(
        red: renderBackgroundSecondaryRed,
        green: renderBackgroundSecondaryGreen,
        blue: renderBackgroundSecondaryBlue,
        opacity: renderBackgroundSecondaryAlpha
      )
    }
    set {
      setSecondaryBackgroundColor(newValue)
    }
  }

  init() {
    loadServers()
  }

  static func int(_ key: String) -> Int {
    if let value = UserDefaults.standard.object(forKey: key) as? Int {
      return value
    }
    return values[key] as? Int ?? 0
  }

  static func double(_ key: String) -> Double {
    if let value = UserDefaults.standard.object(forKey: key) as? Double {
      return value
    }
    return values[key] as? Double ?? 0
  }

  static func float(_ key: String) -> Float {
    if let value = UserDefaults.standard.object(forKey: key) as? Double {
      return Float(value)
    }
    return Float(values[key] as? Double ?? 0)
  }

  static func string(_ key: String) -> String {
    if let value = UserDefaults.standard.object(forKey: key) as? String {
      return value
    }
    return values[key] as? String ?? ""
  }

  static func bool(_ key: String) -> Bool {
    if let value = UserDefaults.standard.object(forKey: key) as? Bool {
      return value
    }
    return values[key] as? Bool ?? false
  }

  private func loadServers() {
    if let decoded = try? JSONDecoder().decode([StoredServer].self, from: serversData) {
      servers = decoded
    }
  }

  private func saveServers() {
    if let data = try? JSONEncoder().encode(servers) {
      serversData = data
    }
  }

  private func setPrimaryBackgroundColor(_ color: Color) {
    let components = AppSettings.components(for: color)
    renderBackgroundPrimaryRed = components.red
    renderBackgroundPrimaryGreen = components.green
    renderBackgroundPrimaryBlue = components.blue
    renderBackgroundPrimaryAlpha = components.alpha
  }

  private func setSecondaryBackgroundColor(_ color: Color) {
    let components = AppSettings.components(for: color)
    renderBackgroundSecondaryRed = components.red
    renderBackgroundSecondaryGreen = components.green
    renderBackgroundSecondaryBlue = components.blue
    renderBackgroundSecondaryAlpha = components.alpha
  }

  private static func components(for color: Color) -> (red: Double, green: Double, blue: Double, alpha: Double) {
    let nsColor = NSColor(color)
    let rgbColor = nsColor.usingColorSpace(.deviceRGB) ?? .black
    return (
      red: Double(rgbColor.redComponent),
      green: Double(rgbColor.greenComponent),
      blue: Double(rgbColor.blueComponent),
      alpha: Double(rgbColor.alphaComponent)
    )
  }
}
