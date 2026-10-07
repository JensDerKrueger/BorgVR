import SwiftUI

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

  /// The dedicated task that owns the compositor render loop.
  var renderTask: Task<Void, Never>?

  /**
   Requests an orderly render-loop shutdown and returns the task so callers can
   wait until the final in-flight frame has completed.
   */
  func cancelRenderLoop() -> Task<Void, Never>? {
    let task = renderTask
    renderTask = nil
    task?.cancel()
    return task
  }

  /// Transitions through the normal close path after an unrecoverable GPU failure.
  func renderLoopFailed() {
    guard renderTask != nil else { return }
    renderTask = nil
    requestDatasetClose(
      destination: groupSessionHost
        ? .datasetSelection
        : .sharePlayWaiting(.datasetSource)
    )
  }

  /// Optional timer for CPU frame tracking.
  var timer: CPUFrameTimer? = nil

  /// Model for performance graphing.
  var performanceModel: PerformanceGraphModel = PerformanceGraphModel()

  var groupSessionHost : Bool = false
  var sharePlayDatasetSource: DatasetOrigin?
  var showsHostDeparturePrompt = false
  var protocolCompatibilityIssue: BorgVRSharePlayCompatibilityIssue?

  enum NavigationState {
    case start
    case settings
    case importData
    case selectData
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
   - transferEditing: Edit the transfer function panel.
   - drawing: Draw freehand annotations.
   - objectPlacement: Place and edit opaque scene objects.
   - measurement: Place and edit physical measurement points.
   - screenView: Position the shared iOS and macOS camera.
   */
  enum InteractionMode: String {
    case model = "model"
    case clipping = "clipping"
    case transferEditing = "transferEditing"
    case drawing = "drawing"
    case objectPlacement = "objectPlacement"
    case measurement = "measurement"
    case screenView = "screenView"
  }
  /// The current interaction mode.
  var interactionMode: InteractionMode = .model {
    didSet { spatialInputContext.update(mode: interactionMode) }
  }

  /// Lock-protected bridge read by the compositor render thread.
  let spatialInputContext = SpatialInputRuntimeContext()

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

    var channelMask: UInt32 {
      var mask: UInt32 = 0
      if red {
        mask |= 1 << 0
      }
      if green {
        mask |= 1 << 1
      }
      if blue {
        mask |= 1 << 2
      }
      if opacity {
        mask |= 1 << 3
      }
      return mask
    }
  }
  /// Toggles for editing transfer function channels.
  var transferEditState: TransferEditState = .init() {
    didSet {
      transferFunctionPanelInteractionState?.updateChannelMask(transferEditState.channelMask)
    }
  }

  /// Shared renderer-side interaction state for the immersive transfer function panel.
  var transferFunctionPanelInteractionState: TransferFunctionPanelInteractionState?

  var openViews: [String: Int] = [:]

  struct AuxiliaryWindowToggleRequest: Equatable {
    let id = UUID()
    let windowID: String
    let mutuallyExclusiveWindowID: String?
  }

  var auxiliaryWindowToggleRequest: AuxiliaryWindowToggleRequest?

  func requestAuxiliaryWindowToggle(
    _ windowID: String,
    mutuallyExclusiveWith mutuallyExclusiveWindowID: String? = nil
  ) {
    auxiliaryWindowToggleRequest = AuxiliaryWindowToggleRequest(
      windowID: windowID,
      mutuallyExclusiveWindowID: mutuallyExclusiveWindowID
    )
  }

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
    case remote(address: String, port: Int, password: String)
    case builtIn

    static func == (lhs: DatasetSource, rhs: DatasetSource) -> Bool {
      switch (lhs, rhs) {
        case (.local, .local),
          (.builtIn, .builtIn):
          return true
        case let (.remote(addr1, port1, password1), .remote(addr2, port2, password2)):
          return addr1 == addr2 && port1 == port2 && password1 == password2
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

  enum DatasetCloseDestination: Equatable {
    case datasetSelection
    case sharePlayWaiting(SharePlayWaitingReason)
  }

  enum DatasetSessionState: Equatable {
    case inactive
    case waitingForSharePlay(SharePlayWaitingReason)
    case resolving(uniqueID: String, description: String)
    case opening(dataset: DatasetEntry, requestID: UUID)
    case rendering(dataset: DatasetEntry, requestID: UUID)
    case closing(dataset: DatasetEntry?, requestID: UUID, destination: DatasetCloseDestination)

    var logDescription: String {
      switch self {
        case .inactive:
          return "inactive"
        case .waitingForSharePlay(let reason):
          return "waiting(\(reason))"
        case .resolving(let uniqueID, _):
          return "resolving(\(uniqueID))"
        case .opening(let dataset, _):
          return "opening(\(dataset.uniqueId))"
        case .rendering(let dataset, _):
          return "rendering(\(dataset.uniqueId))"
        case .closing(let dataset, _, let destination):
          return "closing(\(dataset?.uniqueId ?? "none"), \(destination))"
      }
    }
  }

  private(set) var datasetSessionState = DatasetSessionState.inactive {
    didSet {
      guard oldValue != datasetSessionState else { return }
      logger.dev(
        "Dataset session: \(oldValue.logDescription) -> \(datasetSessionState.logDescription)"
      )
    }
  }

  var activeDataset: DatasetEntry? {
    switch datasetSessionState {
      case .opening(let dataset, _), .rendering(let dataset, _), .closing(let dataset?, _, _):
        return dataset
      case .inactive, .waitingForSharePlay, .resolving, .closing(nil, _, _):
        return nil
    }
  }

  var sharePlayWaitingReason: SharePlayWaitingReason? {
    switch datasetSessionState {
      case .waitingForSharePlay(let reason):
        return reason
      case .resolving:
        return .datasetSource
      case .closing(_, _, .sharePlayWaiting(let reason)):
        return reason
      default:
        return nil
    }
  }

  struct DatasetInfo {
    let description: String
    let width: Int
    let height: Int
    let depth: Int
    let voxelSpacingX: Float
    let voxelSpacingY: Float
    let voxelSpacingZ: Float
    let componentCount: Int
    let bytesPerComponent: Int
    let volumeScale: SIMD3<Float>

    init(meta: BORGVRMetaData) {
      self.description = meta.datasetDescription
      self.width = meta.width
      self.height = meta.height
      self.depth = meta.depth
      self.voxelSpacingX = meta.voxelSpacingX
      self.voxelSpacingY = meta.voxelSpacingY
      self.voxelSpacingZ = meta.voxelSpacingZ
      self.componentCount = meta.componentCount
      self.bytesPerComponent = meta.bytesPerComponent
      self.volumeScale = VolumeRenderResources.normalizedVolumeExtent(for: meta)
    }
  }

  var activeDatasetInfo: DatasetInfo? = nil {
    didSet { spatialInputContext.update(datasetInfo: activeDatasetInfo) }
  }

  /// Navigation outside the dataset lifecycle.
  var navigationState: NavigationState = .start
  /// The current window size of the application.
  var windowSize: CGSize = CGSize(width: 1000, height: 520)

  @discardableResult
  func markImmersiveSpaceOpened(requestID: UUID? = nil) -> Bool {
    immersiveSpaceState = .open
    guard let requestID else { return true }
    switch datasetSessionState {
      case .opening(_, let currentRequestID), .rendering(_, let currentRequestID):
        return currentRequestID == requestID
      default:
        return false
    }
  }

  func isOpeningOrDisplayingDataset(withUniqueID uniqueID: String) -> Bool {
    switch datasetSessionState {
      case .opening(let dataset, _), .rendering(let dataset, _):
        return dataset.uniqueId == uniqueID
      case .closing(let dataset?, _, _):
        return dataset.uniqueId == uniqueID
      default:
        return false
    }
  }

  func startImmersiveSpace(dataset: DatasetEntry,
                           asGroupSessionHost:Bool) {    
    guard !isOpeningOrDisplayingDataset(withUniqueID: dataset.uniqueId) else {
      return
    }
    groupSessionHost = asGroupSessionHost
    sharePlayDatasetSource = nil
    datasetSessionState = .opening(dataset: dataset, requestID: UUID())
  }

  func waitForSharePlayDataset(reason: SharePlayWaitingReason) {
    guard activeDataset == nil else { return }
    sharePlayDatasetSource = nil
    datasetSessionState = .waitingForSharePlay(reason)
  }

  func beginResolvingSharePlayDataset(uniqueID: String, description: String) {
    if case .resolving(let currentID, _) = datasetSessionState,
       currentID == uniqueID {
      return
    }
    datasetSessionState = .resolving(uniqueID: uniqueID, description: description)
  }

  func markDatasetRendererReady(uniqueID: String) {
    guard case .opening(let dataset, let requestID) = datasetSessionState,
          dataset.uniqueId == uniqueID else { return }
    datasetSessionState = .rendering(dataset: dataset, requestID: requestID)
  }

  func requestDatasetClose(destination: DatasetCloseDestination = .datasetSelection) {
    if case .closing = datasetSessionState { return }
    guard activeDataset != nil || immersiveSpaceState != .closed || renderTask != nil else {
      completeDatasetClose(destination: destination)
      return
    }
    datasetSessionState = .closing(
      dataset: activeDataset,
      requestID: UUID(),
      destination: destination
    )
  }

  func completeDatasetClose(requestID: UUID? = nil,
                            destination: DatasetCloseDestination) {
    if let requestID,
       case .closing(_, let currentRequestID, _) = datasetSessionState,
       currentRequestID != requestID {
      return
    }
    activeDatasetInfo = nil
    sharePlayDatasetSource = nil
    switch destination {
      case .datasetSelection:
        datasetSessionState = .inactive
        navigationState = .selectData
      case .sharePlayWaiting(let reason):
        datasetSessionState = .waitingForSharePlay(reason)
    }
  }

  func immersiveSpaceWasClosedBySystem() {
    let wasManagedTransition = immersiveSpaceState == .inTransition
    immersiveSpaceState = .closed
    guard !wasManagedTransition else { return }
    switch datasetSessionState {
      case .opening, .rendering:
        requestDatasetClose(destination: .datasetSelection)
      default:
        break
    }
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

}

extension RuntimeAppModel.DatasetInfo {
  var physicalExtentMeters: SIMD3<Float> {
    SIMD3<Float>(
      Float(width) * voxelSpacingX,
      Float(height) * voxelSpacingY,
      Float(depth) * voxelSpacingZ
    )
  }
}

final class SpatialInputRuntimeContext: @unchecked Sendable {
  struct Snapshot {
    let mode: RuntimeAppModel.InteractionMode
    let datasetInfo: RuntimeAppModel.DatasetInfo?
  }

  private let lock = NSLock()
  private var mode: RuntimeAppModel.InteractionMode = .model
  private var datasetInfo: RuntimeAppModel.DatasetInfo?

  func update(mode: RuntimeAppModel.InteractionMode) {
    lock.lock()
    self.mode = mode
    lock.unlock()
  }

  func update(datasetInfo: RuntimeAppModel.DatasetInfo?) {
    lock.lock()
    self.datasetInfo = datasetInfo
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(mode: mode, datasetInfo: datasetInfo)
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
