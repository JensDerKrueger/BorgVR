/**
 A ring (circular) buffer that provides bidirectional collection capabilities.

 The RingBuffer is implemented using an underlying array with optional elements.
 When the buffer becomes full, it automatically resizes to accommodate additional
 elements.

 This structure conforms to BidirectionalCollection and CustomStringConvertible.
 */
struct RingBuffer<T>: BidirectionalCollection, CustomStringConvertible {
  // MARK: - Storage

  /// The underlying storage for buffer elements.
  private var buffer: [T?]
  /// The index of the first element in the buffer.
  private var head = 0
  /// The number of elements currently stored in the buffer.
  private(set) var count = 0

  // MARK: - Initialization

  /**
   Initializes a new RingBuffer with the specified capacity.

   - Parameter capacity: The initial capacity of the buffer. Defaults to 100.
   If a capacity less than 1 is provided, 1 is used.
   */
  init(capacity: Int = 100) {
    self.buffer = Array(repeating: nil, count: Swift.max(1, capacity))
  }

  // MARK: - Computed Properties

  /// The total capacity of the buffer.
  var capacity: Int { buffer.count }
  /// A Boolean value indicating whether the buffer is empty.
  var isEmpty: Bool { count == 0 }
  /// The first element of the buffer, or nil if the buffer is empty.
  var first: T? { self[startIndex] }
  /// The last element of the buffer, or nil if the buffer is empty.
  var last: T? {
    guard !isEmpty else { return nil }
    return self[index(before: endIndex)]
  }
  /// A textual representation of the buffer elements.
  var description: String { map { "\($0)" }
      .joined(separator: ", ")
    .wrapped(in: "[", "]") }

  // MARK: - Mutation Methods

  /**
   Appends a new element to the end of the ring buffer.

   If the buffer is full, it automatically resizes to accommodate the new element.

   - Parameter element: The element to append.
   */
  mutating func append(_ element: T) {
    if count == capacity {
      resizeBuffer(newCapacity: capacity * 2)
    }
    let index = (head + count) % capacity
    buffer[index] = element
    count += 1
  }

  /**
   Removes and returns the first element of the ring buffer.

   - Returns: The removed element, or nil if the buffer is empty.
   */
  @discardableResult
  mutating func removeFirst() -> T? {
    guard !isEmpty else { return nil }
    let value = buffer[head]
    buffer[head] = nil
    head = (head + 1) % capacity
    count -= 1
    return value
  }

  /**
   Removes elements from the buffer that are older than a cutoff element.

   The provided closure determines if the current first element is considered
   "older" than the cutoff. Elements are removed until this condition fails.

   - Parameters:
   - cutoff: The element used as the threshold.
   - isOlder: A closure that returns true if the first element is older than cutoff.
   */
  mutating func removeOld(olderThan cutoff: T, isOlder: (T, T) -> Bool) {
    while !isEmpty, let first = self.first, isOlder(first, cutoff) {
      _ = removeFirst()
    }
  }

  /// Removes all elements from the buffer.
  mutating func removeAll() {
    buffer = Array(repeating: nil, count: capacity)
    head = 0
    count = 0
  }

  /**
   Resizes the underlying storage by doubling its capacity.

   All existing elements are copied to the new storage.
   */
  private mutating func resizeBuffer(newCapacity: Int) {
    var newBuffer = Array<T?>(repeating: nil, count: newCapacity)
    for i in 0..<count {
      newBuffer[i] = buffer[(head + i) % capacity]
    }
    buffer = newBuffer
    head = 0
  }

  // MARK: - Collection Conformance

  /**
   A type representing an index in the RingBuffer.

   The index is based on an integer offset relative to the logical start of the buffer.
   */
  struct Index: Comparable {
    /// The offset of the index.
    let offset: Int
    static func < (lhs: Index, rhs: Index) -> Bool { lhs.offset < rhs.offset }
  }

  /// The index of the first element in the collection.
  var startIndex: Index { Index(offset: 0) }
  /// The index one past the last element in the collection.
  var endIndex: Index { Index(offset: count) }

  /**
   Returns the index immediately after the given index.

   - Parameter i: A valid index of the buffer.
   - Returns: The index immediately after i.
   */
  func index(after i: Index) -> Index {
    Index(offset: i.offset + 1)
  }

  /**
   Returns the index immediately before the given index.

   - Parameter i: A valid index of the buffer.
   - Returns: The index immediately before i.
   */
  func index(before i: Index) -> Index {
    Index(offset: i.offset - 1)
  }

  /**
   Accesses the element at the specified position.

   - Parameter position: The position of the element to access.
   - Returns: The element at the specified position.
   - Precondition: The index must be within larger than tero
   */
  subscript(position: Index) -> T {
    get {
      return buffer[(head + position.offset) % capacity]!
    }
  }

  /**
   Accesses the element at the specified index.

   - Parameter index: The integer index of the element to access.
   - Returns: The element at the specified position.
   - Precondition: The index must be within the bounds of the buffer.
   */
  subscript(index: Int) -> T {
    get {
      return self[Index(offset: index)]
    }
    set {
      buffer[(head + index) % capacity] = newValue
    }
  }
}

/// An extension on String that provides a helper method to wrap the string.
extension String {
  /**
   Wraps the string with a given prefix and suffix.

   - Parameters:
   - prefix: The string to prepend.
   - suffix: The string to append.
   - Returns: The resulting string after wrapping.
   */
  func wrapped(in prefix: String, _ suffix: String) -> String {
    return prefix + self + suffix
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

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
