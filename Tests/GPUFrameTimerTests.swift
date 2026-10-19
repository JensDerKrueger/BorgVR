import Foundation
import QuartzCore

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): return message
    }
  }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func expectNear(
  _ value: Double,
  _ expected: Double,
  tolerance: Double = 0.001,
  _ message: String
) throws {
  try expect(abs(value - expected) <= tolerance, "\(message): got \(value), expected \(expected)")
}

private func testValidGPUTimestamps() throws {
  let timer = GPUFrameTimer()
  let base = CACurrentMediaTime()

  timer.recordCompletedFrame(
    gpuStartTime: base,
    gpuEndTime: base + 0.02,
    completedAt: base + 0.021
  )
  try expect(timer.timingSource == .gpu, "Valid Metal timestamps did not select GPU timing")
  try expect(timer.renderedFrameCount == 1, "The first GPU frame was not counted")
  try expectNear(timer.lastFPS, 50, "The GPU duration produced the wrong FPS")
  try expectNear(timer.averageFPS, 50, "The first GPU average was incorrect")

  timer.recordCompletedFrame(
    gpuStartTime: base + 0.03,
    gpuEndTime: base + 0.07,
    completedAt: base + 0.071
  )
  try expectNear(timer.lastFPS, 25, "The second GPU duration produced the wrong FPS")
  try expectNear(timer.averageFPS, 2 / 0.06, "GPU average did not use accumulated busy time")
  try expect(timer.gpuTimingSampleCount == 2, "GPU samples were not counted")
  try expect(timer.fallbackTimingSampleCount == 0, "Valid timestamps used the fallback")
}

private func testCompletionFallback() throws {
  let timer = GPUFrameTimer()
  let base = CACurrentMediaTime()

  timer.recordCompletedFrame(gpuStartTime: 0, gpuEndTime: 0, completedAt: base)
  try expect(timer.renderedFrameCount == 0, "A fallback frame was invented without an interval")

  timer.recordCompletedFrame(gpuStartTime: 0, gpuEndTime: 0, completedAt: base + 0.025)
  try expect(timer.timingSource == .cpuFallback, "Missing GPU timestamps did not use the fallback")
  try expect(timer.renderedFrameCount == 1, "The first measurable fallback frame was not counted")
  try expectNear(timer.lastFPS, 40, "The completion interval produced the wrong fallback FPS")
  try expect(timer.fallbackTimingSampleCount == 1, "Fallback samples were not counted")

  timer.recordCompletedFrame(
    gpuStartTime: base + 0.03,
    gpuEndTime: base + 0.04,
    completedAt: base + 0.041
  )
  try expect(timer.timingSource == .gpu, "GPU timing did not recover after fallback")
  try expectNear(timer.lastFPS, 100, "Recovered GPU timing produced the wrong FPS")
}

private func testPerformanceCallbacksAndReset() throws {
  let timer = GPUFrameTimer()
  let base = CACurrentMediaTime()
  var slowdownCount = 0
  timer.dropThreshold = 30
  timer.onPerformanceTooSlow = { _, _ in slowdownCount += 1 }

  timer.recordCompletedFrame(
    gpuStartTime: base,
    gpuEndTime: base + 0.05,
    completedAt: base + 0.051
  )
  try expect(slowdownCount == 1, "A slow GPU frame did not trigger adaptation")

  timer.reset()
  try expect(timer.renderedFrameCount == 0, "Reset did not clear the frame count")
  try expect(timer.timingSource == .unavailable, "Reset did not clear the timing source")
  try expect(timer.lastFPS == 0 && timer.averageFPS == 0, "Reset did not clear FPS values")
}

@main
private enum GPUFrameTimerTestRunner {
  static func main() throws {
    try testValidGPUTimestamps()
    try testCompletionFallback()
    try testPerformanceCallbacksAndReset()
    print("GPU frame timer tests passed")
  }
}
