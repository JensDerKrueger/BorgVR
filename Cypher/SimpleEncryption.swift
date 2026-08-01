import Foundation
import Security

public enum SimpleEncryption {

  public enum Error: Swift.Error, CustomStringConvertible {
    case invalidUUID
    case negativeChunkIndex
    case saltGen
    case saltDecode

    public var description: String {
      switch self {
        case .invalidUUID:
          return "Invalid UUID"
        case .negativeChunkIndex:
          return "chunkIndex must be >= 0"
        case .saltGen:
          return "Unable to generate session salt"
        case .saltDecode:
          return "Unable to decode session salt"
      }
    }
  }

  // MARK: - Public API

  public class Context {
    let uuidBytes : [UInt8]
    let key: [UInt8]
    let saltBytes: [UInt8]

    init(passphrase: String, uuidString: String, saltBytes: [UInt8]) throws {

      if let u = UUID(uuidString: uuidString) {
        var t = u.uuid  // tuple of 16 UInt8
        self.uuidBytes = withUnsafeBytes(of: &t) { raw -> [UInt8] in
          Array(raw)
        }
      } else {
        throw SimpleEncryption.Error.invalidUUID
      }

      self.saltBytes = saltBytes

      self.key = KeyDerivation.deriveKey(passphrase: passphrase, uuidBytes: uuidBytes, saltBytes:saltBytes)
    }
  }

  static func cypher(payload: Data,
                     context: Context,
                     chunkIndex: Int) throws -> Data {
    if payload.isEmpty { return Data() }
    guard chunkIndex >= 0 else { throw Error.negativeChunkIndex }

    let nonce = KeyDerivation.deriveNonce(uuidBytes: context.uuidBytes, chunkIndex: UInt64(chunkIndex),
                                          saltBytes:context.saltBytes)

    var out = payload
    out.withUnsafeMutableBytes { rawBuf in
      guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
      ChaCha20.xorInPlace(data: base, length: rawBuf.count, key: context.key, nonce: nonce)
    }

    return out
  }

  static func cypher(payload: Data,
                     passphrase: String,
                     uuid: String,
                     salt: String,
                     chunkIndex: Int) throws -> Data {
    let context = try Context(passphrase: passphrase, uuidString:uuid, saltBytes:try decodeSaltString(salt))
    return try cypher(payload: payload, context: context, chunkIndex: chunkIndex)
  }

  static func generateSaltBytes(count: Int = 32) throws -> [UInt8] {
    precondition(count > 0)

    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw SimpleEncryption.Error.saltGen
    }
    return bytes
  }


  static func encodeSaltString(_ salt: [UInt8], urlSafeBase64: Bool = true) -> String {
    let b64 = Data(salt).base64EncodedString()
    guard urlSafeBase64 else { return b64 }
    return b64
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decodeSaltString(_ saltString: String) throws -> [UInt8] {
    // Accept Base64URL or standard Base64
    var s = saltString
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    // restore padding if missing
    let mod = s.count % 4
    if mod != 0 {
      s += String(repeating: "=", count: 4 - mod)
    }

    guard let data = Data(base64Encoded: s) else {
      throw SimpleEncryption.Error.saltDecode
    }
    return [UInt8](data)
  }

}


// MARK: - Key + nonce derivation

private enum KeyDerivation {

  /// key = SHA256(passphraseBytes || saltBytes || uuidBytes)
  static func deriveKey(passphrase: String, uuidBytes: [UInt8], saltBytes: [UInt8]) -> [UInt8] {
    var sha = SHA256()
    sha.update(bytes: Array(passphrase.utf8))
    sha.update(bytes: saltBytes)
    sha.update(bytes: uuidBytes)
    return sha.finalize()
  }

  /// nonce = first12( SHA256(uuidBytes || saltBytes || littleEndianUInt64(chunkIndex)) )
  static func deriveNonce(uuidBytes: [UInt8], chunkIndex: UInt64, saltBytes: [UInt8]) -> [UInt8] {
    // Layout: uuid(16) || salt(N) || chunkIndexLE(8)
    var tmp = [UInt8]()
    tmp.reserveCapacity(16 + saltBytes.count + 8)

    tmp.append(contentsOf: uuidBytes[0..<16])
    tmp.append(contentsOf: saltBytes)
    tmp.append(contentsOf: le64(chunkIndex))

    var sha = SHA256()
    sha.update(bytes: tmp)
    let digest = sha.finalize()
    return Array(digest[0..<12])
  }

