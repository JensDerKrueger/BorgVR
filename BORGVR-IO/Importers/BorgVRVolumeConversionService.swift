import Foundation
import simd

/// Forward affine transform in voxel-center coordinates, followed by a target-grid crop.
public struct BorgVRVolumeResampling: Sendable {
  public let matrix: [Double]
  public let cropOrigin: Vec3<Int>
  public let cropSize: Vec3<Int>?
  public let filter: BorgVRVolumeResamplingFilter

  public init(matrix: [Double], cropOrigin: Vec3<Int> = Vec3(x: 0, y: 0, z: 0),
              cropSize: Vec3<Int>? = nil, filter: BorgVRVolumeResamplingFilter = .trilinear) throws {
    guard matrix.count == 16, matrix.allSatisfy(\.isFinite),
          Array(matrix[12...15]) == [0, 0, 0, 1] else {
      throw BORGVRError.other("Resampling requires 16 finite row-major affine matrix values; the last row must be 0 0 0 1.")
    }
    let linear = simd_double3x3(columns: (
      SIMD3(matrix[0], matrix[4], matrix[8]), SIMD3(matrix[1], matrix[5], matrix[9]),
      SIMD3(matrix[2], matrix[6], matrix[10])))
    let determinant = simd_determinant(linear)
    guard determinant.isFinite, abs(determinant) > 1e-12,
          cropOrigin.x >= 0, cropOrigin.y >= 0, cropOrigin.z >= 0 else {
      throw BORGVRError.other("Resampling requires an invertible matrix and a nonnegative crop origin.")
    }
    self.matrix = matrix
    self.cropOrigin = cropOrigin
    self.cropSize = cropSize
    self.filter = filter
  }

  func outputSize(source: Vec3<Int>) throws -> Vec3<Int> {
    let size = cropSize ?? source
    for (origin, count, limit) in [(cropOrigin.x, size.x, source.x),
      (cropOrigin.y, size.y, source.y), (cropOrigin.z, size.z, source.z)] {
      guard count > 0, origin <= limit, count <= limit - origin else {
        throw BORGVRError.other("The crop must fit inside the transformed target grid (same dimensions as the source).")
      }
    }
    return size
  }

  var inverse: simd_double4x4 {
    simd_inverse(simd_double4x4(columns: (
      SIMD4(matrix[0], matrix[4], matrix[8], matrix[12]),
      SIMD4(matrix[1], matrix[5], matrix[9], matrix[13]),
      SIMD4(matrix[2], matrix[6], matrix[10], matrix[14]),
      SIMD4(matrix[3], matrix[7], matrix[11], matrix[15]))))
  }

  func writeRaw(_ source: BorgVRRawVolumeSource, to url: URL, logger: LoggerBase?,
                cancellationToken: BorgVRVolumeConversionCancellationToken?) throws -> BorgVRRawVolumeSource {
    let size = try outputSize(source: source.size)
    let accessor = try RawFileAccessor(filename: source.url.path, size: source.size,
      bytesPerComponent: source.bytesPerComponent, componentCount: source.componentCount,
      voxelSpacing: source.voxelSpacing, offset: source.offset)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw BorgVRVolumeConversionError.cannotCreateTemporaryVolume(url)
    }
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    switch source.bytesPerComponent {
      case 1: try write(UInt8.self, accessor, output, size, logger, cancellationToken)
      case 2: try write(UInt16.self, accessor, output, size, logger, cancellationToken)
      case 4: try write(UInt32.self, accessor, output, size, logger, cancellationToken)
      default: throw BORGVRError.other("Resampling currently supports unsigned 8/16/32-bit components.")
    }
    return BorgVRRawVolumeSource(url: url, offset: 0, size: size,
      bytesPerComponent: source.bytesPerComponent, componentCount: source.componentCount,
      voxelSpacing: source.voxelSpacing, channelInterpretation: source.channelInterpretation)
  }

  private func write<T: FixedWidthInteger & UnsignedInteger>(
    _ type: T.Type, _ source: RawFileAccessor, _ output: FileHandle, _ size: Vec3<Int>,
    _ logger: LoggerBase?, _ cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let channels = source.componentCount
    let rowCount = size.x.multipliedReportingOverflow(by: channels)
    guard !rowCount.overflow,
          !rowCount.partialValue.multipliedReportingOverflow(by: MemoryLayout<T>.size).overflow else {
      throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
    }
    let values = source.mappedMemory.assumingMemoryBound(to: T.self)
    let transform = inverse
    guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { transform[column][$0].isFinite } }) else {
      throw BORGVRError.other("The inverse resampling matrix is not finite.")
    }
    var row = [T](repeating: 0, count: rowCount.partialValue)
    let extent = source.size
    func value(_ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Double {
      Double(values[((z * extent.y + y) * extent.x + x) * channels + c])
    }
    for z in 0..<size.z {
      for y in 0..<size.y {
        try cancellationToken?.checkCancellation()
        for x in 0..<size.x {
          let p = transform * SIMD4(Double(x + cropOrigin.x), Double(y + cropOrigin.y),
                                    Double(z + cropOrigin.z), 1)
          let valid = p.x.isFinite && p.y.isFinite && p.z.isFinite &&
            p.x >= -1e-9 && p.y >= -1e-9 && p.z >= -1e-9 &&
            p.x <= Double(extent.x - 1) + 1e-9 && p.y <= Double(extent.y - 1) + 1e-9 &&
            p.z <= Double(extent.z - 1) + 1e-9
          guard valid else {
            for c in 0..<channels { row[x * channels + c] = 0 }
            continue
          }
          let q = SIMD3(max(0, min(Double(extent.x - 1), p.x)),
                        max(0, min(Double(extent.y - 1), p.y)),
                        max(0, min(Double(extent.z - 1), p.z)))
          for c in 0..<channels {
            let sample: Double
            if filter == .nearestNeighbor {
              sample = value(Int(q.x.rounded()), Int(q.y.rounded()), Int(q.z.rounded()), c)
            } else {
              let lo = SIMD3(Int(q.x), Int(q.y), Int(q.z))
              let hi = SIMD3(min(lo.x + 1, extent.x - 1), min(lo.y + 1, extent.y - 1), min(lo.z + 1, extent.z - 1))
              let f = q - SIMD3(Double(lo.x), Double(lo.y), Double(lo.z))
              var sum = 0.0
              for dz in 0...1 { for dy in 0...1 { for dx in 0...1 {
                let weight = (dx == 0 ? 1 - f.x : f.x) * (dy == 0 ? 1 - f.y : f.y) * (dz == 0 ? 1 - f.z : f.z)
                sum += weight * value(dx == 0 ? lo.x : hi.x, dy == 0 ? lo.y : hi.y, dz == 0 ? lo.z : hi.z, c)
              } } }
              sample = sum
            }
            row[x * channels + c] = T(min(Double(T.max), max(0, sample.rounded()))).littleEndian
          }
        }
        try row.withUnsafeBytes { try output.write(contentsOf: $0) }
      }
      logger?.progress("Resampling volume", Double(z + 1) / Double(size.z))
    }
  }
}

public final class BorgVRVolumeConversionCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  public init() {}

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  public func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  public func checkCancellation() throws {
    if isCancelled {
      throw CancellationError()
    }
  }
}

public struct BorgVRVolumeConversionSettings: Sendable {
  public let brickSize: Int
  public let overlap: Int
  public let useCompression: Bool
  public let extensionStrategy: ExtensionStrategy
  public let quantizeTo8Bit: Bool
  public let colorCompression: Int

  public init(
    brickSize: Int,
    overlap: Int,
    useCompression: Bool,
    extensionStrategy: ExtensionStrategy,
    quantizeTo8Bit: Bool = false,
    colorCompression: Int = 0
  ) {
    self.brickSize = brickSize
    self.overlap = overlap
    self.useCompression = useCompression
    self.extensionStrategy = extensionStrategy
    self.quantizeTo8Bit = quantizeTo8Bit
    self.colorCompression = colorCompression
  }

  public func validate() throws {
    guard [0, 4, 8].contains(colorCompression) else {
      throw BORGVRError.other("Color compression must be 0, 4, or 8, and the brick size must be a multiple of its footprint.")
    }
    guard brickSize > 0 else {
      throw BorgVRVolumeConversionError.invalidBrickSize(brickSize)
    }
    guard overlap >= 0, overlap <= (brickSize - 1) / 2 else {
      throw BorgVRVolumeConversionError.invalidOverlap(
        overlap: overlap,
        brickSize: brickSize
      )
    }
  }
}

public struct BorgVRRawVolumeSource: Sendable {
  public let url: URL
  public let offset: Int
  public let size: Vec3<Int>
  public let bytesPerComponent: Int
  public let componentCount: Int
  public let voxelSpacing: Vec3<Float>
  public let hasPhysicalVoxelSpacing: Bool
  public let channelInterpretation: BORGVRChannelInterpretation

  public init(
    url: URL,
    offset: Int,
    size: Vec3<Int>,
    bytesPerComponent: Int,
    componentCount: Int,
    voxelSpacing: Vec3<Float>,
    hasPhysicalVoxelSpacing: Bool = true,
    channelInterpretation: BORGVRChannelInterpretation = .independentChannels
  ) {
    self.url = url
    self.offset = offset
    self.size = size
    self.bytesPerComponent = bytesPerComponent
    self.componentCount = componentCount
    self.voxelSpacing = voxelSpacing
    self.hasPhysicalVoxelSpacing = hasPhysicalVoxelSpacing
    self.channelInterpretation = channelInterpretation
  }
}

public enum BorgVRVolumeResamplingFilter: String, Sendable {
  case nearestNeighbor
  case trilinear
}

public enum BorgVRVolumeInput: Sendable {
  /// Any supported volume file, including native .data and Zarr directories.
  case file(URL)
  case dicomDirectory(URL)
}

public enum BorgVRVolumeConversionSource: Sendable {
  case file(URL)
  case borgVR(URL)
  case dicomDirectory(URL)
  case imageSequence(URL)
  case registeredPair(
    reference: BorgVRVolumeInput,
    moving: BorgVRVolumeInput,
    filter: BorgVRVolumeResamplingFilter
  )
  case raw(BorgVRRawVolumeSource)
}

struct BorgVRUnbrickedVolumeChannelMetadata: Sendable {
  let description: String
  let modality: String?
  let patientName: String?
  let seriesDate: String?
  let isSigned: Bool
  let pixelPaddingValue: Int32?
}

struct BorgVRUnbrickedVolume: Sendable {
  let source: BorgVRRawVolumeSource
  let orientation: BorgVRVolumeOrientation?
  let origin: Vec3<Float>?
  let frameOfReferenceUID: String?
  let channels: [BorgVRUnbrickedVolumeChannelMetadata]
  var sourceFiles: [URL] = []
  var provenance: [BORGVRProvenanceEntry] = []
  var meta: String = ""
}

