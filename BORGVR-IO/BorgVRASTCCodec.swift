import Foundation
import simd

/// Fast experimental LDR encoder: one partition, direct RGBA endpoints, two-bit weights.
/// 4x4/8x8 footprints share single-plane 4x4 and dual-plane 4x2/2x4 weight grids.
/// Bit layout: https://github.com/KhronosGroup/DataFormat/blob/main/astc.txt
enum BorgVRASTCCodec {
  static func decodeInPlace(_ buffer: UnsafeMutablePointer<UInt8>, metadata: BORGVRMetaData) throws {
    let block = metadata.channelInterpretation.astcBlockSize
    guard block != 0 else { return }
    let encoded = Array(UnsafeBufferPointer(start: buffer, count: try metadata.fullBrickByteCount()))
    try encoded.withUnsafeBufferPointer {
      try decode($0.baseAddress!, brickSize: metadata.brickSize, components: metadata.componentCount,
        blockSize: block, output: buffer)
    }
  }

  /// Direct RGBA endpoint bounds conservatively include all interpolated alpha values.
  static func conservativeRanges(_ encoded: [UInt8], components: Int) -> [BORGVRComponentRange] {
    guard components == 4 else { return [] }
    var low = 255, high = 0
    for offset in stride(from: 0, to: encoded.count, by: 16) {
      func bits(_ start: Int, _ count: Int) -> Int {
        var value = 0
        for bit in 0..<count { value |= Int((encoded[offset + (start + bit) / 8] >> ((start + bit) % 8)) & 1) << bit }
        return value
      }
      if bits(0, 9) == 0x1FC {
        let alpha = bits(112, 16)
        low = min(low, alpha / 257); high = max(high, (alpha + 256) / 257)
      } else {
        let a = bits(65, 8), b = bits(73, 8)
        low = min(low, min(a, b)); high = max(high, max(a, b))
      }
    }
    return [.init(minValue: low, maxValue: high)]
  }

  /// Software fallback for the LDR block modes emitted by this encoder. Stored ASTC
  /// always uses sliced 2D blocks; unsupported encodings fail instead of producing voxels.
  static func decode(_ input: UnsafePointer<UInt8>, brickSize: Int, components: Int,
                     blockSize: Int, output: UnsafeMutablePointer<UInt8>) throws {
    guard [4, 8].contains(blockSize), brickSize > 0, brickSize % blockSize == 0,
          [3, 4].contains(components) else { throw BORGVRError.other("Invalid ASTC brick layout.") }
    let blocks = brickSize / blockSize
    for z in 0..<brickSize { for by in 0..<blocks { for bx in 0..<blocks {
      let bytes = input.advanced(by: ((z * blocks + by) * blocks + bx) * 16)
      func bits(_ offset: Int, _ count: Int) -> Int {
        var value = 0
        for bit in 0..<count { value |= Int((bytes[(offset + bit) / 8] >> ((offset + bit) % 8)) & 1) << bit }
        return value
      }
      let mode = bits(0, 11)
      var a = SIMD4<Int>.zero, b = SIMD4<Int>.zero
      let constant = mode & 0x1FF == 0x1FC
      var gridX = 4, gridY = 4, planes = 1
      if constant {
        guard mode & 0x200 == 0 else { throw BORGVRError.other("Unsupported ASTC HDR block.") }
        for c in 0..<4 { a[c] = (bits(64 + 16 * c, 16) + 128) / 257 }
      } else {
        switch mode {
          case 0x42: break
          case 0x402: gridY = 2; planes = 2
          case 0x54E: gridX = 2; planes = 2
          default: throw BORGVRError.other("Unsupported ASTC software decoding mode: \(mode).")
        }
        guard bits(11, 2) == 0, bits(13, 4) == 12,
              planes == 1 || bits(94, 2) == 3 else { throw BORGVRError.other("Unsupported ASTC endpoint encoding.") }
        for c in 0..<4 { a[c] = bits(17 + c * 16, 8); b[c] = bits(25 + c * 16, 8) }
        if a.x + a.y + a.z > b.x + b.y + b.z {
          a.x = (a.x + a.z) / 2; a.y = (a.y + a.z) / 2
          b.x = (b.x + b.z) / 2; b.y = (b.y + b.z) / 2
          swap(&a, &b)
        }
      }
      var weights = [Int](repeating: 0, count: 16)
      if !constant {
        let unquantized = [0, 21, 43, 64]
        for i in 0..<16 { weights[i] = unquantized[bits(127 - i * 2, 1) | (bits(126 - i * 2, 1) << 1)] }
      }
      let scale = (1024 + blockSize / 2) / (blockSize - 1)
      for y in 0..<blockSize { for x in 0..<blockSize {
        let sx = (scale * x * (gridX - 1) + 32) >> 6, sy = (scale * y * (gridY - 1) + 32) >> 6
        let ix = sx >> 4, iy = sy >> 4, fx = sx & 15, fy = sy & 15
        let w11 = (fx * fy + 8) >> 4
        let factors = [16 - fx - fy + w11, fx - w11, fy - w11, w11]
        let offset = ((z * brickSize + by * blockSize + y) * brickSize + bx * blockSize + x) * components
        for c in 0..<components {
          var weight = 8
          if !constant {
            for corner in 0..<4 where factors[corner] != 0 {
              weight += factors[corner] * weights[((iy + corner / 2) * gridX + ix + corner % 2) * planes + (planes == 2 && c == 3 ? 1 : 0)]
            }
          }
          output[offset + c] = UInt8(constant ? a[c] : (a[c] * (64 - (weight >> 4)) + b[c] * (weight >> 4) + 32) >> 6)
        }
      } }
    } } }
  }

