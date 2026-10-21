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

struct BorgVRVoxelTransform: Sendable {
  let xAxis: Vec3<Float>
  let yAxis: Vec3<Float>
  let zAxis: Vec3<Float>
  let translation: Vec3<Float>

  static let identity = BorgVRVoxelTransform(
    xAxis: Vec3<Float>(x: 1, y: 0, z: 0),
    yAxis: Vec3<Float>(x: 0, y: 1, z: 0),
    zAxis: Vec3<Float>(x: 0, y: 0, z: 1),
    translation: .zero
  )

  init(
    metricTransform: BorgVRRigidTransform,
    referenceSpacing: Vec3<Float>,
    movingSpacing: Vec3<Float>
  ) {
    xAxis = Vec3<Float>(
      x: metricTransform.xAxis.x * referenceSpacing.x / movingSpacing.x,
      y: metricTransform.xAxis.y * referenceSpacing.x / movingSpacing.y,
      z: metricTransform.xAxis.z * referenceSpacing.x / movingSpacing.z
    )
    yAxis = Vec3<Float>(
      x: metricTransform.yAxis.x * referenceSpacing.y / movingSpacing.x,
      y: metricTransform.yAxis.y * referenceSpacing.y / movingSpacing.y,
      z: metricTransform.yAxis.z * referenceSpacing.y / movingSpacing.z
    )
    zAxis = Vec3<Float>(
      x: metricTransform.zAxis.x * referenceSpacing.z / movingSpacing.x,
      y: metricTransform.zAxis.y * referenceSpacing.z / movingSpacing.y,
      z: metricTransform.zAxis.z * referenceSpacing.z / movingSpacing.z
    )
    translation = Vec3<Float>(
      x: metricTransform.translation.x / movingSpacing.x,
      y: metricTransform.translation.y / movingSpacing.y,
      z: metricTransform.translation.z / movingSpacing.z
    )
  }

  private init(
    xAxis: Vec3<Float>,
    yAxis: Vec3<Float>,
    zAxis: Vec3<Float>,
    translation: Vec3<Float>
  ) {
    self.xAxis = xAxis
    self.yAxis = yAxis
    self.zAxis = zAxis
    self.translation = translation
  }

