import Foundation

final class BorgVRRegistrationLevel: @unchecked Sendable {
  let source: BorgVRRawVolumeSource
  let isSigned: Bool
  let pixelPaddingValue: Int32?
  private let temporaryURL: URL?

  var size: Vec3<Int> { source.size }

  init(
    source: BorgVRRawVolumeSource,
    isSigned: Bool,
    pixelPaddingValue: Int32?,
    temporaryURL: URL?
  ) {
    self.source = source
    self.isSigned = isSigned
    self.pixelPaddingValue = pixelPaddingValue
    self.temporaryURL = temporaryURL
  }

  deinit {
    if let temporaryURL {
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }
}

enum BorgVRRegistrationDownsampler {
  static func downsample(
    _ level: BorgVRRegistrationLevel,
    factors: Vec3<Int>,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil
  ) throws -> BorgVRRegistrationLevel {
    guard level.source.componentCount == 1,
          [1, 2, 4].contains(level.source.bytesPerComponent) else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    let source = try RawFileAccessor(
      filename: level.source.url.path,
      size: level.source.size,
      bytesPerComponent: level.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: level.source.voxelSpacing,
      offset: level.source.offset,
      readOnly: true
    )
    let targetSize = Vec3<Int>(
      x: reducedSize(source.size.x, factor: factors.x),
      y: reducedSize(source.size.y, factor: factors.y),
      z: reducedSize(source.size.z, factor: factors.z)
    )
    let voxelCount = try checkedProduct(targetSize.x, targetSize.y, targetSize.z)
    let byteCount = try checkedProduct(voxelCount, source.bytesPerComponent)
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-registration-\(UUID().uuidString).raw")

    do {
      let target = try MemoryMappedFile(filename: outputURL.path, size: Int64(byteCount))
      switch (source.bytesPerComponent, level.isSigned) {
        case (1, false):
          try downsampleValues(
            source: source.mappedMemory.assumingMemoryBound(to: UInt8.self),
            target: target.mappedMemory.assumingMemoryBound(to: UInt8.self),
            sourceSize: source.size,
            targetSize: targetSize,
            paddingValue: level.pixelPaddingValue.map { UInt8(truncatingIfNeeded: $0) },
            factors: factors,
            cancellationToken: cancellationToken
          )
        case (1, true):
          try downsampleValues(
            source: source.mappedMemory.assumingMemoryBound(to: Int8.self),
            target: target.mappedMemory.assumingMemoryBound(to: Int8.self),
            sourceSize: source.size,
            targetSize: targetSize,
            paddingValue: level.pixelPaddingValue.map { Int8(truncatingIfNeeded: $0) },
            factors: factors,
            cancellationToken: cancellationToken
          )
        case (2, false):
          try downsampleValues(
            source: source.mappedMemory.assumingMemoryBound(to: UInt16.self),
            target: target.mappedMemory.assumingMemoryBound(to: UInt16.self),
            sourceSize: source.size,
            targetSize: targetSize,
            paddingValue: level.pixelPaddingValue.map { UInt16(truncatingIfNeeded: $0) },
            factors: factors,
            cancellationToken: cancellationToken
          )
        case (2, true):
          try downsampleValues(
            source: source.mappedMemory.assumingMemoryBound(to: Int16.self),
            target: target.mappedMemory.assumingMemoryBound(to: Int16.self),
            sourceSize: source.size,
            targetSize: targetSize,
            paddingValue: level.pixelPaddingValue.map { Int16(truncatingIfNeeded: $0) },
            factors: factors,
            cancellationToken: cancellationToken
          )
        case (4, false):
          try downsampleValues(
            source: source.mappedMemory.assumingMemoryBound(to: UInt32.self),
            target: target.mappedMemory.assumingMemoryBound(to: UInt32.self),
            sourceSize: source.size,
            targetSize: targetSize,
            paddingValue: level.pixelPaddingValue.map { UInt32(truncatingIfNeeded: $0) },
            factors: factors,
            cancellationToken: cancellationToken
          )
        case (4, true):
          try downsampleValues(
            source: source.mappedMemory.assumingMemoryBound(to: Int32.self),
            target: target.mappedMemory.assumingMemoryBound(to: Int32.self),
            sourceSize: source.size,
            targetSize: targetSize,
            paddingValue: level.pixelPaddingValue,
            factors: factors,
            cancellationToken: cancellationToken
          )
        default:
          throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
      }
      try target.sync()
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }

    return BorgVRRegistrationLevel(
      source: BorgVRRawVolumeSource(
        url: outputURL,
        offset: 0,
        size: targetSize,
        bytesPerComponent: level.source.bytesPerComponent,
        componentCount: 1,
        voxelSpacing: Vec3<Float>(
          x: level.source.voxelSpacing.x * Float(factors.x),
          y: level.source.voxelSpacing.y * Float(factors.y),
          z: level.source.voxelSpacing.z * Float(factors.z)
        )
      ),
      isSigned: level.isSigned,
      pixelPaddingValue: level.pixelPaddingValue,
      temporaryURL: outputURL
    )
  }

