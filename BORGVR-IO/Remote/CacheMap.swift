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

  /// A localized description of the cache map error.
  var errorDescription: String? {
    switch self {
      case .tooSmall:
        return "Corrupted cache map: file too small"
      case .incompleteBitmap(let expected, let actual):
        return "Corrupted cache map: expected \(expected) bytes but found \(actual)"
    }
  }
}

/**
 A structure representing a cache map that tracks a series of Boolean flags.

 The CacheMap stores a fixed number of bits compactly in a byte array, allowing individual bits
 to be set and queried. It also provides methods for loading from and saving to a file, checking
 if a bit is set, finding the first unset bit, determining completeness, and clearing the map.
 */
class CacheMap {
  /// The total number of bits the cache map is designed to track.
  private(set) var count: Int
  /// The underlying byte array representing the bit map.
  private var map: [UInt8]
  /// The number of bits that are currently set.
  private(set) var setCount: Int = 0
  /// A serial dispatch queue to protect access to the Cachemap
  private let queue = DispatchQueue(label: "CachemapQueue")

  /// The ratio of elements that have been cached so far.
  var fillRatio: Double {
    return queue.sync {
      if setCount == 0 {
        return 0.0
      }
      return Double(setCount) / Double(count)
    }
  }

  /**
   Initializes a new CacheMap with the specified number of bits.

   - Parameter count: The total number of bits to be tracked.
   */
  init(count: Int) {
    self.count = count
    let byteCount = (count + 7) / 8
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

    // Load the count from the first 8 bytes (stored as a UInt64).
    self.count = Int(data.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) })

    let byteCount = (count + 7) / 8
    guard data.count >= 8 + byteCount else {
      throw CacheMapError.incompleteBitmap(expected: 8 + byteCount, actual: data.count)
    }

    self.map = Array(data[8..<8 + byteCount])
    self.setCount = map.reduce(0) { $0 + $1.nonzeroBitCount }
  }

  /**
   Saves the cache map to a file at the specified URL.

   The file will contain the count (as a UInt64) followed by the bitmap.

   - Parameter url: The file URL where the cache map should be saved.
   - Throws: An error if writing to the file fails.
   */
  func save(to url: URL) throws {
    var data = Data()
    var count64 = UInt64(count)
    data.append(Data(bytes: &count64, count: MemoryLayout<UInt64>.size))
    data.append(contentsOf: map)
    try data.write(to: url)
  }

  /**
   Checks if the bit at the specified index is set.

   - Parameter index: The index to check.
   - Returns: True if the bit at the specified index is set; otherwise, false.
   */
  func isSet(index: Int) -> Bool {
    return queue.sync {
      let byte = map[index / 8]
      let bit = 7 - (index % 8)
      return (byte & (1 << bit)) != 0
    }
  }

  /**
   Sets the bit at the specified index.

   If the bit was not previously set, it is marked as set and the count of set bits is incremented.

   - Parameter index: The index of the bit to set.
   */
  func set(index: Int) {
    queue.sync {
      let byteIndex = index / 8
      let bit = 7 - (index % 8)
      let mask: UInt8 = (1 << bit)
      
      if (map[byteIndex] & mask) == 0 {
        map[byteIndex] |= mask
        setCount += 1
      }
    }
  }

  /**
   Finds the first index where the bit is not set.

   - Returns: The first unset index, or nil if all bits are set.
   */
  func firstUnsetIndex() -> Int? {
    for byteIndex in 0..<map.count {
      let byte = map[byteIndex]
      if byte != 0xFF {
        for bit in 0..<8 {
          let mask: UInt8 = 1 << (7 - bit)
          let index = byteIndex * 8 + bit
          if index >= count {
            return nil
          }
          if (byte & mask) == 0 {
            return index
          }
        }
      }
    }
    return nil  // All bits are set.
  }

  /**
   Finds the last index where the bit is not set.

   - Returns: The last unset index, or nil if all bits are set.
   */
  func lastUnsetIndex() -> Int? {
    for byteIndex in (0..<map.count).reversed() {
      let byte = map[byteIndex]
      if byte != 0xFF {
        for bit in 0..<8 {
          let mask: UInt8 = 1 << (7 - bit)
          let index = byteIndex * 8 + bit
          if index >= count {
            continue
          }
          if (byte & mask) == 0 {
            return index
          }
        }
      }
    }
    return nil  // All bits are set.
  }

  /**
   Determines if all bits in the cache map are set.

   - Returns: True if the number of set bits equals the total count; otherwise, false.
   */
  func isComplete() -> Bool {
    return queue.sync {
      return setCount == count
    }
  }

  /// Clears all bits in the cache map, resetting the set count to zero.
  func clear() {
    map = Array(repeating: 0, count: map.count)
    setCount = 0
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of
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
