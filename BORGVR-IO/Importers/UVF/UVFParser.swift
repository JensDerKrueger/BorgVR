import Foundation

/// Standalone reader for Tuvok UVF TOC and legacy raster volumes. Only LoD 0
/// is reconstructed; rendering metadata, histograms and geometry are ignored.
/// Layout follows ImageVis3D/Tuvok's GlobalHeader, DataBlock, RasterDataBlock
/// and ExtendedOctree readers.
public final class UVFParser: VolumeFileParser {
  public enum Error: Swift.Error, LocalizedError {
    case invalid(String)
    case unsupported(String)

    public var errorDescription: String? {
      switch self {
        case .invalid(let reason): return "Invalid UVF data: \(reason)."
        case .unsupported(let reason): return "Unsupported UVF data: \(reason)."
      }
    }
  }

  public let sourceFiles: [URL]
  public let absoluteFilename: String
  public let size: Vec3<Int>
  public let voxelSpacing: Vec3<Float>
  public let hasPhysicalVoxelSpacing = false
  public let channelInterpretation: BORGVRChannelInterpretation
  public let bytesPerComponent: Int
  public let components: Int
  public let isLittleEndian = true
  public let offset = 0
  public let dataIsTempCopy = true

  public init(filename: String, cancellationCheck: (() throws -> Void)? = nil,
              progress: ((Double) -> Void)? = nil, log: ((String) -> Void)? = nil) throws {
    try cancellationCheck?()
    let source = URL(fileURLWithPath: filename).standardizedFileURL
    let data = try Data(contentsOf: source, options: .mappedIfSafe)
    let layout = try Self.layout(data, cancellationCheck: cancellationCheck)
    let volumeBytes = try uvfProduct(layout.dimensions + [layout.bytes, layout.outputChannels])
    let longest = zip(layout.spacing, layout.dimensions).map { $0 * Double($1) }.max()!
    let spacing = layout.spacing.map { Float($0 / longest) }
    guard spacing.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Error.invalid("voxel spacing") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("borgvr-uvf-\(UUID()).raw")
    var success = false
    defer { if !success { try? FileManager.default.removeItem(at: temporary) } }
    let output = try MemoryMappedFile(filename: temporary.path, size: Int64(volumeBytes))
    defer { try? output.close() }
    log?(String(format: String(localized: "UVF: extracting LoD 0 (%@, %ld channel(s)).", table: "ImportMessages"),
      layout.dimensions.map(String.init).joined(separator: " x "), layout.outputChannels))
    if layout.normals {
      log?(String(localized: "UVF: discarding precomputed normals; preserving the first (scalar) component.", table: "ImportMessages"))
    }
    let extractionWeight = layout.floating ? 0.8 : (layout.signed ? 0.9 : 1)
    progress?(0)
    try layout.extract(data, into: output.mappedMemory, cancellationCheck: cancellationCheck,
                       progress: { progress?($0 * extractionWeight) })
    try Self.convertSamples(layout, memory: output.mappedMemory, byteCount: volumeBytes,
                            cancellationCheck: cancellationCheck, progress: progress, log: log)
    try cancellationCheck?()
    try output.close()
    if layout.floating {
      let file = try FileHandle(forWritingTo: temporary)
      defer { try? file.close() }
      try file.truncate(atOffset: UInt64(volumeBytes / layout.bytes * 2))
    }
    self.sourceFiles = [] // UVF is self-contained; no sidecars to collect.
    self.absoluteFilename = temporary.path
    self.size = Vec3(layout.dimensions[0], layout.dimensions[1], layout.dimensions[2])
    self.voxelSpacing = Vec3(spacing[0], spacing[1], spacing[2])
    self.bytesPerComponent = layout.outputBytes
    self.components = layout.outputChannels
    // Match ImageVis3D's color-volume interpretation, not an arbitrary set of TFs.
    if !layout.normals && !layout.signed && !layout.floating && layout.bytes == 1 && layout.channels == 3 {
      self.channelInterpretation = .rgb
    } else if !layout.normals && !layout.signed && !layout.floating && layout.bytes == 1 && layout.channels == 4 {
      self.channelInterpretation = .rgba
    } else { self.channelInterpretation = .independentChannels }
    success = true
    progress?(1)
  }

