import Foundation
import Metal
import QuartzCore

public enum GPUFrameTimingSource: Equatable {
  case unavailable
  case gpu
  case cpuFallback
}

/**
 Tracks the execution rate of completed Metal frames.

 Valid Metal GPU timestamps are the preferred source. Some environments, most notably
 simulators, can return zero timestamps even for completed command buffers. In that case the
 timer falls back to the interval between command-buffer completions instead of silently
 stopping its statistics.
 */
public final class GPUFrameTimer: FrameTimerProtocol, @unchecked Sendable {
  private struct FrameSample {
    let timestamp: CFTimeInterval
    let duration: CFTimeInterval
  }

  private let lock = NSRecursiveLock()
  private let logger: LoggerBase?

  private var samples = RingBuffer<FrameSample>()
  private var measurementStartTimestamp: CFTimeInterval = 0
  private var lastCompletionTimestamp: CFTimeInterval = 0
  private var lastSampleTimestamp: CFTimeInterval = 0
  private var emaInitialized = false
  private var didReportFallback = false
  private let smoothingFactor = 0.1

  private var storedLastFPS: Double = 0
  private var storedAverageFPS: Double = 0
  private var storedSmoothedFPS: Double = 0
  private var storedMinFPS = Double.greatestFiniteMagnitude
  private var storedMaxFPS: Double = 0
  private var storedRenderedFrameCount: UInt64 = 0
  private var storedTimingSource: GPUFrameTimingSource = .unavailable
  private var storedGPUTimingSampleCount: UInt64 = 0
  private var storedFallbackTimingSampleCount: UInt64 = 0
  private var storedHistoryDuration: CFTimeInterval = 5

  private var storedOnStateChanged: ((PerformanceState) -> Void)?
  private var storedOnPerformanceTooSlow: ((Double, Double) -> Void)?
  private var storedOnPerformanceRecovered: ((Double, Double) -> Bool)?
  private var storedDropThreshold = 30.0
  private var storedRecoveryThreshold = 35.0
  private var storedMinimumDropDuration: TimeInterval = 2.0
  private var state: PerformanceState = .normal

  public init(logger: LoggerBase? = nil) {
    self.logger = logger
  }

  public var lastFPS: Double { withLock { storedLastFPS } }
  public var averageFPS: Double { withLock { storedAverageFPS } }
  public var smoothedFPS: Double { withLock { storedSmoothedFPS } }
  public var minFPS: Double { withLock { storedMinFPS } }
  public var maxFPS: Double { withLock { storedMaxFPS } }
  public var renderedFrameCount: UInt64 { withLock { storedRenderedFrameCount } }
  public var timingSource: GPUFrameTimingSource { withLock { storedTimingSource } }
  public var gpuTimingSampleCount: UInt64 { withLock { storedGPUTimingSampleCount } }
  public var fallbackTimingSampleCount: UInt64 { withLock { storedFallbackTimingSampleCount } }

  public var historyDuration: CFTimeInterval {
    get { withLock { storedHistoryDuration } }
    set {
      withLock {
        storedHistoryDuration = max(0.1, newValue)
        purgeOldSamples(currentTime: lastSampleTimestamp)
        updateAverageFPS()
      }
    }
  }

  public var measurementDuration: CFTimeInterval {
    withLock {
      guard measurementStartTimestamp > 0 else { return 0 }
      return max(0, CACurrentMediaTime() - measurementStartTimestamp)
    }
  }

  public var hasCompleteMeasurementWindow: Bool {
    withLock {
      guard storedRenderedFrameCount > 0, measurementStartTimestamp > 0 else { return false }
      return CACurrentMediaTime() - measurementStartTimestamp >= storedHistoryDuration
    }
  }

  public var onStateChanged: ((PerformanceState) -> Void)? {
    get { withLock { storedOnStateChanged } }
    set { withLock { storedOnStateChanged = newValue } }
  }

  public var dropThreshold: Double {
    get { withLock { storedDropThreshold } }
    set { withLock { storedDropThreshold = newValue } }
  }

  public var recoveryThreshold: Double {
    get { withLock { storedRecoveryThreshold } }
    set { withLock { storedRecoveryThreshold = newValue } }
  }

  public var minimumDropDuration: TimeInterval {
    get { withLock { storedMinimumDropDuration } }
    set { withLock { storedMinimumDropDuration = newValue } }
  }

  public var onPerformanceTooSlow: ((Double, Double) -> Void)? {
    get { withLock { storedOnPerformanceTooSlow } }
    set { withLock { storedOnPerformanceTooSlow = newValue } }
  }

  public var onPerformanceRecovered: ((Double, Double) -> Bool)? {
    get { withLock { storedOnPerformanceRecovered } }
    set { withLock { storedOnPerformanceRecovered = newValue } }
  }

  /**
   Records a command buffer after Metal has completed it. GPU timestamps are not valid before that
   point according to the Metal API contract.
   */
  public func recordCompletedFrame(_ commandBuffer: MTLCommandBuffer) {
    recordCompletedFrame(
      gpuStartTime: commandBuffer.gpuStartTime,
      gpuEndTime: commandBuffer.gpuEndTime,
      completedAt: CACurrentMediaTime()
    )
  }

