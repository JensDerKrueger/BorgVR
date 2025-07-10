import SwiftUI
import RealityKit
import ARKit

// MARK: - RenderMode

/**
 Enumeration of rendering modes for volume visualization.

 - transferFunction1D: Use a 1D transfer function for color mapping.
 - isoValue: Render using an isovalue threshold.
 */
enum RenderMode: CustomStringConvertible {
  /// Use a 1D transfer function.
  case transferFunction1D
  /// Use a 1D transfer function with illumination.
  case transferFunction1DLighting
  /// Use an isovalue threshold.
  case isoValue

  /// A human-readable description of the render mode.
  var description: String {
    switch self {
      case .transferFunction1D:
        return "Transfer Function"
      case .transferFunction1DLighting:
        return "Transfer Function with illumination"
      case .isoValue:
        return "Isovalue"
    }
  }
}

// MARK: - AppModel

/**
 Maintains app-wide state for the Vision Pro volumetric rendering application.

 This observable model holds state for the immersive space, content view, interaction mode,
 dataset source, and various rendering settings.
 */
@MainActor
@Observable
class AppModel {
  /// The identifier used for the immersive space.
  let immersiveSpaceID = "ImmersiveSpace"

  /**
   Represents the state of the immersive space.

   - closed: The immersive space is closed.
   - inTransition: The immersive space is in the process of opening or closing.
   - open: The immersive space is open.
   */
  enum ImmersiveSpaceState {
    case closed
    case inTransition
    case open
  }
  /// The current state of the immersive space.
  var immersiveSpaceState = ImmersiveSpaceState.closed

  /// Optional timer for CPU frame tracking.
  var timer: CPUFrameTimer? = nil

  /// Model for performance graphing.
  var performanceModel: PerformanceGraphModel = PerformanceGraphModel()

  /**
   Represents the possible content view states.

   - start: The initial state, showing the main menu.
   - settings: The settings view state.
   - importData: The state for importing a dataset.
   - selectData: The state for selecting a dataset.
   - renderData: The state for rendering the dataset.
   */
  enum ContentViewState {
    case start
    case settings
    case importData
    case selectData
    case renderData
  }

  /// A flag indicating if mixed immersion style is enabled.
  var mixedImmersionStyle: Bool = true
  /// The maximum number of buffers in flight.
  let maxBuffersInFlight = 1
  /// Indicates whether multisampling should be used if available.
  let useMultisamplingIfAvailable = false

  let logger = GUILogger()

  /// Periodically write performance to log
  var logPerformance: Bool = false

  /// roate the dataset by 360° and record the performance
  var startRotationCapture: Bool = false

  /**
   Modes of user interaction within the application.

   - model: Manipulate the 3D model.
   - transferEditing: Edit the transfer function.
   - clipping: Adjust clipping planes.
   */
  enum InteractionMode: String {
    case model = "model"
    case transferEditing = "transferEditing"
    case clipping = "clipping"
  }
  /// The current interaction mode.
  var interactionMode: InteractionMode = .model

  var openViews: [String: Int] = [:]

  func registerView(name: String) {
    openViews[name, default: 0] += 1
  }

  func unregisterView(name: String) {
    if let count = openViews[name], count > 1 {
      openViews[name] = count - 1

    } else {
      openViews.removeValue(forKey: name)
    }
  }

  func isViewOpen(_ name: String) -> Bool {
    openViews[name, default: 0] > 0
  }

  /**
   Represents the source of the dataset.

   - Local: The dataset is stored locally.
   - Remote: The dataset is retrieved from a remote server.
   */
  enum DatasetSource {
    case Local
    case Remote
  }

  typealias DatasetEntry = (String, String, AppModel.DatasetSource)

  /// The currently active dataset path or identifier.
  var activeDataset: String = ""
  /// The source of the dataset (local or remote).
  var datasetSource: DatasetSource = .Local
  /// The current content view state of the application.
  var currentState: ContentViewState = .start
  /// The current window size of the application.
  var windowSize: CGSize = CGSize(width: 1300, height: 1000)

  /**
   Quits the application after a short delay in debug Mode.

   This method schedules an exit call on the main thread with a 0.5 second delay.
   */
  func quitApp() {
#if DEBUG
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      exit(0)
    }
#endif
  }
}

