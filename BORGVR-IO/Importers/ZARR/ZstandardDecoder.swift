import Foundation

/// Bounded, dictionary-free Zstandard decoder, implemented from RFC 8878.
/// No external library, executable, or private platform API is used.
enum ZstandardDecoder {
  struct Error: Swift.Error, LocalizedError {
    let reason: String
    var errorDescription: String? { "Invalid or unsupported Zstandard data: \(reason)." }
  }

  static func decode(_ data: Data, expectedSize: Int) throws -> Data {
    guard data.count >= 4 else { throw Error(reason: "missing frame") }
    guard (0...(512 << 20)).contains(expectedSize) else { throw Error(reason: "chunk size exceeds limit") }
    var input = Cursor(bytes: Array(data))
    var output: [UInt8] = []
    output.reserveCapacity(expectedSize)
    while input.position < input.bytes.count {
      let magic = try input.integer(4)
      if (0x184d2a50...0x184d2a5f).contains(magic) {
        let count = try input.integer(4)
        _ = try input.take(count)
        continue
      }
      guard magic == 0xfd2fb528 else { throw Error(reason: "frame magic") }
      let descriptor = try input.integer(1)
      guard descriptor & 0x18 == 0 else { throw Error(reason: "reserved frame flags") }
      let single = descriptor & 0x20 != 0
      var window = 0
      if !single {
        let wd = try input.integer(1)
        let exponent = 10 + (wd >> 3)
        guard exponent <= 29 else { throw Error(reason: "window exceeds limit") }
        let base = 1 << exponent
        window = base + (base >> 3) * (wd & 7)
      }
      let dictionaryBytes = [0, 1, 2, 4][descriptor & 3]
      guard try input.integer(dictionaryBytes) == 0 else { throw Error(reason: "external dictionary required") }
      let sizeFlag = descriptor >> 6
      let sizeBytes = sizeFlag == 0 ? (single ? 1 : 0) : [0, 2, 4, 8][sizeFlag]
      let contentSize = sizeBytes == 0 ? nil : try input.integer(sizeBytes) + (sizeFlag == 1 ? 256 : 0)
      guard contentSize.map({ $0 <= expectedSize - output.count }) ?? true else {
        throw Error(reason: "frame content size exceeds expected size")
      }
      if single { window = contentSize ?? 0 }
      let frameStart = output.count
      var state = FrameState()
      var last = false
      repeat {
        let header = try input.integer(3)
        last = header & 1 != 0
        let kind = (header >> 1) & 3
        let size = header >> 3
        guard size <= min(128 << 10, window) else { throw Error(reason: "block size") }
        let before = output.count
        switch kind {
          case 0:
            guard size <= expectedSize - output.count else { throw Error(reason: "output overflow") }
            output.append(contentsOf: try input.take(size))
          case 1:
            let value = UInt8(try input.integer(1))
            guard size <= expectedSize - output.count else { throw Error(reason: "output overflow") }
            output.append(contentsOf: repeatElement(value, count: size))
          case 2:
            var block = Cursor(bytes: try input.take(size))
            try state.decodeBlock(&block, output: &output, limit: min(expectedSize, before + min(128 << 10, window)),
                                  frameStart: frameStart, window: window)
          default: throw Error(reason: "reserved block type")
        }
        guard output.count - before <= min(128 << 10, window) else { throw Error(reason: "decoded block size") }
      } while !last
      guard contentSize.map({ $0 == output.count - frameStart }) ?? true else {
        throw Error(reason: "frame content size mismatch")
      }
      if descriptor & 4 != 0 {
        let checksum = UInt32(try input.integer(4))
        guard checksum == UInt32(truncatingIfNeeded: xxhash64(Array(output[frameStart...]))) else {
          throw Error(reason: "frame checksum mismatch")
        }
      }
    }
    guard output.count == expectedSize else { throw Error(reason: "decoded chunk size mismatch") }
    return Data(output)
  }