  static func encode(_ input: UnsafePointer<UInt8>, brickSize b: Int, components: Int,
                     blockSize: Int) -> [UInt8] {
    precondition((blockSize == 4 || blockSize == 8) && b > 0 && b % blockSize == 0 && (components == 3 || components == 4))
    let blocks = b / blockSize
    var output = [UInt8](repeating: 0, count: blocks * blocks * b * 16)
    var pixels = [SIMD4<Float>](repeating: .zero, count: blockSize * blockSize)
    for z in 0..<b { for by in 0..<blocks { for bx in 0..<blocks {
      for y in 0..<blockSize { for x in 0..<blockSize {
        let i = ((z * b + by * blockSize + y) * b + bx * blockSize + x) * components
        pixels[y * blockSize + x] = SIMD4(Float(input[i]), Float(input[i + 1]), Float(input[i + 2]),
          components == 4 ? Float(input[i + 3]) : 255)
      } }
      let offset = ((z * blocks + by) * blocks + bx) * 16
      let block = encodeBlock(pixels, size: blockSize)
      for i in 0..<16 { output[offset + i] = UInt8(truncatingIfNeeded: block[i / 4] >> ((i % 4) * 8)) }
    } } }
    return output
  }

  private struct Candidate {
    var block: SIMD4<UInt32>
    var error: Float
  }

  private static func encodeBlock(_ pixels: [SIMD4<Float>], size: Int) -> SIMD4<UInt32> {
    if pixels.allSatisfy({ $0 == pixels[0] }) {
      let p = SIMD4<UInt32>(pixels[0]) &* 257
      return SIMD4(0xFFFFFDFC, .max, p.x | (p.y << 16), p.z | (p.w << 16))
    }
    var best = candidate(pixels, size: size, gridX: 4, gridY: 4, dual: false)
    if pixels.contains(where: { $0.w != pixels[0].w }) {
      for (x, y) in [(4, 2), (2, 4)] {
        let next = candidate(pixels, size: size, gridX: x, gridY: y, dual: true)
        if next.error < best.error { best = next }
      }
    }
    return best.block
  }