  func applying(to point: Vec3<Float>) -> Vec3<Float> {
    xAxis * point.x
      + yAxis * point.y
      + zAxis * point.z
      + translation
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

  func translated(by delta: Vec3<Float>) -> BorgVRRigidTransform {
    BorgVRRigidTransform(
      xAxis: xAxis,
      yAxis: yAxis,
      zAxis: zAxis,
      translation: translation + delta
    )
  }

  func rotated(
    around axis: Vec3<Float>,
    angle: Float,
    pivot referencePivot: Vec3<Float>
  ) -> BorgVRRigidTransform {
    let movingPivot = applying(to: referencePivot)
    return BorgVRRigidTransform(
      xAxis: Self.rotate(xAxis, around: axis, angle: angle),
      yAxis: Self.rotate(yAxis, around: axis, angle: angle),
      zAxis: Self.rotate(zAxis, around: axis, angle: angle),
      translation: Self.rotate(
        translation - movingPivot,
        around: axis,
        angle: angle
      ) + movingPivot
    )
  }

  private static func rotate(
    _ vector: Vec3<Float>,
    around axis: Vec3<Float>,
    angle: Float
  ) -> Vec3<Float> {
    let cosine = cos(angle)
    let sine = sin(angle)
    return vector * cosine
      + axis.cross(vector) * sine
      + axis * (axis.dot(vector) * (1 - cosine))
  }
}

private struct BorgVRRegistrationMetricEvaluator {
  let sampleCount: Int
  let binCount: Int
  let evaluate: (BorgVRRigidTransform) throws -> BorgVRRegistrationMetricEvaluation
}

private struct BorgVRRegistrationMetricEvaluation {
  let nmi: Double
  let overlap: Double
}

private final class BorgVRNormalizedMutualInformation<
  ReferenceValue: FixedWidthInteger,
  MovingValue: FixedWidthInteger
> {
  private struct ReferenceSample {
    let position: Vec3<Float>
    let bin: Int
  }

  private static var maximumSampleCount: Int { 1_000_000 }

  private let referenceAccessor: RawFileAccessor
  private let movingAccessor: RawFileAccessor
  private let binCount: Int
  private let referenceSamples: [ReferenceSample]
  private let movingValues: UnsafePointer<MovingValue>
  private let movingSize: Vec3<Int>
  private let referenceSpacing: Vec3<Float>
  private let movingSpacing: Vec3<Float>
  private let movingPadding: MovingValue?
  private let movingMinimum: Double
  private let movingBinScale: Double
  private let cancellationToken: BorgVRVolumeConversionCancellationToken?
  private var jointHistogram: [Double]
  private var referenceHistogram: [Double]
  private var movingHistogram: [Double]

  init(
    reference: BorgVRRegistrationLevel,
    moving: BorgVRRegistrationLevel,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    referenceAccessor = try RawFileAccessor(
      filename: reference.source.url.path,
      size: reference.size,
      bytesPerComponent: reference.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: reference.source.voxelSpacing,
      offset: reference.source.offset,
      readOnly: true
    )
    movingAccessor = try RawFileAccessor(
      filename: moving.source.url.path,
      size: moving.size,
      bytesPerComponent: moving.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: moving.source.voxelSpacing,
      offset: moving.source.offset,
      readOnly: true
    )
    guard referenceAccessor.supportsAlignedTypedAccess,
          movingAccessor.supportsAlignedTypedAccess else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    let referenceValues = UnsafePointer(
      referenceAccessor.mappedMemory.assumingMemoryBound(to: ReferenceValue.self)
    )
    movingValues = UnsafePointer(
      movingAccessor.mappedMemory.assumingMemoryBound(to: MovingValue.self)
    )
    movingSize = moving.size
    referenceSpacing = reference.source.voxelSpacing
    movingSpacing = moving.source.voxelSpacing
    self.cancellationToken = cancellationToken
    let referencePadding = reference.pixelPaddingValue.map {
      ReferenceValue(truncatingIfNeeded: $0)
    }
    movingPadding = moving.pixelPaddingValue.map {
      MovingValue(truncatingIfNeeded: $0)
    }

    let referenceStride = Self.samplingStride(for: reference.size)
    var rawSamples: [(position: Vec3<Float>, value: Double)] = []
    rawSamples.reserveCapacity(Self.maximumSampleCount)
    var sampleIndex = 0
    for z in Self.sampleIndices(count: reference.size.z, stride: referenceStride) {
      try cancellationToken?.checkCancellation()
      for y in Self.sampleIndices(count: reference.size.y, stride: referenceStride) {
        for x in Self.sampleIndices(count: reference.size.x, stride: referenceStride) {
          let value = referenceValues[(z * reference.size.y + y) * reference.size.x + x]
          if value == referencePadding { continue }
          let numericValue = Double(value)
          rawSamples.append((
            position: Vec3<Float>(
              x: Float(x),
              y: Float(y),
              z: Float(z)
            ),
            value: numericValue
          ))
          sampleIndex += 1
          if sampleIndex & 4095 == 0 {
            try cancellationToken?.checkCancellation()
          }
        }
      }
    }

    let selectedBinCount = Self.histogramBinCount(for: rawSamples.count)
    binCount = selectedBinCount
    let referenceBounds = Self.robustIntensityBounds(rawSamples.map(\.value))
    let referenceMinimum = referenceBounds.minimum
    let referenceRange = referenceBounds.maximum - referenceBounds.minimum
    let referenceScale = referenceRange > 0
      ? Double(selectedBinCount - 1) / referenceRange
      : 0
    referenceSamples = rawSamples.map {
      ReferenceSample(
        position: $0.position,
        bin: Self.histogramBin(
          value: $0.value,
          minimum: referenceMinimum,
          scale: referenceScale,
          binCount: selectedBinCount
        )
      )
    }

    let movingStride = Self.samplingStride(for: moving.size)
    var sampledMovingValues: [Double] = []
    sampledMovingValues.reserveCapacity(Self.maximumSampleCount)
    for z in Self.sampleIndices(count: moving.size.z, stride: movingStride) {
      try cancellationToken?.checkCancellation()
      for y in Self.sampleIndices(count: moving.size.y, stride: movingStride) {
        for x in Self.sampleIndices(count: moving.size.x, stride: movingStride) {
          let value = movingValues[(z * moving.size.y + y) * moving.size.x + x]
          if value == movingPadding { continue }
          sampledMovingValues.append(Double(value))
        }
      }
    }
    let movingBounds = Self.robustIntensityBounds(sampledMovingValues)
    movingMinimum = movingBounds.minimum
    let movingRange = movingBounds.maximum - movingBounds.minimum
    movingBinScale = movingRange > 0
      ? Double(selectedBinCount - 1) / movingRange
      : 0
    jointHistogram = [Double](
      repeating: 0,
      count: selectedBinCount * selectedBinCount
    )
    referenceHistogram = [Double](repeating: 0, count: selectedBinCount)
    movingHistogram = [Double](repeating: 0, count: selectedBinCount)
  }

  var evaluator: BorgVRRegistrationMetricEvaluator {
    BorgVRRegistrationMetricEvaluator(
      sampleCount: referenceSamples.count,
      binCount: binCount,
      evaluate: { [self] transform in
        try evaluate(transform)
      }
    )
  }

  private func evaluate(
    _ transform: BorgVRRigidTransform
  ) throws -> BorgVRRegistrationMetricEvaluation {
    guard referenceSamples.count >= 2,
          movingMinimum.isFinite,
          movingBinScale > 0 else {
      return BorgVRRegistrationMetricEvaluation(nmi: -Double.infinity, overlap: 0)
    }
    for index in jointHistogram.indices { jointHistogram[index] = 0 }
    for index in referenceHistogram.indices { referenceHistogram[index] = 0 }
    for index in movingHistogram.indices { movingHistogram[index] = 0 }

    var validPairCount = 0
    let voxelTransform = BorgVRVoxelTransform(
      metricTransform: transform,
      referenceSpacing: referenceSpacing,
      movingSpacing: movingSpacing
    )
    for (index, sample) in referenceSamples.enumerated() {
      if index & 4095 == 0 {
        try cancellationToken?.checkCancellation()
      }
      let movingPoint = voxelTransform.applying(to: sample.position)
      let movingCoordinate = Vec3<Float>(
        x: Self.snapToVoxel(movingPoint.x),
        y: Self.snapToVoxel(movingPoint.y),
        z: Self.snapToVoxel(movingPoint.z)
      )
      guard let movingValue = interpolatedMovingValue(at: movingCoordinate) else {
        continue
      }
      let movingBin = Self.histogramBin(
        value: movingValue,
        minimum: movingMinimum,
        scale: movingBinScale,
        binCount: binCount
      )
      jointHistogram[sample.bin * binCount + movingBin] += 1
      validPairCount += 1
    }

    let minimumPairCount = min(
      referenceSamples.count,
      max(16, referenceSamples.count / 20)
    )
    let overlap = Double(validPairCount) / Double(referenceSamples.count)
    guard validPairCount >= minimumPairCount else {
      return BorgVRRegistrationMetricEvaluation(
        nmi: -Double.infinity,
        overlap: overlap
      )
    }

    for referenceBin in 0..<binCount {
      let rowOffset = referenceBin * binCount
      for movingBin in 0..<binCount {
        let count = jointHistogram[rowOffset + movingBin]
        referenceHistogram[referenceBin] += count
        movingHistogram[movingBin] += count
      }
    }
    let totalWeight = Double(validPairCount)
    let referenceEntropy = Self.entropy(referenceHistogram, totalWeight: totalWeight)
    let movingEntropy = Self.entropy(movingHistogram, totalWeight: totalWeight)
    let jointEntropy = Self.entropy(jointHistogram, totalWeight: totalWeight)
    guard referenceEntropy > 0,
          movingEntropy > 0,
          jointEntropy > 0 else {
      return BorgVRRegistrationMetricEvaluation(
        nmi: -Double.infinity,
        overlap: overlap
      )
    }
    return BorgVRRegistrationMetricEvaluation(
      nmi: (referenceEntropy + movingEntropy) / jointEntropy,
      overlap: overlap
    )
  }

  private func interpolatedMovingValue(at coordinate: Vec3<Float>) -> Double? {
    guard coordinate.x.isFinite,
          coordinate.y.isFinite,
          coordinate.z.isFinite,
          coordinate.x >= 0,
          coordinate.x <= Float(movingSize.x - 1),
          coordinate.y >= 0,
          coordinate.y <= Float(movingSize.y - 1),
          coordinate.z >= 0,
          coordinate.z <= Float(movingSize.z - 1) else {
      return nil
    }

    let x0 = Int(coordinate.x.rounded(.down))
    let y0 = Int(coordinate.y.rounded(.down))
    let z0 = Int(coordinate.z.rounded(.down))
    let x1 = min(x0 + 1, movingSize.x - 1)
    let y1 = min(y0 + 1, movingSize.y - 1)
    let z1 = min(z0 + 1, movingSize.z - 1)
    let tx = Double(coordinate.x - Float(x0))
    let ty = Double(coordinate.y - Float(y0))
    let tz = Double(coordinate.z - Float(z0))

    guard let c000 = movingValue(x: x0, y: y0, z: z0, weight: (1 - tx) * (1 - ty) * (1 - tz)),
          let c100 = movingValue(x: x1, y: y0, z: z0, weight: tx * (1 - ty) * (1 - tz)),
          let c010 = movingValue(x: x0, y: y1, z: z0, weight: (1 - tx) * ty * (1 - tz)),
          let c110 = movingValue(x: x1, y: y1, z: z0, weight: tx * ty * (1 - tz)),
          let c001 = movingValue(x: x0, y: y0, z: z1, weight: (1 - tx) * (1 - ty) * tz),
          let c101 = movingValue(x: x1, y: y0, z: z1, weight: tx * (1 - ty) * tz),
          let c011 = movingValue(x: x0, y: y1, z: z1, weight: (1 - tx) * ty * tz),
          let c111 = movingValue(x: x1, y: y1, z: z1, weight: tx * ty * tz) else {
      return nil
    }
    return c000 + c100 + c010 + c110 + c001 + c101 + c011 + c111
  }

  private func movingValue(x: Int, y: Int, z: Int, weight: Double) -> Double? {
    guard weight > 0 else { return 0 }
    let value = movingValues[(z * movingSize.y + y) * movingSize.x + x]
    guard value != movingPadding else { return nil }
    return Double(value) * weight
  }

  private static func entropy(_ histogram: [Double], totalWeight: Double) -> Double {
    var result: Double = 0
    for count in histogram where count > 0 {
      let probability = count / totalWeight
      result -= probability * log(probability)
    }
    return result
  }

  private static func samplingStride(for size: Vec3<Int>) -> Int {
    var stride = 1
    while sampledCount(size: size, stride: stride) > maximumSampleCount {
      stride += 1
    }
    return stride
  }

  private static func sampledCount(size: Vec3<Int>, stride: Int) -> Int {
    ((size.x + stride - 1) / stride)
      * ((size.y + stride - 1) / stride)
      * ((size.z + stride - 1) / stride)
  }

  private static func sampleIndices(count: Int, stride: Int) -> StrideTo<Int> {
    Swift.stride(from: min(stride / 2, count - 1), to: count, by: stride)
  }

  private static func histogramBin(
    value: Double,
    minimum: Double,
    scale: Double,
    binCount: Int
  ) -> Int {
    let coordinate = (value - minimum) * scale
    return min(max(Int(coordinate.rounded()), 0), binCount - 1)
  }

  private static func histogramBinCount(for sampleCount: Int) -> Int {
    if sampleCount >= 250_000 { return 256 }
    if sampleCount >= 50_000 { return 128 }
    return 64
  }

  private static func robustIntensityBounds(
    _ values: [Double]
  ) -> (minimum: Double, maximum: Double) {
    guard !values.isEmpty else { return (.infinity, -.infinity) }
    let sorted = values.sorted()
    let lastIndex = sorted.count - 1
    let lower = sorted[Int(Double(lastIndex) * 0.005)]
    let upper = sorted[Int(Double(lastIndex) * 0.995)]
    if upper > lower { return (lower, upper) }
    return (sorted[0], sorted[lastIndex])
  }

  private static func snapToVoxel(_ coordinate: Float) -> Float {
    let rounded = coordinate.rounded()
    return abs(coordinate - rounded) < 0.0001 ? rounded : coordinate
  }
}

private enum BorgVRRigidRegistrationOptimizer {
  struct Result {
    let transform: BorgVRRigidTransform
    let initialEvaluation: BorgVRRegistrationMetricEvaluation
    let finalEvaluation: BorgVRRegistrationMetricEvaluation
    let evaluationCount: Int
  }