  private struct Cursor {
    let bytes: [UInt8]
    var position = 0
    mutating func take(_ count: Int) throws -> [UInt8] {
      guard count >= 0, count <= bytes.count - position else { throw Error(reason: "truncated data") }
      defer { position += count }
      return Array(bytes[position..<(position + count)])
    }
    mutating func integer(_ count: Int) throws -> Int {
      var value: UInt64 = 0
      for (i, byte) in try take(count).enumerated() { value |= UInt64(byte) << (8 * i) }
      guard value <= UInt64(Int.max) else { throw Error(reason: "integer overflow") }
      return Int(value)
    }
  }

  private struct Bits {
    let bytes: [UInt8]
    var position: Int
    let reversed: Bool
    init(_ bytes: [UInt8], reversed: Bool) throws {
      self.bytes = bytes
      self.reversed = reversed
      if reversed {
        guard let last = bytes.last, last != 0 else { throw Error(reason: "missing bitstream end marker") }
        position = (bytes.count - 1) * 8 + 7 - last.leadingZeroBitCount
      } else { position = 0 }
    }
    var remaining: Int { reversed ? position : bytes.count * 8 - position }
    func peek(_ count: Int, padded: Bool = false) throws -> Int {
      guard (0...32).contains(count), padded || count <= remaining else {
        throw Error(reason: "truncated bitstream")
      }
      let available = min(count, remaining)
      let start = reversed ? position - available : position
      var value = 0
      for i in 0..<available { value |= Int((bytes[(start + i) >> 3] >> ((start + i) & 7)) & 1) << i }
      return reversed ? value << (count - available) : value
    }
    mutating func read(_ count: Int) throws -> Int {
      let value = try peek(count)
      position += reversed ? -count : count
      return value
    }
  }

  private struct FSE {
    struct Entry { let symbol: Int; let bits: Int; let base: Int }
    let log: Int
    let entries: [Entry]

    init(symbol: Int) { log = 0; entries = [Entry(symbol: symbol, bits: 0, base: 0)] }

    init(counts: [Int], log: Int) throws {
      guard (5...9).contains(log), counts.reduce(0, { $0 + abs($1) }) == 1 << log else {
        throw Error(reason: "FSE distribution")
      }
      let size = 1 << log
      var symbols = [Int](repeating: 0, count: size)
      var high = size - 1
      for (symbol, count) in counts.enumerated() where count == -1 {
        symbols[high] = symbol; high -= 1
      }
      let step = (size >> 1) + (size >> 3) + 3
      var position = 0
      for (symbol, count) in counts.enumerated() where count > 0 {
        for _ in 0..<count {
          symbols[position] = symbol
          position = (position + step) & (size - 1)
          while position > high { position = (position + step) & (size - 1) }
        }
      }
      guard position == 0 else { throw Error(reason: "FSE table spread") }
      var next = counts.map { max(1, $0) }
      var result: [Entry] = []
      for symbol in symbols {
        let value = next[symbol]
        next[symbol] += 1
        let bits = log - Self.floorLog(value)
        result.append(Entry(symbol: symbol, bits: bits, base: (value << bits) - size))
      }
      self.log = log; entries = result
    }

    static func read(_ input: inout Cursor, maxSymbol: Int, maxLog: Int) throws -> FSE {
      var bits = try Bits(Array(input.bytes[input.position...]), reversed: false)
      let log = try bits.read(4) + 5
      guard log <= maxLog else { throw Error(reason: "FSE accuracy log") }
      var remaining = (1 << log) + 1
      var counts: [Int] = []
      while remaining > 1 {
        guard counts.count <= maxSymbol else { throw Error(reason: "too many FSE symbols") }
        let n = floorLog(remaining) + 1
        let threshold = 1 << (n - 1)
        let maximum = 2 * threshold - 1 - remaining
        let small = try bits.peek(n - 1)
        var count: Int
        if small < maximum { count = try bits.read(n - 1) }
        else {
          count = try bits.read(n)
          if count >= threshold { count -= maximum }
        }
        count -= 1
        remaining -= abs(count)
        guard remaining >= 1 else { throw Error(reason: "FSE probability overflow") }
        counts.append(count)
        if count == 0 {
          var repeatCount: Int
          repeat {
            repeatCount = try bits.read(2)
            guard counts.count + repeatCount <= maxSymbol + 1 else { throw Error(reason: "FSE zero run") }
            counts.append(contentsOf: repeatElement(0, count: repeatCount))
          } while repeatCount == 3
        }
      }
      input.position += (bits.position + 7) / 8
      return try FSE(counts: counts, log: log)
    }

