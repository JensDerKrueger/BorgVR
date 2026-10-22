import Foundation

/*
 This MC33 case resolver is a Swift port of the algorithm and lookup table from:

 David E. Vega M., Javier E. Abache R., and David Coll G.,
 "A Fast and Memory-Saving Marching Cubes 33 Implementation with the Correct
 Interior Test", Journal of Computer Graphics Techniques, 8(3), 2019.

 It incorporates the topological corrections discussed by Custodio et al. in
 "Practical considerations on Marching Cubes 33 topological correctness" and
 the later fixes documented by Vega et al.

 The reference implementation is distributed under the following license:

 MIT License

 Copyright (c) 2019 David E. Vega M. and Javier E. Abache R.

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

/// Resolves a sampled cube into the topologically correct MC33 triangulation.
enum BorgVRMarchingCubes33 {
  struct Triangle: Sendable {
    let firstEdge: Int
    let secondEdge: Int
    let thirdEdge: Int

    var edges: [Int] {
      [firstEdge, secondEdge, thirdEdge]
    }
  }

  /// The reference implementation uses this vertex order:
  ///
  ///     3 -------- 2
  ///    /|         /|
  ///   7 -------- 6 |
  ///   | 0 -------|-1
  ///   |/         |/
  ///   4 -------- 5
  ///
  /// BorgVR uses the conventional cyclic order on each z plane, while the
  /// reference advances along a different cube axis.
  private static let referenceCornerOrder = [0, 3, 7, 4, 1, 2, 6, 5]
  private static let borgVREdgeForReferenceEdge = [3, 11, 7, 8, 1, 10, 5, 9, 0, 2, 6, 4, 12]

  /// Shared with the Metal classifier so both extraction paths use the exact
  /// same corrected MC33 triangulation table.
  static var metalLookupTable: [UInt16] { table }

  static func triangles(values: [Double], threshold: Double) -> [Triangle] {
    precondition(values.count == 8)
    let values = referenceCornerOrder.map { threshold - values[$0] }

    var cubeIndex = 0
    for index in values.indices where values[index] < 0 {
      cubeIndex |= 1 << (7 - index)
    }
    guard cubeIndex != 0, cubeIndex != 0xFF else { return [] }

    var descriptor: Int
    var firstWindingIndex: Int
    var secondWindingIndex: Int
    if cubeIndex & 0x80 != 0 {
      descriptor = Int(table[cubeIndex ^ 0xFF])
      firstWindingIndex = descriptor & 0x800 == 0 ? 1 : 0
      secondWindingIndex = 1 - firstWindingIndex
    } else {
      descriptor = Int(table[cubeIndex])
      secondWindingIndex = descriptor & 0x800 == 0 ? 1 : 0
      firstWindingIndex = 1 - secondWindingIndex
    }

    var patternOffset = descriptor & 0x7FF
    var configuration = patternOffset
    let canonicalIndex = firstWindingIndex != 0 ? cubeIndex : cubeIndex ^ 0xFF

    switch descriptor >> 12 {
      case 0: // 1, 2, 5, 8, 9, 11, and 14
        break
      case 1: // 3
        let face = configuration >> 2
        patternOffset = canonicalIndex & faceTest(face, values: values) != 0
          ? 183 + (configuration << 1)
          : 159 + configuration
      case 2: // 4
        patternOffset = interiorTest(configuration, case13: false, values: values) != 0
          ? 239 + 6 * configuration
          : 231 + (configuration << 1)
      case 3: // 6
        if canonicalIndex & faceTest(configuration % 6, values: values) != 0 {
          patternOffset = 575 + 5 * configuration
        } else {
          patternOffset = interiorTest(configuration / 6, case13: false, values: values) != 0
            ? 407 + 7 * configuration
            : 335 + 3 * configuration
        }
      case 4: // 7
        let tests = faceTests(index: canonicalIndex, values: values)
        switch tests.sum {
          case -3:
            patternOffset = 695 + 3 * configuration
          case -1:
            let base = tests.results[4] + tests.results[5] < 0
              ? (tests.results[0] + tests.results[2] < 0 ? 759 : 799)
              : 719
            patternOffset = base + 5 * configuration
          case 1:
            let base = tests.results[4] + tests.results[5] < 0
              ? 983
              : (tests.results[0] + tests.results[2] < 0 ? 839 : 911)
            patternOffset = base + 9 * configuration
          default:
            patternOffset = interiorTest(configuration >> 1, case13: false, values: values) != 0
              ? 1095 + 9 * configuration
              : 1055 + 5 * configuration
        }
      case 5: // 10
        let tests = faceTests(index: canonicalIndex, values: values)
        switch tests.sum {
          case -2:
            let connected = configuration == 2
              ? interiorTest(0, case13: false, values: values) != 0
              : interiorTest(0, case13: false, values: values) != 0 ||
                interiorTest(configuration != 0 ? 1 : 3, case13: false, values: values) != 0
            patternOffset = connected
              ? 1213 + (configuration << 3)
              : 1189 + (configuration << 2)
          case 0:
            patternOffset = (tests.results[2 + configuration] < 0 ? 1261 : 1285) +
              (configuration << 3)
          default:
            let connected = configuration == 2
              ? interiorTest(1, case13: false, values: values) != 0
              : interiorTest(2, case13: false, values: values) != 0 ||
                interiorTest(configuration != 0 ? 3 : 1, case13: false, values: values) != 0
            patternOffset = connected
              ? 1237 + (configuration << 3)
              : 1201 + (configuration << 2)
        }
      case 6: // 12
        let tests = faceTests(index: canonicalIndex, values: values)
        switch tests.sum {
          case -2:
            let diagonal = (0xDA010C >> (configuration << 1)) & 3
            patternOffset = interiorTest(diagonal, case13: false, values: values) != 0
              ? 1453 + (configuration << 3)
              : 1357 + (configuration << 2)
          case 0:
            patternOffset = (tests.results[configuration >> 1] < 0 ? 1645 : 1741) +
              (configuration << 3)
          default:
            let diagonal = (0xA7B7E5 >> (configuration << 1)) & 3
            patternOffset = interiorTest(diagonal, case13: false, values: values) != 0
              ? 1549 + (configuration << 3)
              : 1405 + (configuration << 2)
        }
      default: // 13
        let tests = faceTests(index: 165, values: values)
        switch abs(tests.sum) {
          case 0:
            configuration = (tests.results[1] < 0 ? 2 : 0) |
              (tests.results[5] < 0 ? 1 : 0)
            if tests.results[0] * tests.results[1] == tests.results[5] {
              patternOffset = 2157 + 12 * configuration
            } else {
              let result = interiorTest(configuration, case13: true, values: values)
              patternOffset = 2285 + (result != 0
                ? 10 * configuration - 40 * result
                : 6 * configuration)
            }
          case 2:
            let first = tests.results[0] < 0
              ? (tests.results[2] > 0 ? 1 : 0)
              : 12 + (tests.results[2] < 0 ? 1 : 0)
            let second = tests.results[1] < 0
              ? (tests.results[3] < 0 ? 1 : 0)
              : 6 + (tests.results[3] > 0 ? 1 : 0)
            patternOffset = 1917 + 10 * (first + second)
            if tests.results[4] > 0 {
              patternOffset += 30
            }
          case 4:
            configuration = 21 + 11 * tests.results[0] + 4 * tests.results[1] +
              3 * tests.results[2] + 2 * tests.results[3] + tests.results[4]
            if configuration >> 4 != 0 {
              configuration -= configuration & 32 != 0 ? 20 : 10
            }
            patternOffset = 1845 + 3 * configuration
          default:
            patternOffset = 1839 + 2 * tests.results[0]
        }
    }

    var triangles: [Triangle] = []
    var cursor = patternOffset
    repeat {
      cursor += 1
      precondition(table.indices.contains(cursor))
      var word = Int(table[cursor])
      let first = word & 0x0F
      word >>= 4
      let second = word & 0x0F
      word >>= 4
      let third = word & 0x0F
      let ordered = [third, second, first]
      triangles.append(
        Triangle(
          firstEdge: borgVREdgeForReferenceEdge[ordered[secondWindingIndex]],
          secondEdge: borgVREdgeForReferenceEdge[ordered[firstWindingIndex]],
          thirdEdge: borgVREdgeForReferenceEdge[ordered[2]]
        )
      )
      word >>= 4
      if word == 0 { break }
    } while true
    return triangles
  }

  private static func faceTests(index: Int, values: [Double]) -> (results: [Int], sum: Int) {
    var result = Array(repeating: 0, count: 6)
    if index & 0x80 != 0 {
      result[0] = index & 0xCC == 0x84 ? (values[0] * values[5] < values[1] * values[4] ? -1 : 1) : 0
      result[3] = index & 0x99 == 0x81 ? (values[0] * values[7] < values[3] * values[4] ? -1 : 1) : 0
      result[4] = index & 0xF0 == 0xA0 ? (values[0] * values[2] < values[1] * values[3] ? -1 : 1) : 0
    } else {
      result[0] = index & 0xCC == 0x48 ? (values[0] * values[5] < values[1] * values[4] ? 1 : -1) : 0
      result[3] = index & 0x99 == 0x18 ? (values[0] * values[7] < values[3] * values[4] ? 1 : -1) : 0
      result[4] = index & 0xF0 == 0x50 ? (values[0] * values[2] < values[1] * values[3] ? 1 : -1) : 0
    }
    if index & 0x02 != 0 {
      result[1] = index & 0x66 == 0x42 ? (values[1] * values[6] < values[2] * values[5] ? -1 : 1) : 0
      result[2] = index & 0x33 == 0x12 ? (values[3] * values[6] < values[2] * values[7] ? -1 : 1) : 0
      result[5] = index & 0x0F == 0x0A ? (values[4] * values[6] < values[5] * values[7] ? -1 : 1) : 0
    } else {
      result[1] = index & 0x66 == 0x24 ? (values[1] * values[6] < values[2] * values[5] ? 1 : -1) : 0
      result[2] = index & 0x33 == 0x21 ? (values[3] * values[6] < values[2] * values[7] ? 1 : -1) : 0
      result[5] = index & 0x0F == 0x05 ? (values[4] * values[6] < values[5] * values[7] ? 1 : -1) : 0
    }
    return (result, result.reduce(0, +))
  }

  private static func faceTest(_ face: Int, values: [Double]) -> Int {
    switch face {
      case 0: return values[0] * values[5] < values[1] * values[4] ? 0x48 : 0x84
      case 1: return values[1] * values[6] < values[2] * values[5] ? 0x24 : 0x42
      case 2: return values[3] * values[6] < values[2] * values[7] ? 0x21 : 0x12
      case 3: return values[0] * values[7] < values[3] * values[4] ? 0x18 : 0x81
      case 4: return values[0] * values[2] < values[1] * values[3] ? 0x50 : 0xA0
      default: return values[4] * values[6] < values[5] * values[7] ? 0x05 : 0x0A
    }
  }

  /// Tests one of the four body diagonals against the trilinear interpolant.
  private static func interiorTest(
    _ diagonal: Int,
    case13: Bool,
    values: [Double]
  ) -> Int {
    var a = values[4] - values[0]
    var b = values[5] - values[1]
    var c = values[6] - values[2]
    var d = values[7] - values[3]
    let quadratic = a * c - b * d

    if quadratic < 0 {
      if diagonal & 1 != 0 { return 0 }
    } else if diagonal & 1 == 0 || quadratic == 0 {
      return 0
    }

    let t = 0.5 * (
      values[3] * b - values[2] * a + values[1] * d - values[0] * c
    ) / quadratic
    guard t > 0, t < 1, t.isFinite else { return 0 }

    a = values[0] + a * t
    b = values[1] + b * t
    c = values[2] + c * t
    d = values[3] + d * t
    let ac = a * c
    let bd = b * d
    if diagonal & 1 != 0 {
      guard ac < bd, bd >= 0 else { return 0 }
      return ((b.sign == values[diagonal].sign) ? 1 : 0) + (case13 ? 1 : 0)
    }
    guard ac > bd, ac >= 0 else { return 0 }
    return ((a.sign == values[diagonal].sign) ? 1 : 0) + (case13 ? 1 : 0)
  }

  /// Little-endian UInt16 encoding of MC33_all_tables from the MIT-licensed
  /// reference implementation. Keeping it encoded makes this source and the
  /// Xcode index substantially smaller than a 2,310-element integer literal.
  private static let table: [UInt16] = {
    let encoded = """
    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
    hxxUHAkMGhzGFwEcgBx4HLYcOxwjHKIMZRymHFkcwhGyHMQXexyUHBoMKxzJERIcSRx0HIccCBwwHLMMpRxUHHYcSBwqHDIcsxxr
    HIcMRRzKEoQcOBwjHFkcGhwBHJAMZRwDHJAcWRy2HMQXexyEHDgMpRxWHAkcMByzHGscKhwSHJEMpRxqHFQcdhyHHAgcyREQHEkM
    phzGFxocARyAHDgcIxyyHHsMxRqmHJQcGRwhHLIcexxnHEUMKxzJEUkcdBy3HDIcgxwIHBAMpRxWHCocMhyDHEgcdBy3HGsMxRrK
    EkUchBw4HAMckBwZHCEMRRy2HDscAxyQHFkchBx4HGcMxRYqHMsTaxyVHAkcEByhHDIMxRZqHJUcdBzIFwgcEByhHEkMphyAHHgc
    ZxwaHCEcshw7HAMMZRoZFLIRtBexBEsXSRGxErQRMAilEoUUdhsyGIIFJRo4ElgUKBUZAGUZkBNjG5MWhAeVFioRkxA2G5YDlRRq
    FwoRcBigB6YXgBegEXAasgNlFFkUGhKyGqYbthd2FKEVUQmEEEgXtxiDG7MSCREwESMRBAmlFisTgxt0GLcYdhVHFbIWYgpFGVoR
    OBAjEAESIRoZFQgZmARlFIATkBiEGZQVRxZnG4MXcwulFpUaoRmREBITARMyG6YSJgulFgkRoRmVGlQXZRd0GJAUQAimG4ATeBM7
    F3sWshqiETASIAGaG7gJJhQkAHUTNQGmF4ARgRdxCkIbKRGSFLcENRqiE1MYhAVlGbATthBpAGoUShkoECsIpReJEYETugclFkAT
    QxchBUYYChlrGCoAlRe6EYkXsQMVEDYSQBVjB2oSKRCpEmIbuBZoFIkUCQilGYkXVxmpERMaoxs3G4cDBRRWFxUQIRAgEzcSJxZF
    B2oUlBoEGQgUgBsCG7IaawqlG4kROBG4E7cYexVaEZUBZRRWESEWMRIwEQMUNxRHBsoZxhoMGSwQvBLLGEwYbASVHLocexxXHMgZ
    OBwTHMoBFRzGEiEcxRR2HMMXAxxADEYcKhyUHKkcwBKAHLgcxgulHMUXuhw7HMkRwROJHMcIxRbGEjwSTBd8E8QQHBBcAbUWgBuw
    FVABhheJESYRgQaaEnQZkhdyA6UUuhOkE0ADdRkCGScZKwdqEUYYYRgTCGoXkBqgF3ADGhtAEbQRSwclEYUSuBJYBJUWNhKWE4kD
    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
    """
    guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
          data.count.isMultiple(of: MemoryLayout<UInt16>.size) else {
      preconditionFailure("Invalid embedded MC33 lookup table")
    }
    return stride(from: 0, to: data.count, by: 2).map {
      UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8
    }
  }()
}