  static func optimize(
    initialTransform: BorgVRRigidTransform,
    reference: BorgVRRegistrationLevel,
    moving: BorgVRRegistrationLevel,
    evaluator: BorgVRRegistrationMetricEvaluator
  ) throws -> Result {
    let referenceExtent = Vec3<Float>(
      x: Float(max(0, reference.size.x - 1)) * reference.source.voxelSpacing.x,
      y: Float(max(0, reference.size.y - 1)) * reference.source.voxelSpacing.y,
      z: Float(max(0, reference.size.z - 1)) * reference.source.voxelSpacing.z
    )
    let referenceCenter = referenceExtent * 0.5
    let radius = max(referenceExtent.magnitude * 0.5, maximumSpacing(reference, moving))
    var translationSteps = Vec3<Float>(
      x: 2 * max(reference.source.voxelSpacing.x, moving.source.voxelSpacing.x),
      y: 2 * max(reference.source.voxelSpacing.y, moving.source.voxelSpacing.y),
      z: 2 * max(reference.source.voxelSpacing.z, moving.source.voxelSpacing.z)
    )
    let largestTranslationStep = max(
      translationSteps.x,
      max(translationSteps.y, translationSteps.z)
    )
    var rotationStep = min(
      5 * .pi / 180,
      max(0.5 * .pi / 180, largestTranslationStep / radius)
    )
    let minimumTranslationSteps = translationSteps / 64
    let minimumRotationStep = rotationStep / 64

    let initialEvaluation = try evaluator.evaluate(initialTransform)
    let minimumOverlap = initialEvaluation.nmi.isFinite
      ? max(0.05, initialEvaluation.overlap * 0.90)
      : 0.05
    var currentTransform = initialTransform
    var currentEvaluation = initialEvaluation
    var currentMerit = merit(
      currentEvaluation,
      initialOverlap: initialEvaluation.overlap,
      minimumOverlap: minimumOverlap
    )
    var evaluationCount = 1
    let maximumEvaluationCount = 240
    let scoreEpsilon = 1e-5

    while evaluationCount + 12 <= maximumEvaluationCount {
      var bestTransform = currentTransform
      var bestEvaluation = currentEvaluation
      var bestMerit = currentMerit
      for parameter in 0..<6 {
        for direction: Float in [-1, 1] {
          let candidate = candidateTransform(
            from: currentTransform,
            parameter: parameter,
            direction: direction,
            translationSteps: translationSteps,
            rotationStep: rotationStep,
            referenceCenter: referenceCenter
          )
          let candidateEvaluation = try evaluator.evaluate(candidate)
          let candidateMerit = merit(
            candidateEvaluation,
            initialOverlap: initialEvaluation.overlap,
            minimumOverlap: minimumOverlap
          )
          evaluationCount += 1
          if candidateMerit > bestMerit + scoreEpsilon {
            bestMerit = candidateMerit
            bestEvaluation = candidateEvaluation
            bestTransform = candidate
          }
        }
      }

      if bestMerit > currentMerit + scoreEpsilon {
        currentTransform = bestTransform
        currentEvaluation = bestEvaluation
        currentMerit = bestMerit
      } else {
        translationSteps = translationSteps / 2
        rotationStep /= 2
        if translationSteps.x <= minimumTranslationSteps.x,
           translationSteps.y <= minimumTranslationSteps.y,
           translationSteps.z <= minimumTranslationSteps.z,
           rotationStep <= minimumRotationStep {
          break
        }
      }
    }
    if initialEvaluation.nmi.isFinite,
       currentEvaluation.nmi < initialEvaluation.nmi + 0.0001 {
      currentTransform = initialTransform
      currentEvaluation = initialEvaluation
    }
    return Result(
      transform: currentTransform,
      initialEvaluation: initialEvaluation,
      finalEvaluation: currentEvaluation,
      evaluationCount: evaluationCount
    )
  }

