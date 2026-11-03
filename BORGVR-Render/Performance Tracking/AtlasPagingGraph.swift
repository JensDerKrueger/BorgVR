import SwiftUI

@MainActor
final class AtlasPagingGraphModel: ObservableObject {
  @Published private(set) var history = AtlasPagingHistory()

  func record(timestamp: TimeInterval, statistics: AtlasPagingStatistics) {
    guard history.shouldRecord(timestamp: timestamp, statistics: statistics) else { return }
    history.record(timestamp: timestamp, statistics: statistics)
  }

  func reset() { history = AtlasPagingHistory() }
}

struct AtlasPagingGraph: View {
  @ObservedObject var model: AtlasPagingGraphModel
  @State private var inspectedTime: TimeInterval?

  var body: some View {
    let samples = model.history.samples
    let latest = samples.last
    let displayed = inspectedTime.flatMap { time in
      samples.min(by: { abs($0.timestamp - time) < abs($1.timestamp - time) })
    } ?? latest
    let maximumRate = max(1, ceil((samples.map(\.bricksPerSecond).max() ?? 0) / 10) * 10)
    VStack(spacing: 12) {
      HStack {
        Label("Paging", systemImage: "line.diagonal")
          .foregroundStyle(.blue)
        Text("\(displayed?.bricksPerSecond ?? 0, specifier: "%.0f") bricks/s")
          .monospacedDigit()
        Spacer()
        Label("Atlas occupancy", systemImage: "line.diagonal")
          .foregroundStyle(.green)
        Text("\((displayed?.fillFraction ?? 0) * 100, specifier: "%.1f") %")
          .monospacedDigit()
        Text(verbatim: "(" + ByteCountFormatter.string(fromByteCount: displayed?.residentBytes ?? 0,
                                                      countStyle: .memory) + ")")
          .monospacedDigit()
      }
      .font(.callout)

      GeometryReader { geometry in
        let plot = CGRect(x: 60, y: 12, width: max(1, geometry.size.width - 108),
                          height: max(1, geometry.size.height - 38))
        let end = latest?.timestamp ?? 0
        Canvas { context, _ in
          for tick in 0...4 {
            let fraction = Double(tick) / 4
            let y = plot.maxY - CGFloat(fraction) * plot.height
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.2)))
            context.draw(Text("\(maximumRate * fraction, specifier: "%.0f")")
              .font(.caption).foregroundColor(.blue),
              at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
            context.draw(Text("\(fraction * 100, specifier: "%.0f") %")
              .font(.caption).foregroundColor(.green),
              at: CGPoint(x: plot.maxX + 8, y: y), anchor: .leading)
          }
          for seconds in stride(from: 0, through: 30, by: 10) {
            let x = plot.minX + CGFloat(seconds) / 30 * plot.width
            context.draw(Text("\(seconds - 30) s").font(.caption).foregroundColor(.secondary),
                         at: CGPoint(x: x, y: plot.maxY + 16))
          }
          for isFill in [false, true] {
            var path = Path()
            for (index, sample) in samples.enumerated() {
              let fraction = isFill ? sample.fillFraction : sample.bricksPerSecond / maximumRate
              let point = CGPoint(
                x: plot.maxX - CGFloat((end - sample.timestamp) / model.history.duration) * plot.width,
                y: plot.maxY - CGFloat(fraction) * plot.height)
              if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(isFill ? .green : .blue), lineWidth: 1.5)
          }
          if let inspectedTime {
            let x = plot.maxX - CGFloat((end - inspectedTime) / model.history.duration) * plot.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(.secondary), style: StrokeStyle(dash: [3, 3]))
          }
        }
        .onContinuousHover { phase in
          switch phase {
            case .active(let location):
              let fraction = min(1, max(0, (location.x - plot.minX) / plot.width))
              inspectedTime = end - (1 - fraction) * model.history.duration
            case .ended: inspectedTime = nil
          }
        }
      }
      .frame(minHeight: 160)

      HStack {
        Text("Last 30 seconds")
        Spacer()
        Text("\(displayed?.residentBricks ?? 0) / \(displayed?.capacity ?? 0) bricks")
          .monospacedDigit()
        Text(verbatim: "(" + ByteCountFormatter.string(fromByteCount: displayed?.capacityBytes ?? 0,
                                                      countStyle: .memory) + ")")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
