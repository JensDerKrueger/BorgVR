import Foundation
import CoreFoundation

extension Notification.Name {
  static let borgVRSettingsImported = Notification.Name("BorgVRSettingsImported")
}

enum BorgVRSettingsArchiveError: LocalizedError {
  case invalidFile
  case invalidValue(String)
  case unsupportedValue

  var errorDescription: String? {
    switch self {
      case .invalidFile: String(localized: "This is not a valid BorgVR settings file.")
      case .invalidValue(let key): String(format: String(localized: "Invalid setting: %@"), key)
      case .unsupportedValue: String(localized: "This setting is not supported on this device.")
    }
  }
}

/// An explicit registry prevents a settings file from writing arbitrary defaults.
/// Platform registries reuse their existing defaults and override Keychain-backed values.
@MainActor
struct BorgVRSettingsStore {
  nonisolated static let fileExtension = "borgvrsettings"
  nonisolated static let typeIdentifier = "de.uni-due.borgvr.settings"
  nonisolated static let maximumFileSize = 24 * 1024 * 1024

  struct Entry {
    let key: String
    let defaultValue: Any
    var sensitive = false
    let read: (_ includeCredentials: Bool) -> Any
    let write: (Any) throws -> Void
    var validate: ((Any) throws -> Void)?
  }

  struct ImportPlan {
    let data: Data
    let values: [String: Any]
    let ignoredCount: Int
    var count: Int { values.count }
  }

  private let entries: [String: Entry]
  private let maximumAtlasSizeMB: Int?
  private let allowedStrings: [String: Set<String>]
  private let didImport: () -> Void

  init(defaultValues: [String: Any], defaults: UserDefaults = .standard,
       overrides: [Entry] = [], maximumAtlasSizeMB: Int? = nil,
       allowedStrings: [String: Set<String>] = [:], didImport: @escaping () -> Void = {}) {
    self.maximumAtlasSizeMB = maximumAtlasSizeMB
    self.allowedStrings = allowedStrings
    self.didImport = didImport
    let sensitiveKeys: Set<String> = ["mcpAccessToken", "webServerCertificateData", "mcpServerCertificateData"]
    var entries: [String: Entry] = [:]
    for (key, value) in defaultValues where key != "serverPassword" {
      entries[key] = Entry(key: key, defaultValue: value, sensitive: sensitiveKeys.contains(key),
        read: { _ in defaults.object(forKey: key) ?? value },
        write: { defaults.set($0, forKey: key) })
    }
    for entry in overrides { entries[entry.key] = entry }
    self.entries = entries
  }

  func export(includeCredentials: Bool) throws -> Data {
    var values: [String: Any] = [:]
    for (key, entry) in entries where includeCredentials || !entry.sensitive {
      let value = try normalized(entry.read(includeCredentials), for: entry, importing: false)
      values[key] = (value as? Data)?.base64EncodedString() ?? value
    }
    return try JSONSerialization.data(withJSONObject: [
      "format": "BorgVR Settings", "formatVersion": 1,
      "includesCredentials": includeCredentials, "settings": values
    ], options: [.prettyPrinted, .sortedKeys])
  }

  /// Automation must not disable or reconfigure its own control connection.
  private static func isMCPConnectionKey(_ key: String) -> Bool {
    key == "enableMCPServer" || key.hasPrefix("mcp")
  }

  func importForAutomation(_ data: Data) throws {
    let plan = try prepareImport(data)
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    root["settings"] = plan.values.filter { !Self.isMCPConnectionKey($0.key) }.mapValues { value in
      (value as? Data)?.base64EncodedString() ?? value
    }
    try apply(prepareImport(JSONSerialization.data(withJSONObject: root)))
  }

  func resetForAutomation() throws {
    let values = entries.filter { !Self.isMCPConnectionKey($0.key) }.mapValues { entry in
      (entry.defaultValue as? Data)?.base64EncodedString() ?? entry.defaultValue
    }
    let data = try JSONSerialization.data(withJSONObject: [
      "format": "BorgVR Settings", "formatVersion": 1, "settings": values
    ])
    try apply(prepareImport(data))
  }

  func prepareImport(_ data: Data) throws -> ImportPlan {
    guard data.count <= Self.maximumFileSize,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      root["format"] as? String == "BorgVR Settings",
      let settings = root["settings"] as? [String: Any] else {
      throw BorgVRSettingsArchiveError.invalidFile
    }
    var values: [String: Any] = [:]
    var ignored = 0
    for (key, value) in settings {
      guard let entry = entries[key] else { ignored += 1; continue }
      do {
        values[key] = try normalized(value, for: entry, importing: true)
      } catch BorgVRSettingsArchiveError.unsupportedValue {
        ignored += 1
      }
    }
    func integer(_ key: String) -> Int? {
      (values[key] ?? entries[key]?.read(true)) as? Int
    }
    if let size = integer("brickSize"), let overlap = integer("brickOverlap"),
      size <= overlap * 2 {
      throw BorgVRSettingsArchiveError.invalidValue("brickSize / brickOverlap")
    }
    return ImportPlan(data: data, values: values, ignoredCount: ignored)
  }