    static func floorLog(_ value: Int) -> Int { Int.bitWidth - 1 - value.leadingZeroBitCount }
  }

  private struct Huffman {
    let log: Int
    let symbols: [Int]
    let lengths: [Int]

    init(_ input: inout Cursor) throws {
      let header = try input.integer(1)
      var weights: [Int] = []
      if header >= 128 {
        let count = header - 127
        for byte in try input.take((count + 1) / 2) { weights += [Int(byte >> 4), Int(byte & 15)] }
        weights = Array(weights.prefix(count))
      } else {
        var compressed = Cursor(bytes: try input.take(header))
        let table = try FSE.read(&compressed, maxSymbol: 11, maxLog: 6)
        var bits = try Bits(Array(compressed.bytes[compressed.position...]), reversed: true)
        var states = [try bits.read(table.log), try bits.read(table.log)]
        var turn = 0
        while true {
          guard weights.count < 255 else { throw Error(reason: "too many Huffman weights") }
          let entry = table.entries[states[turn]]
          weights.append(entry.symbol)
          if entry.bits > bits.remaining {
            weights.append(table.entries[states[1 - turn]].symbol)
            break
          }
          states[turn] = entry.base + (try bits.read(entry.bits))
          turn = 1 - turn
        }
      }
      guard weights.count <= 255, weights.allSatisfy({ (0...11).contains($0) }) else {
        throw Error(reason: "Huffman weights")
      }
      let total = weights.reduce(0) { $0 + ($1 == 0 ? 0 : 1 << ($1 - 1)) }
      guard total > 0 else { throw Error(reason: "empty Huffman table") }
      log = FSE.floorLog(total) + 1
      guard log <= 11 else { throw Error(reason: "Huffman depth") }
      let rest = (1 << log) - total
      guard rest > 0, rest & (rest - 1) == 0 else { throw Error(reason: "incomplete Huffman tree") }
      weights.append(FSE.floorLog(rest) + 1)
      var symbols = [Int](repeating: 0, count: 1 << log)
      var lengths = symbols
      var cursor = 0
      for weight in 1...log {
        for (symbol, w) in weights.enumerated() where w == weight {
          let count = 1 << (weight - 1)
          guard count <= symbols.count - cursor else { throw Error(reason: "Huffman table overflow") }
          for i in cursor..<(cursor + count) { symbols[i] = symbol; lengths[i] = log + 1 - weight }
          cursor += count
        }
      }
      guard cursor == symbols.count else { throw Error(reason: "Huffman table size") }
      self.symbols = symbols; self.lengths = lengths
    }

    func decode(_ bytes: [UInt8], count: Int) throws -> [UInt8] {
      var bits = try Bits(bytes, reversed: true)
      var output: [UInt8] = []
      output.reserveCapacity(count)
      for _ in 0..<count {
        let index = try bits.peek(log, padded: true)
        _ = try bits.read(lengths[index])
        output.append(UInt8(symbols[index]))
      }
      guard bits.remaining == 0 else { throw Error(reason: "Huffman stream size mismatch") }
      return output
    }
  }

  private struct FrameState {
    var huffman: Huffman?
    var tables: [FSE?] = [nil, nil, nil]
    var offsets = [1, 4, 8]