  /**
   Scalar entry point used by renderers and tests. The completion timestamp must use the host clock.
   */
  public func recordCompletedFrame(
    gpuStartTime: CFTimeInterval,
    gpuEndTime: CFTimeInterval,
    completedAt: CFTimeInterval = CACurrentMediaTime()
  ) {
    withLock {
      let previousCompletionTimestamp = lastCompletionTimestamp
      if completedAt.isFinite, completedAt > 0 {
        lastCompletionTimestamp = completedAt
      }

      let hasValidGPUTimestamps = gpuStartTime.isFinite &&
        gpuEndTime.isFinite &&
        gpuStartTime > 0 &&
        gpuEndTime > gpuStartTime

      let duration: CFTimeInterval
      let timestamp: CFTimeInterval
      if hasValidGPUTimestamps {
        duration = min(gpuEndTime - gpuStartTime, 1)
        timestamp = gpuEndTime
        storedTimingSource = .gpu
        storedGPUTimingSampleCount &+= 1
        if didReportFallback {
          logger?.info("Metal GPU frame timing is available again.")
          didReportFallback = false
        }
      } else {
        guard previousCompletionTimestamp > 0,
              completedAt.isFinite,
              completedAt > previousCompletionTimestamp else {
          reportFallbackIfNeeded()
          return
        }
        duration = min(completedAt - previousCompletionTimestamp, 1)
        timestamp = completedAt
        storedTimingSource = .cpuFallback
        storedFallbackTimingSampleCount &+= 1
        reportFallbackIfNeeded()
      }

      guard duration > 0 else { return }
      recordSample(timestamp: timestamp, duration: duration)
    }
  }

  public func reset() {
    withLock {
      samples.removeAll()
      measurementStartTimestamp = 0
      lastCompletionTimestamp = 0
      lastSampleTimestamp = 0
      storedLastFPS = 0
      storedAverageFPS = 0
      storedSmoothedFPS = 0
      storedMinFPS = Double.greatestFiniteMagnitude
      storedMaxFPS = 0
      storedRenderedFrameCount = 0
      storedTimingSource = .unavailable
      storedGPUTimingSampleCount = 0
      storedFallbackTimingSampleCount = 0
      emaInitialized = false
      didReportFallback = false
      state = .normal
    }
    logger?.dev("GPU FPS stats reset.")
  }

  private func recordSample(timestamp: CFTimeInterval, duration: CFTimeInterval) {
    if measurementStartTimestamp == 0 {
      measurementStartTimestamp = timestamp
    }
    lastSampleTimestamp = timestamp
    storedRenderedFrameCount &+= 1

    let fps = 1 / duration
    storedLastFPS = fps
    if emaInitialized {
      storedSmoothedFPS = smoothingFactor * fps + (1 - smoothingFactor) * storedSmoothedFPS
    } else {
      storedSmoothedFPS = fps
      emaInitialized = true
    }
    storedMinFPS = min(storedMinFPS, fps)
    storedMaxFPS = max(storedMaxFPS, fps)

    samples.append(FrameSample(timestamp: timestamp, duration: duration))
    purgeOldSamples(currentTime: timestamp)
    updateAverageFPS()

    logger?.dev(
      "GPU FPS: \(String(format: "%.1f", fps)) " +
      "(source: \(storedTimingSource == .gpu ? "Metal" : "completion fallback"))"
    )
    handleStateTransition(now: timestamp, fps: fps)
  }

  private func updateAverageFPS() {
    guard !samples.isEmpty else {
      storedAverageFPS = 0
      return
    }
    let accumulatedGPUTime = samples.reduce(0) { $0 + $1.duration }
    storedAverageFPS = accumulatedGPUTime > 0
      ? Double(samples.count) / accumulatedGPUTime
      : 0
  }

  private func purgeOldSamples(currentTime: CFTimeInterval) {
    guard currentTime > 0 else { return }
    let cutoff = currentTime - storedHistoryDuration
    while let first = samples.first, first.timestamp < cutoff {
      samples.removeFirst()
    }
  }

  private func reportFallbackIfNeeded() {
    guard !didReportFallback else { return }
    didReportFallback = true
    logger?.warning(
      "Metal returned no valid GPU timestamps; frame timing uses command-buffer completions."
    )
  }

  private func handleStateTransition(now: CFTimeInterval, fps: Double) {
    switch state {
      case .normal:
        if fps < storedDropThreshold {
          updateState(to: .tooSlow(startTime: now))
          logger?.warning("Entered low-performance state at \(fps) FPS.")
          let percentBelow = max(0, (storedDropThreshold - fps) / storedDropThreshold)
          storedOnPerformanceTooSlow?(fps, percentBelow)
        }
      case .tooSlow(let startTime):
        if fps >= storedRecoveryThreshold,
           now - startTime >= storedMinimumDropDuration {
          updateState(to: .recovering)
          logger?.dev("Performance recovering from low state at \(fps) FPS.")
          attemptRecovery(fps: fps)
        } else if fps < storedDropThreshold {
          let percentBelow = max(0, (storedDropThreshold - fps) / storedDropThreshold)
          storedOnPerformanceTooSlow?(fps, percentBelow)
        }
      case .recovering:
        if fps < storedDropThreshold {
          updateState(to: .tooSlow(startTime: now))
          logger?.warning("Recovery interrupted, back to low-performance state.")
          let percentBelow = max(0, (storedDropThreshold - fps) / storedDropThreshold)
          storedOnPerformanceTooSlow?(fps, percentBelow)
        } else if fps >= storedRecoveryThreshold {
          attemptRecovery(fps: fps)
        }
    }
  }

  private func attemptRecovery(fps: Double) {
    let percentAbove = max(0, (fps - storedRecoveryThreshold) / storedRecoveryThreshold)
    if let recovered = storedOnPerformanceRecovered?(fps, percentAbove), recovered {
      logger?.dev("Recovery step executed.")
    } else {
      logger?.dev("All recovery steps complete. Returning to normal state.")
      updateState(to: .normal)
    }
  }

  private func updateState(to newState: PerformanceState) {
    guard state != newState else { return }
    state = newState
    storedOnStateChanged?(newState)
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
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
