import SwiftUI

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

// MARK: - AppSettings

/**
 Manages application settings stored in `UserDefaults` via `@AppStorage`.

 Provides default values and convenience accessors for various configuration keys,
 including network settings, brick parameters, performance targets, and UI preferences.
 */
final class AppSettings: ObservableObject {

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
    "showProfiling": false
  ]

  // MARK: - Network Settings

  /// The address of the remote server.
  @AppStorage("serverAddress") var serverAddress: String = AppSettings.string("serverAddress")
  /// The port number of the remote server.
  @AppStorage("serverPort") var serverPort: Int = AppSettings.int("serverPort")
  /// Network timeout duration in seconds.
  @AppStorage("timeout") var timeout: Double = AppSettings.double("timeout")
  /// Whether to make a local copy of downloaded data.
  @AppStorage("makeLocalCopy") var makeLocalCopy: Bool = AppSettings.bool("makeLocalCopy")
  /// Whether to load the bricks progressively or upfront (false)
  @AppStorage("progressiveLoading") var progressiveLoading: Bool = AppSettings.bool("progressiveLoading")


  // MARK: - Brick and Compression Settings

  /// The size of each brick (in voxels).
  @AppStorage("brickSize") var brickSize: Int = AppSettings.int("brickSize")
  /// The overlap between adjacent bricks (in voxels).
  @AppStorage("brickOverlap") var brickOverlap: Int = AppSettings.int("brickOverlap")
  /// Whether to compress bricks when sending over network.
  @AppStorage("enableCompression") var enableCompression: Bool = AppSettings.bool("enableCompression")
  /// The border mode used for brick edges (e.g., "zeroes" or "clamp").
  @AppStorage("borderMode") var borderMode: String = AppSettings.string("borderMode")

  // MARK: - Rendering and Performance Settings

  /// The allowable screen-space error for LOD selection.
  @AppStorage("screenSpaceError") var screenSpaceError: Double = AppSettings.double("screenSpaceError")
  /// Initial number of bricks to load.
  @AppStorage("initialBricks") var initialBricks: Int = AppSettings.int("initialBricks")
  /// Minimum size (in MB) of the the bricks represented be the internal hash table.
  @AppStorage("minHashTableSize") var minHashTableSize: Int = AppSettings.int("minHashTableSize")
  ///  Maximum linear probing attempts in the hash table before giving up
  @AppStorage("maxProbingAttempts") var maxProbingAttempts: Int = AppSettings.int("maxProbingAttempts")
  /// Size of the texture atlas in megabytes.
  @AppStorage("atlasSizeMB") var atlasSizeMB: Int = AppSettings.int("atlasSizeMB")
  /// The oversampling factor for rendering.
  @AppStorage("oversampling") var oversampling: Double = AppSettings.double("oversampling")
  /// The oversampling mode ("static" or "dynamic").
  @AppStorage("oversamplingMode") var oversamplingMode: String = AppSettings.string("oversamplingMode")
  /// Target frames per second below which the step size is increase.
  @AppStorage("dropFPS") var dropFPS: Int = AppSettings.int("dropFPS")
  /// FPS at which recovery occurs after step size increment.
  @AppStorage("recoveryFPS") var recoveryFPS: Int = AppSettings.int("recoveryFPS")
  /// Whether to automatically load the transfer function.
  @AppStorage("autoloadTF") var autoloadTF: Bool = AppSettings.bool("autoloadTF")
  /// Whether to automatically load the object transfomration.
  @AppStorage("autoloadTransform") var autoloadTransform: Bool = AppSettings.bool("autoloadTransform")
  /// Whether to disable the build-in foveation feature
  @AppStorage("disableFoveation") var disableFoveation: Bool = AppSettings.bool("disableFoveation")
  /// Whether to request a low resolution LOD along with the high res
  @AppStorage("requestLowResLOD") var requestLowResLOD: Bool = AppSettings.bool("requestLowResLOD")
  /// Whether the raycaster should terminate if a brick is missing
  @AppStorage("stopOnMiss") var stopOnMiss: Bool = AppSettings.bool("stopOnMiss")
  /// Whether the Profiling Button should be displayed
  @AppStorage("showProfiling") var showProfiling: Bool = AppSettings.bool("showProfiling")

  

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
    return AppSettings.values[key] as? Int ?? 0
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
    return AppSettings.values[key] as? Double ?? 0.0
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
    return Float(AppSettings.values[key] as? Double ?? 0.0)
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
    return AppSettings.values[key] as? String ?? ""
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
    return AppSettings.values[key] as? Bool ?? false
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