  private static func le64(_ value: UInt64) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 8)
    for i in 0..<8 {
      out[i] = UInt8((value >> UInt64(8 * i)) & 0xFF)
    }
    return out
  }
}


// MARK: - SHA-256

private struct SHA256 {

  private var totalLen: UInt64 = 0 // in bytes
  private var h: [UInt32] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ]
  private var buffer = [UInt8](repeating: 0, count: 64)
  private var bufferLen: Int = 0

  // Same constants as in the C++ file.
  private static let k: [UInt32] = [
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
  ]

  mutating func update(bytes: [UInt8]) {
    bytes.withUnsafeBytes { rawBuf in
      update(raw: rawBuf)
    }
  }

  mutating func update(raw: UnsafeRawBufferPointer) {
    let p = raw.bindMemory(to: UInt8.self)
    var remaining = p.count
    var idx = 0

    totalLen &+= UInt64(remaining)

    while remaining > 0 {
      let take = min(remaining, 64 - bufferLen)
      buffer.withUnsafeMutableBytes { buf in
        buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
          .advanced(by: bufferLen)
          .update(from: p.baseAddress!.advanced(by: idx), count: take)
      }
      bufferLen += take
      idx += take
      remaining -= take

      if bufferLen == 64 {
        compress(block: buffer)
        bufferLen = 0
      }
    }
  }

  mutating func finalize() -> [UInt8] {
    // Capture bit length BEFORE padding (matches C++ code)
    let bitLen = totalLen &* 8

    // Pad: 0x80 then zeros
    var pad = [UInt8](repeating: 0, count: 64)
    pad[0] = 0x80

    let padLen: Int = (bufferLen < 56) ? (56 - bufferLen) : (120 - bufferLen)
    pad.withUnsafeBytes { raw in
      let p = raw.baseAddress!
      update(raw: UnsafeRawBufferPointer(start: p, count: padLen))
    }

    // Append big-endian length
    var lenBe = [UInt8](repeating: 0, count: 8)
    for i in 0..<8 {
      lenBe[i] = UInt8((bitLen >> UInt64(56 - 8 * i)) & 0xFF)
    }
    update(bytes: lenBe)

    // Output big-endian words
    var out = [UInt8](repeating: 0, count: 32)
    for i in 0..<8 {
      let v = h[i]
      out[4*i + 0] = UInt8((v >> 24) & 0xFF)
      out[4*i + 1] = UInt8((v >> 16) & 0xFF)
      out[4*i + 2] = UInt8((v >> 8) & 0xFF)
      out[4*i + 3] = UInt8(v & 0xFF)
    }
    return out
  }

  private mutating func compress(block: [UInt8]) {
    var w = [UInt32](repeating: 0, count: 64)

    // big-endian load for SHA-256 message schedule
    for i in 0..<16 {
      let j = 4 * i
      w[i] = (UInt32(block[j]) << 24)
      | (UInt32(block[j+1]) << 16)
      | (UInt32(block[j+2]) << 8)
      | UInt32(block[j+3])
    }

    for i in 16..<64 {
      w[i] = smallSigma1(w[i-2]) &+ w[i-7] &+ smallSigma0(w[i-15]) &+ w[i-16]
    }

    var a = h[0], b = h[1], c = h[2], d = h[3]
    var e = h[4], f = h[5], g = h[6], hh = h[7]

    for i in 0..<64 {
      let t1 = hh &+ bigSigma1(e) &+ ch(e, f, g) &+ SHA256.k[i] &+ w[i]
      let t2 = bigSigma0(a) &+ maj(a, b, c)
      hh = g
      g = f
      f = e
      e = d &+ t1
      d = c
      c = b
      b = a
      a = t1 &+ t2
    }

    h[0] = h[0] &+ a
    h[1] = h[1] &+ b
    h[2] = h[2] &+ c
    h[3] = h[3] &+ d
    h[4] = h[4] &+ e
    h[5] = h[5] &+ f
    h[6] = h[6] &+ g
    h[7] = h[7] &+ hh
  }

  @inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
    return (x >> n) | (x << (32 - n))
  }
  @inline(__always) private func ch(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
    return (x & y) ^ (~x & z)
  }
  @inline(__always) private func maj(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
    return (x & y) ^ (x & z) ^ (y & z)
  }
  @inline(__always) private func bigSigma0(_ x: UInt32) -> UInt32 {
    return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22)
  }
  @inline(__always) private func bigSigma1(_ x: UInt32) -> UInt32 {
    return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25)
  }
  @inline(__always) private func smallSigma0(_ x: UInt32) -> UInt32 {
    return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3)
  }
  @inline(__always) private func smallSigma1(_ x: UInt32) -> UInt32 {
    return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10)
  }
}

