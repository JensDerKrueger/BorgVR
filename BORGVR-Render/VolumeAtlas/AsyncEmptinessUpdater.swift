import Foundation

/**
 A simple semaphore based on CheckedContinuation that supports asynchronous waiting.
 */
final class SyncSemaphore {
  /// The stored continuation to resume waiting tasks.
  private var continuation: CheckedContinuation<Void, Never>? = nil
  /// An NSLock to protect access to the continuation.
  private let lock = NSLock()

  /**
   Signals the semaphore, resuming any waiting task.
   */
  func signal() {
    lock.withLock({
      continuation?.resume()
      continuation = nil
    })
  }

  /**
   Asynchronously waits until the semaphore is signalled.
   */
  func wait() async {
    await withCheckedContinuation { continuation in
      lock.withLock({
        self.continuation = continuation
      })
    }
  }
}

/**
 An asynchronous updater that monitors and updates the "emptiness" status of bricks
 in a volumetric dataset. It periodically computes whether each brick is empty based on
 a transfer function or an isovalue, and updates associated metadata.
 */
class AsyncEmptinessUpdater {
  // MARK: - Asynchronous Emptiness Variables

  /// The background task performing emptiness updates.
  private var backgroundTask: Task<Void, Never>?
  /// A semaphore used to pause and resume background processing.
  private let waitSemaphore = SyncSemaphore()
  /// Lock for controlling access to the stop flag.
  private let stopLock = NSLock()
  /// Indicates if the updater should stop.
  private var shouldStop: Bool = false
  /// Lock for controlling access to metadata storage.
  private let storageLock = NSLock()
  /// Lock for coordinating restart requests.
  private let restartLock = NSLock()
  /// Indicates if the updater should restart its processing loop.
  private var shouldRestart: Bool = false
  /// Lock for tracking changes in emptiness.
  private let hasChangedLock = NSLock()
  /// Flag indicating whether the emptiness data has changed.
  private var hasChanged: Bool = false
  /// Lock for synchronizing transfer function updates.
  private let transferFunctionLock = NSLock()
  /// The transfer function used to determine brick emptiness.
  private var transferFunction = TransferFunction1D()
  /// The current isovalue used when render mode is isoValue.
  private var isoValue: Int = 0
  /// The BorgVR dataset protocol instance providing volume data.
  private var borgData: BORGVRDatasetProtocol
  /// An array storing metadata flags for each brick.
  private var metaStorage: [UInt32] = []
  /// A mapping from brick indices to page indices.
  private var brickToPage: [Int: Int] = [:]
  /// Metadata for each page.
  private var pageMetadata: [PageMetadata] = []
  /// A table mapping each brick to its child bricks.
  private var childTable: [[Int]] = []
  /// The current render mode.
  private var renderMode: RenderMode = .transferFunction1D
  /// The last computed emptiness state for each brick.
  private var lastEmptiness: [Bool] = []
  /// An optional logger for debug and error messages.
  private let logger: LoggerBase?

  /**
   Initializes a new AsyncEmptinessUpdater.

   - Parameters:
   - borgData: The dataset protocol instance.
   - transferFunction: The initial transfer function.
   - isoValue: The normalized isovalue (as a Float) to be converted to an integer.
   */
  init(borgData: BORGVRDatasetProtocol,
       transferFunction: TransferFunction1D,
       isoValue: Float,
       logger: LoggerBase?) {
    self.borgData = borgData
    self.logger = logger
    self.isoValue = intIsoValue(normIsoValue: isoValue)
    self.transferFunction = TransferFunction1D(copyFrom: transferFunction)
    computeChildTable()

    initialSynchronousUpdate()
    start()
    logger?.dev("AsyncEmptinessUpdater initialized")
  }

  deinit {
    terminateBackgroundTask()
    logger?.dev("AsyncEmptinessUpdater deinitialized")
  }

  /**
   Computes the child table for the dataset.

   This method iterates over the levels (skipping level 0) of the dataset's brick hierarchy
   and builds a table mapping each brick to its children based on a fixed child factor.
   */
  private func computeChildTable() {
    let metadata = borgData.getMetadata()
    let levelMetadata = metadata.levelMetadata
    let totalBricks = metadata.brickMetadata.count

    childTable = Array(repeating: [], count: totalBricks)
    let childFactor = 2

    for level in 1..<levelMetadata.count {
      let prevLevel = levelMetadata[level - 1]
      let currLevel = levelMetadata[level]

      let prevSizeX = prevLevel.totalBricks.x
      let prevSizeY = prevLevel.totalBricks.y
      let prevSizeZ = prevLevel.totalBricks.z
      let prevBricksPerLayer = prevSizeX * prevSizeY
      let prevOffset = prevLevel.prevBricks

      let currSizeX = currLevel.totalBricks.x
      let currSizeY = currLevel.totalBricks.y
      let currSizeZ = currLevel.totalBricks.z
      let currOffset = currLevel.prevBricks

      for z in 0..<currSizeZ {
        let zOffset = z * currSizeX * currSizeY
        for y in 0..<currSizeY {
          let yOffset = y * currSizeX
          for x in 0..<currSizeX {
            let currBrickIndex = currOffset + zOffset + yOffset + x

            var buffer = ContiguousArray<Int>()
            buffer.reserveCapacity(8)

            let maxZ = min((z + 1) * childFactor, prevSizeZ)
            let maxY = min((y + 1) * childFactor, prevSizeY)
            let maxX = min((x + 1) * childFactor, prevSizeX)

            for nz in (z * childFactor)..<maxZ {
              let nzOffset = nz * prevBricksPerLayer
              for ny in (y * childFactor)..<maxY {
                let nyOffset = ny * prevSizeX
                for nx in (x * childFactor)..<maxX {
                  let childBrickIndex = prevOffset + nzOffset + nyOffset + nx
                  buffer.append(childBrickIndex)
                }
              }
            }

            childTable[currBrickIndex] = Array(buffer)
          }
        }
      }
    }
  }


