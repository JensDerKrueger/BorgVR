import SwiftUI

// MARK: - RenderMode

/**
 Enumeration of rendering modes for volume visualization.

 - transferFunction1D: Use a 1D transfer function for color mapping.
 - isoValue: Render using an isovalue threshold.
 */
enum RenderMode: UInt8, CustomStringConvertible {
  /// Use a 1D transfer function.
  case transferFunction1D         = 0
  /// Use a 1D transfer function with illumination.
  case transferFunction1DLighting = 1
  /// Use an isovalue threshold.
  case isoValue                   = 2

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

  // MARK: - Serialization helpers

  /// Serialize this enum case to a single byte.
  func serialize() -> UInt8 {
    return self.rawValue
  }

  /// Deserialize from a byte. Falls back to `.transferFunction1D` if unknown.
  static func deserialize(_ byte: UInt8) -> RenderMode {
    return RenderMode(rawValue: byte) ?? .transferFunction1D
  }
}


// MARK: - RuntimeAppModel

/**
 Holds all ephemeral, in-memory state that the application needs while running.
 This data is never persisted to disk and is not shared across devices or sessions.
 Use this model for temporary runtime values such as transient UI state,
 or scratch data that is valid only for the current execution of the app.
 */
@MainActor
@Observable
class RuntimeAppModel {
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

  enum ImmersiveSpaceIntent {
    case open
    case close
    case keepCurrent
  }

  var immersiveSpaceIntent = ImmersiveSpaceIntent.keepCurrent

  /// Optional timer for CPU frame tracking.
  var timer: CPUFrameTimer? = nil

  /// Model for performance graphing.
  var performanceModel: PerformanceGraphModel = PerformanceGraphModel()

  var groupSessionHost : Bool = false

  /**
   Represents the possible content view states.

   - start: The initial state, showing the main menu.
   - settings: The settings view state.
   - waitingForHost: Displayed when the host is still selecting data
   - importData: The state for importing a dataset.
   - selectData: The state for selecting a dataset.
   - renderData: The state for rendering the dataset.
   */
  enum ContentViewState {
    case start
    case waitingForHost
    case settings
    case importData
    case selectData
    case renderData
  }

  /// A flag indicating if mixed immersion style is enabled.
  var mixedImmersionStyle: Bool = true
  /// The maximum number of buffers in the swap chain
  let maxBuffersInFlight = 1
  /// Indicates whether multisampling should be used if available.
  let useMultisamplingIfAvailable = false

  let logger = GUILogger()

  let notifier = GUINotifier()

  /// Periodically write performance to log
  var logPerformance: Bool = false

  /// rotate the dataset by 360° and record the performance
  var startRotationCapture: Bool = false

  /**
   Modes of user interaction within the application.

   - model: Manipulate the 3D model.
   - clipping: Adjust clipping planes.
   */
  enum InteractionMode: String {
    case model = "model"
    case clipping = "clipping"
  }
  /// The current interaction mode.
  var interactionMode: InteractionMode = .model

  /**
   Represents toggles for editing individual channels of the transfer function.

   - red: Enable editing of the red channel.
   - green: Enable editing of the green channel.
   - blue: Enable editing of the blue channel.
   - opacity: Enable editing of the opacity channel.
   */
  struct TransferEditState {
    var red: Bool = false
    var green: Bool = false
    var blue: Bool = false
    var opacity: Bool = false
  }
  /// Toggles for editing transfer function channels.
  var transferEditState: TransferEditState = .init()

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
   - builtIn: The dataset is part of the application
   */
  enum DatasetSource : Equatable {
    case local
    case remote(address: String, port: Int)
    case builtIn

    static func == (lhs: DatasetSource, rhs: DatasetSource) -> Bool {
      switch (lhs, rhs) {
        case (.local, .local),
          (.builtIn, .builtIn):
          return true
        case let (.remote(addr1, port1), .remote(addr2, port2)):
          return addr1 == addr2 && port1 == port2
        default:
          return false
      }
    }
  }

  struct DatasetEntry: Equatable {
    /// The dataset's path or identifier.
    let identifier: String
    /// The dataset's description
    let description: String
    /// The source of the dataset (local, built-in, or remote).
    let source: RuntimeAppModel.DatasetSource
    /// The dataset's unique identifier.
    let uniqueId: String

    static func == (lhs: DatasetEntry, rhs: DatasetEntry) -> Bool {
      return lhs.uniqueId == rhs.uniqueId
    }
  }

  /// The currently active dataset
  var activeDataset : DatasetEntry? = nil

  struct DatasetInfo {
    let description: String
    let width: Int
    let height: Int
    let depth: Int
    let componentCount: Int
    let bytesPerComponent: Int

    init(meta: BORGVRMetaData) {
      self.description = meta.datasetDescription
      self.width = meta.width
      self.height = meta.height
      self.depth = meta.depth
      self.componentCount = meta.componentCount
      self.bytesPerComponent = meta.bytesPerComponent
    }
  }

  var activeDatasetInfo: DatasetInfo? = nil

  /// The current content view state of the application.
  var currentState: ContentViewState = .start
  /// The current window size of the application.
  var windowSize: CGSize = CGSize(width: 1300, height: 1000)


  func startImmersiveSpace(dataset: DatasetEntry,
                           asGroupSessionHost:Bool) {    
    groupSessionHost = asGroupSessionHost
    activeDataset = dataset
    immersiveSpaceIntent = .open
  }

  func startImmersiveSpace(identifier: String,
                          description: String,
                          source: DatasetSource,
                          uniqueId: String,
                          asGroupSessionHost:Bool) {
    let dataset = DatasetEntry(identifier: identifier,
                               description: description,
                               source: source,
                               uniqueId: uniqueId)

    startImmersiveSpace(dataset:dataset, asGroupSessionHost:asGroupSessionHost)
  }

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