  private static func downsampleValues<Value: FixedWidthInteger>(
    source: UnsafePointer<Value>,
    target: UnsafeMutablePointer<Value>,
    sourceSize: Vec3<Int>,
    targetSize: Vec3<Int>,
    paddingValue: Value?,
    factors: Vec3<Int>,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let xTaps = kernelTaps(factor: factors.x)
    let yTaps = kernelTaps(factor: factors.y)
    let zTaps = kernelTaps(factor: factors.z)

    for z in 0..<targetSize.z {
      try cancellationToken?.checkCancellation()
      let sourceZCenter = z * factors.z
      for y in 0..<targetSize.y {
        let sourceYCenter = y * factors.y
        for x in 0..<targetSize.x {
          let sourceXCenter = x * factors.x
          var weightedSum: Double = 0
          var validWeight: Double = 0

          for zTap in zTaps {
            let sourceZ = reflectedIndex(sourceZCenter + zTap.offset, count: sourceSize.z)
            for yTap in yTaps {
              let sourceY = reflectedIndex(sourceYCenter + yTap.offset, count: sourceSize.y)
              for xTap in xTaps {
                let sourceX = reflectedIndex(sourceXCenter + xTap.offset, count: sourceSize.x)
                let sourceIndex = (sourceZ * sourceSize.y + sourceY) * sourceSize.x + sourceX
                let value = source[sourceIndex]
                if value == paddingValue { continue }
                let weight = Double(xTap.weight * yTap.weight * zTap.weight)
                weightedSum += Double(value) * weight
                validWeight += weight
              }
            }
          }

          let targetIndex = (z * targetSize.y + y) * targetSize.x + x
          target[targetIndex] = validWeight > 0
            ? quantize(weightedSum / validWeight, as: Value.self)
            : paddingValue ?? 0
        }
      }
    }
  }

  private struct KernelTap {
    let offset: Int
    let weight: Int
  }

  private static func kernelTaps(factor: Int) -> [KernelTap] {
    factor == 2
      ? [KernelTap(offset: -1, weight: 1),
         KernelTap(offset: 0, weight: 2),
         KernelTap(offset: 1, weight: 1)]
      : [KernelTap(offset: 0, weight: 1)]
  }

  private static func reflectedIndex(_ index: Int, count: Int) -> Int {
    guard count > 1 else { return 0 }
    if index < 0 { return -index }
    if index >= count { return 2 * count - index - 2 }
    return index
  }

  private static func reducedSize(_ size: Int, factor: Int) -> Int {
    factor == 2 ? (size + 1) / 2 : size
  }

  private static func quantize<Value: FixedWidthInteger>(
    _ value: Double,
    as: Value.Type
  ) -> Value {
    let rounded = min(max(value.rounded(), Double(Value.min)), Double(Value.max))
    return Value(clamping: Int64(rounded))
  }

  private static func checkedProduct(_ values: Int...) throws -> Int {
    var result = 1
    for value in values {
      let next = result.multipliedReportingOverflow(by: value)
      guard value > 0, !next.overflow else {
        throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
      }
      result = next.partialValue
    }
    return result
  }
}

struct BorgVRRigidTransform: Sendable {
  let xAxis: Vec3<Float>
  let yAxis: Vec3<Float>
  let zAxis: Vec3<Float>
  let translation: Vec3<Float>

  static let identity = BorgVRRigidTransform(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1),
    translation: .zero
  )

  /// Maps reference-local metric coordinates to moving-local metric coordinates.
  func applying(to point: Vec3<Float>) -> Vec3<Float> {
    xAxis * point.x
      + yAxis * point.y
      + zAxis * point.z
      + translation
  }
}

enum BorgVRDICOMRigidRegistration {
  private static let minimumAxisLength = 16

  private struct Level: Sendable {
    let reference: BorgVRRegistrationLevel
    let moving: BorgVRRegistrationLevel
  }

  static func register(
    reference: BorgVRUnbrickedVolume,
    moving: BorgVRUnbrickedVolume,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil
  ) throws -> BorgVRRigidTransform {
    guard reference.source.componentCount == 1,
          moving.source.componentCount == 1,
          reference.source.bytesPerComponent == moving.source.bytesPerComponent else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    let initialTransform = dicomInitialTransform(reference: reference, moving: moving)
    logger?.info("Starting recursive rigid DICOM registration.")
    return try register(
      level: Level(
        reference: registrationLevel(from: reference),
        moving: registrationLevel(from: moving)
      ),
      dicomInitialTransform: initialTransform,
      logger: logger,
      cancellationToken: cancellationToken
    )
  }

