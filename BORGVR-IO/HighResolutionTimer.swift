import Foundation

final class HighResolutionTimer {
  private var startTime: DispatchTime?

  /// Starts the timer.
  func start() {
    startTime = DispatchTime.now()
  }

  /// Returns the elapsed time in seconds since `start()` and resets the timer.
  func stop() -> Double {
    guard let start = startTime else {
      return 0.0
    }
    let now = DispatchTime.now()
    startTime = nil
    return Double(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
  }

  /// Returns the elapsed time in seconds since `start()` without resetting.
  func sample() -> Double {
    guard let start = startTime else {
      return 0.0
    }
    let now = DispatchTime.now()
    return Double(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
  }
}
