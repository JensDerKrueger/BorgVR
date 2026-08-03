import SwiftUI
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
      case .system: return String(localized: "Systemfarbe")
      case .solid: return String(localized: "Eigene Farbe")
      case .gradient: return String(localized: "Vertikaler Verlauf")
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
  private static let maximum3DTextureDimension = 2048
#if os(iOS)
  // iOS can fail to map very large shared 3D texture allocations even on
  // 64-bit devices. Keep the default/settings cap below that practical limit.
  private static let maximumSingleAtlasAllocationMB = 2048
#endif

  static var physicalMemoryMB: Int {
    Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
  }

  static var maximumAtlasTextureSizeMB: Int {
    let dimension = Int64(maximum3DTextureDimension)
    let bytes = dimension * dimension * dimension
    return Int(bytes / 1024 / 1024)
  }

  static var maximumAtlasSizeMB: Int {
#if os(iOS)
    max(128, min(physicalMemoryMB, maximumAtlasTextureSizeMB, maximumSingleAtlasAllocationMB))
#else
    max(128, min(physicalMemoryMB, maximumAtlasTextureSizeMB))
#endif
  }

  static var defaultAtlasSizeMB: Int {
    max(128, min(physicalMemoryMB / 2, maximumAtlasSizeMB))
  }

  static let values: [String: Any] = [
    "timeout": 2.0,
    "makeLocalCopy": true,
    "progressiveLoading": true,
    "brickSize": 64,
    "brickOverlap": 2,
    "enableCompression": true,
    "borderMode": "zeroes",
    "screenSpaceError": 0.25,
    "initialBricks": 4000,
    "minHashTableSize": 16,
    "maxProbingAttempts": 32,
    "maxBricksPerGetRequest": 20,
    "atlasSizeMB": defaultAtlasSizeMB,
    "oversampling": 1.0,
    "oversamplingMode": OversamplingMode.dynamicMode.rawValue,
    "dropFPS": 20,
    "recoveryFPS": 50,
    "sharePlayServerPort": 12346,
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
  @AppStorage("maxBricksPerGetRequest") var maxBricksPerGetRequest: Int = AppSettings.int("maxBricksPerGetRequest")
  @AppStorage("atlasSizeMB") var atlasSizeMB: Int = AppSettings.int("atlasSizeMB")
  @AppStorage("oversampling") var oversampling: Double = AppSettings.double("oversampling")
  @AppStorage("oversamplingMode") var oversamplingMode: String = AppSettings.string("oversamplingMode")
  @AppStorage("dropFPS") var dropFPS: Int = AppSettings.int("dropFPS")
  @AppStorage("recoveryFPS") var recoveryFPS: Int = AppSettings.int("recoveryFPS")
  @AppStorage("sharePlayServerPort") var sharePlayServerPort: Int = AppSettings.int("sharePlayServerPort")
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
    clampAtlasSizeToSupportedRange()
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

  private func clampAtlasSizeToSupportedRange() {
    atlasSizeMB = min(max(128, atlasSizeMB), Self.maximumAtlasSizeMB)
  }

  func resetRenderingDefaults() {
    autoloadTF = Self.boolDefault("autoloadTF")
    autoloadTransform = Self.boolDefault("autoloadTransform")
    oversampling = Self.doubleDefault("oversampling")
    oversamplingMode = Self.stringDefault("oversamplingMode")
    atlasSizeMB = Self.intDefault("atlasSizeMB")
    minHashTableSize = Self.intDefault("minHashTableSize")
    renderBackgroundMode = Self.stringDefault("renderBackgroundMode")
    renderBackgroundPrimaryRed = Self.doubleDefault("renderBackgroundPrimaryRed")
    renderBackgroundPrimaryGreen = Self.doubleDefault("renderBackgroundPrimaryGreen")
    renderBackgroundPrimaryBlue = Self.doubleDefault("renderBackgroundPrimaryBlue")
    renderBackgroundPrimaryAlpha = Self.doubleDefault("renderBackgroundPrimaryAlpha")
    renderBackgroundSecondaryRed = Self.doubleDefault("renderBackgroundSecondaryRed")
    renderBackgroundSecondaryGreen = Self.doubleDefault("renderBackgroundSecondaryGreen")
    renderBackgroundSecondaryBlue = Self.doubleDefault("renderBackgroundSecondaryBlue")
    renderBackgroundSecondaryAlpha = Self.doubleDefault("renderBackgroundSecondaryAlpha")
    logLevel = Self.stringDefault("logLevel")
  }

  func resetImportDefaults() {
    brickSize = Self.intDefault("brickSize")
    brickOverlap = Self.intDefault("brickOverlap")
    enableCompression = Self.boolDefault("enableCompression")
    borderMode = Self.stringDefault("borderMode")
  }

  func resetRemoteDefaults() {
    timeout = Self.doubleDefault("timeout")
    makeLocalCopy = Self.boolDefault("makeLocalCopy")
    progressiveLoading = Self.boolDefault("progressiveLoading")
    maxBricksPerGetRequest = Self.intDefault("maxBricksPerGetRequest")
    sharePlayServerPort = Self.intDefault("sharePlayServerPort")
    servers = []
  }

  func resetLODDefaults() {
    screenSpaceError = Self.doubleDefault("screenSpaceError")
    initialBricks = Self.intDefault("initialBricks")
    maxProbingAttempts = Self.intDefault("maxProbingAttempts")
    dropFPS = Self.intDefault("dropFPS")
    recoveryFPS = Self.intDefault("recoveryFPS")
    requestLowResLOD = Self.boolDefault("requestLowResLOD")
    stopOnMiss = Self.boolDefault("stopOnMiss")
  }

  func resetToDefaults() {
    resetRenderingDefaults()
    resetImportDefaults()
    resetRemoteDefaults()
    resetLODDefaults()
  }

  private static func intDefault(_ key: String) -> Int {
    values[key] as? Int ?? 0
  }

  private static func doubleDefault(_ key: String) -> Double {
    values[key] as? Double ?? 0
  }

  private static func stringDefault(_ key: String) -> String {
    values[key] as? String ?? ""
  }

  private static func boolDefault(_ key: String) -> Bool {
    values[key] as? Bool ?? false
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
    #if canImport(UIKit)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (
      red: Double(red),
      green: Double(green),
      blue: Double(blue),
      alpha: Double(alpha)
    )
    #elseif canImport(AppKit)
    let nsColor = NSColor(color)
    let rgbColor = nsColor.usingColorSpace(.deviceRGB) ?? .black
    return (
      red: Double(rgbColor.redComponent),
      green: Double(rgbColor.greenComponent),
      blue: Double(rgbColor.blueComponent),
      alpha: Double(rgbColor.alphaComponent)
    )
    #else
    return (0, 0, 0, 1)
    #endif
  }
}
