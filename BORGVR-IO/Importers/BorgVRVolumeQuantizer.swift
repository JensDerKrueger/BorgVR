import Foundation

/// Quantizes each interleaved channel independently before bricking and LOD generation.
enum BorgVRVolumeQuantizer {
  static func quantize(
    _ source: RawFileAccessor,
    signedComponents: [Bool] = [],
    to outputURL: URL,
    logger: LoggerBase? = nil,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil,
    recordProvenance: ((String) -> Void)? = nil
  ) throws -> RawFileAccessor {
    try cancellationToken?.checkCancellation()
    let originalRanges: String
    switch source.bytesPerComponent {
      case 1: return source
      case 2:
        originalRanges = try write(UInt16.self, source: source, signedComponents: signedComponents,
          to: outputURL, logger: logger, cancellationToken: cancellationToken)
      case 4:
        originalRanges = try write(UInt32.self, source: source, signedComponents: signedComponents,
          to: outputURL, logger: logger, cancellationToken: cancellationToken)
      default: throw RawFileAccessor.Error.incompatibleTypeSize
    }
    let result = try RawFileAccessor(filename: outputURL.path, size: source.size,
      bytesPerComponent: 1, componentCount: source.componentCount,
      voxelSpacing: source.voxelSpacing)
    recordProvenance?("Quantized to UInt8 per channel from \(source.bytesPerComponent * 8)-bit samples; "
      + "independent linear min/max mapping with nearest rounding; original ranges: \(originalRanges)")
    return result
  }

  private static func write<Value: FixedWidthInteger & UnsignedInteger>(
    _ type: Value.Type, source: RawFileAccessor, signedComponents: [Bool],
    to outputURL: URL, logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> String {
    let channels = source.componentCount
    // Flipping the sign bit orders signed samples without changing the source data.
    let signMasks: [Value] = (0..<channels).map {
      signedComponents.indices.contains($0) && signedComponents[$0]
        ? Value(1) << (Value.bitWidth - 1) : 0
    }
    var minima = [Value](repeating: .max, count: channels)
    var maxima = [Value](repeating: 0, count: channels)
    let chunkVoxels = max(1, 1_000_000 / channels)
    let voxelCount = source.totalVoxels

    logger?.info(String(localized: "Quantizing volume to 8 bits per channel.", table: "ImportMessages"))
    for start in stride(from: 0, to: voxelCount, by: chunkVoxels) {
      try cancellationToken?.checkCancellation()
      let end = min(start + chunkVoxels, voxelCount)
      for voxel in start..<end {
        for channel in 0..<channels {
          let offset = (voxel * channels + channel) * MemoryLayout<Value>.stride
          let value = source.mappedMemory.loadUnaligned(fromByteOffset: offset, as: Value.self)
            ^ signMasks[channel]
          minima[channel] = min(minima[channel], value)
          maxima[channel] = max(maxima[channel], value)
        }
      }
      logger?.progress(String(localized: "Analyzing channel ranges", table: "ImportMessages"), Double(end) / Double(voxelCount))
    }
    let originalRanges = (0..<channels).map { channel in
      let minimum = Int64(minima[channel]) - Int64(signMasks[channel])
      let maximum = Int64(maxima[channel]) - Int64(signMasks[channel])
      logger?.info(String(format: String(localized:
        "Channel %ld: original value range %lld...%lld; quantizing to 8 bits.", table: "ImportMessages"),
        channel + 1, minimum, maximum))
      return "channel \(channel + 1): \(minimum)...\(maximum)"
    }

    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
      throw BorgVRVolumeConversionError.cannotCreateTemporaryVolume(outputURL)
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: outputURL) } }
    let ranges = zip(minima, maxima).map { UInt64($1) - UInt64($0) }
    for start in stride(from: 0, to: voxelCount, by: chunkVoxels) {
      try cancellationToken?.checkCancellation()
      let end = min(start + chunkVoxels, voxelCount)
      var bytes = [UInt8](repeating: 0, count: (end - start) * channels)
      for voxel in start..<end {
        for channel in 0..<channels {
          let offset = (voxel * channels + channel) * MemoryLayout<Value>.stride
          let value = source.mappedMemory.loadUnaligned(fromByteOffset: offset, as: Value.self)
            ^ signMasks[channel]
          let range = ranges[channel]
          // UInt64 also keeps full-range UInt32 inputs exact through rounding.
          let quantized = range > 0
            ? UInt8(((UInt64(value) - UInt64(minima[channel])) * 255 + range / 2) / range)
            : (value == signMasks[channel] ? 0 : 255)
          bytes[(voxel - start) * channels + channel] = quantized
        }
      }
      try output.write(contentsOf: Data(bytes))
      logger?.progress(String(localized: "Quantizing volume", table: "ImportMessages"), Double(end) / Double(voxelCount))
    }
    try cancellationToken?.checkCancellation()
    completed = true
    return originalRanges.joined(separator: "; ")
  }
}