  private static func layout(_ data: Data, cancellationCheck: (() throws -> Void)?) throws -> UVFVolumeLayout {
    var magic = try UVFBinaryReader(data)
    guard try magic.take(8) == Data("UVF-DATA".utf8) else { throw Error.invalid("signature") }
    let endian = try magic.integer(1)
    guard endian <= 1 else { throw Error.invalid("byte order") }
    var header = try UVFBinaryReader(data, start: 9, bigEndian: endian == 1)
    let version = try header.integer(), checksum = try header.integer(), checksumSize = try header.integer()
    guard (1...5).contains(version) else { throw Error.unsupported("file version \(version)") }
    guard (checksum == 0 && checksumSize == 0) || (checksum == 1 && checksumSize == 4) || (checksum == 2 && checksumSize == 16) else {
      throw Error.invalid("checksum header")
    }
    // UVF checksums cover the container, not individual bricks. Codec checksums
    // and all structural bounds are checked; the optional container hash is not.
    try header.skip(checksumSize)
    let padding = try header.integer()
    var block = try uvfAdd(header.position, padding)
    while block < data.count {
      try cancellationCheck?()
      var reader = try UVFBinaryReader(data, start: block, bigEndian: endian == 1)
      let nameLength = try reader.integer()
      try reader.skip(nameLength)
      let semantic = try reader.integer(), compression = try reader.integer(), next = try reader.integer()
      let end = next == 0 ? data.count : try uvfAdd(block, next)
      guard end >= reader.position, end <= data.count, next == 0 || end > block else { throw Error.invalid("block chain") }
      if semantic == 1 || semantic == 9 {
        guard compression == 0 else { throw Error.unsupported("container-level compression") }
        return semantic == 9
          ? try UVFVolumeLayout.toc(data, base: reader.position, end: end, fileVersion: version, cancellationCheck: cancellationCheck)
          : try UVFVolumeLayout.raster(data, base: reader.position, end: end, bigEndian: endian == 1)
      }
      if next == 0 { break }
      block = end
    }
    throw Error.unsupported("no volume block found")
  }

  private static func convertSamples(_ layout: UVFVolumeLayout, memory: UnsafeMutableRawPointer, byteCount: Int,
                                     cancellationCheck: (() throws -> Void)?, progress: ((Double) -> Void)?,
                                     log: ((String) -> Void)?) throws {
    let count = byteCount / layout.bytes
    if layout.signed {
      log?(String(format: String(localized:
        "UVF: shifting signed %ld-bit samples into the unsigned range by flipping the sign bit.", table: "ImportMessages"), layout.bytes * 8))
      for start in stride(from: 0, to: count, by: 1000000) {
        try cancellationCheck?()
        let end = start + min(1000000, count - start)
        for i in start..<end {
          let offset = i * layout.bytes + layout.bytes - 1
          memory.storeBytes(of: memory.load(fromByteOffset: offset, as: UInt8.self) ^ 0x80, toByteOffset: offset, as: UInt8.self)
        }
        progress?(0.9 + 0.1 * Double(end) / Double(count))
      }
    }
    guard layout.floating else { return }
    func sample(_ i: Int) -> Double {
      if layout.bytes == 4 {
        return Double(Float(bitPattern: UInt32(littleEndian: memory.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))))
      }
      return Double(bitPattern: UInt64(littleEndian: memory.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)))
    }
    let channels = layout.outputChannels
    var minimum = [Double](repeating: .infinity, count: channels)
    var maximum = [Double](repeating: -.infinity, count: channels)
    for start in stride(from: 0, to: count, by: 1000000) {
      try cancellationCheck?()
      let end = start + min(1000000, count - start)
      for i in start..<end {
        let value = sample(i), channel = i % channels
        if value.isFinite { minimum[channel] = min(minimum[channel], value); maximum[channel] = max(maximum[channel], value) }
      }
      progress?(0.8 + 0.1 * Double(end) / Double(count))
    }
    for channel in 0..<channels {
      let range = minimum[channel].isFinite ? "\(minimum[channel]) ... \(maximum[channel])"
        : String(localized: "none", table: "ImportMessages")
      log?(String(format: String(localized:
        "%@ channel %ld: original finite range %@; quantizing to UInt16 (0 ... 65535). Constant/NaN/-Infinity -> 0; +Infinity -> 65535.",
        table: "ImportMessages"), "UVF", channel + 1, range))
    }
    // Shrink forwards in place, without allocating another full volume.
    for start in stride(from: 0, to: count, by: 1000000) {
      try cancellationCheck?()
      let end = start + min(1000000, count - start)
      for i in start..<end {
        let value = sample(i), channel = i % channels
        let low = minimum[channel], high = maximum[channel]
        let normalized: Double
        if value == .infinity { normalized = 1 }
        else if !value.isFinite || !(high > low) { normalized = 0 }
        else if (high - low).isFinite { normalized = (value - low) / (high - low) }
        else { normalized = (value / 2 - low / 2) / (high / 2 - low / 2) }
        memory.storeBytes(of: UInt16((min(1, max(0, normalized)) * 65535).rounded()).littleEndian,
                          toByteOffset: i * 2, as: UInt16.self)
      }
      progress?(0.9 + 0.1 * Double(end) / Double(count))
    }
  }
}
