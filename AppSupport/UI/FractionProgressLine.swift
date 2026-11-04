import SwiftUI

/// A left-aligned fraction of the available width, without a track or a spinner.
struct FractionProgressLine: View {
  let fraction: Double
  var color: Color = .red

  var body: some View {
    GeometryReader { geometry in
      Rectangle().fill(color)
        .frame(width: geometry.size.width * (fraction.isFinite ? min(1, max(0, fraction)) : 0))
    }
    .frame(height: 2)
  }
}