// MARK: - ChaCha20

private enum ChaCha20 {

  static func xorInPlace(data: UnsafeMutablePointer<UInt8>,
                         length: Int,
                         key: [UInt8],
                         nonce: [UInt8],
                         counterStart: UInt32 = 0) {
    precondition(key.count == 32)
    precondition(nonce.count == 12)

    var counter = counterStart
    var offset = 0

    var block = [UInt8](repeating: 0, count: 64)

    while offset < length {
      chacha20Block(out: &block, key: key, counter: counter, nonce: nonce)
      counter &+= 1

      let take = min(64, length - offset)
      for i in 0..<take {
        data[offset + i] ^= block[i]
      }
      offset += take
    }
  }

  private static func chacha20Block(out: inout [UInt8],
                                    key: [UInt8],
                                    counter: UInt32,
                                    nonce: [UInt8]) {
    // Same constants as C++ loads from "expand 32-byte k" in little-endian
    var state = [UInt32](repeating: 0, count: 16)
    state[0] = 0x61707865
    state[1] = 0x3320646e
    state[2] = 0x79622d32
    state[3] = 0x6b206574

    for i in 0..<8 {
      state[4 + i] = loadLe32(from: key, offset: 4 * i)
    }

    state[12] = counter
    state[13] = loadLe32(from: nonce, offset: 0)
    state[14] = loadLe32(from: nonce, offset: 4)
    state[15] = loadLe32(from: nonce, offset: 8)

    var x = state

    for _ in 0..<10 {
      // Column rounds
      quarterRound(&x, 0, 4, 8, 12)
      quarterRound(&x, 1, 5, 9, 13)
      quarterRound(&x, 2, 6, 10, 14)
      quarterRound(&x, 3, 7, 11, 15)

      // Diagonal rounds
      quarterRound(&x, 0, 5, 10, 15)
      quarterRound(&x, 1, 6, 11, 12)
      quarterRound(&x, 2, 7, 8, 13)
      quarterRound(&x, 3, 4, 9, 14)
    }

    for i in 0..<16 {
      x[i] = x[i] &+ state[i]
      storeLe32(into: &out, offset: 4 * i, value: x[i])
    }
  }

  @inline(__always)
  private static func rotl32(_ x: UInt32, _ n: UInt32) -> UInt32 {
    return (x << n) | (x >> (32 - n))
  }

  /// Quarter round operating on indices to satisfy Swift's exclusive access rules.
  @inline(__always)
  private static func quarterRound(_ x: inout [UInt32], _ ai: Int, _ bi: Int, _ ci: Int, _ di: Int) {
    var a = x[ai]
    var b = x[bi]
    var c = x[ci]
    var d = x[di]

    a = a &+ b; d ^= a; d = rotl32(d, 16)
    c = c &+ d; b ^= c; b = rotl32(b, 12)
    a = a &+ b; d ^= a; d = rotl32(d, 8)
    c = c &+ d; b ^= c; b = rotl32(b, 7)

    x[ai] = a
    x[bi] = b
    x[ci] = c
    x[di] = d
  }

  @inline(__always)
  private static func loadLe32(from bytes: [UInt8], offset: Int) -> UInt32 {
    return UInt32(bytes[offset])
    | (UInt32(bytes[offset + 1]) << 8)
    | (UInt32(bytes[offset + 2]) << 16)
    | (UInt32(bytes[offset + 3]) << 24)
  }

  @inline(__always)
  private static func storeLe32(into out: inout [UInt8], offset: Int, value: UInt32) {
    out[offset + 0] = UInt8(value & 0xFF)
    out[offset + 1] = UInt8((value >> 8) & 0xFF)
    out[offset + 2] = UInt8((value >> 16) & 0xFF)
    out[offset + 3] = UInt8((value >> 24) & 0xFF)
  }
}