  private static func merit(
    _ evaluation: BorgVRRegistrationMetricEvaluation,
    initialOverlap: Double,
    minimumOverlap: Double
  ) -> Double {
    guard evaluation.nmi.isFinite,
          evaluation.overlap >= minimumOverlap else {
      return -Double.infinity
    }
    let overlapLoss = max(0, initialOverlap - evaluation.overlap)
      / max(initialOverlap, 0.05)
    return evaluation.nmi - 0.20 * overlapLoss
  }

  private static func candidateTransform(
    from transform: BorgVRRigidTransform,
    parameter: Int,
    direction: Float,
    translationSteps: Vec3<Float>,
    rotationStep: Float,
    referenceCenter: Vec3<Float>
  ) -> BorgVRRigidTransform {
    switch parameter {
      case 0:
        return transform.translated(
          by: Vec3<Float>(x: direction * translationSteps.x, y: 0, z: 0)
        )
      case 1:
        return transform.translated(
          by: Vec3<Float>(x: 0, y: direction * translationSteps.y, z: 0)
        )
      case 2:
        return transform.translated(
          by: Vec3<Float>(x: 0, y: 0, z: direction * translationSteps.z)
        )
      case 3:
        return transform.rotated(
          around: Vec3<Float>(x: 1, y: 0, z: 0),
          angle: direction * rotationStep,
          pivot: referenceCenter
        )
      case 4:
        return transform.rotated(
          around: Vec3<Float>(x: 0, y: 1, z: 0),
          angle: direction * rotationStep,
          pivot: referenceCenter
        )
      default:
        return transform.rotated(
          around: Vec3<Float>(x: 0, y: 0, z: 1),
          angle: direction * rotationStep,
          pivot: referenceCenter
        )
    }
  }

