import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import UniformTypeIdentifiers

struct MetalScreenshotReadback {
  let buffer: MTLBuffer
  let width: Int
  let height: Int
  let bytesPerRow: Int
}

enum MetalScreenshotEncoder {
  static func encodeReadback(
    from texture: MTLTexture,
    slice: Int = 0,
    commandBuffer: MTLCommandBuffer
  ) throws -> MetalScreenshotReadback {
    guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb else {
      throw MetalScreenshotError.unsupportedPixelFormat
    }
    return try encodeFourByteReadback(from: texture, slice: slice, commandBuffer: commandBuffer)
  }

  private static func encodeFourByteReadback(
    from texture: MTLTexture, slice: Int, commandBuffer: MTLCommandBuffer
  ) throws -> MetalScreenshotReadback {
    guard texture.width > 0, texture.height > 0 else {
      throw MetalScreenshotError.emptyTexture
    }
    let bytesPerRow = ((texture.width * 4 + 255) / 256) * 256
    let byteCount = bytesPerRow * texture.height
    guard let buffer = texture.device.makeBuffer(length: byteCount, options: .storageModeShared),
          let encoder = commandBuffer.makeBlitCommandEncoder() else {
      throw MetalScreenshotError.readbackFailed
    }
    encoder.copy(
      from: texture,
      sourceSlice: min(max(slice, 0), max(texture.arrayLength - 1, 0)),
      sourceLevel: 0,
      sourceOrigin: .init(x: 0, y: 0, z: 0),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
      to: buffer,
      destinationOffset: 0,
      destinationBytesPerRow: bytesPerRow,
      destinationBytesPerImage: byteCount
    )
    encoder.endEncoding()
    return MetalScreenshotReadback(
      buffer: buffer,
      width: texture.width,
      height: texture.height,
      bytesPerRow: bytesPerRow
    )
  }

  static func encodePairedReadback(
    color: MTLTexture, depth: MTLTexture, textureToClip: simd_float4x4,
    viewport: MTLViewport? = nil, rateMap: MTLRasterizationRateMap? = nil,
    commandBuffer: MTLCommandBuffer
  ) throws -> MetalPairedScreenshotReadback {
    let readback = try encodeReadback(from: color, commandBuffer: commandBuffer)
    let colorOnly = MetalPairedScreenshotReadback(color: readback, positionReadback: nil)
    guard color.width == depth.width, color.height == depth.height,
          depth.pixelFormat == .r32Float,
          color.width <= BorgVRScreenshotPositions.maximumPixels / color.height else {
      return colorOnly
    }
    let inverse = simd_inverse(textureToClip)
    guard (0..<4).allSatisfy({ column in (0..<4).allSatisfy { inverse[column][$0].isFinite } }) else {
      return colorOnly
    }
    let viewport = viewport ?? .init(originX: 0, originY: 0, width: Double(color.width),
                                      height: Double(color.height), znear: 0, zfar: 1)
    guard viewport.width > 0, viewport.height > 0,
          let depthReadback = try? encodeFourByteReadback(from: depth, slice: 0, commandBuffer: commandBuffer) else {
      return colorOnly
    }
    // The PNG is a physical-pixel readback. Undo the eye's rate map before unprojecting.
    let physicalSize = rateMap?.physicalSize(layer: 0)
    let columns = (0..<color.width).map { x -> Float in
      guard x < (physicalSize?.width ?? color.width) else { return .nan }
      let p = MTLCoordinate2D(x: Float(x) + 0.5, y: 0.5)
      let logical = rateMap?.screenCoordinates(physicalCoordinates: p, layer: 0) ?? p
      return Float((Double(logical.x) - viewport.originX) / viewport.width * 2 - 1)
    }
    let rows = (0..<color.height).map { y -> Float in
      guard y < (physicalSize?.height ?? color.height) else { return .nan }
      let p = MTLCoordinate2D(x: 0.5, y: Float(y) + 0.5)
      let logical = rateMap?.screenCoordinates(physicalCoordinates: p, layer: 0) ?? p
      return Float(1 - (Double(logical.y) - viewport.originY) / viewport.height * 2)
    }
    return .init(color: readback, positionReadback: .init(depth: depthReadback,
      clipToVolume: inverse, columns: columns, rows: rows))
  }

  static func pngData(from readback: MetalScreenshotReadback, maxWidth: Int? = nil) throws -> Data {
    try pngImage(from: readback, maxWidth: maxWidth).data
  }

  static let maximumPreviewWidth = 16_384

  static func pngImage(from readback: MetalScreenshotReadback, maxWidth: Int?) throws
    -> (data: Data, width: Int, height: Int) {
    let byteCount = readback.bytesPerRow * readback.height
    let pixels = Data(bytes: readback.buffer.contents(), count: byteCount)
    guard let provider = CGDataProvider(data: pixels as CFData) else {
      throw MetalScreenshotError.imageCreationFailed
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
    )
    guard var image = CGImage(
      width: readback.width,
      height: readback.height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: readback.bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ) else {
      throw MetalScreenshotError.imageCreationFailed
    }

    if let maxWidth, maxWidth < image.width {
      let height = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
      guard maxWidth > 0, let context = CGContext(data: nil, width: maxWidth, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
        throw MetalScreenshotError.imageCreationFailed
      }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
      guard let scaled = context.makeImage() else { throw MetalScreenshotError.imageCreationFailed }
      image = scaled
    }

    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw MetalScreenshotError.destinationCreationFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw MetalScreenshotError.writeFailed
    }
    return (output as Data, image.width, image.height)
  }
}