  /**
   Determines whether a brick is empty.

   - Parameters:
   - brickMetadata: The metadata for the brick.
   - useTF: The transfer function to use when evaluating emptiness.
   - Returns: True if the brick is considered empty; otherwise, false.
   */
  func brickIsEmpty(brickMetadata: BrickMetadata, useTF: TransferFunction1D) -> Bool {
    switch renderMode {
      case .transferFunction1D, .transferFunction1DLighting:
        return useTF.isBrickEmpty(brickMetadata: brickMetadata)
      case .isoValue:
        return isoValue > brickMetadata.maxValue
    }
  }

  /**
   Starts the background task that updates brick emptiness.

   The task runs in the background and continuously monitors and updates the emptiness
   state of bricks, handling restart and stop conditions.
   */
  func start() {
    backgroundTask = Task(priority: .userInitiated) { [weak self] in
      guard let self = self else { return }

      // Constants for flag values.
      let BI_EMPTY       = UInt32(BrickIDFlags.BI_EMPTY.rawValue)
      let BI_CHILD_EMPTY = UInt32(BrickIDFlags.BI_CHILD_EMPTY.rawValue)
      let BI_MISSING     = UInt32(BrickIDFlags.BI_MISSING.rawValue)
      let BI_FLAG_COUNT  = UInt32(BrickIDFlags.BI_FLAG_COUNT.rawValue)

      let brickCount = self.borgData.getMetadata().brickMetadata.count

      // We'll use these to detect changes in the emptiness state.
      var emptinessTF: TransferFunction1D!
      lastEmptiness = []

      while true {
        // Wait until signalled to restart, unless already scheduled.
        if !self.shouldRestart {
          await self.waitSemaphore.wait()
        }

        // If a stop has been signalled, exit.
        let shouldExit = self.stopLock.withLock { return self.shouldStop }
        if shouldExit { return }

        // Reset the restart flag.
        self.restartLock.withLock { self.shouldRestart = false }

        // If in transfer function render mode, make a local copy.
        if renderMode == .transferFunction1D {
          self.transferFunctionLock.withLock {
            emptinessTF = TransferFunction1D(copyFrom: self.transferFunction)
          }
        }

        // Compute current emptiness per brick.
        var currentEmptiness = Array(repeating: false, count: brickCount)
        for index in 0..<brickCount {
          if self.shouldRestart { break }
          let brickMetadata = self.borgData.getMetadata().brickMetadata[index]
          currentEmptiness[index] = self.brickIsEmpty(brickMetadata: brickMetadata,
                                                      useTF: emptinessTF)
        }
        if self.shouldRestart { continue }

        // Only update metaStorage if emptiness has changed.
        if lastEmptiness != currentEmptiness {
          var currentEmptinessHasChanged = false

          self.storageLock.withLock {
            for index in 0..<currentEmptiness.count {
              if self.shouldRestart { break }

              if currentEmptiness[index] {
                // If a brick that was paged in is now empty.
                if self.metaStorage[index] >= BI_FLAG_COUNT,
                   let foundIndex = self.brickToPage[index] {
                  self.pageMetadata[foundIndex].flagEmpty()
                }
                // Update metaStorage based on whether the brick is child-empty.
                if self.isChildEmpty(index) {
                  if self.metaStorage[index] != BI_CHILD_EMPTY {
                    self.metaStorage[index] = BI_CHILD_EMPTY
                    currentEmptinessHasChanged = true
                  }
                } else {
                  if self.metaStorage[index] != BI_EMPTY {
                    self.metaStorage[index] = BI_EMPTY
                    currentEmptinessHasChanged = true
                  }
                }
              } else {
                // If a brick was empty but is now visible.
                if self.metaStorage[index] == BI_EMPTY || self.metaStorage[index] == BI_CHILD_EMPTY {
                  if let foundIndex = self.brickToPage[index],
                     self.pageMetadata[foundIndex].reactivate(ifItContains: index) {
                    self.metaStorage[index] = UInt32(self.pageMetadata[foundIndex].pageID) + BI_FLAG_COUNT
                  } else {
                    self.metaStorage[index] = BI_MISSING
                  }
                  currentEmptinessHasChanged = true
                }
              }
            }
          }

          if self.shouldRestart { continue }

          self.hasChangedLock.withLock {
            self.lastEmptiness = currentEmptiness
            self.hasChanged = currentEmptinessHasChanged
          }
        }
      }
    }
  }

