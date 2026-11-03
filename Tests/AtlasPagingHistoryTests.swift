import Foundation

private struct PagingHistoryTestFailure: Error { let message: String }

@main
private enum AtlasPagingHistoryTests {
  static func main() throws {
    try testFillFraction()
    try testFirstIdleAndLoad()
    try testThrottleAndIntervalRate()
    try testPurge()
    try testCounterReset()
    try testTimeReversal()
    try testDurationAndBounds()
    try testInvalidTimestamps()
    try testByteCounts()
    print("Atlas paging history tests passed")
  }

  private static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw PagingHistoryTestFailure(message: message) }
  }

  private static func near(_ value: Double?, _ expected: Double, _ message: String) throws {
    try check(value.map { abs($0 - expected) < 0.000_001 } ?? false, message)
  }

  private static func statistics(_ resident: Int = 0, capacity: Int = 100,
                               uploaded: UInt64 = 0) -> AtlasPagingStatistics {
    .init(residentBricks: resident, capacity: capacity, totalUploadedBricks: uploaded)
  }

  private static func testFillFraction() throws {
    for (resident, capacity, expected) in [(0, 0, 0.0), (10, -1, 0.0), (-2, 10, 0.0),
                                            (5, 10, 0.5), (10, 10, 1.0), (20, 10, 1.0)] {
      let stats = statistics(resident, capacity: capacity)
      let sample = AtlasPagingHistory.Sample(timestamp: 0, bricksPerSecond: 0,
        residentBricks: resident, capacity: capacity)
      try near(stats.fillFraction, expected, "Statistics fill fraction is invalid")
      try near(sample.fillFraction, expected, "Sample fill fraction is invalid")
      try check(stats == statistics(resident, capacity: capacity), "Statistics equality changed")
    }
  }

  private static func testByteCounts() throws {
    let stats = AtlasPagingStatistics(residentBricks: 5, capacity: 10, totalUploadedBricks: 50,
      bytesPerBrick: 4096)
    try check(stats.residentBytes == 20480 && stats.capacityBytes == 40960,
      "Atlas byte counts must use the actual encoded page size")
    var history = AtlasPagingHistory()
    history.record(timestamp: 0, statistics: stats)
    try check(history.samples.last?.residentBytes == 20480 && history.samples.last?.capacityBytes == 40960,
      "Historical samples must retain their byte counts")
  }

  private static func testFirstIdleAndLoad() throws {
    var history = AtlasPagingHistory()
    try check(history.samples.isEmpty && history.duration == 30, "Incorrect initial history")
    let first = statistics(10, uploaded: 50)
    try check(history.shouldRecord(timestamp: 10, statistics: first), "First sample was throttled")
    history.record(timestamp: 10, statistics: first)
    try near(history.samples.last?.bricksPerSecond, 0, "First sample counted earlier uploads")
    history.record(timestamp: 11, statistics: first)
    try near(history.samples.last?.bricksPerSecond, 0, "Idle atlas has a nonzero rate")
    history.record(timestamp: 13, statistics: statistics(30, uploaded: 90))
    try near(history.samples.last?.bricksPerSecond, 20, "Actual elapsed time was not used")
    try near(history.samples.last?.fillFraction, 0.3, "Loaded atlas fill was not captured")
    history.record(timestamp: 14, statistics: statistics(30, uploaded: 100))
    try near(history.samples.last?.bricksPerSecond, 10, "Replacement uploads must count at constant occupancy")
    history.record(timestamp: 15, statistics: statistics(40, uploaded: 100))
    try near(history.samples.last?.bricksPerSecond, 0, "Occupancy was counted as uploads")
  }

  private static func testThrottleAndIntervalRate() throws {
    var history = AtlasPagingHistory()
    history.record(timestamp: 10, statistics: statistics(uploaded: 100))
    let skipped = statistics(5, uploaded: 110)
    try check(!history.shouldRecord(timestamp: 10.05, statistics: skipped), "Sub-interval sample was accepted")
    history.record(timestamp: 10.05, statistics: skipped)
    try check(history.samples.count == 1, "record did not enforce throttling")
    let next = statistics(10, uploaded: 120)
    try check(history.shouldRecord(timestamp: 10.1, statistics: next), "Exact 0.1-second boundary was throttled")
    history.record(timestamp: 10.1, statistics: next)
    try near(history.samples.last?.bricksPerSecond, 200, "Skipped observations changed the rate baseline")
    try check(!history.shouldRecord(timestamp: 10.1, statistics: next), "Duplicate sample was accepted")
  }

  private static func testPurge() throws {
    var history = AtlasPagingHistory()
    history.record(timestamp: 0, statistics: statistics(80, uploaded: 100))
    let purged = statistics(1, uploaded: 100)
    try check(history.shouldRecord(timestamp: 0.01, statistics: purged), "Purge was throttled")
    history.record(timestamp: 0.01, statistics: purged)
    try check(history.samples.count == 2 && history.samples.last?.residentBricks == 1,
      "Purge occupancy was not captured immediately")
    try near(history.samples.last?.bricksPerSecond, 0, "Purge produced a negative/upload rate")
    history.record(timestamp: 0.02, statistics: statistics(0, uploaded: 102))
    try near(history.samples.last?.bricksPerSecond, 200, "Purge discarded successful interval uploads")
    history.record(timestamp: 0.02, statistics: statistics(-1, uploaded: 102))
    try near(history.samples.last?.bricksPerSecond, 0, "Same-time purge divided by zero")
  }

  private static func testCounterReset() throws {
    var history = AtlasPagingHistory()
    history.record(timestamp: 0, statistics: statistics(10, uploaded: UInt64.max))
    let reset = statistics(10, uploaded: 3)
    try check(history.shouldRecord(timestamp: 0.01, statistics: reset), "Counter reset was throttled")
    history.record(timestamp: 0.01, statistics: reset)
    try near(history.samples.last?.bricksPerSecond, 0, "Counter reset underflowed")
    history.record(timestamp: 1.01, statistics: statistics(12, uploaded: 13))
    try near(history.samples.last?.bricksPerSecond, 10, "Rate did not recover after counter reset")
    history.record(timestamp: 1.01, statistics: statistics(12, uploaded: 0))
    try near(history.samples.last?.bricksPerSecond, 0, "Same-time counter reset divided by zero")
  }

  private static func testTimeReversal() throws {
    var history = AtlasPagingHistory()
    history.record(timestamp: 100, statistics: statistics(uploaded: 10))
    history.record(timestamp: 101, statistics: statistics(uploaded: 20))
    let reversed = statistics(uploaded: 30)
    try check(history.shouldRecord(timestamp: 50, statistics: reversed), "Time reversal was throttled")
    history.record(timestamp: 50, statistics: reversed)
    try check(history.samples.count == 1 && history.samples.last?.timestamp == 50,
      "Time reversal left an unordered history")
    try near(history.samples.last?.bricksPerSecond, 0, "Time reversal produced an invalid rate")
    history.record(timestamp: 51, statistics: statistics(uploaded: 35))
    try near(history.samples.last?.bricksPerSecond, 5, "Time reversal did not reset the baseline")
  }

  private static func testDurationAndBounds() throws {
    var history = AtlasPagingHistory()
    for second in 0...100 {
      history.record(timestamp: Double(second), statistics: statistics(uploaded: UInt64(second)))
    }
    try check(history.samples.count == 31 && history.samples.first?.timestamp == 70,
      "Duration trimming lost the boundary or retained old samples")
    history.record(timestamp: 200, statistics: statistics(uploaded: 101))
    try check(history.samples.count == 1, "Long idle interval retained expired history")
    try near(history.samples.last?.bricksPerSecond, 0.01, "Trim changed the interval rate")

    var bursts = AtlasPagingHistory()
    for index in 0..<1500 {
      bursts.record(timestamp: Double(index) * 0.001,
        statistics: statistics(uploaded: UInt64(2000 - index)))
    }
    try check(bursts.samples.count == 600, "Exceptional events exceeded the sample bound")
    try check(bursts.samples.capacity <= 640, "Ring storage grew beyond the bounded history")
    try near(bursts.samples.first?.timestamp, 0.9, "Bound trimming did not retain newest samples")
    try check(bursts.samples.allSatisfy { $0.bricksPerSecond.isFinite && $0.bricksPerSecond >= 0 },
      "Burst rates are invalid")
  }

  private static func testInvalidTimestamps() throws {
    var history = AtlasPagingHistory()
    for timestamp in [Double.nan, .infinity, -.infinity] {
      try check(!history.shouldRecord(timestamp: timestamp, statistics: statistics()),
        "Non-finite timestamp was accepted")
      history.record(timestamp: timestamp, statistics: statistics())
    }
    try check(history.samples.isEmpty, "Invalid timestamps poisoned the history")
    history.record(timestamp: 0, statistics: statistics())
    try check(history.samples.count == 1, "History did not recover after invalid timestamps")
  }
}
