import Foundation

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
      case .failed(let message): return message
    }
  }
}

private enum SourceFailure: Error, Equatable {
  case unavailable
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw TestFailure.failed(message) }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) throws {
  do {
    try body()
    throw TestFailure.failed(message)
  } catch is TestFailure {
    throw TestFailure.failed(message)
  } catch {}
}

private func temporaryURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("borgvr-cache-map-\(UUID().uuidString)")
}

private func countData(_ count: UInt64, bitmap: [UInt8]) -> Data {
  var littleEndianCount = count.littleEndian
  var result = Data(bytes: &littleEndianCount, count: MemoryLayout<UInt64>.size)
  result.append(contentsOf: bitmap)
  return result
}

private func testRoundTripAndBounds() throws {
  let url = temporaryURL()
  defer { try? FileManager.default.removeItem(at: url) }

  let map = try CacheMap(count: 10)
  try expect(map.set(index: 0), "The first cache bit could not be set")
  try expect(map.set(index: 9), "The last cache bit could not be set")
  try expect(!map.set(index: -1), "A negative cache index was accepted")
  try expect(!map.set(index: 10), "An index beyond the cache map was accepted")
  try map.save(to: url)

  let loaded = try CacheMap(fromFile: url)
  try expect(loaded.snapshot == CacheMapSnapshot(count: 10, setCount: 2),
             "The cache map snapshot did not survive a round trip")
  try expect(loaded.isSet(index: 0), "The first cache bit was lost")
  try expect(loaded.isSet(index: 9), "The last cache bit was lost")
  try expect(!loaded.isSet(index: 10), "An out-of-range cache query succeeded")
}

private func testMalformedFiles() throws {
  let url = temporaryURL()
  defer { try? FileManager.default.removeItem(at: url) }

  try Data(repeating: 0, count: 7).write(to: url)
  try expectThrows("A truncated cache header was accepted") {
    _ = try CacheMap(fromFile: url)
  }

  try countData(UInt64.max, bitmap: []).write(to: url)
  try expectThrows("An unrepresentable cache count was accepted") {
    _ = try CacheMap(fromFile: url)
  }

  try countData(1_000_000_001, bitmap: []).write(to: url)
  try expectThrows("An implausibly large cache count was accepted") {
    _ = try CacheMap(fromFile: url)
  }

  try countData(9, bitmap: [0]).write(to: url)
  try expectThrows("An incomplete cache bitmap was accepted") {
    _ = try CacheMap(fromFile: url)
  }

  try countData(1, bitmap: [0xff]).write(to: url)
  let padded = try CacheMap(fromFile: url)
  try expect(padded.snapshot == CacheMapSnapshot(count: 1, setCount: 1),
             "Padding bits were counted as cached bricks")
}

private func testConcurrentMapAccess() throws {
  let count = 1024
  let map = try CacheMap(count: count)
  DispatchQueue.concurrentPerform(iterations: count) { index in
    _ = map.set(index: index)
    _ = map.snapshot
    _ = map.isSet(index: count - index - 1)
  }
  try expect(map.snapshot == CacheMapSnapshot(count: count, setCount: count),
             "Concurrent cache updates lost bits")
  map.clear()
  try expect(map.snapshot == CacheMapSnapshot(count: count, setCount: 0),
             "Clearing the cache map did not reset its complete state")
}

private final class AvailabilityFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class WaitResultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: CachingRemoteWaitResult?

  func set(_ result: CachingRemoteWaitResult) {
    lock.lock()
    value = result
    lock.unlock()
  }

  func get() -> CachingRemoteWaitResult? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private func testAvailabilitySignal() throws {
  let lifecycle = CachingRemoteLifecycle()
  let available = AvailabilityFlag()
  let result = WaitResultBox()
  let completed = DispatchSemaphore(value: 0)

  DispatchQueue.global().async {
    result.set(
      lifecycle.waitUntilAvailable(deadline: Date().addingTimeInterval(2)) {
        available.get()
      }
    )
    completed.signal()
  }

  Thread.sleep(forTimeInterval: 0.02)
  available.set()
  lifecycle.recordBrickAvailable()
  try expect(completed.wait(timeout: .now() + 1) == .success,
             "A first-brick waiter was not signalled")
  guard case .available? = result.get() else {
    throw TestFailure.failed("A signalled first brick was not reported as available")
  }
}

private func testStopAndTimeoutErrors() throws {
  let stoppedLifecycle = CachingRemoteLifecycle()
  stoppedLifecycle.recordFetchFailure(SourceFailure.unavailable)
  _ = stoppedLifecycle.requestStop()
  let stopped = stoppedLifecycle.waitUntilAvailable(deadline: Date().addingTimeInterval(1)) {
    false
  }
  guard case .stopped(let error) = stopped,
        error as? SourceFailure == .unavailable else {
    throw TestFailure.failed("Stopping did not preserve the last source error")
  }

  let timedLifecycle = CachingRemoteLifecycle()
  timedLifecycle.recordFetchFailure(SourceFailure.unavailable)
  let timed = timedLifecycle.waitUntilAvailable(deadline: Date().addingTimeInterval(0.01)) {
    false
  }
  guard case .timedOut(let error) = timed,
        error as? SourceFailure == .unavailable else {
    throw TestFailure.failed("Timing out did not preserve the last source error")
  }
}

private func testFinalizationLifecycle() throws {
  let lifecycle = CachingRemoteLifecycle()
  try expect(!lifecycle.beginFinalization(), "Finalization began before caching completed")
  lifecycle.markCachingComplete()
  try expect(lifecycle.beginFinalization(), "Finalization did not begin")
  try expect(!lifecycle.beginFinalization(), "Concurrent finalization was accepted")
  lifecycle.finishFinalization(success: false)
  try expect(lifecycle.beginFinalization(), "Failed finalization could not be retried")
  lifecycle.finishFinalization(success: true)
  try expect(lifecycle.isLocalCopyFinalized, "Successful finalization was not recorded")
  try expect(!lifecycle.beginFinalization(), "Completed finalization was started twice")
}

@main
private enum CacheMapLifecycleTestRunner {
  static func main() throws {
    try testRoundTripAndBounds()
    try testMalformedFiles()
    try testConcurrentMapAccess()
    try testAvailabilitySignal()
    try testStopAndTimeoutErrors()
    try testFinalizationLifecycle()
    print("Cache map and caching lifecycle tests passed")
  }
}