enum BorgVRVolumeFusion {
  private struct WriteContext {
    let referenceAccessor: RawFileAccessor
    let movingAccessor: RawFileAccessor
    let movingSize: Vec3<Int>
    let movingPaddingValue: Int32?
    let referenceToMoving: BorgVRVoxelTransform
    let filter: BorgVRVolumeResamplingFilter
    let output: FileHandle
    let size: Vec3<Int>
    let bytesPerComponent: Int
    let outputSliceByteCount: Int
    let outputVoxelByteCount: Int
    let referenceSliceStride: Int
    let referenceRowStride: Int
    let logger: LoggerBase?
    let cancellationToken: BorgVRVolumeConversionCancellationToken?
  }

  static func fuse(
    reference: BorgVRUnbrickedVolume,
    moving: BorgVRUnbrickedVolume,
    referenceToMoving: BorgVRVoxelTransform,
    filter: BorgVRVolumeResamplingFilter,
    outputURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRUnbrickedVolume {
    guard reference.source.componentCount == 1,
          moving.source.componentCount == 1,
          reference.source.bytesPerComponent == moving.source.bytesPerComponent,
          [1, 2, 4].contains(reference.source.bytesPerComponent) else {
      throw BorgVRVolumeConversionError.incompatibleFusionSampleFormats
    }

    let referenceAccessor = try RawFileAccessor(
      filename: reference.source.url.path,
      size: reference.source.size,
      bytesPerComponent: reference.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: reference.source.voxelSpacing,
      offset: reference.source.offset,
      readOnly: true
    )
    let movingAccessor = try RawFileAccessor(
      filename: moving.source.url.path,
      size: moving.source.size,
      bytesPerComponent: moving.source.bytesPerComponent,
      componentCount: 1,
      voxelSpacing: moving.source.voxelSpacing,
      offset: moving.source.offset,
      readOnly: true
    )

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }
    guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
      throw BorgVRVolumeConversionError.cannotCreateTemporaryVolume(outputURL)
    }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }

    let size = reference.source.size
    let bytesPerComponent = reference.source.bytesPerComponent
    let movingIsSigned = moving.channels.first?.isSigned ?? false
    let outputVoxelByteCount = try checkedProduct(bytesPerComponent, 2)
    let outputSliceByteCount = try checkedProduct(
      size.x, size.y, outputVoxelByteCount
    )
    let referenceSliceStride = try checkedProduct(size.x, size.y, bytesPerComponent)
    let referenceRowStride = try checkedProduct(size.x, bytesPerComponent)

    logger?.info("Fusing volumes into a two-channel intermediate volume.")
    let context = WriteContext(
      referenceAccessor: referenceAccessor,
      movingAccessor: movingAccessor,
      movingSize: moving.source.size,
      movingPaddingValue: moving.channels.first?.pixelPaddingValue,
      referenceToMoving: referenceToMoving,
      filter: filter,
      output: output,
      size: size,
      bytesPerComponent: bytesPerComponent,
      outputSliceByteCount: outputSliceByteCount,
      outputVoxelByteCount: outputVoxelByteCount,
      referenceSliceStride: referenceSliceStride,
      referenceRowStride: referenceRowStride,
      logger: logger,
      cancellationToken: cancellationToken
    )
    switch (bytesPerComponent, movingIsSigned) {
      case (1, false):
        try writeFusedVolume(movingType: UInt8.self, context: context)
      case (1, true):
        try writeFusedVolume(movingType: Int8.self, context: context)
      case (2, false):
        try writeFusedVolume(movingType: UInt16.self, context: context)
      case (2, true):
        try writeFusedVolume(movingType: Int16.self, context: context)
      case (4, false):
        try writeFusedVolume(movingType: UInt32.self, context: context)
      case (4, true):
        try writeFusedVolume(movingType: Int32.self, context: context)
      default:
        throw BorgVRVolumeConversionError.incompatibleFusionSampleFormats
    }

    let matrix = String(decoding: try JSONEncoder().encode(referenceToMoving.matrixRows), as: UTF8.self)
    let provenance = reference.provenance.map {
      BORGVRProvenanceEntry(timestampMilliseconds: $0.timestampMilliseconds, text: "Reference (channel 1): \($0.text)")
    } + moving.provenance.map {
      BORGVRProvenanceEntry(timestampMilliseconds: $0.timestampMilliseconds, text: "Registered (channel 2): \($0.text)")
    } + [BORGVRProvenanceEntry("Rigid volume registration and fusion; resampling: \(filter.rawValue); "
      + "reference grid: \(reference.source.size), voxel spacing (m): \(reference.source.voxelSpacing); "
      + "registered grid: \(moving.source.size), voxel spacing (m): \(moving.source.voxelSpacing); "
      + "reference voxel indices -> registered voxel indices, column vectors, row-major 4x4 matrix: \(matrix)")]
    return BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: outputURL,
        offset: 0,
        size: size,
        bytesPerComponent: bytesPerComponent,
        componentCount: 2,
        voxelSpacing: reference.source.voxelSpacing,
        hasPhysicalVoxelSpacing: reference.source.hasPhysicalVoxelSpacing
      ),
      orientation: reference.orientation,
      origin: reference.origin,
      frameOfReferenceUID: reference.frameOfReferenceUID,
      channels: reference.channels + moving.channels,
      provenance: provenance,
      meta: reference.meta.isEmpty && moving.meta.isEmpty ? "" : String(
        decoding: try JSONEncoder().encode(["reference": reference.meta, "registered": moving.meta]),
        as: UTF8.self
      )
    )
  }

  private static func writeFusedVolume<MovingValue: FixedWidthInteger>(
    movingType: MovingValue.Type,
    context: WriteContext
  ) throws {
    _ = movingType
    guard context.movingAccessor.supportsAlignedTypedAccess,
          MemoryLayout<MovingValue>.size == context.bytesPerComponent else {
      throw BorgVRVolumeConversionError.incompatibleFusionSampleFormats
    }
    let sampler = BorgVRIntegerVolumeSampler(
      values: UnsafePointer(
        context.movingAccessor.mappedMemory.assumingMemoryBound(to: MovingValue.self)
      ),
      size: context.movingSize,
      paddingValue: context.movingPaddingValue.map { MovingValue(truncatingIfNeeded: $0) }
    )

    for z in 0..<context.size.z {
      try context.cancellationToken?.checkCancellation()
      var outputSlice = [UInt8](repeating: 0, count: context.outputSliceByteCount)
      for y in 0..<context.size.y {
        for x in 0..<context.size.x {
          let referenceOffset = z * context.referenceSliceStride
            + y * context.referenceRowStride + x * context.bytesPerComponent
          let movingCoordinate = continuousMovingVoxelCoordinate(
            forReference: Vec3<Int>(x: x, y: y, z: z),
            referenceToMoving: context.referenceToMoving
          )
          let outputOffset = (y * context.size.x + x) * context.outputVoxelByteCount
          for byte in 0..<context.bytesPerComponent {
            outputSlice[outputOffset + byte] = context.referenceAccessor.mappedMemory
              .load(fromByteOffset: referenceOffset + byte, as: UInt8.self)
          }
          guard let movingCoordinate else { continue }
          let movingValue: Double?
          switch context.filter {
            case .nearestNeighbor:
              movingValue = sampler.nearestNeighbor(at: movingCoordinate)
            case .trilinear:
              movingValue = sampler.trilinear(at: movingCoordinate)
          }
          if let movingValue {
            writeSample(
              movingValue,
              to: &outputSlice,
              at: outputOffset + context.bytesPerComponent,
              bytesPerComponent: context.bytesPerComponent,
              isSigned: MovingValue.isSigned
            )
          }
        }
      }
      try context.output.write(contentsOf: Data(outputSlice))
      context.logger?.progress(
        "Fusing DICOM volumes",
        Double(z + 1) / Double(context.size.z)
      )
    }
  }

  private static func continuousMovingVoxelCoordinate(
    forReference coordinate: Vec3<Int>,
    referenceToMoving: BorgVRVoxelTransform
  ) -> Vec3<Float>? {
    let floatingCoordinate = referenceToMoving.applying(
      to: Vec3<Float>(
        x: Float(coordinate.x),
        y: Float(coordinate.y),
        z: Float(coordinate.z)
      )
    )
    guard floatingCoordinate.x.isFinite,
          floatingCoordinate.y.isFinite,
          floatingCoordinate.z.isFinite else {
      return nil
    }
    return floatingCoordinate
  }

  private static func writeSample(
    _ value: Double,
    to data: inout [UInt8],
    at offset: Int,
    bytesPerComponent: Int,
    isSigned: Bool
  ) {
    let rounded: UInt64
    if isSigned {
      switch bytesPerComponent {
        case 1:
          rounded = UInt64(UInt8(bitPattern: Int8(clamping: Int64(value.rounded()))))
        case 2:
          rounded = UInt64(UInt16(bitPattern: Int16(clamping: Int64(value.rounded()))))
        case 4:
          rounded = UInt64(UInt32(bitPattern: Int32(clamping: Int64(value.rounded()))))
        default:
          return
      }
    } else {
      let maximum = Double(UInt64(1) << UInt64(bytesPerComponent * 8)) - 1
      rounded = UInt64(min(max(value.rounded(), 0), maximum))
    }
    for byte in 0..<bytesPerComponent {
      data[offset + byte] = UInt8(truncatingIfNeeded: rounded >> UInt64(byte * 8))
    }
  }

  private static func checkedProduct(_ values: Int...) throws -> Int {
    var result = 1
    for value in values {
      let next = result.multipliedReportingOverflow(by: value)
      guard value >= 0, !next.overflow else {
        throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
      }
      result = next.partialValue
    }
    return result
  }
}

