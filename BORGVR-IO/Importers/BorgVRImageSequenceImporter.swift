import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Decodes one filename-sorted image per Z slice, keeping only one slice in memory.
enum BorgVRImageSequenceImporter {
  static func imageFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
      .filter { url in
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
          && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func decode(
    directory: URL, physicalSizeMeters: Vec3<Float>, output: URL,
    logger: LoggerBase?, cancellationToken: BorgVRVolumeConversionCancellationToken?
  ) throws -> BorgVRRawVolumeSource {
    guard [physicalSizeMeters.x, physicalSizeMeters.y, physicalSizeMeters.z]
      .allSatisfy({ $0.isFinite && $0 > 0 }) else {
      throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
    }
    let files = try imageFiles(in: directory)
    guard !files.isEmpty else { throw failure("image_sequence_empty") }

    var hasAlpha = false
    for file in files {
      try cancellationToken?.checkCancellation()
      guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        throw failure("image_sequence_invalid", file.lastPathComponent)
      }
      hasAlpha = hasAlpha || (properties[kCGImagePropertyHasAlpha] as? Bool == true)
    }
    let components = hasAlpha ? 4 : 3
    guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
      throw BorgVRVolumeConversionError.cannotCreateTemporaryVolume(output)
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    var width = 0, height = 0
    for (z, file) in files.enumerated() {
      try cancellationToken?.checkCancellation()
      try autoreleasepool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
          throw failure("image_sequence_invalid", file.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let image: CGImage
        if orientation == 1 {
          image = original
        } else {
          guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(original.width, original.height)
          ] as CFDictionary) else {
            throw failure("image_sequence_invalid", file.lastPathComponent)
          }
          image = oriented
        }
        if z == 0 { width = image.width; height = image.height }
        guard width == image.width, height == image.height else {
          throw failure("image_sequence_dimensions", file.lastPathComponent)
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 8)
        guard !pixelOverflow, !byteOverflow, bytes > 0 else {
          throw BorgVRVolumeConversionError.invalidIntermediateVolumeSize
        }
        // Higher precision avoids losing RGB levels when removing premultiplied alpha.
        var rgba = [UInt16](repeating: 0, count: bytes / 2)
        try rgba.withUnsafeMutableBytes { buffer in
          guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 16, bytesPerRow: width * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw failure("image_sequence_invalid", file.lastPathComponent)
          }
          context.setBlendMode(.copy)
          context.interpolationQuality = .none
          context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var slice = Data(count: pixels * components)
        slice.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
          for pixel in 0..<pixels {
            let sourceIndex = pixel * 4, targetIndex = pixel * components
            let alpha = Int(rgba[sourceIndex + 3])
            for channel in 0..<3 {
              // The on-disk color is straight RGB, not Core Graphics' premultiplied RGB.
              destination[targetIndex + channel] = alpha == 0 ? 0
                : UInt8(min(255, (Int(rgba[sourceIndex + channel]) * 255 + alpha / 2) / alpha))
            }
            if hasAlpha { destination[targetIndex + 3] = UInt8((alpha + 128) / 257) }
          }
        }
        try handle.write(contentsOf: slice)
      }
      logger?.progress("Reading image sequence", Double(z + 1) / Double(files.count))
    }
    logger?.info("Image sequence: \(width) x \(height) x \(files.count), \(hasAlpha ? "RGBA" : "RGB"), sorted by filename.")
    return BorgVRRawVolumeSource(url: output, offset: 0,
      size: Vec3(x: width, y: height, z: files.count), bytesPerComponent: 1,
      componentCount: components,
      voxelSpacing: Vec3(x: physicalSizeMeters.x / Float(width),
        y: physicalSizeMeters.y / Float(height), z: physicalSizeMeters.z / Float(files.count)),
      channelInterpretation: hasAlpha ? .rgba : .rgb)
  }

  private static func failure(_ key: String, _ filename: String = "") -> NSError {
    let fallback: String
    switch key {
      case "image_sequence_empty": fallback = "The folder contains no supported images."
      case "image_sequence_dimensions": fallback = "Image dimensions differ from the other slices: %@."
      default: fallback = "Cannot read a single image slice from %@."
    }
    return NSError(domain: "BorgVRImageSequence", code: 1, userInfo: [NSLocalizedDescriptionKey:
      String(format: Bundle.main.localizedString(forKey: key, value: fallback, table: nil), filename)])
  }
}
