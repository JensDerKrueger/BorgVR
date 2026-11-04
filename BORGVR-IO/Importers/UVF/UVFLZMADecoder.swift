import Foundation

/// UVF uses raw LZMA1 (lc=3, lp=0, pb=2), without an end marker or
/// properties prefix. Apple Compression instead expects an XZ container.
/// The known brick size bounds the dictionary and terminates decoding.
enum UVFLZMADecoder {
  static func decode(_ data: Data, size: Int) throws -> Data {
    var decoder = try RangeDecoder(data)
    var output = Data(count: size)
    try output.withUnsafeMutableBytes { raw in
      let out = raw.bindMemory(to: UInt8.self)
      var position = 0, state = 0
      var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
      while position < size {
        let posState = position & 3
        if try decoder.bit(state * 16 + posState) == 0 {
          let previous = position == 0 ? 0 : Int(out[position - 1])
          let base = 1846 + (previous >> 5) * 768
          var symbol = 1
          if state >= 7 {
            guard rep0 < position else { throw UVFParser.Error.invalid("LZMA literal distance") }
            var match = Int(out[position - rep0 - 1])
            repeat {
              let matchBit = (match >> 7) & 1
              match = (match << 1) & 255
              let bit = try decoder.bit(base + ((1 + matchBit) << 8) + symbol)
              symbol = (symbol << 1) | bit
              if matchBit != bit { break }
            } while symbol < 256
          }
          while symbol < 256 { symbol = try (symbol << 1) | decoder.bit(base + symbol) }
          out[position] = UInt8(symbol - 256); position += 1
          state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
          continue
        }
        var length: Int
        if try decoder.bit(192 + state) == 1 {
          if try decoder.bit(204 + state) == 0 {
            if try decoder.bit(240 + state * 16 + posState) == 0 {
              state = state < 7 ? 9 : 11
              length = 1
            } else {
              length = try decoder.length(1332, posState: posState)
              state = state < 7 ? 8 : 11
            }
          } else {
            let distance: Int
            if try decoder.bit(216 + state) == 0 { distance = rep1 }
            else {
              if try decoder.bit(228 + state) == 0 { distance = rep2 }
              else { distance = rep3; rep3 = rep2 }
              rep2 = rep1
            }
            rep1 = rep0; rep0 = distance
            length = try decoder.length(1332, posState: posState)
            state = state < 7 ? 8 : 11
          }
        } else {
          rep3 = rep2; rep2 = rep1; rep1 = rep0
          length = try decoder.length(818, posState: posState)
          state = state < 7 ? 7 : 10
          let slot = try decoder.tree(432 + min(length - 2, 3) * 64, bits: 6)
          if slot < 4 { rep0 = slot }
          else {
            let bits = (slot >> 1) - 1
            rep0 = (2 | (slot & 1)) << bits
            if slot < 14 { rep0 += try decoder.reverseTree(688 + rep0 - slot - 1, bits: bits) }
            else {
              rep0 += try decoder.direct(bits - 4) << 4
              rep0 += try decoder.reverseTree(802, bits: 4)
            }
          }
        }
        guard rep0 >= 0, rep0 < position, length <= size - position else { throw UVFParser.Error.invalid("LZMA match bounds") }
        for _ in 0..<length { out[position] = out[position - rep0 - 1]; position += 1 }
      }
      guard decoder.code == 0, decoder.position == data.count else { throw UVFParser.Error.invalid("LZMA stream termination") }
    }
    return output
  }

  private struct RangeDecoder {
    let data: Data
    var position = 5
    var range = UInt32.max
    var code: UInt32 = 0
    var probabilities = [UInt16](repeating: 1024, count: 1846 + 768 * 8)

    init(_ data: Data) throws {
      guard data.count >= 5, data[0] == 0 else { throw UVFParser.Error.invalid("LZMA range header") }
      self.data = data
      for i in 1..<5 { code = (code << 8) | UInt32(data[i]) }
      guard code < UInt32.max else { throw UVFParser.Error.invalid("LZMA initial range") }
    }

    mutating func normalize() throws {
      if range < 1 << 24 {
        guard position < data.count else { throw UVFParser.Error.invalid("truncated LZMA stream") }
        range <<= 8
        code = (code << 8) | UInt32(data[position]); position += 1
      }
    }

    mutating func bit(_ index: Int) throws -> Int {
      let probability = UInt32(probabilities[index])
      let bound = (range >> 11) * probability
      let value: Int
      if code < bound {
        range = bound
        probabilities[index] += UInt16((2048 - probability) >> 5)
        value = 0
      } else {
        range -= bound; code -= bound
        probabilities[index] -= UInt16(probability >> 5)
        value = 1
      }
      try normalize()
      return value
    }

    mutating func tree(_ base: Int, bits: Int) throws -> Int {
      var symbol = 1
      for _ in 0..<bits { symbol = try (symbol << 1) | bit(base + symbol) }
      return symbol - (1 << bits)
    }

    mutating func reverseTree(_ base: Int, bits: Int) throws -> Int {
      var symbol = 1, value = 0
      for i in 0..<bits {
        let b = try bit(base + symbol)
        symbol = (symbol << 1) | b; value |= b << i
      }
      return value
    }

    mutating func direct(_ bits: Int) throws -> Int {
      var value = 0
      for _ in 0..<bits {
        range >>= 1
        let b = code >= range ? 1 : 0
        if b != 0 { code -= range }
        value = (value << 1) | b
        try normalize()
      }
      return value
    }

    mutating func length(_ base: Int, posState: Int) throws -> Int {
      if try bit(base) == 0 { return try 2 + tree(base + 2 + posState * 8, bits: 3) }
      if try bit(base + 1) == 0 { return try 10 + tree(base + 130 + posState * 8, bits: 3) }
      return try 18 + tree(base + 258, bits: 8)
    }
  }
}
