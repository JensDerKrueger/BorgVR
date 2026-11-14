import Foundation

/// Sun/GE raster VFF: ASCII assignments terminated by form feed, then XYZ samples.
/// Layout/sign convention follows Tuvok/IO/VFFConverter.cpp. GE's elementsize is
/// in millimeters (OME Bio-Formats MicroCTReader); spacing supplies axis factors.
/// https://github.com/ome/bioformats/blob/develop/components/formats-gpl/src/loci/formats/in/MicroCTReader.java
public final class VFFParser: VolumeFileParser {
  public enum Error: Swift.Error, LocalizedError {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
      switch self {
        case .invalid(let reason): return "Invalid VFF data: \(reason)."
        case .unsupported(let reason): return "Unsupported VFF data: \(reason)."
      }
    }
  }

  public let absoluteFilename: String
  public let size: Vec3<Int>
  public let voxelSpacing: Vec3<Float>
  public let hasPhysicalVoxelSpacing: Bool
  public let bytesPerComponent: Int
  public let components = 1
  public let isLittleEndian = true
  public let offset = 0
  public let dataIsTempCopy = true

  public init(filename: String, cancellationCheck: (() throws -> Void)? = nil,
              progress: ((Double) -> Void)? = nil, log: ((String) -> Void)? = nil) throws {
    try cancellationCheck?()
    let data = try Data(contentsOf: URL(fileURLWithPath: filename), options: .mappedIfSafe)
    guard data.starts(with: Data("ncaa".utf8)),
          let delimiter = data.prefix(1 << 20).firstIndex(of: 12),
          let header = String(data: data[4..<delimiter], encoding: .ascii) else {
      throw Error.invalid("missing ncaa signature or ASCII header terminator")
    }
    let fields = try Self.fields(header)
    guard fields["type"]?.lowercased() == "raster",
          fields["format"]?.lowercased() == "slice" else {
      throw Error.unsupported("only raster volumes with slice layout are supported")
    }
    guard let rank = Int(fields["rank"] ?? ""), (2...3).contains(rank) else {
      throw Error.unsupported("rank must be 2 or 3")
    }
    guard fields["bands"] == "1" else { throw Error.unsupported("only scalar volumes are supported") }
    guard let bits = Int(fields["bits"] ?? ""), [8, 16, 32].contains(bits) else {
      throw Error.unsupported("expected signed 8-, 16- or 32-bit integer samples")
    }
    if let compression = fields["compression"], compression.lowercased() != "none" {
      throw Error.unsupported("compressed voxel payload")
    }
    if let sampleType = fields["data_type"], !["integer", "signed"].contains(sampleType.lowercased()) {
      throw Error.unsupported("non-integer sample type")
    }
    let dimensionTokens = (fields["size"] ?? "").split(whereSeparator: \.isWhitespace)
    let dimensions = dimensionTokens.compactMap { Int($0) }
    guard dimensionTokens.count == rank, dimensions.count == rank, dimensions.allSatisfy({ $0 > 0 }) else {
      throw Error.invalid("size does not match rank")
    }
    var axes = dimensions
    if rank == 2 { axes.append(1) }
    let bytes = bits / 8
    var byteCount = bytes
    for axis in axes {
      let (product, overflow) = byteCount.multipliedReportingOverflow(by: axis)
      guard !overflow else { throw Error.invalid("volume size overflows") }
      byteCount = product
    }
    var payload = delimiter + 1
    // A normal VFF ends its header with FF/LF (or FF/CRLF). Also accept a bare
    // FF when the remaining byte count is exact, without eating a first voxel 10.
    if data.count - payload != byteCount {
      if payload < data.count, data[payload] == 13 { payload += 1 }
      guard payload < data.count, data[payload] == 10 else {
        throw Error.invalid("missing header newline or truncated voxel payload")
      }
      payload += 1
    }
    guard data.count - payload == byteCount else {
      throw Error.invalid("voxel payload size does not match dimensions and bit depth")
    }
    var spacing = [Double](repeating: 1, count: 3)
    if let value = fields["spacing"] {
      let tokens = value.split(whereSeparator: \.isWhitespace)
      let values = tokens.compactMap { Double($0) }
      guard tokens.count == rank, values.count == rank, values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw Error.invalid("spacing must be finite and positive")
      }
      for axis in 0..<rank { spacing[axis] = values[axis] }
    }
    let physical = fields["elementsize"] != nil || fields["spacingunit"] != nil
    if physical {
      let elementSize = Double(fields["elementsize"] ?? "1") ?? .nan
      guard elementSize.isFinite, elementSize > 0 else { throw Error.invalid("elementsize") }
      let unit: Double
      switch (fields["spacingunit"] ?? "mm").lowercased() {
        case "m", "meter", "meters": unit = 1
        case "cm": unit = 0.01
        case "mm": unit = 0.001
        case "um", "micron", "microns": unit = 0.000001
        default: throw Error.unsupported("spacing unit")
      }
      spacing = spacing.map { $0 * elementSize * unit }
    } else {
      let longest = zip(spacing, axes).map { $0 * Double($1) }.max()!
      spacing = spacing.map { $0 / longest }
    }
    let convertedSpacing = spacing.map(Float.init)
    guard convertedSpacing.allSatisfy({ $0.isFinite && $0 > 0 }) else {
      throw Error.invalid("voxel spacing cannot be represented")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-vff-\(UUID()).raw")
    var succeeded = false
    defer { if !succeeded { try? FileManager.default.removeItem(at: temporary) } }
    let output = try MemoryMappedFile(filename: temporary.path, size: Int64(byteCount))
    defer { try? output.close() }
    log?(String(format: String(localized:
      "VFF: reading %@, signed %ld-bit Big Endian samples; shifting into the unsigned range.", table: "ImportMessages"),
      axes.map(String.init).joined(separator: " x "), bits))
    progress?(0)
    try data.withUnsafeBytes { source in
      let samples = UnsafeRawBufferPointer(rebasing: source[payload..<(payload + byteCount)])
      switch bytes {
        case 1: try Self.convert(UInt8.self, samples, to: output.mappedMemory, cancellationCheck, progress)
        case 2: try Self.convert(UInt16.self, samples, to: output.mappedMemory, cancellationCheck, progress)
        default: try Self.convert(UInt32.self, samples, to: output.mappedMemory, cancellationCheck, progress)
      }
    }
    try cancellationCheck?()
    try output.close()
    absoluteFilename = temporary.path
    size = Vec3(axes[0], axes[1], axes[2])
    bytesPerComponent = bytes
    voxelSpacing = Vec3(convertedSpacing[0], convertedSpacing[1], convertedSpacing[2])
    hasPhysicalVoxelSpacing = physical
    succeeded = true
  }

  private static func convert<T: FixedWidthInteger & UnsignedInteger>(
    _ type: T.Type, _ source: UnsafeRawBufferPointer, to target: UnsafeMutableRawPointer,
    _ cancellationCheck: (() throws -> Void)?, _ progress: ((Double) -> Void)?
  ) throws {
    let width = MemoryLayout<T>.size
    let count = source.count / width
    let signBit: T = 1 << (T.bitWidth - 1)
    let output = target.assumingMemoryBound(to: T.self)
    for start in stride(from: 0, to: count, by: 1000000) {
      try cancellationCheck?()
      let end = start + min(1000000, count - start)
      for i in start..<end {
        let value = T(bigEndian: source.loadUnaligned(fromByteOffset: i * width, as: T.self)) ^ signBit
        output[i] = value.littleEndian
      }
      progress?(Double(end) / Double(count))
    }
  }

  private static func fields(_ header: String) throws -> [String: String] {
    var result: [String: String] = [:]
    var quoted = false
    var start = header.startIndex
    for index in header.indices {
      if header[index] == "\"" { quoted.toggle() }
      if header[index] == ";", !quoted {
        let assignment = header[start..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = assignment.firstIndex(of: "=") else { throw Error.invalid("header assignment") }
        let key = assignment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = assignment[assignment.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, result[key] == nil else { throw Error.invalid("duplicate or empty header key") }
        result[key] = value
        start = header.index(after: index)
      }
    }
    guard !quoted, header[start...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Error.invalid("unterminated header assignment")
    }
    return result
  }
}