    mutating func literals(_ input: inout Cursor) throws -> [UInt8] {
      let first = try input.integer(1)
      let kind = first & 3, format = (first >> 2) & 3
      if kind < 2 {
        let size: Int
        switch format {
          case 0, 2: size = first >> 3
          case 1: size = (first >> 4) | (try input.integer(1) << 4)
          default: size = (first >> 4) | (try input.integer(2) << 4)
        }
        guard size <= 128 << 10 else { throw Error(reason: "literal size") }
        return kind == 0 ? try input.take(size) : Array(repeating: UInt8(try input.integer(1)), count: size)
      }
      let fieldBits = [10, 10, 14, 18][format]
      let header = first | (try input.integer([2, 2, 3, 4][format]) << 8)
      let regenerated = (header >> 4) & ((1 << fieldBits) - 1)
      let compressedSize = header >> (4 + fieldBits)
      guard regenerated <= 128 << 10 else { throw Error(reason: "literal size") }
      var compressed = Cursor(bytes: try input.take(compressedSize))
      if kind == 2 { huffman = try Huffman(&compressed) }
      guard let huffman else { throw Error(reason: "missing Huffman table") }
      if format == 0 { return try huffman.decode(Array(compressed.bytes[compressed.position...]), count: regenerated) }
      let sizes = [try compressed.integer(2), try compressed.integer(2), try compressed.integer(2)]
      let segment = (regenerated + 3) / 4
      guard regenerated >= 3 * segment else { throw Error(reason: "four-stream literal size") }
      var output: [UInt8] = []
      for i in 0..<4 {
        let count = i == 3 ? regenerated - 3 * segment : segment
        let length = i == 3 ? compressed.bytes.count - compressed.position : sizes[i]
        output += try huffman.decode(compressed.take(length), count: count)
      }
      return output
    }

    mutating func decodeBlock(_ input: inout Cursor, output: inout [UInt8], limit: Int,
                              frameStart: Int, window: Int) throws {
      let literals = try literals(&input)
      let first = try input.integer(1)
      let count: Int
      if first < 128 { count = first }
      else if first < 255 { count = ((first - 128) << 8) + (try input.integer(1)) }
      else { count = (try input.integer(2)) + 0x7f00 }
      if count == 0 {
        guard input.position == input.bytes.count, literals.count <= limit - output.count else {
          throw Error(reason: "literal-only block size")
        }
        output += literals
        return
      }
      let modes = try input.integer(1)
      guard modes & 3 == 0 else { throw Error(reason: "reserved sequence flags") }
      for i in 0..<3 {
        let mode = (modes >> (6 - i * 2)) & 3
        switch mode {
          case 0: tables[i] = try FSE(counts: Self.distributions[i], log: i == 1 ? 5 : 6)
          case 1:
            let symbol = try input.integer(1)
            guard symbol <= [35, 31, 52][i] else { throw Error(reason: "RLE sequence symbol") }
            tables[i] = FSE(symbol: symbol)
          case 2: tables[i] = try FSE.read(&input, maxSymbol: [35, 31, 52][i], maxLog: i == 1 ? 8 : 9)
          default: guard tables[i] != nil else { throw Error(reason: "missing repeated FSE table") }
        }
      }
      let ll = tables[0]!, of = tables[1]!, ml = tables[2]!
      var bits = try Bits(Array(input.bytes[input.position...]), reversed: true)
      var states = [try bits.read(ll.log), try bits.read(of.log), try bits.read(ml.log)]
      var literalPosition = 0
      for sequence in 0..<count {
        let l = ll.entries[states[0]], o = of.entries[states[1]], m = ml.entries[states[2]]
        let offsetValue = (1 << o.symbol) + (try bits.read(o.symbol))
        let matchLength = Self.matchBases[m.symbol] + (try bits.read(Self.matchBits[m.symbol]))
        let literalLength = Self.literalBases[l.symbol] + (try bits.read(Self.literalBits[l.symbol]))
        let distance: Int
        if offsetValue > 3 {
          distance = offsetValue - 3
          offsets = [distance, offsets[0], offsets[1]]
        } else {
          let index = offsetValue - 1 + (literalLength == 0 ? 1 : 0)
          distance = index == 3 ? offsets[0] - 1 : offsets[index]
          if index != 0 {
            if index < 3 { offsets.remove(at: index) } else { offsets.removeLast() }
            offsets.insert(distance, at: 0)
          }
        }
        guard literalLength <= literals.count - literalPosition,
              literalLength <= limit - output.count else { throw Error(reason: "literal copy exceeds output") }
        output.append(contentsOf: literals[literalPosition..<(literalPosition + literalLength)])
        literalPosition += literalLength
        guard distance > 0, distance <= min(window, output.count - frameStart),
              matchLength <= limit - output.count else { throw Error(reason: "invalid match distance or length") }
        for _ in 0..<matchLength { output.append(output[output.count - distance]) }
        if sequence + 1 < count {
          states[0] = l.base + (try bits.read(l.bits))
          states[2] = m.base + (try bits.read(m.bits))
          states[1] = o.base + (try bits.read(o.bits))
        }
      }
      guard bits.remaining == 0, literals.count - literalPosition <= limit - output.count else {
        throw Error(reason: "sequence bitstream size mismatch")
      }
      output.append(contentsOf: literals[literalPosition...])
    }