  private static func candidate(_ pixels: [SIMD4<Float>], size: Int, gridX: Int, gridY: Int, dual: Bool) -> Candidate {
    let mean = pixels.reduce(.zero, +) / Float(pixels.count)
    var low = pixels[0], high = pixels[0]
    for p in pixels { low = simd_min(low, p); high = simd_max(high, p) }
    var span = high - low
    if dual { span.w = 0 }
    // A diagonal seed can be perpendicular to perfectly anticorrelated color channels.
    let component = (0..<4).max { span[$0] < span[$1] }!
    var axis = SIMD4<Float>.zero
    axis[component] = 1
    for _ in 0..<4 {
      let length = simd_length(axis)
      if length < 0.0001 { break }
      axis /= length
      var next = SIMD4<Float>.zero
      for p in pixels {
        var d = p - mean
        if dual { d.w = 0 }
        next += d * simd_dot(d, axis)
      }
      if simd_length_squared(next) < 0.0001 { break }
      axis = next
    }
    let length = simd_length(axis)
    axis = length > 0.0001 ? axis / length : SIMD4(1, 0, 0, 0)
    var lo = Float.infinity, hi = -Float.infinity
    for p in pixels {
      let t = simd_dot(p - mean, axis)
      lo = min(lo, t); hi = max(hi, t)
    }
    var a = simd_clamp((mean + axis * lo).rounded(.toNearestOrAwayFromZero), .zero, SIMD4(repeating: 255))
    var b = simd_clamp((mean + axis * hi).rounded(.toNearestOrAwayFromZero), .zero, SIMD4(repeating: 255))
    if dual { a.w = low.w; b.w = high.w }
    // Direct endpoint mode otherwise invokes blue contraction and swaps endpoints.
    if a.x + a.y + a.z > b.x + b.y + b.z { swap(&a, &b) }
    var block = SIMD4<UInt32>.zero
    write(dual ? (gridX == 4 ? 0x402 : 0x54E) : 0x42, bits: 11, at: 0, into: &block)
    write(12, bits: 4, at: 13, into: &block)
    for c in 0..<4 {
      write(UInt32(a[c]), bits: 8, at: 17 + c * 16, into: &block)
      write(UInt32(b[c]), bits: 8, at: 25 + c * 16, into: &block)
    }
    if dual { write(3, bits: 2, at: 94, into: &block) }
    let delta = b - a
    let weights: [Int] = [0, 21, 43, 64]
    var indices = [Int](repeating: 0, count: 16)
    for y in 0..<gridY { for x in 0..<gridX {
      let pixel = pixels[(y * (size - 1) / (gridY - 1)) * size + x * (size - 1) / (gridX - 1)]
      for plane in 0..<(dual ? 2 : 1) {
        var error = Float.infinity, selected = 0
        for index in 0..<4 {
          let d = a + delta * (Float(weights[index]) / 64) - pixel
          let e = dual ? (plane == 1 ? d.w * d.w : d.x * d.x + d.y * d.y + d.z * d.z)
            : simd_length_squared(d)
          if e < error { error = e; selected = index }
        }
        let i = (y * gridX + x) * (dual ? 2 : 1) + plane
        indices[i] = weights[selected]
        // Weight bitstream runs backwards from the last bit of the block.
        for bit in 0..<2 { write(UInt32((selected >> bit) & 1), bits: 1, at: 127 - i * 2 - bit, into: &block) }
      }
    } }
    var error: Float = 0
    let coordinateScale = (1024 + size / 2) / (size - 1)
    for y in 0..<size { for x in 0..<size {
      // ASTC's integer bilinear weight interpolation, including grid decimation.
      let sx = (coordinateScale * x * (gridX - 1) + 32) >> 6
      let sy = (coordinateScale * y * (gridY - 1) + 32) >> 6
      let ix = sx >> 4, iy = sy >> 4, fx = sx & 15, fy = sy & 15
      let w11 = (fx * fy + 8) >> 4
      let factors = [16 - fx - fy + w11, fx - w11, fy - w11, w11]
      var decoded = a
      for c in 0..<4 {
        let plane = dual && c == 3 ? 1 : 0
        var weight = 8
        for corner in 0..<4 where factors[corner] != 0 {
          let i = ((iy + corner / 2) * gridX + ix + corner % 2) * (dual ? 2 : 1) + plane
          weight += factors[corner] * indices[i]
        }
        decoded[c] += delta[c] * Float(weight >> 4) / 64
      }
      let d = decoded - pixels[y * size + x]
      error += d.x * d.x + d.y * d.y + d.z * d.z + 4 * d.w * d.w
    } }
    return Candidate(block: block, error: error)
  }

  private static func write(_ value: UInt32, bits: Int, at offset: Int, into block: inout SIMD4<UInt32>) {
    let word = offset / 32, shift = offset % 32
    block[word] |= value << shift
    if shift + bits > 32 { block[word + 1] |= value >> (32 - shift) }
  }
}
