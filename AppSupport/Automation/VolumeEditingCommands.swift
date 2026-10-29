import Foundation
import CoreFoundation

enum BorgVRVolumeEditingArguments {
  static func channels(_ value: Any) throws -> BorgVRVolumeEditChannels {
    if let text = value as? String {
      if text.lowercased() == "all" { return .all }
      let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
      guard !parts.isEmpty, parts.count <= BORGVRMetaData.maximumComponentCount else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Provide all or a list of one-based channel numbers.")
      }
      let indices = try parts.map { part -> Int in
        guard let channel = Int(part), channel > 0, channel <= BORGVRMetaData.maximumComponentCount else {
          throw BorgVRVolumeEditingCommandError.invalidArgument("Channel numbers must be positive integers.")
        }
        return channel - 1
      }
      return .selected(indices)
    }
    guard let list = value as? [Any], !list.isEmpty, list.count <= BORGVRMetaData.maximumComponentCount else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Provide all or a list of one-based channel numbers.")
    }
    return .selected(try list.map { value in
      let channel = try number(value)
      guard channel >= 1, channel <= Double(BORGVRMetaData.maximumComponentCount), channel.rounded() == channel else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Channel numbers must be positive integers.")
      }
      return Int(channel) - 1
    })
  }

  static func mode(_ value: String) throws -> BorgVRVolumeBrushMode {
    guard let mode = BorgVRVolumeBrushMode(rawValue: value.lowercased()) else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Brush mode must be erase or restore.")
    }
    return mode
  }

  static func number(_ value: Any?) throws -> Double {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Expected a finite number, not a boolean or string.")
    }
    return number.doubleValue
  }

  static func boolean(_ value: Any?) throws -> Bool? {
    guard let value else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Expected a boolean.")
    }
    return number.boolValue
  }

  static func samples(_ value: Any?) throws -> [BorgVRVolumeBrushSample] {
    guard let rows = value as? [[String: Any]], !rows.isEmpty,
          rows.count <= BorgVRVolumeBrushLimits.maximumSampleCount else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Provide between 1 and 65536 brush samples.")
    }
    return try rows.map { row in
      guard let center = row["center_meters"] as? [Any], center.count == 3 else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("center_meters must contain three numbers.")
      }
      let sample = try BorgVRVolumeBrushSample(center: SIMD3(number(center[0]), number(center[1]), number(center[2])),
        radius: number(row["radius_meters"]))
      try sample.validate()
      return sample
    }
  }

  static func samples(text: String) throws -> [BorgVRVolumeBrushSample] {
    let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
    guard !words.isEmpty, words.count.isMultiple(of: 4), words.count / 4 <= BorgVRVolumeBrushLimits.maximumSampleCount else {
      throw BorgVRVolumeEditingCommandError.invalidArgument("Expected x y z radius groups in meters.")
    }
    let values = try words.map { word -> Double in
      guard let value = Double(word), value.isFinite else {
        throw BorgVRVolumeEditingCommandError.invalidArgument("Brush samples must contain finite numbers.")
      }
      return value
    }
    return try stride(from: 0, to: values.count, by: 4).map { i in
      let sample = BorgVRVolumeBrushSample(center: SIMD3(values[i], values[i + 1], values[i + 2]), radius: values[i + 3])
      try sample.validate()
      return sample
    }
  }
}

struct BorgVRVolumeExportJob: Codable, Equatable, Sendable {
  enum Status: String, Codable, Sendable { case running, cancelling, completed, cancelled, failed }
  let id: UUID
  let outputPath: String
  var status: Status
  var progress: Double
  var error: String?

  var isActive: Bool { status == .running || status == .cancelling }
}

struct BorgVRVolumeEditingState: Codable, Sendable {
  var available: Bool
  var datasetID: String?
  var hasEdits: Bool
  var isUpdatingBricks: Bool
  var pendingBrickCount: Int
  var mode: BorgVRVolumeBrushMode
  var radiusFraction: Double
  var radiusMeters: Double
  var projectsOntoVolume: Bool
  var export: BorgVRVolumeExportJob?
  var activeStateID: UUID? = nil
  var savedStates: [BorgVRVolumeEditState] = []
  var shared: Bool = false
  var waitingForSharedState: Bool = false
  var componentCount: Int = 1
  var channels: [Int] = [1]
}

enum BorgVRVolumeEditingCommandError: LocalizedError {
  case unavailable
  case busy
  case exportUnavailableDuringSharePlay
  case invalidArgument(String)
  case unknownExport
  case exportFailed(String)
  case timeout

  var errorDescription: String? {
    switch self {
      case .unavailable: String(localized: "No editable dataset is open.")
      case .busy: String(localized: "A conflicting volume-edit operation is already active.")
      case .exportUnavailableDuringSharePlay: String(localized: "Exports are unavailable during SharePlay.")
      case .invalidArgument(let message), .exportFailed(let message): message
      case .unknownExport: String(localized: "The requested export is not the current export job.")
      case .timeout: String(localized: "Volume edits did not finish before the timeout.")
    }
  }
}

@MainActor
protocol BorgVRVolumeEditingCommands: AnyObject {
  func selectState(_ id: UUID?) async throws
  func duplicateState(name: String, empty: Bool) async throws
  func renameState(_ id: UUID, name: String) throws
  func deleteState(_ id: UUID) throws
  func volumeEditingState() -> BorgVRVolumeEditingState
  func configureVolumeBrush(mode: BorgVRVolumeBrushMode?, radiusFraction: Double?, projectsOntoVolume: Bool?) throws
  func setVolumeBrushChannels(_ channels: BorgVRVolumeEditChannels) throws
  func editVolume(mode: BorgVRVolumeBrushMode, samples: [BorgVRVolumeBrushSample]) async throws
  func discardVolumeEdits() async throws
  func waitForVolumeEdits(timeout: TimeInterval) async throws
  func prepareVolumeEdits() async throws
  func startVolumeExport(to url: URL, name: String?, description: String?) throws -> BorgVRVolumeExportJob
  func waitForVolumeExport(id: UUID) async throws -> BorgVRVolumeExportJob
  func cancelVolumeExport(id: UUID) throws
}
