import SwiftUI

/// The remaining fraction stays on the right, disappearing from left to right.
struct FractionProgressLine: View {
  let fraction: Double
  var color: Color = .red

  var body: some View {
    GeometryReader { geometry in
      Rectangle().fill(color)
        .frame(width: geometry.size.width * (fraction.isFinite ? min(1, max(0, fraction)) : 0))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(height: 2)
  }
}