struct MetalPairedScreenshotReadback {
  let color: MetalScreenshotReadback
  let positionReadback: MetalScreenshotPositionReadback?
}

struct MetalScreenshotPositionReadback {
  let depth: MetalScreenshotReadback
  let clipToVolume: simd_float4x4
  let columns: [Float]
  let rows: [Float]

  func positions() -> BorgVRScreenshotPositions {
    .init(depth: Data(bytes: depth.buffer.contents(), count: depth.bytesPerRow * depth.height),
          depthBytesPerRow: depth.bytesPerRow, clipToVolume: clipToVolume,
          columns: columns, rows: rows)
  }
}

struct BorgVRScreenshotPositions: Sendable {
  static let maximumPixels = 32 * 1024 * 1024
  static let fileExtension = "borgvrcapture"

  // Immutable depth and projection are a compact, lossless backing for the XYZ map.
  let depth: Data
  let depthBytesPerRow: Int
  let clipToVolume: simd_float4x4
  let columns: [Float]
  let rows: [Float]

  var width: Int { columns.count }
  var height: Int { rows.count }

  func position(x: Double, y: Double) -> SIMD3<Float>? {
    guard (0...1).contains(x), (0...1).contains(y), width > 0, height > 0 else { return nil }
    return depth.withUnsafeBytes {
      position(column: min(width - 1, Int(x * Double(width))),
               row: min(height - 1, Int(y * Double(height))), depths: $0)
    }
  }

  private func position(column: Int, row: Int, depths: UnsafeRawBufferPointer) -> SIMD3<Float>? {
    let value = depths.loadUnaligned(fromByteOffset: row * depthBytesPerRow + column * 4, as: Float.self)
    guard (0...1).contains(value), abs(columns[column]) <= 1, abs(rows[row]) <= 1 else { return nil }
    let p = clipToVolume * SIMD4(columns[column], rows[row], value, 1)
    guard abs(p.w) > 0.000_001 else { return nil }
    let point = SIMD3(p.x, p.y, p.z) / p.w
    guard (0..<3).allSatisfy({ (-0.0001...1.0001).contains(point[$0]) }) else { return nil }
    return simd_clamp(point, .zero, SIMD3(repeating: 1))
  }

  func archive(png: Data, maximumBytes: Int? = nil) throws -> Data {
    let pngOffset = 20
    let positionsOffset = (pngOffset + png.count + 3) & ~3
    let fileSize = positionsOffset + width * height * 12
    guard maximumBytes.map({ fileSize <= $0 }) ?? true else {
      throw MetalScreenshotError.inlineCaptureTooLarge
    }
    var data = Data(count: fileSize)
    try data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
      output.copyBytes(from: Array("BVRPOS1\n".utf8))
      for (index, value) in [width, height, png.count].enumerated() {
        output.storeBytes(of: UInt32(value).littleEndian, toByteOffset: 8 + index * 4, as: UInt32.self)
      }
      let base = output.baseAddress!
      png.withUnsafeBytes { source in
        if let bytes = source.baseAddress { base.advanced(by: pngOffset).copyMemory(from: bytes, byteCount: png.count) }
      }
      let positions = base.advanced(by: positionsOffset).bindMemory(to: UInt32.self, capacity: width * height * 3)
      try depth.withUnsafeBytes { depths in
        for row in 0..<height {
          try Task.checkCancellation()
          for column in 0..<width {
            let p = position(column: column, row: row, depths: depths) ?? SIMD3(repeating: .nan)
            let i = (row * width + column) * 3
            positions[i] = p.x.bitPattern.littleEndian
            positions[i + 1] = p.y.bitPattern.littleEndian
            positions[i + 2] = p.z.bitPattern.littleEndian
          }
        }
      }
    }
    return data
  }
}

final class BorgVRScreenshotCache: @unchecked Sendable {
  struct Capture: Sendable {
    let renderedFrame: UInt64
    let positions: BorgVRScreenshotPositions
  }

  private let lock = NSLock()
  private var id: UUID?
  private var capture: Capture?

  func begin(_ id: UUID?) {
    lock.withLock {
      self.id = id
      capture = nil
    }
  }

  func store(_ positions: BorgVRScreenshotPositions, id: UUID, renderedFrame: UInt64) {
    lock.withLock {
      guard self.id == id else { return }
      capture = Capture(renderedFrame: renderedFrame, positions: positions)
    }
  }

  func lookup(_ id: UUID) -> Capture? {
    lock.withLock { self.id == id ? capture : nil }
  }
}

enum MetalScreenshotError: LocalizedError {
  case emptyTexture
  case unsupportedPixelFormat
  case readbackFailed
  case imageCreationFailed
  case destinationCreationFailed
  case writeFailed
  case positionBufferUnavailable
  case inlineCaptureTooLarge

  var errorDescription: String? {
    switch self {
      case .emptyTexture: "The render texture is empty."
      case .unsupportedPixelFormat: "The render texture uses an unsupported pixel format."
      case .readbackFailed: "The render texture could not be read back."
      case .imageCreationFailed: "The screenshot image could not be created."
      case .destinationCreationFailed: "The PNG encoder could not be created."
      case .writeFailed: "The screenshot could not be encoded as PNG."
      case .positionBufferUnavailable: "No matching position buffer is available for this screenshot."
      case .inlineCaptureTooLarge: "The extended screenshot is too large to return inline. Supply output_path to save it."
    }
  }
}
