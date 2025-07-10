import Foundation

/**
 A protocol that defines a frame timer interface.

 Conforming types track frame rate statistics such as last, average, smoothed, minimum, and
 maximum frames per second (FPS) and can be reset.
 */
public protocol FrameTimerProtocol: AnyObject {
  /// The FPS measured for the last rendered frame.
  var lastFPS: Double { get }
  /// The average FPS over a period of time.
  var averageFPS: Double { get }
  /// The exponentially smoothed FPS value.
  var smoothedFPS: Double { get }
  /// The minimum recorded FPS.
  var minFPS: Double { get }
  /// The maximum recorded FPS.
  var maxFPS: Double { get }

  /// Resets the frame timer statistics.
  func reset()

  /// Callback triggered when the performance state changes.
  var onStateChanged: ((PerformanceState) -> Void)? { get set }
}

// MARK: - PerformanceState

/**
 Represents the performance state of the frame timer.

 - normal: Performance is within acceptable limits.
 - tooSlow(startTime:): Performance has dropped below the threshold.
 - recovering: Performance is recovering.
 */
public enum PerformanceState: Equatable {
  case normal
  case tooSlow(startTime: CFTimeInterval)
  case recovering

  public static func == (lhs: PerformanceState, rhs: PerformanceState) -> Bool {
    switch (lhs, rhs) {
      case (.normal, .normal), (.recovering, .recovering):
        return true
      case let (.tooSlow(a), .tooSlow(b)):
        return a == b
      default:
        return false
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University
 of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
