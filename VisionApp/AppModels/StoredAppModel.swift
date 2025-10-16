import SwiftUI

// MARK: - Bundle Extension

extension Bundle {
  /// The app's short version string from the Info.plist.
  var appVersion: String {
    return infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
  }

  /// The app's build number from the Info.plist.
  var appBuild: String {
    return infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
  }
}

// MARK: - OversamplingMode

/**
 Represents the mode used for oversampling in volume rendering.

 - staticMode: Use a fixed oversampling factor.
 - dynamicMode: Adjust oversampling dynamically based on performance.
 */
enum OversamplingMode: String {
  /// Use a fixed oversampling factor.
  case staticMode = "static"
  /// Adjust oversampling dynamically based on performance.
  case dynamicMode = "dynamic"
}

// MARK: - StoredAppModel

/**
 Manages application settings stored in `UserDefaults` via `@AppStorage`.

 Manages all persistent local state that should survive app restarts but remain private to the device.
 This includes settings, preferences, and session data.
 The model provides functionality for reading and writing to the system’s storage API.
*/
final class StoredAppModel: ObservableObject {

  /// Default values for all supported settings keys.
  static let values: [String: Any] = [
    "serverAddress": "",
    "serverPort": 12345,
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
    "disableFoveation": false,
    "requestLowResLOD": true,
    "stopOnMiss": false,
    "showProfiling": false,
    "showNotifications": false,
    "enableVoiceInput": false,
    "autostartVoiceInput": false,
    "enableVoiceOutput": false
  ]

  // MARK: - Network Settings

  /// The address of the remote server.
  @AppStorage("serverAddress") var serverAddress: String = StoredAppModel.string("serverAddress")
  /// The port number of the remote server.
  @AppStorage("serverPort") var serverPort: Int = StoredAppModel.int("serverPort")
  /// Network timeout duration in seconds.
  @AppStorage("timeout") var timeout: Double = StoredAppModel.double("timeout")
  /// Whether to make a local copy of downloaded data.
  @AppStorage("makeLocalCopy") var makeLocalCopy: Bool = StoredAppModel.bool("makeLocalCopy")
  /// Whether to load the bricks progressively or upfront (false)
  @AppStorage("progressiveLoading") var progressiveLoading: Bool = StoredAppModel.bool("progressiveLoading")


  // MARK: - Brick and Compression Settings

  /// The size of each brick (in voxels).
  @AppStorage("brickSize") var brickSize: Int = StoredAppModel.int("brickSize")
  /// The overlap between adjacent bricks (in voxels).
  @AppStorage("brickOverlap") var brickOverlap: Int = StoredAppModel.int("brickOverlap")
  /// Whether to compress bricks when sending over network.
  @AppStorage("enableCompression") var enableCompression: Bool = StoredAppModel.bool("enableCompression")
  /// The border mode used for brick edges (e.g., "zeroes" or "clamp").
  @AppStorage("borderMode") var borderMode: String = StoredAppModel.string("borderMode")

  // MARK: - Rendering and Performance Settings

