import Foundation

struct UVFVolumeLayout {
  enum Storage {
    case toc(table: Int, base: Int, end: Int, entrySize: Int)
    case raster(start: Int, end: Int)
  }
  let dimensions: [Int]
  let spacing: [Double]
  let brick: [Int]
  let overlap: [Int]
  let core: [Int]
  let counts: [Int]
  let bytes: Int
  let channels: Int
  let signed: Bool
  let floating: Bool
  let normals: Bool
  let bigEndian: Bool
  let storage: Storage

  var outputChannels: Int { normals ? 1 : channels }
  var outputBytes: Int { floating ? 2 : bytes }

  static func toc(_ data: Data, base: Int, end: Int, fileVersion: Int,
                  cancellationCheck: (() throws -> Void)?) throws -> Self {
    guard fileVersion >= 5 else { throw UVFParser.Error.unsupported("TOC version 0 (UVF before version 5)") }
    // Unlike the outer UVF headers, Tuvok wrote TOCs in writer-native byte
    // order. Infer it from the bounded component count, not the outer flag.
    var probe = try UVFBinaryReader(data, start: base, end: end)
    let type = try probe.integer(4), count = try probe.uint()
    let big = type > 9 || !(1...4).contains(count)
    var reader = try UVFBinaryReader(data, start: base, end: end, bigEndian: big)
    let componentType = try reader.integer(4), channels = try reader.integer()
    guard (0...9).contains(componentType), (1...4).contains(channels) else { throw UVFParser.Error.invalid("TOC component type/count") }
    let flag = try reader.integer(1)
    guard flag <= 1, flag == 0 || channels == 4 else { throw UVFParser.Error.invalid("precomputed normals flag") }
    let dimensions = try (0..<3).map { _ in try reader.integer() }
    let spacing = try (0..<3).map { _ in try reader.double() }
    let brick = try (0..<3).map { _ in try reader.integer() }
    let halo = try reader.integer(4)
    let version = try reader.integer(4)
    guard (1...2).contains(version) else { throw UVFParser.Error.unsupported("TOC version \(version)") }
    let totalSize = try reader.integer()
    if version == 2 { _ = try reader.integer(4) } // LZMA level does not change lc/lp/pb.
    guard dimensions.allSatisfy({ $0 > 0 }), spacing.allSatisfy({ $0.isFinite && $0 > 0 }),
          brick.allSatisfy({ $0 > 0 && halo < $0 && halo <= ($0 - 1) / 2 }),
          totalSize > 0, totalSize <= end - base else { throw UVFParser.Error.invalid("TOC geometry/size") }
    let core = brick.map { $0 - 2 * halo }
    let counts = zip(dimensions, core).map { 1 + ($0 - 1) / $1 }
    var level = dimensions, totalBricks = 0
    repeat {
      totalBricks = try uvfAdd(totalBricks, uvfProduct(zip(level, core).map { 1 + ($0 - 1) / $1 }))
      if level == [1, 1, 1] { break }
      level = level.map { $0 / 2 + $0 % 2 }
    } while true
    let tableSize = try uvfProduct([totalBricks, 36])
    let payload = try uvfAdd(reader.position, tableSize)
    let blockEnd = try uvfAdd(base, totalSize)
    guard payload <= blockEnd else { throw UVFParser.Error.invalid("TOC table size") }
    let widths = [1, 2, 4, 8, 1, 2, 4, 8, 4, 8]
    guard componentType != 3, componentType != 7 else { throw UVFParser.Error.unsupported("64-bit integer samples") }
    let largestBrick = (0..<3).map { min(core[$0], dimensions[$0]) + 2 * halo }
    guard try uvfProduct(largestBrick + [channels, widths[componentType]]) <= 512 << 20 else {
      throw UVFParser.Error.invalid("brick exceeds decoder limits")
    }
    // Check all entries, including lower LoDs, before creating a temporary file.
    var entries = reader
    for i in 0..<totalBricks {
      if i % 4096 == 0 { try cancellationCheck?() }
      let offset = try entries.integer(), length = try entries.integer()
      _ = try entries.integer(4)
      let valid = try entries.integer()
      let aw = try entries.integer(4), ah = try entries.integer(4)
      guard offset >= payload - base, offset <= totalSize, length > 0, length <= totalSize - offset,
            valid >= length, (aw == 0) == (ah == 0) else { throw UVFParser.Error.invalid("TOC brick bounds or incomplete brick") }
    }
    return Self(dimensions: dimensions, spacing: spacing, brick: brick, overlap: [halo, halo, halo],
                core: core, counts: counts, bytes: widths[componentType], channels: channels,
                signed: (4...7).contains(componentType), floating: componentType >= 8, normals: flag == 1,
                bigEndian: big, storage: .toc(table: reader.position, base: base, end: blockEnd, entrySize: 36))
  }

