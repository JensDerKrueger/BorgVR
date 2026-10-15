import CoreGraphics
import Foundation
import ImageIO
import Metal
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
    guard texture.width > 0, texture.height > 0 else {
      throw MetalScreenshotError.emptyTexture
    }
    guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb else {
      throw MetalScreenshotError.unsupportedPixelFormat
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

  static func pngData(from readback: MetalScreenshotReadback) throws -> Data {
    let byteCount = readback.bytesPerRow * readback.height
    let pixels = Data(bytes: readback.buffer.contents(), count: byteCount)
    guard let provider = CGDataProvider(data: pixels as CFData) else {
      throw MetalScreenshotError.imageCreationFailed
    }
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
    )
    guard let image = CGImage(
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
    return output as Data
  }
}

enum MetalScreenshotError: LocalizedError {
  case emptyTexture
  case unsupportedPixelFormat
  case readbackFailed
  case imageCreationFailed
  case destinationCreationFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
      case .emptyTexture: "The render texture is empty."
      case .unsupportedPixelFormat: "The render texture uses an unsupported pixel format."
      case .readbackFailed: "The render texture could not be read back."
      case .imageCreationFailed: "The screenshot image could not be created."
      case .destinationCreationFailed: "The PNG encoder could not be created."
      case .writeFailed: "The screenshot could not be encoded as PNG."
    }
  }
}
