@main
enum ClippingInteractionTests {
  static func main() {
    func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 0.000001 }
    let d = ClippingInteraction.deadZone
    for sign: Float in [-1, 1] {
      assert(ClippingInteraction.translation(start: 0, delta: sign * d * 0.9) == 0)
      assert(close(ClippingInteraction.translation(start: 0, delta: sign * d * 2), sign * d))
      assert(close(ClippingInteraction.translation(start: sign * 0.2, delta: 0), sign * 0.2))
      assert(ClippingInteraction.translation(start: sign * 0.2, delta: -sign * (0.2 + d)) == 0)
      assert(close(ClippingInteraction.translation(start: sign * 0.2, delta: -sign * (0.2 + d * 3)), -sign * d))
    }
    var gesture = ClippingInteraction()
    var value: Float = 0
    for _ in 0..<10 { value = gesture.move(axis: 0, delta: d / 20, current: value) }
    assert(value == 0)
    for _ in 0..<40 { value = gesture.move(axis: 0, delta: d / 20, current: value) }
    assert(close(value, d * 1.5), "Small deltas must accumulate through the dead zone")
    value = gesture.move(axis: 0, delta: 0, current: 0)
    assert(value == 0, "An external reset must clear earlier travel")
    assert(gesture.move(axis: 1, delta: 100, current: 0) == 0.98)
    assert(gesture.move(axis: 2, delta: -100, current: 0) == -0.98)
    print("Clipping dead-zone tests passed: both directions, incremental travel, external reset, axis independence and limits")
  }
}