  static func raster(_ data: Data, base: Int, end: Int, bigEndian: Bool) throws -> Self {
    var reader = try UVFBinaryReader(data, start: base, end: end, bigEndian: bigEndian)
    guard try reader.integer() == 3 else { throw UVFParser.Error.unsupported("non-3D raster volume") }
    let semantics = try (0..<3).map { _ in try reader.integer() }
    guard semantics == [1, 2, 3] || semantics == [0, 0, 0] else { throw UVFParser.Error.unsupported("raster domain axis order") }
    let matrix = try (0..<16).map { _ in try reader.double() }
    let dimensions = try (0..<3).map { _ in try reader.integer() }
    let brick = try (0..<3).map { _ in try reader.integer() }
    let overlap = try (0..<3).map { _ in try reader.integer() }
    let factors = try (0..<3).map { _ in try reader.integer() }
    let groups = try (0..<3).map { _ in try reader.integer() }
    guard dimensions.allSatisfy({ $0 > 0 }), factors.allSatisfy({ $0 > 0 }),
          zip(brick, overlap).allSatisfy({ $0 > $1 }), let maxGroup = groups.max(), maxGroup < 3 else {
      throw UVFParser.Error.invalid("raster geometry/LoD groups")
    }
    for _ in 0...maxGroup {
      guard try reader.integer() > 0 else { throw UVFParser.Error.invalid("raster LoD count") }
    }
    guard try reader.integer() == 1 else { throw UVFParser.Error.unsupported("raster tensor elements") }
    let channels = try reader.integer()
    guard (1...4).contains(channels) else { throw UVFParser.Error.unsupported("raster component count") }
    _ = try (0..<channels).map { _ in try reader.integer() } // Element semantics.
    let bits = try (0..<channels).map { _ in try reader.integer() }
    let mantissas = try (0..<channels).map { _ in try reader.integer() }
    let signs = try (0..<channels).map { _ in try reader.integer(1) }
    guard Set(bits).count == 1, Set(mantissas).count == 1, Set(signs).count == 1, signs[0] <= 1 else {
      throw UVFParser.Error.unsupported("mixed raster component representations")
    }
    let floating = (bits[0] == 32 && mantissas[0] == 23) || (bits[0] == 64 && mantissas[0] == 52)
    guard floating || ([8, 16, 32].contains(bits[0]) && mantissas[0] == bits[0] - signs[0]) else {
      throw UVFParser.Error.unsupported("raster sample representation")
    }
    let padding = try reader.integer()
    try reader.skip(padding)
    let core = zip(brick, overlap).map { $0 - $1 }
    let counts = (0..<3).map { max(1, 1 + (max(1, dimensions[$0] - overlap[$0]) - 1) / core[$0]) }
    // Legacy overlap is shared between adjacent bricks, with no outer halo.
    let storedAxes = try (0..<3).map { axis in
      try uvfAdd(dimensions[axis], uvfProduct([counts[axis] - 1, overlap[axis]]))
    }
    let length = try uvfProduct(storedAxes + [channels, bits[0] / 8])
    guard length <= end - reader.position, matrix.allSatisfy(\.isFinite) else { throw UVFParser.Error.invalid("raster payload/transform") }
    guard try uvfProduct(zip(brick, dimensions).map { min($0, $1) } + [channels, bits[0] / 8]) <= 512 << 20 else {
      throw UVFParser.Error.invalid("raster brick exceeds decoder limits")
    }
    let spacing = (0..<3).map { column in
      hypot(hypot(matrix[column], matrix[4 + column]), matrix[8 + column])
    }
    guard spacing.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw UVFParser.Error.invalid("raster voxel spacing") }
    return Self(dimensions: dimensions, spacing: spacing, brick: brick, overlap: overlap, core: core, counts: counts,
                bytes: bits[0] / 8, channels: channels, signed: !floating && signs[0] == 1, floating: floating,
                normals: false, bigEndian: bigEndian, storage: .raster(start: reader.position, end: end))
  }

  func extract(_ data: Data, into output: UnsafeMutableRawPointer,
               cancellationCheck: (() throws -> Void)?, progress: ((Double) -> Void)?) throws {
    let voxelBytes = try uvfProduct([bytes, channels])
    let outputVoxelBytes = try uvfProduct([bytes, outputChannels])
    let brickCount = try uvfProduct(counts)
    var index = 0, rasterOffset = 0
    if case .raster(let start, _) = storage { rasterOffset = start }
    for bz in 0..<counts[2] { for by in 0..<counts[1] { for bx in 0..<counts[0] {
      try cancellationCheck?()
      let coordinate = [bx, by, bz]
      let origin = (0..<3).map { coordinate[$0] * core[$0] }
      let extent: [Int], stored: [Int], local: [Int]
      let decoded: Data
      var atlasWidth = 0
      switch storage {
        case .toc(let table, let base, let end, let entrySize):
          extent = (0..<3).map { min(core[$0], dimensions[$0] - origin[$0]) }
          stored = (0..<3).map { extent[$0] + 2 * overlap[$0] }
          local = overlap
          var entry = try UVFBinaryReader(data, start: table + index * entrySize, end: end, bigEndian: bigEndian)
          let offset = try entry.integer(), length = try entry.integer(), codec = try entry.integer(4)
          let validLength = try entry.integer()
          atlasWidth = try entry.integer(4)
          let atlasHeight = try entry.integer(4)
          let size = try uvfProduct(stored + [voxelBytes])
          // Tuvok leaves validLength at the uncompressed length after compression;
          // other writers use the stored length. Both must decode to the full brick.
          guard validLength == length || validLength == size else { throw UVFParser.Error.invalid("incomplete TOC brick") }
          guard length <= 512 << 20 else { throw UVFParser.Error.invalid("encoded brick exceeds decoder limits") }
          if atlasWidth != 0 {
            guard atlasWidth >= brick[0], atlasWidth % brick[0] == 0,
                  atlasHeight > 0 else { throw UVFParser.Error.invalid("atlasified brick dimensions") }
          }
          var payload = try UVFBinaryReader(data, start: uvfAdd(base, offset), end: end)
          decoded = try UVFCompression.decode(payload.take(length), codec: codec, size: size)
        case .raster(_, let end):
          stored = (0..<3).map { min(brick[$0], dimensions[$0] - origin[$0]) }
          extent = (0..<3).map { coordinate[$0] < counts[$0] - 1 ? stored[$0] - overlap[$0] : stored[$0] }
          local = [0, 0, 0]
          let size = try uvfProduct(stored + [voxelBytes])
          guard size <= 512 << 20 else { throw UVFParser.Error.invalid("raster brick exceeds decoder limits") }
          var payload = try UVFBinaryReader(data, start: rasterOffset, end: end)
          decoded = try payload.take(size)
          rasterOffset = payload.position
      }
      try decoded.withUnsafeBytes { raw in
        let source = raw.bindMemory(to: UInt8.self)
        for z in 0..<extent[2] {
          try cancellationCheck?()
          for y in 0..<extent[1] {
            let sz = z + local[2], sy = y + local[1]
            let sourceVoxel: Int
            if atlasWidth == 0 { sourceVoxel = local[0] + stored[0] * (sy + stored[1] * sz) }
            else {
              let tiles = atlasWidth / brick[0]
              let row = try uvfAdd(uvfProduct([sz / tiles, brick[1]]), sy)
              let column = try uvfAdd(uvfProduct([sz % tiles, brick[0]]), local[0])
              guard column <= atlasWidth, extent[0] <= atlasWidth - column else { throw UVFParser.Error.invalid("atlas row width") }
              sourceVoxel = try uvfAdd(column, uvfProduct([row, atlasWidth]))
            }
            let sourceStart = try uvfProduct([sourceVoxel, voxelBytes])
            let rowSize = extent[0] * voxelBytes
            guard sourceStart >= 0, sourceStart <= source.count, rowSize <= source.count - sourceStart else {
              throw UVFParser.Error.invalid("brick row bounds")
            }
            let targetVoxel = origin[0] + dimensions[0] * (origin[1] + y + dimensions[1] * (origin[2] + z))
            let target = output.advanced(by: targetVoxel * outputVoxelBytes)
            if !normals && (!bigEndian || bytes == 1) {
              target.copyMemory(from: raw.baseAddress!.advanced(by: sourceStart), byteCount: rowSize)
            } else {
              for x in 0..<extent[0] { for c in 0..<outputChannels { for b in 0..<bytes {
                target.storeBytes(of: source[sourceStart + x * voxelBytes + c * bytes + (bigEndian ? bytes - 1 - b : b)],
                                  toByteOffset: x * outputVoxelBytes + c * bytes + b, as: UInt8.self)
              } } }
            }
          }
        }
      }
      index += 1
      progress?(Double(index) / Double(brickCount))
    } } }
  }
}
