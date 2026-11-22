import CoreGraphics
import Foundation
import ImageIO

/// A small, isolated projection of one scalar channel. No live renderer state is used.
struct VoiceAgentVolumePreview: Sendable {
  let width: Int
  let height: Int
  let depth: Int
  let samples: [Float]

  static func read(_ source: any BORGVRDatasetProtocol, channel: Int) throws -> Self {
    let metadata = source.getMetadata()
    guard metadata.channelInterpretation == .independentChannels,
          metadata.componentType == .unsignedInteger,
          metadata.componentRanges.indices.contains(channel), metadata.componentCount > channel,
          let level = metadata.levelMetadata.last,
          level.totalBricks.x == 1, level.totalBricks.y == 1, level.totalBricks.z == 1,
          try metadata.voxelBrickByteCount() <= 64 * 1024 * 1024
    else { throw BorgVRMCPCommandError.screenshotUnavailable }
    let extent = metadata.physicalExtentMeters
    guard extent.x.isFinite, extent.y.isFinite, extent.x > 0, extent.y > 0 else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    let size = metadata.brickSize
    let inset = metadata.overlap
    let usable = size - 2 * inset
    let shape = level.size
    guard usable > 0, (1...usable).contains(shape.x), (1...usable).contains(shape.y), (1...usable).contains(shape.z) else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    let width = max(1, Int((128 * (extent.x / max(extent.x, extent.y))).rounded()))
    let height = max(1, Int((128 * (extent.y / max(extent.x, extent.y))).rounded()))
    let depth = min(128, shape.z)
    let bytes = source.allocateBrickBuffer()
    defer { bytes.deallocate() }
    try Task.checkCancellation()
    try source.getFirstBrick(outputBuffer: bytes)
    // Match the native TF texture bias: sample value divided by the channel maximum.
    let maximum = max(metadata.componentRanges[channel].maximum, 1)
    let componentBytes = metadata.bytesPerComponent
    let voxelBytes = componentBytes * metadata.componentCount
    var samples = [Float](repeating: .nan, count: width * height * depth)
    // Z planes are contiguous so each preview can fill all rays in order.
    for z in 0..<depth {
      try Task.checkCancellation()
      let srcZ = inset + ((2 * z + 1) * shape.z) / (2 * depth)
      for y in 0..<height {
        let srcY = inset + ((2 * (height - 1 - y) + 1) * shape.y) / (2 * height)
        for x in 0..<width {
          let srcX = inset + ((2 * x + 1) * shape.x) / (2 * width)
          let offset = ((srcZ * size + srcY) * size + srcX) * voxelBytes + channel * componentBytes
          var bits: UInt64 = 0
          for index in 0..<componentBytes { bits |= UInt64(bytes[offset + index]) << (8 * index) }
          samples[(z * height + y) * width + x] = Float(min(1, Double(bits) / maximum))
        }
      }
    }
    return Self(width: width, height: height, depth: depth, samples: samples)
  }

  func render(low: Double, high: Double, rainbow: Bool) throws -> Data {
    guard low.isFinite, high.isFinite, 0 <= low, low < high, high <= 1 else {
      throw BorgVRMCPCommandError.invalidArgument("Expected 0 <= low < high <= 1.")
    }
    let pixels = width * height
    let lower = Float(low), upper = Float(high)
    var rgba = [UInt8](repeating: 0, count: pixels * 4)
    var uncovered = pixels
    for z in 0..<depth {
      try Task.checkCancellation()
      let base = z * pixels
      for i in 0..<pixels where rgba[4 * i + 3] == 0 {
        let value = samples[base + i]
        guard value >= lower && (value < upper || high == 1 && value == upper) else { continue }
        let offset = 4 * i
        if rainbow {
          let hue = 4 * (1 - value)
          let sector = Int(hue)
          let fraction = UInt8((255 * (hue - Float(sector))).rounded())
          switch sector {
            case 0: rgba[offset] = 255; rgba[offset + 1] = fraction
            case 1: rgba[offset] = 255 - fraction; rgba[offset + 1] = 255
            case 2: rgba[offset + 1] = 255; rgba[offset + 2] = fraction
            case 3: rgba[offset + 1] = 255 - fraction; rgba[offset + 2] = 255
            default: rgba[offset + 2] = 255
          }
        } else {
          let gray = UInt8((255 * value).rounded())
          rgba[offset] = gray; rgba[offset + 1] = gray; rgba[offset + 2] = gray
        }
        rgba[offset + 3] = 255
        uncovered -= 1
      }
      if uncovered == 0 { break }
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
      throw BorgVRMCPCommandError.screenshotUnavailable
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BorgVRMCPCommandError.screenshotUnavailable }
    return png as Data
  }
}