public struct BorgVRVolumeConversionRequest: Sendable {
  public let source: BorgVRVolumeConversionSource
  public let destinationURL: URL
  public let datasetDescription: String
  public let metaDescription: String
  public let settings: BorgVRVolumeConversionSettings
  public let physicalSizeMeters: Vec3<Float>?
  public let sizeXMeters: Float?
  public let forceSizeX: Bool
  public let provenance: [BORGVRProvenanceEntry]
  public let meta: String
  public let toolIdentification: String
  public let resampling: BorgVRVolumeResampling?

  public init(
    source: BorgVRVolumeConversionSource,
    destinationURL: URL,
    datasetDescription: String,
    metaDescription: String,
    settings: BorgVRVolumeConversionSettings,
    physicalSizeMeters: Vec3<Float>? = nil,
    sizeXMeters: Float? = nil,
    forceSizeX: Bool = false,
    provenance: [BORGVRProvenanceEntry] = [],
    meta: String = "",
    toolIdentification: String = BorgVRVolumeConversionService.toolIdentification,
    resampling: BorgVRVolumeResampling? = nil
  ) {
    self.source = source
    self.destinationURL = destinationURL
    self.datasetDescription = datasetDescription
    self.metaDescription = metaDescription
    self.settings = settings
    self.physicalSizeMeters = physicalSizeMeters
    self.sizeXMeters = sizeXMeters
    self.forceSizeX = forceSizeX
    self.provenance = provenance
    self.meta = meta
    self.toolIdentification = toolIdentification
    self.resampling = resampling
  }
}