  func apply(_ plan: ImportPlan) throws {
    // Revalidate against current settings in case they changed while confirmation was open.
    let plan = try prepareImport(plan.data)
    let previous = plan.values.keys.sorted().map { ($0, entries[$0]!.read(true)) }
    do {
      // Configure ports/credentials before activating services.
      let activationKeys: Set<String> = ["enableDatasetServer", "enableWebServer", "enableMCPServer", "autoStartServer"]
      let ordered = plan.values.keys.sorted {
        if activationKeys.contains($0) != activationKeys.contains($1) { return !activationKeys.contains($0) }
        return $0 < $1
      }
      for key in ordered { try entries[key]!.write(plan.values[key]!) }
    } catch {
      for (key, value) in previous.reversed() { try? entries[key]!.write(value) }
      didImport()
      throw error
    }
    didImport()
    NotificationCenter.default.post(name: .borgVRSettingsImported, object: nil)
  }

  private func normalized(_ value: Any, for entry: Entry, importing: Bool) throws -> Any {
    func invalid() -> BorgVRSettingsArchiveError { .invalidValue(entry.key) }
    let result: Any
    if entry.defaultValue is Data {
      if let data = value as? Data { result = data }
      else if importing, let string = value as? String, let data = Data(base64Encoded: string) { result = data }
      else { throw invalid() }
    } else if entry.defaultValue is String {
      guard let string = value as? String, string.utf8.count <= 65536 else { throw invalid() }
      let choices = allowedStrings[entry.key] ?? Self.stringChoices[entry.key]
      if let choices, !choices.contains(string) { throw BorgVRSettingsArchiveError.unsupportedValue }
      result = string
    } else if let initial = entry.defaultValue as? NSNumber {
      guard let number = value as? NSNumber else { throw invalid() }
      let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
      if CFGetTypeID(initial) == CFBooleanGetTypeID() {
        guard isBool else { throw invalid() }
        result = number.boolValue
      } else {
        let numeric = number.doubleValue
        guard !isBool, numeric.isFinite else { throw invalid() }
        let integer = !CFNumberIsFloatType(unsafeBitCast(initial, to: CFNumber.self))
        if integer {
          guard numeric.rounded() == numeric, numeric >= Double(Int.min), numeric < Double(Int.max) else { throw invalid() }
        }
        guard Self.range(for: entry.key).contains(numeric) else { throw invalid() }
        if ["atlasCompression", "importColorCompression"].contains(entry.key), ![0.0, 4.0, 8.0].contains(numeric) {
          throw BorgVRSettingsArchiveError.unsupportedValue
        }
        let adjusted = entry.key == "atlasSizeMB" ? min(numeric, Double(maximumAtlasSizeMB ?? Int.max)) : numeric
        result = integer ? Int(adjusted) as Any : adjusted as Any
      }
    } else {
      guard JSONSerialization.isValidJSONObject(value) else { throw invalid() }
      result = value
    }
    try entry.validate?(result)
    return result
  }

  private static let stringChoices: [String: Set<String>] = [
    "borderMode": ["zeroes", "border", "repeat"],
    "dicomResamplingFilter": ["nearestNeighbor", "trilinear"],
    "oversamplingMode": ["static", "dynamic"],
    "renderBackgroundMode": ["system", "solid", "gradient"],
    "logLevel": ["dev", "progress", "info", "warning", "error"]
  ]

  private static func range(for key: String) -> ClosedRange<Double> {
    if key.lowercased().hasSuffix("port") { return 1...65535 }
    if key.hasPrefix("markerDefault") || key.hasPrefix("renderBackground") { return 0...1 }
    switch key {
      case "timeout": return 0.01...3600
      case "brickSize": return 1...512
      case "brickOverlap": return 0...255
      case "screenSpaceError": return 0.001...100
      case "initialBricks": return 0...1_000_000
      case "minHashTableSize": return 1...8192
      case "maxProbingAttempts": return 1...4096
      case "maxBricksPerGetRequest": return 1...1_000_000
      case "atlasSizeMB": return 128...1_000_000
      case "oversampling": return 0.01...100
      case "screenFieldOfView": return 10...120
      case "foveationSamplingStrength": return 0...4
      case "uiRenderModes": return 1...7
      case "uiInteractionModes": return 1...127
      case "uiPanelButtons": return 0...31
      case "alphaEpsilon": return 0...1
      case "dropFPS", "recoveryFPS": return 1...1000
      case "tfMode": return 0...2
      case "quickMarkerDoublePinchInterval": return 0.01...10
      default: return -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    }
  }
}