  private static func maximumSpacing(
    _ reference: BorgVRRegistrationLevel,
    _ moving: BorgVRRegistrationLevel
  ) -> Float {
    max(
      reference.source.voxelSpacing.x,
      reference.source.voxelSpacing.y,
      reference.source.voxelSpacing.z,
      moving.source.voxelSpacing.x,
      moving.source.voxelSpacing.y,
      moving.source.voxelSpacing.z
    )
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
  ) throws -> BorgVRVoxelTransform {
    guard reference.source.componentCount == 1,
          moving.source.componentCount == 1,
          reference.source.bytesPerComponent == moving.source.bytesPerComponent else {
      throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }

    let usesSharedFrame = canUseSharedDICOMFrame(reference: reference, moving: moving)
    let initialTransform = dicomInitialTransform(reference: reference, moving: moving)
    if usesSharedFrame {
      logger?.info("Initializing DICOM registration from the shared Frame of Reference.")
    } else {
      logger?.info(
        "DICOM series do not share a usable Frame of Reference; aligning their physical centers."
      )
    }
    let initialVoxelTransform = BorgVRVoxelTransform(
      metricTransform: initialTransform,
      referenceSpacing: reference.source.voxelSpacing,
      movingSpacing: moving.source.voxelSpacing
    )
    logger?.info(
      "Initial DICOM voxel transform:\n" + formattedMatrix(initialVoxelTransform)
    )
    logger?.info("Starting recursive rigid DICOM registration.")
    let result = try register(
      level: Level(
        reference: registrationLevel(from: reference),
        moving: registrationLevel(from: moving)
      ),
      dicomInitialTransform: initialTransform,
      logger: logger,
      cancellationToken: cancellationToken
    )
    let voxelTransform = BorgVRVoxelTransform(
      metricTransform: result,
      referenceSpacing: reference.source.voxelSpacing,
      movingSpacing: moving.source.voxelSpacing
    )
    logger?.info("Final DICOM voxel transform:\n" + formattedMatrix(voxelTransform))
    return voxelTransform
  }

