import Foundation

struct AtlasPagingStatistics: Sendable, Equatable {
  let residentBricks: Int
  let capacity: Int
  let totalUploadedBricks: UInt64
  let bytesPerBrick: Int

  init(residentBricks: Int, capacity: Int, totalUploadedBricks: UInt64, bytesPerBrick: Int = 0) {
    self.residentBricks = residentBricks
    self.capacity = capacity
    self.totalUploadedBricks = totalUploadedBricks
    self.bytesPerBrick = bytesPerBrick
  }

  var residentBytes: Int64 { Int64(max(0, min(residentBricks, capacity))) * Int64(max(0, bytesPerBrick)) }
  var capacityBytes: Int64 { Int64(max(0, capacity)) * Int64(max(0, bytesPerBrick)) }

  var fillFraction: Double {
    guard capacity > 0 else { return 0 }
    return min(1, max(0, Double(residentBricks) / Double(capacity)))
  }
}

struct AtlasPagingHistory {
  struct Sample: Sendable, Equatable {
    let timestamp: TimeInterval
    let bricksPerSecond: Double
    let residentBricks: Int
    let capacity: Int
    let residentBytes: Int64
    let capacityBytes: Int64

    init(timestamp: TimeInterval, bricksPerSecond: Double, residentBricks: Int, capacity: Int,
         residentBytes: Int64 = 0, capacityBytes: Int64 = 0) {
      self.timestamp = timestamp
      self.bricksPerSecond = bricksPerSecond
      self.residentBricks = residentBricks
      self.capacity = capacity
      self.residentBytes = residentBytes
      self.capacityBytes = capacityBytes
    }

    var fillFraction: Double {
      guard capacity > 0 else { return 0 }
      return min(1, max(0, Double(residentBricks) / Double(capacity)))
    }
  }

  let duration: TimeInterval = 30
  private(set) var samples = RingBuffer<Sample>(capacity: 320)
  private var previousStatistics: AtlasPagingStatistics?

  func shouldRecord(timestamp: TimeInterval, statistics: AtlasPagingStatistics) -> Bool {
    guard timestamp.isFinite else { return false }
    guard let previous = samples.last, let previousStatistics else { return true }
    return timestamp < previous.timestamp ||
      timestamp >= previous.timestamp + 0.1 ||
      statistics.residentBricks < previous.residentBricks ||
      statistics.totalUploadedBricks < previousStatistics.totalUploadedBricks
  }

  mutating func record(timestamp: TimeInterval, statistics: AtlasPagingStatistics) {
    guard shouldRecord(timestamp: timestamp, statistics: statistics) else { return }
    var rate = 0.0
    if let previous = samples.last {
      if timestamp < previous.timestamp {
        samples.removeAll()
      } else if timestamp > previous.timestamp, let previousStatistics,
                statistics.totalUploadedBricks >= previousStatistics.totalUploadedBricks {
        let uploaded = statistics.totalUploadedBricks - previousStatistics.totalUploadedBricks
        rate = min(Double.greatestFiniteMagnitude, Double(uploaded) / (timestamp - previous.timestamp))
      }
    }

    // Purge/reset events can arrive faster than the regular sampling interval.
    while !samples.isEmpty, let first = samples.first,
          first.timestamp < timestamp - duration || samples.count >= 600 {
      samples.removeFirst()
    }
    samples.append(Sample(timestamp: timestamp, bricksPerSecond: rate,
      residentBricks: statistics.residentBricks, capacity: statistics.capacity,
      residentBytes: statistics.residentBytes, capacityBytes: statistics.capacityBytes))
    previousStatistics = statistics
  }
}