public enum BorgVRVolumeConversionError: LocalizedError {
  case invalidBrickSize(Int)
  case invalidOverlap(overlap: Int, brickSize: Int)
  case noDICOMFiles(URL)
  case incompatibleFusionSampleFormats
  case cannotCreateTemporaryVolume(URL)
  case invalidIntermediateVolumeSize

  public var errorDescription: String? {
    switch self {
      case .invalidBrickSize(let brickSize):
        return "Invalid brick size: \(brickSize)."
      case .invalidOverlap(let overlap, let brickSize):
        return "Invalid overlap \(overlap) for brick size \(brickSize)."
      case .noDICOMFiles(let url):
        return "The directory does not contain any DICOM files: \(url.path)"
      case .incompatibleFusionSampleFormats:
        return String(localized: "Fusion requires two single-channel integer volumes with matching 8-, 16- or 32-bit precision.")
      case .cannotCreateTemporaryVolume(let url):
        return "The temporary intermediate volume could not be created: \(url.path)"
      case .invalidIntermediateVolumeSize:
        return "The intermediate volume is too large to represent safely."
    }
  }
}

public enum BorgVRVolumeConversionService {
  public static var toolIdentification: String {
    BORGVRToolIdentification.current
  }
  public static func convert(
    _ request: BorgVRVolumeConversionRequest,
    logger: LoggerBase? = nil,
    cancellationToken: BorgVRVolumeConversionCancellationToken? = nil
  ) throws {
    try request.settings.validate()
    if request.resampling != nil {
      guard case .borgVR = request.source,
            request.physicalSizeMeters == nil, request.sizeXMeters == nil else {
        throw BORGVRError.other("Resampling requires a BorgVR source and preserves its voxel spacing.")
      }
    }
    if let sizeX = request.sizeXMeters {
      guard sizeX.isFinite, sizeX > 0, request.physicalSizeMeters == nil else {
        throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
      }
    }
    try cancellationToken?.checkCancellation()

    if case .borgVR(let sourceURL) = request.source,
       sourceURL.standardizedFileURL.resolvingSymlinksInPath() ==
         request.destinationURL.standardizedFileURL.resolvingSymlinksInPath() {
      throw BORGVRError.other("The repacked file must not replace its source dataset. Choose a different output path.")
    }

    let fileManager = FileManager.default
    let outputDirectory = request.destinationURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    let stagedURL = outputDirectory.appendingPathComponent(
      ".\(request.destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
    defer { try? fileManager.removeItem(at: stagedURL) }

    switch request.source {
      case .borgVR(let sourceURL):
        try convertBorgVR(sourceURL, request: request, stagedURL: stagedURL,
          logger: logger, cancellationToken: cancellationToken)
      case .imageSequence(let directory):
        guard let extent = request.physicalSizeMeters else {
          throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
        }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        let rawURL = fileManager.temporaryDirectory.appendingPathComponent("borgvr-images-\(UUID().uuidString).raw")
        defer { try? fileManager.removeItem(at: rawURL) }
        let source = try BorgVRImageSequenceImporter.decode(directory: directory,
          physicalSizeMeters: extent, output: rawURL, logger: logger, cancellationToken: cancellationToken)
        try convertRaw(source, request: request, stagedURL: stagedURL,
          logger: logger, cancellationToken: cancellationToken)
      case .file(let sourceURL):
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() } }
        try convertFile(
          sourceURL,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
      case .dicomDirectory(let directoryURL):
        try convertDICOMDirectory(
          directoryURL,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
      case .registeredPair(let reference, let moving, let filter):
        try convertRegisteredPair(
          referenceInput: reference,
          movingInput: moving,
          filter: filter,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
      case .raw(let source):
        try convertRaw(
          source,
          request: request,
          stagedURL: stagedURL,
          logger: logger,
          cancellationToken: cancellationToken
        )
    }

    try cancellationToken?.checkCancellation()
    try installStagedOutput(stagedURL, at: request.destinationURL)
  }

  private static func convertBorgVR(
    _ sourceURL: URL,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let access = sourceURL.startAccessingSecurityScopedResource()
    defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
    let metadata = try BORGVRMetaData(url: sourceURL)
    if let resampling = request.resampling {
      _ = try resampling.outputSize(source: metadata.levelMetadata[0].size)
    }
    let rawURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-repack-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: rawURL) }
    let raw = try BORGVRVolumeExporter.exportRaw(inputURL: sourceURL, outputURL: rawURL,
      logger: logger, cancellationCheck: { try cancellationToken?.checkCancellation() })
    let resampledURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-resample-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: resampledURL) }
    var source = BorgVRRawVolumeSource(url: rawURL, offset: 0, size: raw.size,
      bytesPerComponent: raw.bytesPerComponent, componentCount: raw.componentCount,
      voxelSpacing: raw.voxelSpacing,
      channelInterpretation: metadata.channelInterpretation.colorInterpretation)
    var history = "Repacked BorgVR dataset: \(sourceURL.lastPathComponent); source dataset: \(metadata.uniqueID)"
    if let resampling = request.resampling {
      source = try resampling.writeRaw(source, to: resampledURL, logger: logger, cancellationToken: cancellationToken)
      let origin = resampling.cropOrigin
      let crop = "\(origin.x),\(origin.y),\(origin.z); size=\(source.size.x),\(source.size.y),\(source.size.z)"
      var effective = resampling.matrix
      effective[3] -= Double(origin.x); effective[7] -= Double(origin.y); effective[11] -= Double(origin.z)
      history = "Resampled BorgVR dataset: \(sourceURL.lastPathComponent); source dataset: \(metadata.uniqueID); "
        + "forward source-to-target voxel matrix (row-major)=\(resampling.matrix); crop origin=\(crop); "
        + "effective source-to-cropped voxel matrix=\(effective); filter=\(resampling.filter.rawValue); outside=0"
      logger?.info(history)
    }
    let effectiveRequest = BorgVRVolumeConversionRequest(
      source: request.source,
      destinationURL: request.destinationURL,
      datasetDescription: metadata.datasetDescription,
      metaDescription: metadata.metaDescription,
      settings: request.settings,
      physicalSizeMeters: request.physicalSizeMeters,
      sizeXMeters: request.sizeXMeters,
      forceSizeX: request.forceSizeX,
      provenance: metadata.provenance + request.provenance + [BORGVRProvenanceEntry(history)],
      meta: metadata.meta,
      toolIdentification: request.toolIdentification
    )
    try convertRaw(source,
      request: effectiveRequest, stagedURL: stagedURL, logger: logger,
      cancellationToken: cancellationToken)
  }

  private static func convertFile(
    _ sourceURL: URL,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let parser = try VolumeFileParserFactory.parser(for: sourceURL.path,
      cancellationCheck: { try cancellationToken?.checkCancellation() },
      progress: { logger?.progress("Reading volume", $0) }, log: { logger?.info($0) })
    defer {
      if parser.dataIsTempCopy {
        try? FileManager.default.removeItem(atPath: parser.absoluteFilename)
      }
    }

    let rawURL = URL(fileURLWithPath: parser.absoluteFilename)
    try BorgVRImportFileAccess.withReadAccess(primary: sourceURL, supporting: rawURL) { readableURL in
      try convertRaw(
        BorgVRRawVolumeSource(
          url: readableURL,
          offset: parser.offset,
          size: parser.size,
          bytesPerComponent: parser.bytesPerComponent,
          componentCount: parser.components,
          voxelSpacing: parser.voxelSpacing,
          hasPhysicalVoxelSpacing: parser.hasPhysicalVoxelSpacing,
          channelInterpretation: parser.channelInterpretation
        ),
        request: request,
        stagedURL: stagedURL,
        logger: logger,
        cancellationToken: cancellationToken
      )
    }
  }

  @discardableResult
  static func convertDICOMDirectory(
    _ directoryURL: URL,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> [URL] {
    let volume = try decodeDICOMDirectory(
      directoryURL,
      logger: logger,
      cancellationToken: cancellationToken
    )
    let temporaryURL = volume.source.url
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let effectiveRequest = BorgVRVolumeConversionRequest(
      source: request.source,
      destinationURL: request.destinationURL,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription.isEmpty
        ? volume.channels.map(\.description).joined(separator: " + ")
        : request.metaDescription,
      settings: request.settings,
      physicalSizeMeters: request.physicalSizeMeters,
      sizeXMeters: request.sizeXMeters,
      forceSizeX: request.forceSizeX,
      provenance: request.provenance + volume.provenance,
      meta: request.meta,
      toolIdentification: request.toolIdentification
    )
    try convertRaw(
      volume.source,
      request: effectiveRequest,
      stagedURL: stagedURL,
      logger: logger,
      cancellationToken: cancellationToken,
      signedComponents: volume.channels.map(\.isSigned)
    )
    return volume.sourceFiles
  }

  private static func convertRegisteredPair(
    referenceInput: BorgVRVolumeInput,
    movingInput: BorgVRVolumeInput,
    filter: BorgVRVolumeResamplingFilter,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws {
    let reference = try decodeVolume(
      referenceInput,
      logger: logger,
      cancellationToken: cancellationToken
    )
    defer { try? FileManager.default.removeItem(at: reference.source.url) }
    let moving = try decodeVolume(
      movingInput,
      logger: logger,
      cancellationToken: cancellationToken
    )
    defer { try? FileManager.default.removeItem(at: moving.source.url) }

    let transform = try BorgVRVolumeRigidRegistration.register(
      reference: reference,
      moving: moving,
      logger: logger,
      cancellationToken: cancellationToken
    )
    let fusedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-fused-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: fusedURL) }
    let fused = try BorgVRVolumeFusion.fuse(
      reference: reference,
      moving: moving,
      referenceToMoving: transform,
      filter: filter,
      outputURL: fusedURL,
      logger: logger,
      cancellationToken: cancellationToken
    )

    let effectiveRequest = BorgVRVolumeConversionRequest(
      source: request.source,
      destinationURL: request.destinationURL,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription.isEmpty
        ? fused.channels.map(\.description).joined(separator: " + ")
        : request.metaDescription,
      settings: request.settings,
      physicalSizeMeters: request.physicalSizeMeters,
      sizeXMeters: request.sizeXMeters,
      forceSizeX: request.forceSizeX,
      provenance: request.provenance + fused.provenance,
      meta: request.meta.isEmpty ? fused.meta : request.meta,
      toolIdentification: request.toolIdentification
    )
    try convertRaw(
      fused.source,
      request: effectiveRequest,
      stagedURL: stagedURL,
      logger: logger,
      cancellationToken: cancellationToken,
      signedComponents: fused.channels.map(\.isSigned)
    )
  }

  /// Each source is decoded once into an owned RAW file, independent of its format.
  private static func decodeVolume(
    _ input: BorgVRVolumeInput,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRUnbrickedVolume {
    let url: URL
    switch input {
      case .file(let file): url = file
      case .dicomDirectory(let directory): url = directory
    }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    if case .dicomDirectory = input {
      return try decodeDICOMDirectory(url, logger: logger, cancellationToken: cancellationToken)
    }

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-registration-\(UUID().uuidString).raw")
    do {
      if url.pathExtension.lowercased() == "data" {
        let metadata = try BORGVRMetaData(url: url)
        guard metadata.componentCount == 1, [1, 2, 4].contains(metadata.bytesPerComponent) else {
          throw BorgVRVolumeConversionError.incompatibleFusionSampleFormats
        }
        let raw = try BORGVRVolumeExporter.exportRaw(inputURL: url, outputURL: temporaryURL,
          logger: logger, cancellationCheck: { try cancellationToken?.checkCancellation() })
        return BorgVRUnbrickedVolume(
          source: BorgVRRawVolumeSource(url: temporaryURL, offset: 0, size: raw.size,
            bytesPerComponent: raw.bytesPerComponent, componentCount: 1, voxelSpacing: raw.voxelSpacing),
          orientation: nil, origin: nil, frameOfReferenceUID: nil,
          channels: [BorgVRUnbrickedVolumeChannelMetadata(description: metadata.datasetDescription,
            modality: nil, patientName: nil, seriesDate: nil, isSigned: false, pixelPaddingValue: nil)],
          provenance: metadata.provenance + [BORGVRProvenanceEntry("Import BorgVR: \(url.lastPathComponent)")],
          meta: metadata.meta
        )
      }
      let parser = try VolumeFileParserFactory.parser(for: url.path,
        cancellationCheck: { try cancellationToken?.checkCancellation() },
        progress: { logger?.progress("Reading volume", $0) }, log: { logger?.info($0) })
      defer {
        if parser.dataIsTempCopy { try? FileManager.default.removeItem(atPath: parser.absoluteFilename) }
      }
      guard parser.components == 1, [1, 2, 4].contains(parser.bytesPerComponent) else {
        throw BorgVRVolumeConversionError.incompatibleFusionSampleFormats
      }
      let rawURL = URL(fileURLWithPath: parser.absoluteFilename)
      try BorgVRImportFileAccess.withReadAccess(primary: url, supporting: rawURL) { readableURL in
        let source = try RawFileAccessor(filename: readableURL.path, size: parser.size,
          bytesPerComponent: parser.bytesPerComponent, componentCount: 1,
          voxelSpacing: parser.voxelSpacing, offset: parser.offset, readOnly: true)
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
          throw BorgVRVolumeConversionError.cannotCreateTemporaryVolume(temporaryURL)
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }
        let total = source.totalBytes
        var offset = 0
        while offset < total {
          try cancellationToken?.checkCancellation()
          let count = min(1_048_576, total - offset)
          try output.write(contentsOf: Data(bytes: source.mappedMemory.advanced(by: offset), count: count))
          offset += count
        }
      }
      return BorgVRUnbrickedVolume(
        source: BorgVRRawVolumeSource(url: temporaryURL, offset: 0, size: parser.size,
          bytesPerComponent: parser.bytesPerComponent, componentCount: 1,
          voxelSpacing: parser.voxelSpacing, hasPhysicalVoxelSpacing: parser.hasPhysicalVoxelSpacing),
        orientation: parser.orientation, origin: parser.origin, frameOfReferenceUID: nil,
        channels: [BorgVRUnbrickedVolumeChannelMetadata(description: url.deletingPathExtension().lastPathComponent,
          modality: nil, patientName: nil, seriesDate: nil, isSigned: parser.isSigned, pixelPaddingValue: nil)],
        provenance: [BORGVRProvenanceEntry("Import file: \(url.lastPathComponent)")], meta: parser.metadataText
      )
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private static func decodeDICOMDirectory(
    _ directoryURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRUnbrickedVolume {
    var listingResult: Result<[URL], Swift.Error>?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: directoryURL, options: [], error: &coordinationError) { url in
      listingResult = Result {
        try FileManager.default.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        ).filter { url in
          try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
      }
    }
    if let coordinationError { throw coordinationError }
    guard let listingResult else { throw CocoaError(.fileReadUnknown) }
    let files = try listingResult.get()
    guard !files.isEmpty else {
      throw BorgVRVolumeConversionError.noDICOMFiles(directoryURL)
    }

    logger?.info(localized(
      "converter_log_info_scanning_dicom_dir",
      fallback: "Scanning DICOM directory"
    ))
    let volume = try DicomParser.decodeVolume(
      from: files,
      logger: logger,
      cancellationToken: cancellationToken
    )
    try cancellationToken?.checkCancellation()

    let temporaryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-dicom-\(UUID().uuidString).raw")
    do {
      try Data(volume.voxelData).write(to: temporaryURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
    let recordedAt = Date()
    let provenance = volume.provenance.map {
      BORGVRProvenanceEntry($0.text, date: $0.date ?? recordedAt)
    } + [BORGVRProvenanceEntry("Import DICOM: \(directoryURL.lastPathComponent)", date: recordedAt)]
    return BorgVRUnbrickedVolume(
      source: BorgVRRawVolumeSource(
        url: temporaryURL,
        offset: 0,
        size: Vec3<Int>(x: volume.width, y: volume.height, z: volume.depth),
        bytesPerComponent: volume.bytesPerVoxel,
        componentCount: 1,
        voxelSpacing: Vec3<Float>(
          x: volume.voxelSpacing.x,
          y: volume.voxelSpacing.y,
          z: volume.voxelSpacing.z
        ),
        hasPhysicalVoxelSpacing: volume.hasPhysicalVoxelSpacing
      ),
      orientation: volume.orientation,
      origin: volume.origin,
      frameOfReferenceUID: volume.frameOfReferenceUID,
      channels: [BorgVRUnbrickedVolumeChannelMetadata(
        description: dicomDescription(for: volume),
        modality: volume.modality,
        patientName: volume.patientName,
        seriesDate: volume.seriesDate,
        isSigned: volume.isSigned,
        pixelPaddingValue: volume.pixelPaddingValue
      )],
      sourceFiles: volume.sourceFiles,
      provenance: provenance
    )
  }

  private static func convertRaw(
    _ source: BorgVRRawVolumeSource,
    request: BorgVRVolumeConversionRequest,
    stagedURL: URL,
    logger: LoggerBase?,
    cancellationToken: BorgVRVolumeConversionCancellationToken?,
    signedComponents: [Bool] = []
  ) throws {
    try cancellationToken?.checkCancellation()
    var provenance = request.provenance
    switch request.source {
      case .imageSequence(let url):
        provenance.append(BORGVRProvenanceEntry("Import image sequence: \(url.lastPathComponent); filename order; physical size \(request.physicalSizeMeters!) m"))
      case .file(let url): provenance.append(BORGVRProvenanceEntry("Import file: \(url.lastPathComponent)"))
      case .dicomDirectory, .registeredPair, .borgVR: break // History is supplied by the decoded/fused volume.
      case .raw(let source): provenance.append(BORGVRProvenanceEntry("Import RAW: \(source.url.lastPathComponent)"))
    }
    var spacing = source.voxelSpacing
    if let extent = request.physicalSizeMeters {
      spacing = Vec3(x: extent.x / Float(source.size.x), y: extent.y / Float(source.size.y),
        z: extent.z / Float(source.size.z))
      guard [spacing.x, spacing.y, spacing.z].allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
      }
    } else if let sizeX = request.sizeXMeters {
      if request.forceSizeX || !source.hasPhysicalVoxelSpacing {
        let oldExtentX = Double(spacing.x) * Double(source.size.x)
        let factor = Double(sizeX) / oldExtentX
        spacing = Vec3(x: Float(Double(spacing.x) * factor), y: Float(Double(spacing.y) * factor),
          z: Float(Double(spacing.z) * factor))
        guard [spacing.x, spacing.y, spacing.z].allSatisfy({ $0.isFinite && $0 > 0 }) else {
          throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
        }
        let text = "Set physical X extent to \(sizeX) m; scaled all voxel axes by \(factor); "
          + "\(request.forceSizeX ? "forced override" : "no physical size in source")"
        provenance.append(BORGVRProvenanceEntry(text))
        logger?.info(text)
      } else {
        logger?.info("Ignoring --size-x: the source supplies physical voxel spacing. Use --force-size-x to override it.")
      }
    }
    var volume = try RawFileAccessor(
      filename: source.url.path,
      size: source.size,
      bytesPerComponent: source.bytesPerComponent,
      componentCount: source.componentCount,
      voxelSpacing: spacing,
      offset: source.offset,
      readOnly: true
    )
    let quantizedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("borgvr-quantized-\(UUID().uuidString).raw")
    defer { try? FileManager.default.removeItem(at: quantizedURL) }
    if request.settings.quantizeTo8Bit, source.bytesPerComponent > 1 {
      volume = try BorgVRVolumeQuantizer.quantize(
        volume, signedComponents: signedComponents, to: quantizedURL,
        logger: logger, cancellationToken: cancellationToken,
        recordProvenance: { provenance.append(BORGVRProvenanceEntry($0)) }
      )
    }
    let reorganizer = BrickedVolumeReorganizer(
      inputVolume: volume,
      brickSize: request.settings.brickSize,
      overlap: request.settings.overlap,
      extensionStrategy: request.settings.extensionStrategy
    )
    try reorganizer.reorganize(
      to: stagedURL.path,
      datasetDescription: request.datasetDescription,
      metaDescription: request.metaDescription,
      useCompressor: request.settings.useCompression,
      logger: logger,
      cancellationToken: cancellationToken,
      provenance: provenance,
      meta: request.meta,
      channelInterpretation: source.channelInterpretation,
      astcBlockSize: request.settings.colorCompression,
      toolIdentification: request.toolIdentification
    )
  }

  private static func installStagedOutput(_ stagedURL: URL, at destinationURL: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(
        destinationURL,
        withItemAt: stagedURL,
        backupItemName: nil,
        options: []
      )
    } else {
      try fileManager.moveItem(at: stagedURL, to: destinationURL)
    }
  }

  private static func dicomDescription(for volume: DicomParser.DicomVolume) -> String {
    var parts = [volume.modality.map { "\($0) scan" } ?? "Scan"]
    if let patientName = volume.patientName {
      parts.append("of \(patientName)")
    }
    if let seriesDate = volume.seriesDate {
      parts.append("at \(seriesDate)")
    }
    return parts.joined(separator: " ").replacingOccurrences(of: "^", with: ", ")
  }

  private static func localized(_ key: String, fallback: String) -> String {
    Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
  }
}
