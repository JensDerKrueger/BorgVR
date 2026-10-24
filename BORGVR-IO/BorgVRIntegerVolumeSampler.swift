import Foundation

struct BorgVRIntegerVolumeSampler<Value: FixedWidthInteger> {
  let values: UnsafePointer<Value>
  let size: Vec3<Int>
  let paddingValue: Value?

  @inline(__always)
  func nearestNeighbor(at coordinate: Vec3<Float>) -> Double? {
    guard coordinate.x.isFinite,
          coordinate.y.isFinite,
          coordinate.z.isFinite else {
      return nil
    }
    let x = Int(coordinate.x.rounded())
    let y = Int(coordinate.y.rounded())
    let z = Int(coordinate.z.rounded())
    guard (0..<size.x).contains(x),
          (0..<size.y).contains(y),
          (0..<size.z).contains(z) else {
      return nil
    }
    return value(x: x, y: y, z: z, weight: 1)
  }

  @inline(__always)
  func trilinear(at coordinate: Vec3<Float>) -> Double? {
    guard coordinate.x.isFinite,
          coordinate.y.isFinite,
          coordinate.z.isFinite,
          coordinate.x >= 0,
          coordinate.x <= Float(size.x - 1),
          coordinate.y >= 0,
          coordinate.y <= Float(size.y - 1),
          coordinate.z >= 0,
          coordinate.z <= Float(size.z - 1) else {
      return nil
    }

    let x0 = Int(coordinate.x.rounded(.down))
    let y0 = Int(coordinate.y.rounded(.down))
    let z0 = Int(coordinate.z.rounded(.down))
    let x1 = min(x0 + 1, size.x - 1)
    let y1 = min(y0 + 1, size.y - 1)
    let z1 = min(z0 + 1, size.z - 1)
    let tx = Double(coordinate.x - Float(x0))
    let ty = Double(coordinate.y - Float(y0))
    let tz = Double(coordinate.z - Float(z0))

    guard let c000 = value(x: x0, y: y0, z: z0, weight: (1 - tx) * (1 - ty) * (1 - tz)),
          let c100 = value(x: x1, y: y0, z: z0, weight: tx * (1 - ty) * (1 - tz)),
          let c010 = value(x: x0, y: y1, z: z0, weight: (1 - tx) * ty * (1 - tz)),
          let c110 = value(x: x1, y: y1, z: z0, weight: tx * ty * (1 - tz)),
          let c001 = value(x: x0, y: y0, z: z1, weight: (1 - tx) * (1 - ty) * tz),
          let c101 = value(x: x1, y: y0, z: z1, weight: tx * (1 - ty) * tz),
          let c011 = value(x: x0, y: y1, z: z1, weight: (1 - tx) * ty * tz),
          let c111 = value(x: x1, y: y1, z: z1, weight: tx * ty * tz) else {
      return nil
    }
    return c000 + c100 + c010 + c110 + c001 + c101 + c011 + c111
  }

  @inline(__always)
  private func value(x: Int, y: Int, z: Int, weight: Double) -> Double? {
    guard weight > 0 else { return 0 }
    let value = values[(z * size.y + y) * size.x + x]
    guard value != paddingValue else { return nil }
    return Double(value) * weight
  }
}