// MARK: - TransferEditing

/**
 Represents toggles for editing individual channels of the transfer function.

 - red: Enable editing of the red channel.
 - green: Enable editing of the green channel.
 - blue: Enable editing of the blue channel.
 - opacity: Enable editing of the opacity channel.
 */
struct TransferEditing {
  var red: Bool = false
  var green: Bool = false
  var blue: Bool = false
  var opacity: Bool = false
}

// MARK: - RenderingParamaters

/**
 Maintains rendering parameters for the volume visualization.

 This observable class holds AR session state, transforms, clipping bounds,
 transfer function, isovalue, render mode, and visibility flags.
 */
@Observable
class RenderingParamaters {
  /// Current device transform.
  var transform: Transform
  /// Last device transform.
  var lastTransform: Transform

  /// Minimum clipping bounds.
  var clipMin: SIMD3<Float>
  /// Maximum clipping bounds.
  var clipMax: SIMD3<Float>

  /// The 1D transfer function for color mapping.
  var transferFunction: TransferFunction1D
  /// Toggles for editing transfer function channels.
  var transferEditing: TransferEditing

  /// Normalized isovalue between 0.0 and 1.0.
  var normIsoValue: Float
  /// Computed isovalue in data units.
  var isoValue: Float {
    return normIsoValue * Float(maxValue) / Float(rangeMax)
  }

  /// The selected rendering mode.
  var renderMode: RenderMode
  /// Flag to show or hide bricks.
  var brickVis: Bool

  /// Minimum data value for mapping.
  var minValue: Int = 0
  /// Maximum data value for mapping.
  var maxValue: Int = 1
  /// Maximum range value for scaling isovalue.
  var rangeMax: Int = 1

  /// A flag indicating that the atas should be emptied
  var purgeAtlas: Bool

  /**
   Default initializer sets up placeholders, then calls `reset` and `updateRanges`
   to apply actual default parameters.
   */
  init() {
    transform = .init()
    lastTransform = .init()
    clipMin = .zero
    clipMax = .zero
    transferFunction = .init()
    transferEditing = .init()
    normIsoValue = 0
    renderMode = .transferFunction1D
    brickVis = false
    purgeAtlas = false

    reset()
    updateRanges(minValue: 0, maxValue: 1, rangeMax: 1)
  }

  /**
   Updates the min/max/range values and applies them to the transfer function.

   - Parameters:
   - minValue: The new minimum data value.
   - maxValue: The new maximum data value.
   - rangeMax: The overall maximum range value.
   */
  func updateRanges(minValue: Int, maxValue: Int, rangeMax: Int) {
    self.minValue = minValue
    self.maxValue = maxValue
    self.rangeMax = rangeMax
    self.transferFunction.updateRanges(
      minValue: minValue,
      maxValue: maxValue,
      rangeMax: rangeMax
    )
  }

  func loadTransform(from url: URL) throws {
    let transform = try Transform.load(from:url)
    self.transform = transform
    self.lastTransform = transform
  }


  /**
   Resets all rendering parameters to default values.

   - Transforms are reset to identity.
   - Clipping bounds set to full volume.
   - Transfer function reset.
   - Isovalue set to 0.1.
   - Render mode set to `.transferFunction1D`.
   - Brick visibility disabled.
   */
  func reset() {
    let defaultTranslation = SIMD3<Float>(-0.5, 1.0, -1.0)
    let defaultScale = SIMD3<Float>(1, 1, 1)
    let defaultRotation: simd_quatf = simd_quatf(.identity)
    let defaultTransform = Transform(
      scale: defaultScale,
      rotation: defaultRotation,
      translation: defaultTranslation
    )

    transform = defaultTransform
    lastTransform = defaultTransform
    clipMin = .init(0, 0, 0)
    clipMax = .init(1, 1, 1)
    transferFunction.reset()
    transferEditing = .init()
    normIsoValue = 0.1
    renderMode = .transferFunction1D
    brickVis = false
  }
}

extension Transform {
  func save(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try encoder.encode(self)
    try data.write(to: url)
  }

  static func load(from url: URL) throws -> Transform {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(Transform.self, from: data)
  }

  mutating func load(from url: URL) throws {
    let loaded = try Transform.load(from: url)
    self = loaded
  }
}



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
