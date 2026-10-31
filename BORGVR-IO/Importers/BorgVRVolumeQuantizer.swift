import Foundation

/// Quantizes each interleaved channel independently before bricking and LOD generation.
enum BorgVRVolumeQuantizer {
  static func quantize(
    _ source: RawFileAccessor,
    signedComponents: [Bool] = [],
    to outputURL: URL,
    logger: LoggerBase? = nil,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil
  ) throws -> RawFileAccessor {
    try cancellationToken?.checkCancellation()
    switch source.bytesPerComponent {
      case 1: return source
      case 2:
        try write(UInt16.self, source: source, signedComponents: signedComponents,
          to: outputURL, logger: logger, cancellationToken: cancellationToken)
      case 4:
        try write(UInt32.self, source: source, signedComponents: signedComponents,
          to: outputURL, logger: logger, cancellationToken: cancellationToken)
      default: throw RawFileAccessor.Error.incompatibleTypeSize
    }
    return try RawFileAccessor(filename: outputURL.path, size: source.size,
      bytesPerComponent: 1, componentCount: source.componentCount,
      voxelSpacing: source.voxelSpacing)
  }

  private static func write<Value: FixedWidthInteger & UnsignedInteger>(
    _ type: Value.Type, source: RawFileAccessor, signedComponents: [Bool],
    to outputURL: URL, logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
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

    logger?.info("Quantizing volume to 8 bits per channel.")
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
      logger?.progress("Analyzing channel ranges", Double(end) / Double(voxelCount))
    }
    for channel in 0..<channels {
      let minimum = Int64(minima[channel]) - Int64(signMasks[channel])
      let maximum = Int64(maxima[channel]) - Int64(signMasks[channel])
      logger?.info("Channel \(channel + 1): original value range \(minimum)...\(maximum); quantizing to 8 bits.")
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
      logger?.progress("Quantizing volume", Double(end) / Double(voxelCount))
    }
    try cancellationToken?.checkCancellation()
    completed = true
  }
}