    // RFC 8878 sections 3.1.1.3.2.1 and 3.1.1.3.2.2 (format constants).
    static let literalBases = Array(0...15) + [16,18,20,22,24,28,32,40,48,64,128,256,512,1024,2048,4096,8192,16384,32768,65536]
    static let literalBits = Array(repeating: 0, count: 16) + [1,1,1,1,2,2,3,3,4,6,7,8,9,10,11,12,13,14,15,16]
    static let matchBases = Array(3...34) + [35,37,39,41,43,47,51,59,67,83,99,131,259,515,1027,2051,4099,8195,16387,32771,65539]
    static let matchBits = Array(repeating: 0, count: 32) + [1,1,1,1,2,2,3,3,4,4,5,7,8,9,10,11,12,13,14,15,16]
    static let distributions = [
      [4,3,2,2,2,2,2,2,2,2,2,2,2,1,1,1,2,2,2,2,2,2,2,2,2,3,2,1,1,1,1,1,-1,-1,-1,-1],
      [1,1,1,1,1,1,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1],
      [1,4,3,2,2,2,2,2,2,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,-1,-1,-1,-1,-1,-1,-1]
    ]
  }

  private static func xxhash64(_ bytes: [UInt8]) -> UInt64 {
    let p1: UInt64 = 11400714785074694791, p2: UInt64 = 14029467366897019727
    let p3: UInt64 = 1609587929392839161, p4: UInt64 = 9650029242287828579, p5: UInt64 = 2870177450012600261
    func rotate(_ x: UInt64, _ n: Int) -> UInt64 { (x << n) | (x >> (64 - n)) }
    func word(_ offset: Int, _ count: Int) -> UInt64 {
      (0..<count).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
    func round(_ v: UInt64, _ x: UInt64) -> UInt64 { rotate(v &+ x &* p2, 31) &* p1 }
    var i = 0
    var hash: UInt64
    if bytes.count >= 32 {
      var v = [p1 &+ p2, p2, 0, 0 &- p1]
      while i <= bytes.count - 32 {
        for j in 0..<4 { v[j] = round(v[j], word(i + j * 8, 8)) }
        i += 32
      }
      hash = rotate(v[0], 1) &+ rotate(v[1], 7) &+ rotate(v[2], 12) &+ rotate(v[3], 18)
      for value in v { hash = (hash ^ round(0, value)) &* p1 &+ p4 }
    } else { hash = p5 }
    hash &+= UInt64(bytes.count)
    while i + 8 <= bytes.count { hash = rotate(hash ^ round(0, word(i, 8)), 27) &* p1 &+ p4; i += 8 }
    if i + 4 <= bytes.count { hash = rotate(hash ^ (word(i, 4) &* p1), 23) &* p2 &+ p3; i += 4 }
    while i < bytes.count { hash = rotate(hash ^ (UInt64(bytes[i]) &* p5), 11) &* p1; i += 1 }
    hash ^= hash >> 33; hash &*= p2; hash ^= hash >> 29; hash &*= p3; hash ^= hash >> 32
    return hash
  }
}
