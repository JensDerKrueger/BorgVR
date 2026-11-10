import Foundation

/// Unit-length volume axes in physical coordinates; voxel spacing is stored separately.
public struct BorgVRVolumeOrientation: Equatable, Sendable {
  public let xAxis: Vec3<Float>
  public let yAxis: Vec3<Float>
  public let zAxis: Vec3<Float>

  public init(xAxis: Vec3<Float>, yAxis: Vec3<Float>, zAxis: Vec3<Float>) {
    self.xAxis = xAxis
    self.yAxis = yAxis
    self.zAxis = zAxis
  }
}
