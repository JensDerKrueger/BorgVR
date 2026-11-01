/// Voxel channels are independent scalars unless the file explicitly declares color data.
/// RGB/RGBA colors are stored without premultiplication by alpha.
public enum BORGVRChannelInterpretation: UInt8, Codable, Sendable {
  case independentChannels = 0
  case rgb = 1
  case rgba = 2

  func rangeCount(componentCount: Int) -> Int {
    switch self {
      case .independentChannels: componentCount
      case .rgb: 0
      case .rgba: 1
    }
  }

  /// Stored ranges describe alpha for RGBA, not its three color components.
  func rangeChannels(componentCount: Int) -> [Int] {
    switch self {
      case .independentChannels: Array(0..<componentCount)
      case .rgb: []
      case .rgba: [3]
    }
  }

  var name: String {
    switch self {
      case .independentChannels: "independentChannels"
      case .rgb: "rgb"
      case .rgba: "rgba"
    }
  }
}
