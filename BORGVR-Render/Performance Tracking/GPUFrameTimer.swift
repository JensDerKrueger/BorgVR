import Foundation
import Metal

/**
 A GPU-based frame timer that tracks frame rates and monitors performance
 using Metal command buffers.

 GPUFrameTimer conforms to FrameTimerProtocol and calculates various FPS
 metrics (last, average, smoothed, min, and max FPS) based on GPU command buffer
 timings. It updates its statistics when a command buffer completes, and it
 triggers performance state transitions and recovery callbacks as needed.
 */
public class GPUFrameTimer: FrameTimerProtocol {
  /// The FPS measured for the last completed frame.
  public private(set) var lastFPS: Double = 0
  /// The average FPS computed over the recorded frame history.
  public private(set) var averageFPS: Double = 0
  /// The exponentially smoothed FPS value.
  public private(set) var smoothedFPS: Double = 0
  /// The minimum FPS recorded.
  public private(set) var minFPS: Double = Double.greatestFiniteMagnitude
  /// The maximum FPS recorded.
  public private(set) var maxFPS: Double = 0

  /// A ring buffer storing recent frame timestamps.
  private var frameTimestamps = RingBuffer<CFTimeInterval>()
  /// The maximum duration (in seconds) for which frame history is retained.
  private let maxHistoryDuration: CFTimeInterval = 5
  /// The smoothing factor used for exponential moving average calculation.
  private let smoothingFactor: Double = 0.1
  /// Indicates whether the exponential moving average has been initialized.
  private var emaInitialized = false

  /// An optional logger used to output FPS metrics.
  private let logger: LoggerBase?

  /// Callback triggered when the performance state changes.
  public var onStateChanged: ((PerformanceState) -> Void)?

  // Performance thresholds.
  public var dropThreshold: Double = 30.0
  public var recoveryThreshold: Double = 35.0
  public var minimumDropDuration: TimeInterval = 2.0

  /// Callback invoked when performance is too slow.
  public var onPerformanceTooSlow: ((Double, Double) -> Void)?
  /// Callback invoked during performance recovery. Returns true if a recovery step
  /// was executed.
  public var onPerformanceRecovered: ((Double, Double) -> Bool)?

  /// The current performance state.
  private var state: PerformanceState = .normal

  /**
   Initializes a new GPUFrameTimer.

   - Parameter logger: An optional LoggerBase instance for logging performance data.
   */
  public init(logger: LoggerBase? = nil) {
    self.logger = logger
  }

  /**
   Registers a completion handler on the provided Metal command buffer to update
   FPS metrics when the command buffer completes.

   - Parameter commandBuffer: The MTLCommandBuffer whose GPU execution time is used
   to calculate FPS.
   */
  public func frameCompleted(with commandBuffer: MTLCommandBuffer) {
    commandBuffer.addCompletedHandler { [weak self] commandBuffer in
      guard let self = self else { return }

      // Clamp the duration to a maximum of 1 second.
      let duration = min(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, 1.0)
      guard duration > 0 else { return }

      let fps = 1.0 / duration
      let timestamp = commandBuffer.gpuEndTime

      self.updateStats(now: timestamp, fps: fps)
    }
  }

  /**
   Updates FPS statistics and handles performance state transitions.

   - Parameters:
   - now: The current GPU timestamp.
   - fps: The calculated frames per second from the command buffer.
   */
  private func updateStats(now: CFTimeInterval, fps: Double) {
    lastFPS = fps

    if emaInitialized {
      smoothedFPS = (smoothingFactor * fps) + ((1 - smoothingFactor) * smoothedFPS)
    } else {
      smoothedFPS = fps
      emaInitialized = true
    }

    minFPS = min(minFPS, fps)
    maxFPS = max(maxFPS, fps)

    frameTimestamps.append(now)
    purgeOldFrames(currentTime: now)

    if frameTimestamps.count > 1 {
      let duration = frameTimestamps.last! - frameTimestamps.first!
      averageFPS = Double(frameTimestamps.count - 1) / duration
    }

    logger?.dev("GPU FPS: \(String(format: "%.1f", fps))")
    handleStateTransition(now: now, fps: fps)
  }

  /**
   Handles transitions between performance states based on the current FPS.

   - Parameters:
   - now: The current timestamp.
   - fps: The current frames per second.
   */
  private func handleStateTransition(now: CFTimeInterval, fps: Double) {
    switch state {
      case .normal:
        if fps < dropThreshold {
          updateState(to: .tooSlow(startTime: now))
          logger?.warning("Entered low-performance state at \(fps) FPS.")
          let percentBelow = max(0, (dropThreshold - fps) / dropThreshold)
          onPerformanceTooSlow?(fps, percentBelow)
        }
      case .tooSlow(let startTime):
        if fps >= recoveryThreshold, (now - startTime) >= minimumDropDuration {
          updateState(to: .recovering)
          logger?.dev("Performance recovering from low state at \(fps) FPS.")
          attemptRecovery(fps: fps)
        } else if fps < dropThreshold {
          let percentBelow = max(0, (dropThreshold - fps) / dropThreshold)
          onPerformanceTooSlow?(fps, percentBelow)
        }
      case .recovering:
        if fps < dropThreshold {
          updateState(to: .tooSlow(startTime: now))
          logger?.warning("Recovery interrupted, back to low-performance state.")
          let percentBelow = max(0, (dropThreshold - fps) / dropThreshold)
          onPerformanceTooSlow?(fps, percentBelow)
        } else if fps >= recoveryThreshold {
          attemptRecovery(fps: fps)
        }
    }
  }

  /**
   Attempts a recovery step if performance has improved.

   - Parameter fps: The current frames per second.
   */
  private func attemptRecovery(fps: Double) {
    let percentAbove = max(0, (fps - recoveryThreshold) / recoveryThreshold)
    if let recovered = onPerformanceRecovered?(fps, percentAbove), recovered {
      logger?.dev("Recovery step executed.")
    } else {
      logger?.dev("All recovery steps complete. Returning to normal state.")
      updateState(to: .normal)
    }
  }

  /**
   Removes old frame timestamps that are outside the maximum history duration.

   - Parameter currentTime: The current timestamp.
   */
  private func purgeOldFrames(currentTime: CFTimeInterval) {
    let cutoff = currentTime - maxHistoryDuration
    while let first = frameTimestamps.first, first < cutoff {
      frameTimestamps.removeFirst()
    }
  }

  /**
   Resets all FPS metrics and frame history.

   This method clears the frame history, resets all statistics, and sets the performance state
   back to normal.
   */
  public func reset() {
    frameTimestamps.removeAll()
    lastFPS = 0
    smoothedFPS = 0
    averageFPS = 0
    minFPS = Double.greatestFiniteMagnitude
    maxFPS = 0
    emaInitialized = false
    state = .normal

    logger?.dev("GPU FPS stats reset.")
  }

  /**
   Updates the performance state and notifies observers of the change.

   - Parameter newState: The new performance state.
   */
  private func updateState(to newState: PerformanceState) {
    guard state != newState else { return }
    state = newState
    onStateChanged?(newState)
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