  private static func formattedMatrix(_ transform: BorgVRVoxelTransform) -> String {
    let rows: [[Float]] = [
      [transform.xAxis.x, transform.yAxis.x, transform.zAxis.x, transform.translation.x],
      [transform.xAxis.y, transform.yAxis.y, transform.zAxis.y, transform.translation.y],
      [transform.xAxis.z, transform.yAxis.z, transform.zAxis.z, transform.translation.z],
      [0, 0, 0, 1]
    ]
    return rows.map { row in
      "[" + row.map { String(format: "%8.2f", $0) }.joined(separator: " ") + " ]"
    }.joined(separator: "\n")
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
      logger: logger,
      cancellationToken: cancellationToken
    )
  }

  private static func optimize(
    level: Level,
    initialTransform: BorgVRRigidTransform,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRigidTransform {
    try cancellationToken?.checkCancellation()
    let evaluator = try makeMetricEvaluator(
      level: level,
      cancellationToken: cancellationToken
    )
    let result = try BorgVRRigidRegistrationOptimizer.optimize(
      initialTransform: initialTransform,
      reference: level.reference,
      moving: level.moving,
      evaluator: evaluator
    )
    if result.finalEvaluation.nmi.isFinite {
      logger?.info(
        "DICOM registration level optimized using \(evaluator.sampleCount) samples, "
          + "\(evaluator.binCount) x \(evaluator.binCount) histogram bins and "
          + "\(max(0, result.evaluationCount - 1)) tried transformations (NMI "
          + String(format: "%.6f", result.initialEvaluation.nmi)
          + " -> " + String(format: "%.6f", result.finalEvaluation.nmi)
          + ", overlap " + String(format: "%.1f%%", result.initialEvaluation.overlap * 100)
          + " -> " + String(format: "%.1f%%", result.finalEvaluation.overlap * 100)
          + ")."
      )
    } else {
      logger?.warning(
        "DICOM registration level contains insufficient intensity information or overlap; "
          + "keeping its initial transform."
      )
    }
    return result.transform
  }

  private static func makeMetricEvaluator(
    level: Level,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRegistrationMetricEvaluator {
    switch (
      level.reference.source.bytesPerComponent,
      level.reference.isSigned,
      level.moving.isSigned
    ) {
      case (1, false, false):
        return try makeMetricEvaluator(
          level: level,
          referenceType: UInt8.self,
          movingType: UInt8.self,
          cancellationToken: cancellationToken
        )
      case (1, false, true):
        return try makeMetricEvaluator(
          level: level,
          referenceType: UInt8.self,
          movingType: Int8.self,
          cancellationToken: cancellationToken
        )
      case (1, true, false):
        return try makeMetricEvaluator(
          level: level,
          referenceType: Int8.self,
          movingType: UInt8.self,
          cancellationToken: cancellationToken
        )
      case (1, true, true):
        return try makeMetricEvaluator(
          level: level,
          referenceType: Int8.self,
          movingType: Int8.self,
          cancellationToken: cancellationToken
        )
      case (2, false, false):
        return try makeMetricEvaluator(
          level: level,
          referenceType: UInt16.self,
          movingType: UInt16.self,
          cancellationToken: cancellationToken
        )
      case (2, false, true):
        return try makeMetricEvaluator(
          level: level,
          referenceType: UInt16.self,
          movingType: Int16.self,
          cancellationToken: cancellationToken
        )
      case (2, true, false):
        return try makeMetricEvaluator(
          level: level,
          referenceType: Int16.self,
          movingType: UInt16.self,
          cancellationToken: cancellationToken
        )
      case (2, true, true):
        return try makeMetricEvaluator(
          level: level,
          referenceType: Int16.self,
          movingType: Int16.self,
          cancellationToken: cancellationToken
        )
      case (4, false, false):
        return try makeMetricEvaluator(
          level: level,
          referenceType: UInt32.self,
          movingType: UInt32.self,
          cancellationToken: cancellationToken
        )
      case (4, false, true):
        return try makeMetricEvaluator(
          level: level,
          referenceType: UInt32.self,
          movingType: Int32.self,
          cancellationToken: cancellationToken
        )
      case (4, true, false):
        return try makeMetricEvaluator(
          level: level,
          referenceType: Int32.self,
          movingType: UInt32.self,
          cancellationToken: cancellationToken
        )
      case (4, true, true):
        return try makeMetricEvaluator(
          level: level,
          referenceType: Int32.self,
          movingType: Int32.self,
          cancellationToken: cancellationToken
        )
      default:
        throw BorgVRVolumeConversionError.incompatibleDICOMSampleFormats
    }
  }

  private static func makeMetricEvaluator<
    ReferenceValue: FixedWidthInteger,
    MovingValue: FixedWidthInteger
  >(
    level: Level,
    referenceType: ReferenceValue.Type,
    movingType: MovingValue.Type,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRegistrationMetricEvaluator {
    _ = referenceType
    _ = movingType
    return try BorgVRNormalizedMutualInformation<ReferenceValue, MovingValue>(
      reference: level.reference,
      moving: level.moving,
      cancellationToken: cancellationToken
    ).evaluator
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
    let rotation: BorgVRRigidTransform
    if let referenceOrientation = reference.orientation,
       let movingOrientation = moving.orientation {
      rotation = BorgVRRigidTransform(
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
        translation: .zero
      )
    } else {
      rotation = .identity
    }

    if canUseSharedDICOMFrame(reference: reference, moving: moving),
       let referenceOrigin = reference.origin,
       let movingOrigin = moving.origin,
       let movingOrientation = moving.orientation {
      let originDelta = referenceOrigin - movingOrigin
      return BorgVRRigidTransform(
        xAxis: rotation.xAxis,
        yAxis: rotation.yAxis,
        zAxis: rotation.zAxis,
        translation: Vec3<Float>(
          x: originDelta.dot(movingOrientation.xAxis),
          y: originDelta.dot(movingOrientation.yAxis),
          z: originDelta.dot(movingOrientation.zAxis)
        )
      )
    }

    let referenceCenter = metricCenter(of: reference)
    let movingCenter = metricCenter(of: moving)
    return BorgVRRigidTransform(
      xAxis: rotation.xAxis,
      yAxis: rotation.yAxis,
      zAxis: rotation.zAxis,
      translation: movingCenter - rotation.applying(to: referenceCenter)
    )
  }

  private static func canUseSharedDICOMFrame(
    reference: BorgVRUnbrickedVolume,
    moving: BorgVRUnbrickedVolume
  ) -> Bool {
    guard let referenceFrame = reference.frameOfReferenceUID,
          let movingFrame = moving.frameOfReferenceUID else {
      return false
    }
    return referenceFrame == movingFrame
      && reference.orientation != nil
      && reference.origin != nil
      && moving.orientation != nil
      && moving.origin != nil
  }

  private static func metricCenter(
    of volume: BorgVRUnbrickedVolume
  ) -> Vec3<Float> {
    Vec3<Float>(
      x: Float(max(0, volume.source.size.x - 1)) * volume.source.voxelSpacing.x * 0.5,
      y: Float(max(0, volume.source.size.y - 1)) * volume.source.voxelSpacing.y * 0.5,
      z: Float(max(0, volume.source.size.z - 1)) * volume.source.voxelSpacing.z * 0.5
    )
  }
}
