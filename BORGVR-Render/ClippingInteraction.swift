/// Keeps gesture travel through zero without applying a clipping plane there.
struct ClippingInteraction {
  static let deadZone: Float = 0.015
  private var travel = SIMD3<Float>(repeating: 0)
  private var previous = SIMD3<Float>(repeating: .nan)

  static func translation(start: Float, delta: Float, limit: Float = 0.99) -> Float {
    let travel = rawTranslation(start) + delta
    let magnitude = max(0, abs(travel) - deadZone)
    return min(limit, magnitude) * (travel < 0 ? -1 : 1)
  }

  static func translation(start: SIMD3<Float>, delta: SIMD3<Float>, limit: Float = 0.99) -> SIMD3<Float> {
    SIMD3(translation(start: start.x, delta: delta.x, limit: limit),
          translation(start: start.y, delta: delta.y, limit: limit),
          translation(start: start.z, delta: delta.z, limit: limit))
  }

  mutating func move(axis: Int, delta: Float, current: Float, limit: Float = 0.98) -> Float {
    if previous[axis] != current { travel[axis] = Self.rawTranslation(current) }
    travel[axis] = min(limit + Self.deadZone, max(-limit - Self.deadZone, travel[axis] + delta))
    previous[axis] = Self.translation(start: 0, delta: travel[axis], limit: limit)
    return previous[axis]
  }

  private static func rawTranslation(_ value: Float) -> Float {
    value == 0 ? 0 : value + (value < 0 ? -deadZone : deadZone)
  }
}
