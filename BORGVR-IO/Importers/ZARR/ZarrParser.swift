import Foundation
import zlib

/// Local Zarr v3 arrays and OME-Zarr 0.5 images, including RFC-9 OZX containers.
/// The highest resolution is materialized once as interleaved, little-endian RAW;
/// BorgVR's existing converter remains responsible for overlap, bricking and LODs.
public final class ZarrParser: VolumeFileParser {
  public let absoluteFilename: String
  public let size: Vec3<Int>
  public let voxelSpacing: Vec3<Float>
  public let hasPhysicalVoxelSpacing: Bool
  public let bytesPerComponent: Int
  public let components: Int
  public let isLittleEndian = true
  public let offset = 0
  public let dataIsTempCopy = true

  public init(filename: String, cancellationCheck: (() throws -> Void)? = nil,
              progress: ((Double) -> Void)? = nil, log: ((String) -> Void)? = nil) throws {
    var url = URL(fileURLWithPath: filename)
    if url.lastPathComponent == "zarr.json" { url.deleteLastPathComponent() }
    let store = try ZarrStore(url: url)
    let root = try Self.metadata(store, key: "zarr.json")
    let array: Node
    let path: String
    let axes: [Axis]
    let transforms: [Transform]
    if root.node_type == "array" {
      array = root; path = ""
      guard let names = root.dimension_names else {
        throw ZarrImportError.unsupported("bare arrays must name their x, y, z and optional c/t axes")
      }
      axes = names.map { Axis(name: $0, unit: nil) }
      transforms = []
    } else {
      guard root.node_type == "group", let ome = root.attributes?.ome, ome.version == "0.5",
            let scales = ome.multiscales, scales.count == 1,
            let scale = scales.first, let first = scale.datasets.first else {
        throw ZarrImportError.unsupported("expected one OME-Zarr 0.5 multiscale image")
      }
      path = first.path
      array = try Self.metadata(store, key: path + "/zarr.json")
      axes = scale.axes
      transforms = first.coordinateTransformations + (scale.coordinateTransformations ?? [])
    }
    let layout = try Layout(array, axes: axes, transforms: transforms)
    size = layout.size
    voxelSpacing = layout.spacing
    hasPhysicalVoxelSpacing = layout.hasPhysicalVoxelSpacing
    bytesPerComponent = layout.floating ? 2 : layout.bytes
    components = layout.components
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-zarr-\(UUID()).raw")
    do {
      let output = try MemoryMappedFile(filename: temporary.path, size: Int64(layout.outputBytes))
      defer { try? output.close() }
      let outerGrid = zip(layout.shape, layout.outerShape).map { ($0 - 1) / $1 + 1 }
      let total = try Self.product(outerGrid)
      var completed = 0
      try Self.coordinates(outerGrid) { coordinate in
        try cancellationCheck?()
        let encoding = array.chunk_key_encoding!
        let separator = encoding.configuration?.separator ?? (encoding.name == "default" ? "/" : ".")
        let suffix = coordinate.map(String.init).joined(separator: separator)
        let key = (path.isEmpty ? "" : path + "/") + (encoding.name == "default" ? "c" + separator : "") + suffix
        let encoded = try store.read(key)
        let outerOrigin = zip(coordinate, layout.outerShape).map(*)
        if let shard = layout.shard {
          let grid = zip(layout.outerShape, layout.innerShape).map { $0 / $1 }
          let indexBytes = try Self.product([Self.product(grid), 16])
          let indexLength = indexBytes + (shard.index_codecs!.last?.name == "crc32c" ? 4 : 0)
          var index: Data?
          let indexStart: Int
          if let encoded {
            indexStart = shard.index_location == "start" ? 0 : encoded.count - indexLength
            index = try Self.decode(encoded.zarrSlice(indexStart, indexLength),
                                    codecs: shard.index_codecs!, size: indexBytes)
          } else { indexStart = 0 }
          var entry = 0
          try Self.coordinates(grid) { inner in
            try cancellationCheck?()
            let origin = zip(outerOrigin, zip(inner, layout.innerShape).map(*)).map(+)
            defer { entry += 1 }
            guard zip(origin, layout.shape).allSatisfy({ $0 < $1 }) else { return }
            var chunk: Data?
            if let encoded, let index {
              let offset = try index.zarrUInt64(entry * 16)
              let length = try index.zarrUInt64(entry * 16 + 8)
              if offset != UInt64.max || length != UInt64.max {
                guard offset <= UInt64(encoded.count), length <= UInt64(encoded.count) - offset else {
                  throw ZarrImportError.invalid("shard chunk range")
                }
                let start = Int(offset), count = Int(length)
                guard shard.index_location == "start" ? start >= indexLength : start + count <= indexStart else {
                  throw ZarrImportError.invalid("shard chunk overlaps index")
                }
                chunk = try encoded.zarrSlice(start, count)
              }
            }
            try layout.write(chunk, origin: origin, codecs: shard.codecs!, to: output.mappedMemory)
          }
        } else {
          try layout.write(encoded, origin: outerOrigin, codecs: array.codecs!, to: output.mappedMemory)
        }
        completed += 1
        progress?(Double(completed) / Double(total) * (layout.floating ? 0.8 : layout.signed ? 0.9 : 1))
      }
      try layout.convertSamples(output.mappedMemory, cancellationCheck: cancellationCheck, progress: progress, log: log)
      try output.close()
      if layout.floating {
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(layout.outputBytes / layout.bytes * 2))
      }
      absoluteFilename = temporary.path
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private struct Node: Decodable {
    let zarr_format: Int
    let node_type: String
    let attributes: Attributes?
    let shape: [Int]?
    let data_type: String?
    let dimension_names: [String]?
    let chunk_grid: Grid?
    let chunk_key_encoding: KeyEncoding?
    let fill_value: FillValue?
    let codecs: [Codec]?
    let storage_transformers: [String]?
  }
  private struct FillValue: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let number = try? container.decode(Double.self) { value = number; return }
      switch try container.decode(String.self) {
        case "NaN": value = .nan
        case "Infinity": value = .infinity
        case "-Infinity": value = -.infinity
        default: throw ZarrImportError.invalid("fill value")
      }
    }
  }
  private struct Attributes: Decodable { let ome: OME? }
  private struct OME: Decodable { let version: String; let multiscales: [Scale]? }
  private struct Scale: Decodable {
    let axes: [Axis]
    let datasets: [Dataset]
    let coordinateTransformations: [Transform]?
  }
  private struct Axis: Decodable { let name: String; let unit: String? }
  private struct Dataset: Decodable { let path: String; let coordinateTransformations: [Transform] }
  private struct Transform: Decodable { let type: String; let scale: [Double]?; let translation: [Double]? }
  private struct Grid: Decodable {
    let name: String
    let configuration: Configuration
    struct Configuration: Decodable { let chunk_shape: [Int] }
  }
  private struct KeyEncoding: Decodable {
    let name: String
    let configuration: Configuration?
    struct Configuration: Decodable { let separator: String? }
  }
  private struct Codec: Decodable {
    let name: String
    let configuration: Configuration?
  }
  private struct Configuration: Decodable {
    let endian: String?
    let chunk_shape: [Int]?
    let codecs: [Codec]?
    let index_codecs: [Codec]?
    let index_location: String?
  }

  private static func metadata(_ store: ZarrStore, key: String) throws -> Node {
    guard let data = try store.read(key, limit: 4 << 20) else { throw ZarrImportError.invalid("missing \(key)") }
    let result = try JSONDecoder().decode(Node.self, from: data)
    guard result.zarr_format == 3 else { throw ZarrImportError.unsupported("Zarr version \(result.zarr_format)") }
    return result
  }

  private struct Layout {
    let size: Vec3<Int>
    let spacing: Vec3<Float>
    let hasPhysicalVoxelSpacing: Bool
    let shape: [Int]
    let outerShape: [Int]
    let innerShape: [Int]
    let shard: Configuration?
    let bytes: Int
    let signed: Bool
    let floating: Bool
    let components: Int
    let outputBytes: Int
    let sampleBytes: Int
    let fill: Data
    let x: Int, y: Int, z: Int, c: Int?

    init(_ node: Node, axes: [Axis], transforms: [Transform]) throws {
      guard node.node_type == "array", let shape = node.shape, (3...5).contains(shape.count),
            shape.allSatisfy({ $0 > 0 }), axes.count == shape.count,
            Set(axes.map(\.name)).count == axes.count,
            axes.allSatisfy({ ["x", "y", "z", "c", "t"].contains($0.name) }),
            let x = axes.firstIndex(where: { $0.name == "x" }),
            let y = axes.firstIndex(where: { $0.name == "y" }),
            let z = axes.firstIndex(where: { $0.name == "z" }),
            node.dimension_names == nil || node.dimension_names == axes.map(\.name) else {
        throw ZarrImportError.unsupported("expected named spatial axes x/y/z and optional c/t")
      }
      if let time = axes.firstIndex(where: { $0.name == "t" }), shape[time] != 1 {
        throw ZarrImportError.unsupported("time series; select one time point before importing")
      }
      self.x = x; self.y = y; self.z = z
      c = axes.firstIndex(where: { $0.name == "c" })
      components = c.map { shape[$0] } ?? 1
      guard (1...4).contains(components) else { throw ZarrImportError.unsupported("more than four channels") }
      signed = node.data_type?.hasPrefix("int") == true
      floating = node.data_type?.hasPrefix("float") == true
      switch node.data_type {
        case "uint8", "int8": bytes = 1
        case "uint16", "int16": bytes = 2
        case "uint32", "int32", "float32": bytes = 4
        case "float64": bytes = 8
        default: throw ZarrImportError.unsupported("sample type \(node.data_type ?? "missing"); expected uint8/16/32, int8/16/32 or float32/64")
      }
      self.shape = shape
      size = Vec3(x: shape[x], y: shape[y], z: shape[z])
      outputBytes = try ZarrParser.product(shape + [bytes])
      guard node.storage_transformers?.isEmpty ?? true,
            let grid = node.chunk_grid, grid.name == "regular",
            let key = node.chunk_key_encoding, ["default", "v2"].contains(key.name),
            ["/", "."].contains(key.configuration?.separator ?? (key.name == "default" ? "/" : ".")),
            let codecs = node.codecs, !codecs.isEmpty else {
        throw ZarrImportError.unsupported("chunk grid, key encoding or storage transformer")
      }
      outerShape = grid.configuration.chunk_shape
      guard outerShape.count == shape.count, outerShape.allSatisfy({ $0 > 0 }) else {
        throw ZarrImportError.invalid("chunk shape")
      }
      if codecs.first?.name == "sharding_indexed" {
        guard codecs.count == 1, let config = codecs[0].configuration,
              let inner = config.chunk_shape, inner.count == shape.count,
              zip(outerShape, inner).allSatisfy({ $1 > 0 && $0 % $1 == 0 }),
              let innerCodecs = config.codecs, let indexCodecs = config.index_codecs,
              config.index_location == nil || ["start", "end"].contains(config.index_location!),
              indexCodecs.map(\.name) == ["bytes"] || indexCodecs.map(\.name) == ["bytes", "crc32c"],
              indexCodecs[0].configuration?.endian == "little" else {
          throw ZarrImportError.unsupported("sharding configuration")
        }
        try ZarrParser.validateCodecs(innerCodecs, bytes: bytes)
        guard try ZarrParser.product(zip(outerShape, inner).map { $0 / $1 }) <= 1000000 else {
          throw ZarrImportError.invalid("too many chunks per shard")
        }
        shard = config; innerShape = inner
      } else {
        try ZarrParser.validateCodecs(codecs, bytes: bytes)
        shard = nil; innerShape = outerShape
      }
      sampleBytes = try ZarrParser.product(innerShape + [bytes])
      guard sampleBytes <= ZarrStore.maximumChunkBytes else { throw ZarrImportError.invalid("chunk exceeds size limit") }
      let fillValue = node.fill_value?.value ?? 0
      let value: UInt64
      if floating {
        guard bytes == 8 || !fillValue.isFinite || Float(fillValue).isFinite else {
          throw ZarrImportError.invalid("fill value does not fit float32")
        }
        value = bytes == 4 ? UInt64(Float(fillValue).bitPattern) : fillValue.bitPattern
      } else {
        let limit = Double(UInt64(1) << (bytes * 8 - (signed ? 1 : 0)))
        guard fillValue.isFinite, fillValue >= (signed ? -limit : 0),
              fillValue < limit, fillValue.rounded() == fillValue else {
          throw ZarrImportError.invalid("fill value does not fit sample type")
        }
        value = UInt64(bitPattern: Int64(fillValue))
      }
      fill = Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
      var scale = [Double](repeating: 1, count: shape.count)
      for transform in transforms {
        switch transform.type {
          case "scale":
            guard let values = transform.scale, values.count == shape.count,
                  values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ZarrImportError.invalid("axis scales") }
            scale = zip(scale, values).map(*)
          case "translation":
            guard let values = transform.translation, values.count == shape.count,
                  values.allSatisfy(\.isFinite) else { throw ZarrImportError.invalid("axis translation") }
          default: throw ZarrImportError.unsupported("coordinate transform \(transform.type)")
        }
      }
      // Unknown units must not silently turn arbitrary spacings into meters.
      // As for PVM/I3M, unitless data use a longest extent of one meter.
      let spatial = [x, y, z]
      let units = spatial.map { axes[$0].unit }
      hasPhysicalVoxelSpacing = units.contains { $0 != nil }
      let values: [Double]
      if units.allSatisfy({ $0 == nil }) {
        let longest = spatial.map { scale[$0] * Double(shape[$0]) }.max()!
        values = spatial.map { scale[$0] / longest }
      } else {
        let meters: [String: Double] = ["meter": 1, "centimeter": 0.01, "millimeter": 0.001,
          "micrometer": 0.000_001, "nanometer": 1e-9, "picometer": 1e-12]
        values = try spatial.map { index in
          guard let unit = axes[index].unit, let factor = meters[unit] else {
            throw ZarrImportError.unsupported("missing or unknown spatial unit")
          }
          return scale[index] * factor
        }
      }
      guard values.allSatisfy({ Float($0).isFinite && Float($0) > 0 }) else {
        throw ZarrImportError.invalid("voxel spacing")
      }
      spacing = Vec3(x: Float(values[0]), y: Float(values[1]), z: Float(values[2]))
    }

    func convertSamples(_ memory: UnsafeMutableRawPointer, cancellationCheck: (() throws -> Void)?,
                        progress: ((Double) -> Void)?, log: ((String) -> Void)?) throws {
      let count = outputBytes / bytes
      if signed {
        // Flipping the sign bit is exactly addition of -Int.min, without overflow.
        for start in stride(from: 0, to: count, by: 1000000) {
          try cancellationCheck?()
          for i in start..<min(start + 1000000, count) {
            let offset = i * bytes + bytes - 1
            let value = memory.load(fromByteOffset: offset, as: UInt8.self)
            memory.storeBytes(of: value ^ 0x80, toByteOffset: offset, as: UInt8.self)
          }
          progress?(0.9 + 0.1 * Double(min(start + 1000000, count)) / Double(count))
        }
      }
      guard floating else { return }
      func sample(_ i: Int) -> Double {
        if bytes == 4 {
          return Double(Float(bitPattern: UInt32(littleEndian: memory.loadUnaligned(fromByteOffset: i * bytes, as: UInt32.self))))
        }
        return Double(bitPattern: UInt64(littleEndian: memory.loadUnaligned(fromByteOffset: i * bytes, as: UInt64.self)))
      }
      var minimum = [Double](repeating: .infinity, count: components)
      var maximum = [Double](repeating: -.infinity, count: components)
      for start in stride(from: 0, to: count, by: 1000000) {
        try cancellationCheck?()
        for i in start..<min(start + 1000000, count) {
          let value = sample(i), channel = i % components
          if value.isFinite {
            minimum[channel] = min(minimum[channel], value)
            maximum[channel] = max(maximum[channel], value)
          }
        }
        progress?(0.8 + 0.1 * Double(min(start + 1000000, count)) / Double(count))
      }
      for channel in 0..<components {
        let range = minimum[channel].isFinite ? "\(minimum[channel]) ... \(maximum[channel])" : "none"
        log?("Zarr channel \(channel + 1): original finite range \(range); quantizing to UInt16 (0 ... 65535). Constant/NaN/-Infinity -> 0; +Infinity -> 65535.")
      }
      // Shrink forwards in place: each destination lies before unread source samples.
      for start in stride(from: 0, to: count, by: 1000000) {
        try cancellationCheck?()
        for i in start..<min(start + 1000000, count) {
          let value = sample(i), channel = i % components
          let low = minimum[channel], high = maximum[channel]
          let normalized: Double
          if value == .infinity { normalized = 1 }
          else if !value.isFinite || !(high > low) { normalized = 0 }
          else if (high - low).isFinite { normalized = (value - low) / (high - low) }
          else { normalized = (value / 2 - low / 2) / (high / 2 - low / 2) }
          let result = UInt16((min(1, max(0, normalized)) * 65535).rounded()).littleEndian
          memory.storeBytes(of: result, toByteOffset: i * 2, as: UInt16.self)
        }
        progress?(0.9 + 0.1 * Double(min(start + 1000000, count)) / Double(count))
      }
    }

    func write(_ encoded: Data?, origin: [Int], codecs: [Codec], to output: UnsafeMutableRawPointer) throws {
      let little = bytes == 1 || codecs[0].configuration?.endian == "little"
      let decoded: Data
      if let encoded { decoded = try ZarrParser.decode(encoded, codecs: codecs, size: sampleBytes) }
      else {
        // Missing chunks use the array's fill value, independent of byte order.
        let target = little ? fill : Data(fill.reversed())
        var data = Data(count: sampleBytes)
        data.withUnsafeMutableBytes { buffer in
          for i in stride(from: 0, to: sampleBytes, by: bytes) {
            for b in 0..<bytes { buffer[i + b] = target[b] }
          }
        }
        decoded = data
      }
      let extent = zip(zip(shape, origin), innerShape).map { min($0.0 - $0.1, $1) }
      var strides = [Int](repeating: 1, count: shape.count)
      for i in stride(from: shape.count - 2, through: 0, by: -1) { strides[i] = strides[i + 1] * innerShape[i + 1] }
      try decoded.withUnsafeBytes { source in
        var rows = extent
        rows[x] = 1
        try ZarrParser.coordinates(rows) { coordinate in
          let inputBase = zip(coordinate, strides).reduce(0) { $0 + $1.0 * $1.1 } * bytes
          let global = zip(coordinate, origin).map(+)
          let voxel = (global[z] * size.y + global[y]) * size.x + global[x]
          let destination = (voxel * components + (c.map { global[$0] } ?? 0)) * bytes
          if little && components == 1 && strides[x] == 1 {
            output.advanced(by: destination).copyMemory(from: source.baseAddress!.advanced(by: inputBase), byteCount: extent[x] * bytes)
          } else {
            for ix in 0..<extent[x] {
              for b in 0..<bytes {
                output.storeBytes(of: source[inputBase + ix * strides[x] * bytes + (little ? b : bytes - 1 - b)],
                                  toByteOffset: destination + ix * components * bytes + b, as: UInt8.self)
              }
            }
          }
        }
      }
    }
  }

  private static func validateCodecs(_ codecs: [Codec], bytes: Int) throws {
    guard codecs.first?.name == "bytes", bytes == 1 || ["little", "big"].contains(codecs[0].configuration?.endian ?? "") else {
      throw ZarrImportError.unsupported("bytes codec or byte order")
    }
    let names = Array(codecs.dropFirst().map(\.name))
    guard [[], ["zstd"], ["gzip"], ["crc32c"], ["zstd", "crc32c"], ["gzip", "crc32c"]].contains(names) else {
      throw ZarrImportError.unsupported("codec pipeline \(names.joined(separator: ", "))")
    }
  }

  private static func decode(_ data: Data, codecs: [Codec], size: Int) throws -> Data {
    var result = data
    for codec in codecs.reversed() {
      switch codec.name {
        case "bytes": break
        case "zstd": result = try ZstandardDecoder.decode(result, expectedSize: size)
        case "gzip": result = try ZarrCompression.inflate(result, size: size, windowBits: MAX_WBITS + 16)
        case "crc32c":
          guard result.count >= 4 else { throw ZarrImportError.invalid("missing CRC32C") }
          let expected = UInt32(try result.zarrInteger(result.count - 4, 4))
          result.removeLast(4)
          guard ZarrCompression.crc32c(result) == expected else { throw ZarrImportError.invalid("CRC32C mismatch") }
        default: throw ZarrImportError.unsupported("codec \(codec.name)")
      }
    }
    guard result.count == size else { throw ZarrImportError.invalid("decoded chunk size mismatch") }
    return result
  }

  private static func product(_ values: [Int]) throws -> Int {
    var result = 1
    for value in values {
      let next = result.multipliedReportingOverflow(by: value)
      guard value > 0, !next.overflow else { throw ZarrImportError.invalid("dimension product overflow") }
      result = next.partialValue
    }
    return result
  }

  private static func coordinates(_ shape: [Int], _ body: ([Int]) throws -> Void) throws {
    var coordinate = [Int](repeating: 0, count: shape.count)
    while true {
      try body(coordinate)
      var axis = shape.count - 1
      coordinate[axis] += 1
      while coordinate[axis] == shape[axis] {
        coordinate[axis] = 0
        if axis == 0 { return }
        axis -= 1
        coordinate[axis] += 1
      }
    }
  }
}