  /**
   Performs an initial synchronous update of emptiness metadata.

   This method initializes metaStorage for all bricks based on their initial emptiness state.
   */
  private func initialSynchronousUpdate() {
    let BI_EMPTY: UInt32       = UInt32(BrickIDFlags.BI_EMPTY.rawValue)
    let BI_CHILD_EMPTY: UInt32 = UInt32(BrickIDFlags.BI_CHILD_EMPTY.rawValue)
    let BI_MISSING: UInt32     = UInt32(BrickIDFlags.BI_MISSING.rawValue)

    // Cache the metadata to avoid repeated lookups.
    let metadata = borgData.getMetadata()
    let brickCount = metadata.brickMetadata.count

    // Initialize metaStorage to BI_MISSING for all bricks.
    metaStorage = Array(repeating: BI_MISSING, count: brickCount)

    // Compute the emptiness for each brick.
    let emptiness = (0..<brickCount).map { index in
      brickIsEmpty(brickMetadata: metadata.brickMetadata[index],
                   useTF: transferFunction)
    }

    // Update metaStorage based on computed emptiness.
    for (index, isEmpty) in emptiness.enumerated() {
      metaStorage[index] = isEmpty ? (self.isChildEmpty(index) ? BI_CHILD_EMPTY : BI_EMPTY)
      : BI_MISSING
    }

    hasChanged = true
  }

  /**
   Retrieves the child brick indices for a given brick.

   - Parameter index: The brick index.
   - Returns: An array of child brick indices.
   */
  private func getChildren(_ index: Int) -> [Int] {
    return childTable[index]
  }

  /**
   Determines whether the children of a brick are empty.

   - Parameter index: The index of the brick.
   - Returns: True if all child bricks are empty; otherwise, false.
   */
  private func isChildEmpty(_ index: Int) -> Bool {
    let childrenIndices = getChildren(index)
    return childrenIndices.allSatisfy {
      metaStorage[$0] == UInt32(BrickIDFlags.BI_CHILD_EMPTY.rawValue)
    }
  }

  /**
   Terminates the background task by signalling a stop.
   */
  func terminateBackgroundTask() {
    stopLock.withLock { shouldStop = true }
    waitSemaphore.signal()
  }

  /**
   Updates the transfer function and signals the background task to restart.

   - Parameter transferFunction: The new transfer function.
   */
  func updateTransferFunction(transferFunction: TransferFunction1D) {
    transferFunctionLock.withLock {
      if self.renderMode != .transferFunction1D ||
          transferFunction.emptinessSignificantChange(self.transferFunction) {
        self.renderMode = .transferFunction1D
        self.transferFunction = TransferFunction1D(copyFrom: transferFunction)
        restartLock.withLock {
          self.shouldRestart = true
        }
        waitSemaphore.signal()
      }
    }
  }

  /**
   Converts a normalized isovalue to an integer isovalue based on the dataset's bytes per component.

   - Parameter normIsoValue: The normalized isovalue.
   - Returns: The corresponding integer isovalue.
   */
  private func intIsoValue(normIsoValue: Float) -> Int {
    return Int(normIsoValue * Float(1 << (8 * borgData.getMetadata().bytesPerComponent) - 1))
  }

  /**
   Updates the isovalue and signals the background task to restart if needed.

   - Parameter isoValue: The new normalized isovalue.
   */
  func updateIsoValue(isoValue: Float) {
    let intIsoValue = intIsoValue(normIsoValue: isoValue)
    guard self.renderMode != .isoValue || self.isoValue != intIsoValue else { return }

    self.isoValue = intIsoValue
    self.renderMode = .isoValue
    restartLock.withLock {
      self.shouldRestart = true
    }
    waitSemaphore.signal()
  }

  /**
   Updates the metadata storage, brick-to-page mapping, and page metadata, then signals a restart.

   - Parameters:
   - metaStorage: The new metadata storage array.
   - brickToPage: A mapping from brick indices to page indices.
   - pageMetadata: An array of page metadata.
   */
  func updateMetadata(metaStorage: [UInt32],
                      brickToPage: [Int: Int],
                      pageMetadata: [PageMetadata]) {
    storageLock.withLock {
      self.metaStorage = metaStorage
      self.pageMetadata = pageMetadata
      self.brickToPage = brickToPage
      lastEmptiness = []
      restartLock.withLock {
        self.shouldRestart = true
      }
      waitSemaphore.signal()
    }
  }

  /**
   Returns the current metadata if any changes have been detected.

   - Returns: An optional array of UInt32 representing the metadata; nil if no change.
   */
  func inCoreDataHasChanged() -> [UInt32]? {
    return hasChangedLock.withLock {
      guard hasChanged else { return nil }
      return storageLock.withLock {
        hasChanged = false
        return metaStorage
      }
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
 FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE.
 */
