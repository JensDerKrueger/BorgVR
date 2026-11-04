import Foundation

/// A bounded view of one UVF block; integers may be unaligned on disk.
struct UVFBinaryReader {
  let data: Data
  var position: Int
  let end: Int
  let bigEndian: Bool

  init(_ data: Data, start: Int = 0, end: Int? = nil, bigEndian: Bool = false) throws {
    let end = end ?? data.count
    guard start >= 0, end >= start, end <= data.count else { throw UVFParser.Error.invalid("block bounds") }
    self.data = data
    self.position = start
    self.end = end
    self.bigEndian = bigEndian
  }

  mutating func take(_ count: Int) throws -> Data {
    guard count >= 0, count <= end - position else { throw UVFParser.Error.invalid("truncated block") }
    defer { position += count }
    return data.subdata(in: position..<(position + count))
  }

  mutating func skip(_ count: Int) throws {
    guard count >= 0, count <= end - position else { throw UVFParser.Error.invalid("truncated header") }
    position += count
  }

  mutating func uint(_ bytes: Int = 8) throws -> UInt64 {
    guard (1...8).contains(bytes), bytes <= end - position else { throw UVFParser.Error.invalid("truncated integer") }
    var value: UInt64 = 0
    for i in 0..<bytes {
      value |= UInt64(data[position + i]) << (8 * (bigEndian ? bytes - i - 1 : i))
    }
    position += bytes
    return value
  }

  mutating func integer(_ bytes: Int = 8) throws -> Int {
    let value = try uint(bytes)
    guard let result = Int(exactly: value) else { throw UVFParser.Error.invalid("integer overflow") }
    return result
  }

  mutating func double() throws -> Double { Double(bitPattern: try uint()) }
}

func uvfAdd(_ a: Int, _ b: Int) throws -> Int {
  let (value, overflow) = a.addingReportingOverflow(b)
  guard a >= 0, b >= 0, !overflow else { throw UVFParser.Error.invalid("size overflow") }
  return value
}

func uvfProduct(_ values: [Int]) throws -> Int {
  try values.reduce(1) { a, b in
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    guard b >= 0, !overflow else { throw UVFParser.Error.invalid("size overflow") }
    return value
  }
}
