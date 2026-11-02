/// Voxel channels are independent scalars unless the file explicitly declares color data.
/// RGB/RGBA colors are stored without premultiplication by alpha.
public enum BORGVRChannelInterpretation: UInt8, Codable, Sendable {
  case independentChannels = 0
  case rgb = 1
  case rgba = 2
  case rgbASTC4x4 = 3
  case rgbaASTC4x4 = 4
  case rgbASTC8x8 = 5
  case rgbaASTC8x8 = 6

  var colorInterpretation: Self {
    switch self {
      case .rgbASTC4x4, .rgbASTC8x8: .rgb
      case .rgbaASTC4x4, .rgbaASTC8x8: .rgba
      default: self
    }
  }

  var astcBlockSize: Int {
    switch self {
      case .rgbASTC4x4, .rgbaASTC4x4: 4
      case .rgbASTC8x8, .rgbaASTC8x8: 8
      default: 0
    }
  }

  func withASTC(blockSize: Int) -> Self {
    guard colorInterpretation != .independentChannels else { return self }
    if blockSize == 4 { return colorInterpretation == .rgb ? .rgbASTC4x4 : .rgbaASTC4x4 }
    if blockSize == 8 { return colorInterpretation == .rgb ? .rgbASTC8x8 : .rgbaASTC8x8 }
    return colorInterpretation
  }

  func rangeCount(componentCount: Int) -> Int {
    switch self {
      case .independentChannels: componentCount
      case .rgb, .rgbASTC4x4, .rgbASTC8x8: 0
      case .rgba, .rgbaASTC4x4, .rgbaASTC8x8: 1
    }
  }

  /// Stored ranges describe alpha for RGBA, not its three color components.
  func rangeChannels(componentCount: Int) -> [Int] {
    switch self {
      case .independentChannels: Array(0..<componentCount)
      case .rgb, .rgbASTC4x4, .rgbASTC8x8: []
      case .rgba, .rgbaASTC4x4, .rgbaASTC8x8: [3]
    }
  }

  var name: String {
    switch self {
      case .independentChannels: "independentChannels"
      case .rgb: "rgb"
      case .rgba: "rgba"
      case .rgbASTC4x4: "rgbASTC4x4"
      case .rgbaASTC4x4: "rgbaASTC4x4"
      case .rgbASTC8x8: "rgbASTC8x8"
      case .rgbaASTC8x8: "rgbaASTC8x8"
    }
  }
}
