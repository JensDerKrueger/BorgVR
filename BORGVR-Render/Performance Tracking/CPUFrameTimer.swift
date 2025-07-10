import Foundation
import QuartzCore

/**
 A CPU-based frame timer that tracks frame rates and handles performance state changes.

 CPUFrameTimer conforms to FrameTimerProtocol and calculates various FPS metrics
 (last, average, smoothed, minimum, and maximum FPS) using frame timestamps. It
 also monitors performance and triggers callbacks when the FPS falls below or
 recovers above specified thresholds.
 */
public class CPUFrameTimer: FrameTimerProtocol {
  /// The FPS measured for the last rendered frame.
  public private(set) var lastFPS: Double = 0
  /// The average FPS over the frame history.
  public private(set) var averageFPS: Double = 0
  /// The exponentially smoothed FPS value.
  public private(set) var smoothedFPS: Double = 0
  /// The minimum recorded FPS.
  public private(set) var minFPS: Double = Double.greatestFiniteMagnitude
  /// The maximum recorded FPS.
  public private(set) var maxFPS: Double = 0

  /// The timestamp of the last rendered frame.
  private var lastTimestamp: CFTimeInterval = 0
  /// A ring buffer storing recent frame timestamps.
  private var frameTimestamps = RingBuffer<CFTimeInterval>()
  /// The maximum duration (in seconds) to keep frame history.
  private let maxHistoryDuration: CFTimeInterval = 5
  /// The smoothing factor used for the exponential moving average.
  private let smoothingFactor: Double = 0.1
  /// Flag indicating whether the exponential moving average has been initialized.
  private var emaInitialized = false

  /// An optional logger for FPS logging.
  private let logger: LoggerBase?
  /// Callback triggered when the performance state changes.
  public var onStateChanged: ((PerformanceState) -> Void)?

  // Thresholds for performance monitoring.
  public var dropThreshold: Double = 30.0
  public var recoveryThreshold: Double = 35.0
  public var minimumDropDuration: TimeInterval = 2.0

  // Callbacks for performance events.
  public var onPerformanceTooSlow: ((Double, Double) -> Void)?
  public var onPerformanceRecovered: ((Double, Double) -> Bool)?

  /// The current performance state.
  private var state: PerformanceState = .normal

  /**
   Initializes a new CPUFrameTimer.

   - Parameter logger: An optional logger for logging performance data.
   */
  public init(logger: LoggerBase? = nil) {
    self.logger = logger
  }

  /**
   Updates the frame timer with a newly rendered frame.

   This method should be called each time a frame is rendered. It calculates the time
   elapsed since the last frame, updates FPS statistics, and triggers state transitions
   if necessary.
   */
  public func frameRendered() {
    let now = CACurrentMediaTime()

    guard lastTimestamp > 0 else {
      lastTimestamp = now
      return
    }

    // Clamp delta to a maximum of 1.0 sec to avoid extreme FPS values.
    let delta = min(now - lastTimestamp, 1.0)
    lastTimestamp = now

    guard delta > 0 else { return }

    let fps = 1.0 / delta
    updateStats(now: now, fps: fps)
  }

  /**
   Updates FPS statistics based on the current frame.

   - Parameters:
   - now: The current timestamp.
   - fps: The frames per second calculated from the current frame.
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

    logger?.dev("CPU FPS: \(String(format: "%.1f", fps))")
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
   Attempts to execute a recovery step if performance has improved.

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
   Removes frame timestamps that are older than the maximum history duration.

   - Parameter currentTime: The current timestamp.
   */
  private func purgeOldFrames(currentTime: CFTimeInterval) {
    let cutoff = currentTime - maxHistoryDuration
    frameTimestamps.removeOld(olderThan: cutoff, isOlder: <)
  }

  /**
   Resets the frame timer statistics and state.

   This method clears all FPS metrics and frame history, and resets the performance state to normal.
   */
  public func reset() {
    lastTimestamp = 0
    frameTimestamps.removeAll()
    lastFPS = 0
    smoothedFPS = 0
    averageFPS = 0
    minFPS = Double.greatestFiniteMagnitude
    maxFPS = 0
    emaInitialized = false
    state = .normal

    logger?.dev("CPU FPS stats reset.")
  }

  /**
   Updates the performance state and notifies any observers.

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

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software
 and associated documentation files (the "Software"), to deal in the Software without restriction,
 including without limitation the rights to use, copy, modify, merge, publish, distribute,
 sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or
 substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
 BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
 DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