  private static func register(
    level: Level,
    dicomInitialTransform: BorgVRRigidTransform,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRigidTransform {
    try cancellationToken?.checkCancellation()

    let referenceFactors = downsamplingFactors(for: level.reference.size)
    let movingFactors = downsamplingFactors(for: level.moving.size)
    let initialTransform: BorgVRRigidTransform
    if referenceFactors != nil || movingFactors != nil {
      let smallerLevel = Level(
        reference: try downsample(
          level.reference,
          factors: referenceFactors,
          cancellationToken: cancellationToken
        ),
        moving: try downsample(
          level.moving,
          factors: movingFactors,
          cancellationToken: cancellationToken
        )
      )
      initialTransform = try register(
        level: smallerLevel,
        dicomInitialTransform: dicomInitialTransform,
        logger: logger,
        cancellationToken: cancellationToken
      )
    } else {
      initialTransform = dicomInitialTransform
    }

    logger?.info(
      "Optimizing DICOM registration level "
        + "\(level.reference.size.x) x \(level.reference.size.y) x "
        + "\(level.reference.size.z) / "
        + "\(level.moving.size.x) x \(level.moving.size.y) x "
        + "\(level.moving.size.z)."
    )
    return try optimize(
      level: level,
      initialTransform: initialTransform,
      cancellationToken: cancellationToken
    )
  }

  private static func optimize(
    level: Level,
    initialTransform: BorgVRRigidTransform,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRigidTransform {
    try cancellationToken?.checkCancellation()
    _ = level
    return initialTransform
  }

  private static func downsamplingFactors(for size: Vec3<Int>) -> Vec3<Int>? {
    let factors = Vec3<Int>(
      x: canDownsample(size.x) ? 2 : 1,
      y: canDownsample(size.y) ? 2 : 1,
      z: canDownsample(size.z) ? 2 : 1
    )
    return factors == Vec3<Int>(repeating: 1) ? nil : factors
  }

  private static func canDownsample(_ size: Int) -> Bool {
    size > 1 && (size + 1) / 2 >= minimumAxisLength
  }

  private static func downsample(
    _ level: BorgVRRegistrationLevel,
    factors: Vec3<Int>?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRegistrationLevel {
    guard let factors else { return level }
    return try BorgVRRegistrationDownsampler.downsample(
      level,
      factors: factors,
      cancellationToken: cancellationToken
    )
  }

  private static func registrationLevel(
    from volume: BorgVRUnbrickedVolume
  ) -> BorgVRRegistrationLevel {
    BorgVRRegistrationLevel(
      source: volume.source,
      isSigned: volume.channels.first?.isSigned ?? false,
      pixelPaddingValue: volume.channels.first?.pixelPaddingValue,
      temporaryURL: nil
    )
  }

  private static func dicomInitialTransform(
    reference: BorgVRUnbrickedVolume,
    moving: BorgVRUnbrickedVolume
  ) -> BorgVRRigidTransform {
    guard let referenceOrientation = reference.orientation,
          let referenceOrigin = reference.origin,
          let movingOrientation = moving.orientation,
          let movingOrigin = moving.origin else {
      return .identity
    }

    let originDelta = referenceOrigin - movingOrigin
    return BorgVRRigidTransform(
      xAxis: Vec3<Float>(
        x: movingOrientation.xAxis.dot(referenceOrientation.xAxis),
        y: movingOrientation.yAxis.dot(referenceOrientation.xAxis),
        z: movingOrientation.zAxis.dot(referenceOrientation.xAxis)
      ),
      yAxis: Vec3<Float>(
        x: movingOrientation.xAxis.dot(referenceOrientation.yAxis),
        y: movingOrientation.yAxis.dot(referenceOrientation.yAxis),
        z: movingOrientation.zAxis.dot(referenceOrientation.yAxis)
      ),
      zAxis: Vec3<Float>(
        x: movingOrientation.xAxis.dot(referenceOrientation.zAxis),
        y: movingOrientation.yAxis.dot(referenceOrientation.zAxis),
        z: movingOrientation.zAxis.dot(referenceOrientation.zAxis)
      ),
      translation: Vec3<Float>(
        x: originDelta.dot(movingOrientation.xAxis),
        y: originDelta.dot(movingOrientation.yAxis),
        z: originDelta.dot(movingOrientation.zAxis)
      )
    )
  }
}
