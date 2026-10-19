import Foundation

/**
 An enum representing errors that can occur when working with a cache map.

 These errors indicate issues with the size of the cache map file or an incomplete bitmap.
 */
enum CacheMapError: Error, LocalizedError {
  /// The cache map file is too small.
  case tooSmall
  /// The cache map file does not contain the expected number of bytes for the bitmap.
  case incompleteBitmap(expected: Int, actual: Int)
  /// The stored element count cannot be represented safely.
  case invalidCount

  /// A localized description of the cache map error.
  var errorDescription: String? {
    switch self {
      case .tooSmall:
        return "Corrupted cache map: file too small"
      case .incompleteBitmap(let expected, let actual):
        return "Corrupted cache map: expected \(expected) bytes but found \(actual)"
      case .invalidCount:
        return "Corrupted cache map: invalid element count"
    }
  }
}

/**
 A structure representing a cache map that tracks a series of Boolean flags.

 The CacheMap stores a fixed number of bits compactly in a byte array, allowing individual bits
 to be set and queried. It also provides methods for loading from and saving to a file, checking
 if a bit is set, finding the first unset bit, determining completeness, and clearing the map.
 */
struct CacheMapSnapshot: Equatable {
  let count: Int
  let setCount: Int

  var isComplete: Bool { setCount == count }
  var fillRatio: Double {
    guard count > 0 else { return 0 }
    return Double(setCount) / Double(count)
  }
}

final class CacheMap {
  private static let maximumCount = 1_000_000_000

  /// The total number of bits the cache map is designed to track.
  let count: Int
  /// The underlying byte array representing the bit map.
  private var map: [UInt8]
  /// The number of bits that are currently set.
  private var setCount: Int = 0
  /// Protects the bitmap and its derived counter as one consistent state.
  private let lock = NSLock()

  /// The ratio of elements that have been cached so far.
  var fillRatio: Double {
    snapshot.fillRatio
  }

  var snapshot: CacheMapSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return CacheMapSnapshot(count: count, setCount: setCount)
  }

  /**
   Initializes a new CacheMap with the specified number of bits.

   - Parameter count: The total number of bits to be tracked.
   */
  init(count: Int) throws {
    guard (0...Self.maximumCount).contains(count) else {
      throw CacheMapError.invalidCount
    }
    self.count = count
    let byteCount = Self.byteCount(for: count)
    self.map = [UInt8](repeating: 0, count: byteCount)
    self.setCount = 0
  }

  /**
   Initializes a CacheMap by reading its data from a file.

   The file should begin with an 8-byte (UInt64) count, followed by the bitmap data.

   - Parameter url: The URL of the file containing the cache map.
   - Throws: A CacheMapError if the file is too small or the bitmap is incomplete.
   */
  init(fromFile url: URL) throws {
    let data = try Data(contentsOf: url)
    guard data.count >= 8 else {
      throw CacheMapError.tooSmall
    }

    var storedCount: UInt64 = 0
    for byteIndex in 0..<MemoryLayout<UInt64>.size {
      storedCount |= UInt64(data[byteIndex]) << UInt64(byteIndex * 8)
    }
    guard let count = Int(exactly: storedCount),
          (0...Self.maximumCount).contains(count) else {
      throw CacheMapError.invalidCount
    }
    self.count = count

    let byteCount = Self.byteCount(for: count)
    let expectedSize = 8.addingReportingOverflow(byteCount)
    guard !expectedSize.overflow else { throw CacheMapError.invalidCount }
    guard data.count >= expectedSize.partialValue else {
      throw CacheMapError.incompleteBitmap(expected: expectedSize.partialValue, actual: data.count)
    }

    self.map = Array(data[8..<8 + byteCount])
    self.setCount = Self.countValidBits(in: map, count: count)
  }

  /**
   Saves the cache map to a file at the specified URL.

   The file will contain the count (as a UInt64) followed by the bitmap.

   - Parameter url: The file URL where the cache map should be saved.
   - Throws: An error if writing to the file fails.
   */
  func save(to url: URL) throws {
    lock.lock()
    let savedMap = map
    lock.unlock()

    var data = Data()
    var count64 = UInt64(count).littleEndian
    data.append(Data(bytes: &count64, count: MemoryLayout<UInt64>.size))
    data.append(contentsOf: savedMap)
    try data.write(to: url, options: .atomic)
  }

  /**
   Checks if the bit at the specified index is set.

   - Parameter index: The index to check.
   - Returns: True if the bit at the specified index is set; otherwise, false.
   */
  func isSet(index: Int) -> Bool {
    guard (0..<count).contains(index) else { return false }
    lock.lock()
    defer { lock.unlock() }
    let byte = map[index / 8]
    let bit = 7 - (index % 8)
    return (byte & (1 << bit)) != 0
  }

  /**
   Sets the bit at the specified index.

   If the bit was not previously set, it is marked as set and the count of set bits is incremented.

   - Parameter index: The index of the bit to set.
   */
  @discardableResult
  func set(index: Int) -> Bool {
    guard (0..<count).contains(index) else { return false }
    lock.lock()
    defer { lock.unlock() }
    let byteIndex = index / 8
    let bit = 7 - (index % 8)
    let mask: UInt8 = (1 << bit)

    if (map[byteIndex] & mask) == 0 {
      map[byteIndex] |= mask
      setCount += 1
    }
    return true
  }

  /**
   Determines if all bits in the cache map are set.

   - Returns: True if the number of set bits equals the total count; otherwise, false.
   */
  func isComplete() -> Bool {
    snapshot.isComplete
  }

  /// Clears all bits in the cache map, resetting the set count to zero.
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    map = Array(repeating: 0, count: map.count)
    setCount = 0
  }

  private static func byteCount(for count: Int) -> Int {
    count / 8 + (count % 8 == 0 ? 0 : 1)
  }

  private static func countValidBits(in map: [UInt8], count: Int) -> Int {
    let completeByteCount = count / 8
    var result = map.prefix(completeByteCount).reduce(0) { $0 + $1.nonzeroBitCount }
    let remainingBits = count % 8
    if remainingBits > 0 {
      let mask = UInt8.max << UInt8(8 - remainingBits)
      result += (map[completeByteCount] & mask).nonzeroBitCount
    }
    return result
  }
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of
 Duisburg-Essen

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
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