  /// The allowable screen-space error for LOD selection.
  @AppStorage("screenSpaceError") var screenSpaceError: Double = StoredAppModel.double("screenSpaceError")
  /// Initial number of bricks to load.
  @AppStorage("initialBricks") var initialBricks: Int = StoredAppModel.int("initialBricks")
  /// Minimum size (in MB) of the the bricks represented be the internal hash table.
  @AppStorage("minHashTableSize") var minHashTableSize: Int = StoredAppModel.int("minHashTableSize")
  ///  Maximum linear probing attempts in the hash table before giving up
  @AppStorage("maxProbingAttempts") var maxProbingAttempts: Int = StoredAppModel.int("maxProbingAttempts")
  /// Size of the texture atlas in megabytes.
  @AppStorage("atlasSizeMB") var atlasSizeMB: Int = StoredAppModel.int("atlasSizeMB")
  /// The oversampling factor for rendering.
  @AppStorage("oversampling") var oversampling: Double = StoredAppModel.double("oversampling")
  /// The oversampling mode ("static" or "dynamic").
  @AppStorage("oversamplingMode") var oversamplingMode: String = StoredAppModel.string("oversamplingMode")
  /// Target frames per second below which the step size is increase.
  @AppStorage("dropFPS") var dropFPS: Int = StoredAppModel.int("dropFPS")
  /// FPS at which recovery occurs after step size increment.
  @AppStorage("recoveryFPS") var recoveryFPS: Int = StoredAppModel.int("recoveryFPS")
  /// Whether to automatically load the transfer function.
  @AppStorage("autoloadTF") var autoloadTF: Bool = StoredAppModel.bool("autoloadTF")
  /// Whether to automatically load the object transfomration.
  @AppStorage("autoloadTransform") var autoloadTransform: Bool = StoredAppModel.bool("autoloadTransform")
  /// Whether to disable the built-in foveation feature
  @AppStorage("disableFoveation") var disableFoveation: Bool = StoredAppModel.bool("disableFoveation")
  /// Whether to request a low resolution LOD along with the high res
  @AppStorage("requestLowResLOD") var requestLowResLOD: Bool = StoredAppModel.bool("requestLowResLOD")
  /// Whether the raycaster should terminate if a brick is missing
  @AppStorage("stopOnMiss") var stopOnMiss: Bool = StoredAppModel.bool("stopOnMiss")
  /// Whether the Profiling Button should be displayed
  @AppStorage("showProfiling") var showProfiling: Bool = StoredAppModel.bool("showProfiling")
  /// Whether the app displays notifictaions of background events
  @AppStorage("showNotifications") var showNotifications: Bool = StoredAppModel.bool("showNotifications")
  /// Whether the voice input is eabled
  @AppStorage("enableVoiceInput") var enableVoiceInput: Bool = StoredAppModel.bool("enableVoiceInput")
  /// Whether the voice starts automatically when a dataset is opened
  @AppStorage("autostartVoiceInput") var autostartVoiceInput: Bool = StoredAppModel.bool("autostartVoiceInput")
  /// Whether voice output is eabled
  @AppStorage("enableVoiceOutput") var enableVoiceOutput: Bool = StoredAppModel.bool("enableVoiceOutput")


  // MARK: - Convenience Accessors

  /**
   Retrieves an `Int` for the given key from `UserDefaults`, or falls back to the default value.

   - Parameter key: The settings key.
   - Returns: The stored or default integer value.
   */
  static func int(_ key: String) -> Int {
    if let value = UserDefaults.standard.object(forKey: key) as? Int {
      return value
    }
    return StoredAppModel.values[key] as? Int ?? 0
  }

  /**
   Retrieves a `Double` for the given key from `UserDefaults`, or falls back to the default value.

   - Parameter key: The settings key.
   - Returns: The stored or default double value.
   */
  static func double(_ key: String) -> Double {
    if let value = UserDefaults.standard.object(forKey: key) as? Double {
      return value
    }
    return StoredAppModel.values[key] as? Double ?? 0.0
  }

  /**
   Retrieves a `Float` for the given key from `UserDefaults`, or falls back to the default value.

   - Parameter key: The settings key.
   - Returns: The stored or default float value.
   */
  static func float(_ key: String) -> Float {
    if let value = UserDefaults.standard.object(forKey: key) as? Double {
      return Float(value)
    }
    return Float(StoredAppModel.values[key] as? Double ?? 0.0)
  }

  /**
   Retrieves a `String` for the given key from `UserDefaults`, or falls back to the default value.

   - Parameter key: The settings key.
   - Returns: The stored or default string.
   */
  static func string(_ key: String) -> String {
    if let value = UserDefaults.standard.object(forKey: key) as? String {
      return value
    }
    return StoredAppModel.values[key] as? String ?? ""
  }

  /**
   Retrieves a `Bool` for the given key from `UserDefaults`, or falls back to the default value.

   - Parameter key: The settings key.
   - Returns: The stored or default boolean.
   */
  static func bool(_ key: String) -> Bool {
    if let value = UserDefaults.standard.object(forKey: key) as? Bool {
      return value
    }
    return StoredAppModel.values[key] as? Bool ?? false
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
