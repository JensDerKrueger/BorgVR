import SwiftUI

// MARK: - Model

/**
 A structure that records performance metrics over time.

 The PerformanceHistory struct stores recent FPS values (last, average, and smoothed)
 in circular buffers. It also supports tracking keyframes (by frame index and color)
 and threshold settings for performance drops and recoveries.
 */
struct PerformanceHistory {
  /// The maximum number of frames to store.
  let maxFrames = 300
  /// A ring buffer to store the most recent FPS values.
  var lastFPS: RingBuffer<Double>
  /// A ring buffer to store the average FPS values.
  var averageFPS: RingBuffer<Double>
  /// A ring buffer to store the smoothed FPS values.
  var smoothedFPS: RingBuffer<Double>
  /// Dictionary storing keyframes (frame index mapped to a color).
  var keyframes: [Int: Color] = [:]
  /// The threshold below which FPS is considered to be dropped.
  var dropThreshold: Double? = nil
  /// The threshold above which FPS is considered recovered.
  var recoveryThreshold: Double? = nil

  /**
   Initializes an empty PerformanceHistory with buffers of capacity maxFrames.
   */
  init() {
    lastFPS = .init(capacity: maxFrames+1)
    averageFPS = .init(capacity: maxFrames+1)
    smoothedFPS = .init(capacity: maxFrames+1)
  }

  /**
   Adds new performance metrics to the history.

   This method appends new FPS values to the respective buffers, maintaining
   the maximum buffer size. It also shifts keyframes by decrementing their frame index.

   - Parameters:
   - last: The latest FPS value.
   - avg: The average FPS value.
   - smoothed: The smoothed FPS value.
   */
  mutating func add(last: Double, avg: Double, smoothed: Double) {
    lastFPS.append(last)
    averageFPS.append(avg)
    smoothedFPS.append(smoothed)

    if lastFPS.count > maxFrames { lastFPS.removeFirst() }
    if averageFPS.count > maxFrames { averageFPS.removeFirst() }
    if smoothedFPS.count > maxFrames { smoothedFPS.removeFirst() }

    // Shift keyframes by decreasing frame indices.
    keyframes = keyframes.compactMapValues { $0 }
    keyframes = keyframes.mapKeys { $0 - 1 }.filter { $0.key >= 0 }
  }

  /**
   Adds a keyframe at the current frame index with the specified color.

   - Parameter color: The color associated with the keyframe.
   */
  mutating func addKeyframe(color: Color) {
    keyframes[lastFPS.count] = color
  }

  /**
   Sets performance drop and recovery thresholds.

   - Parameters:
   - drop: The FPS drop threshold.
   - recovery: The FPS recovery threshold.
   */
  mutating func setThresholds(drop: Double?, recovery: Double?) {
    dropThreshold = drop
    recoveryThreshold = recovery
  }
}

/**
 An extension on Dictionary to transform the keys.

 - Parameter transform: A closure that transforms a key to a new key.
 - Returns: A new dictionary with transformed keys.
 */
extension Dictionary {
  func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
    Dictionary<T, Value>(uniqueKeysWithValues: self.map { (transform($0.key), $0.value) })
  }
}

// MARK: - Shared Observable

/**
 A model that maintains state for the performance graph.

 This observable object tracks the performance history and various settings that
 control what is shown on the graph (e.g., FPS values, grid lines, thresholds, legend).
 */
class PerformanceGraphModel: ObservableObject {
  @Published var history = PerformanceHistory()
  @Published var showLast = true
  @Published var showAvg = true
  @Published var showSmoothed = true
  @Published var showGrid = true
  @Published var showThresholds = true
  @Published var showLegend = true
  @Published var hoverIndex: Int? = nil
  @Published var showZones = true
  @Published var useFrameTime = false {
    didSet {
      if useFrameTime {
        showThresholds = false
        showZones = false
      }
    }
  }
}

// MARK: - SwiftUI Graph View

/**
 A SwiftUI view that displays a performance graph.

 This view draws various elements including performance zones, grid lines, Y-axis labels,
 threshold lines, keyframes, performance curves (last, average, smoothed), and a tooltip for
 hovering over data points.
 */
struct PerformanceGraph: View {
  @ObservedObject var model: PerformanceGraphModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geo in
        let visibleMaxY = computeVisibleMaxY()
        Canvas { context, size in
          drawPerformanceZones(in: size, context: &context, maxY: visibleMaxY)
          drawGrid(in: size, context: &context)
          drawYAxisLabels(in: size, context: &context, maxY: visibleMaxY)
          drawThresholdLines(in: size, context: &context, maxY: visibleMaxY)
          drawKeyframes(in: size, context: &context)
          drawGraphs(in: size, context: &context, maxY: visibleMaxY)
          drawTooltip(in: size, context: &context)
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
          let relativeX = value.location.x / geo.size.width
          let index = Int(CGFloat(model.history.maxFrames) * relativeX)
          model.hoverIndex = max(0, min(model.history.maxFrames - 1, index))
        }.onEnded { _ in
          model.hoverIndex = nil
        })
      }
      .frame(height: 160)

      if model.showLegend {
        VStack(spacing: 4) {
          HStack(spacing: 12) {
            Label("Last", systemImage: "line.diagonal.arrow")
              .foregroundColor(.blue)
            Label("Avg", systemImage: "line.diagonal.arrow")
              .foregroundColor(.orange)
            Label("Smoothed", systemImage: "line.diagonal.arrow")
              .foregroundColor(.purple)
          }
          HStack(spacing: 12) {
            Label("Below Drop", systemImage: "rectangle.fill")
              .foregroundColor(.red.opacity(0.4))
            Label("Between", systemImage: "rectangle.fill")
              .foregroundColor(.yellow.opacity(0.4))
            Label("Above Recovery", systemImage: "rectangle.fill")
              .foregroundColor(.green.opacity(0.4))
          }
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
      }

      HStack(spacing: 12) {
        Toggle("Last", isOn: $model.showLast)
          .toggleStyle(.button)
          .accessibilityLabel("Show last frame rate curve")

        Toggle("Avg", isOn: $model.showAvg)
          .toggleStyle(.button)
          .accessibilityLabel("Show average frame rate curve")

        Toggle("Smoothed", isOn: $model.showSmoothed)
          .toggleStyle(.button)
          .accessibilityLabel("Show smoothed frame rate curve")

        Toggle("Grid", isOn: $model.showGrid)
          .toggleStyle(.button)
          .accessibilityLabel("Show grid lines on graph")

        Toggle("Thresholds", isOn: $model.showThresholds)
          .toggleStyle(.button)
          .accessibilityLabel("Show threshold lines")
          .disabled(model.useFrameTime)

        Toggle("Legend", isOn: $model.showLegend)
          .toggleStyle(.button)
          .accessibilityLabel("Show graph legend")

        Toggle("Zones", isOn: $model.showZones)
          .toggleStyle(.button)
          .accessibilityLabel("Show performance zones")
          .disabled(model.useFrameTime)

        Toggle("ms", isOn: $model.useFrameTime)
          .toggleStyle(.button)
          .accessibilityLabel("Switch to frame time in milliseconds")
      }
      .font(.caption2)
      .frame(maxWidth: .infinity)
    }
    .padding(4)
  }

  /**
   Computes the maximum Y-value to display on the graph.

   The maximum Y-value is determined by considering the currently visible FPS values (or frame times).

   - Returns: The maximum Y value for the performance graph.
   */
  private func computeVisibleMaxY() -> Double {
    var values: [Double] = []
    if model.showLast { values += model.history.lastFPS }
    if model.showAvg { values += model.history.averageFPS }
    if model.showSmoothed { values += model.history.smoothedFPS }
    if model.useFrameTime {
      values = values.map { 1000.0 / max($0, 0.01) }
    }
    return max(values.max() ?? 1.0, model.useFrameTime ? 100.0 : 60.0)
  }

  /**
   Adjusts a Y-value to fit within the graph view based on available space.

   - Parameters:
   - value: The original Y-value.
   - size: The size of the drawing area.
   - Returns: The Y-coordinate adjusted for drawing.
   */
  private func adjustedY(for value: Double, size: CGSize, maxY: Double) -> CGFloat {
    let padding: CGFloat = 12
    let graphHeight = size.height - padding * 2
    let yValue = model.useFrameTime ? 1000.0 / max(value, 0.01) : value
    return padding + graphHeight - CGFloat(yValue / maxY) * graphHeight
  }

  /**
   Draws colored performance zones on the graph.

   Zones are drawn based on the drop and recovery thresholds, if available.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawPerformanceZones(in size: CGSize, context: inout GraphicsContext, maxY: Double) {
    guard model.showZones else { return }
    let bottom = size.height

    if let drop = model.history.dropThreshold {
      let yDrop = adjustedY(for: drop, size: size, maxY: maxY)
      let zone = Path(CGRect(x: 0, y: yDrop, width: size.width,
                             height: bottom - yDrop))
      context.fill(zone, with: .color(.red.opacity(0.1)))
    }

    if let drop = model.history.dropThreshold, let recovery = model.history.recoveryThreshold {
      let yDrop = adjustedY(for: drop, size: size, maxY: maxY)
      let yRecovery = adjustedY(for: recovery, size: size, maxY: maxY)
      let midZone = Path(CGRect(x: 0, y: yRecovery, width: size.width,
                                height: yDrop - yRecovery))
      context.fill(midZone, with: .color(.yellow.opacity(0.08)))
    }

    if let recovery = model.history.recoveryThreshold {
      let yRecovery = adjustedY(for: recovery, size: size, maxY:maxY)
      let zone = Path(CGRect(x: 0, y: 0, width: size.width, height: yRecovery))
      context.fill(zone, with: .color(.green.opacity(0.05)))
    }
  }

  /**
   Draws Y-axis labels on the graph.

   Labels indicate FPS (or frame time) values at regular intervals along the Y-axis.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawYAxisLabels(in size: CGSize, context: inout GraphicsContext, maxY: Double) {
    let stepY: CGFloat = (size.height - 24) / 6

    let unit = model.useFrameTime ? "ms" : "fps"
    for i in 1..<6 {
      let yPos = CGFloat(i) * stepY + 12
      let label = String(format: "%.0f %@", maxY - Double(i) * maxY / 6, unit)
      context.draw(Text(label)
        .font(.caption2)
        .foregroundColor(.gray),
                   at: CGPoint(x: 2, y: yPos - 6),
                   anchor: .topLeading)
    }
  }

  /**
   Draws performance graphs (lines) on the graph view.

   Three different graphs (last, average, and smoothed) may be drawn based on the model's settings.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawGraphs(in size: CGSize, context: inout GraphicsContext, maxY: Double) {
    let stepX = size.width / CGFloat(model.history.maxFrames)

    if model.showLast {
      drawLine(values: model.history.lastFPS, color: .blue,
               stepX: stepX, size: size, context: &context, maxY: maxY)
    }
    if model.showAvg {
      drawLine(values: model.history.averageFPS, color: .orange,
               stepX: stepX, size: size, context: &context, maxY: maxY)
    }
    if model.showSmoothed {
      drawLine(values: model.history.smoothedFPS, color: .purple,
               stepX: stepX, size: size, context: &context, maxY: maxY)
    }
  }

  /**
   Draws a line graph for the given performance values.

   - Parameters:
   - values: The ring buffer containing performance measurements.
   - color: The color to draw the line.
   - stepX: The horizontal distance between adjacent data points.
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawLine(
    values: RingBuffer<Double>,
    color: Color,
    stepX: CGFloat,
    size: CGSize,
    context: inout GraphicsContext,
    maxY: Double
  ) {
    guard values.count > 1 else { return }
    var path = Path()
    let step = max(1, values.count / Int(size.width))
    for i in stride(from: 0, to: values.count, by: step) {
      let point = CGPoint(x: CGFloat(i) * stepX,
                          y: adjustedY(for: values[i], size: size, maxY: maxY))
      if i == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }
    context.stroke(path, with: .color(color), lineWidth: 1.2)
  }

  /**
   Draws a tooltip showing detailed performance values at a hovered index.

   The tooltip displays FPS or frame time values from last, average, and smoothed curves.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawTooltip(in size: CGSize, context: inout GraphicsContext) {
    guard let index = model.hoverIndex else { return }
    let stepX = size.width / CGFloat(model.history.maxFrames)
    let x = CGFloat(index) * stepX

    var tooltip: [String] = []
    let unit = model.useFrameTime ? "ms" : "fps"
    if model.showLast, index < model.history.lastFPS.count {
      tooltip.append("Last: \(String(format: "%.1f", model.history.lastFPS[index])) \(unit)")
    }
    if model.showAvg, index < model.history.averageFPS.count {
      tooltip.append("Avg: \(String(format: "%.1f", model.history.averageFPS[index])) \(unit)")
    }
    if model.showSmoothed, index < model.history.smoothedFPS.count {
      tooltip.append("Smoothed: \(String(format: "%.1f", model.history.smoothedFPS[index])) \(unit)")
    }

    if !tooltip.isEmpty {
      let box = CGRect(x: x + 6, y: 4,
                       width: 140, height: CGFloat(tooltip.count) * 14 + 16)
      context.fill(Path(roundedRect: box, cornerRadius: 6),
                   with: .color(.black.opacity(0.6)))
      for (i, text) in tooltip.enumerated() {
        context.draw(Text(text)
          .font(.caption2)
          .foregroundColor(.white),
                     at: CGPoint(x: box.minX + 6,
                                 y: box.minY + 8 + CGFloat(i) * 14),
                     anchor: .topLeading)
      }
    }

    var path = Path()
    path.move(to: CGPoint(x: x, y: 0))
    path.addLine(to: CGPoint(x: x, y: size.height))
    context.stroke(path, with: .color(.white.opacity(0.3)),
                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
  }

  /**
   Draws horizontal threshold lines on the graph for performance drop and recovery.

   Lines are drawn if the respective thresholds are set.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawThresholdLines(in size: CGSize,
                                  context: inout GraphicsContext,
                                  maxY: Double) {
    guard model.showThresholds else { return }
    if let drop = model.history.dropThreshold {
      let y = adjustedY(for: drop, size: size, maxY: maxY)
      var path = Path()
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
      context.stroke(path, with: .color(.red.opacity(0.6)),
                     style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    if let recovery = model.history.recoveryThreshold {
      let y = adjustedY(for: recovery, size: size, maxY: maxY)
      var path = Path()
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
      context.stroke(path, with: .color(.green.opacity(0.6)),
                     style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
  }

  /**
   Draws vertical keyframe lines on the graph.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawKeyframes(in size: CGSize, context: inout GraphicsContext) {
    let stepX = size.width / CGFloat(model.history.maxFrames)
    for (frame, color) in model.history.keyframes {
      let x = CGFloat(frame) * stepX
      var path = Path()
      path.move(to: CGPoint(x: x, y: 0))
      path.addLine(to: CGPoint(x: x, y: size.height))
      context.stroke(path, with: .color(color),
                     style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }
  }

  /**
   Draws horizontal grid lines on the performance graph.

   - Parameters:
   - size: The size of the drawing area.
   - context: The graphics context for drawing.
   */
  private func drawGrid(in size: CGSize, context: inout GraphicsContext) {
    guard model.showGrid else { return }
    let stepY: CGFloat = (size.height - 24) / 6
    for i in 1..<6 {
      let y = CGFloat(i) * stepY + 12
      var path = Path()
      path.move(to: CGPoint(x: 0, y: y))
      path.addLine(to: CGPoint(x: size.width, y: y))
      context.stroke(path, with: .color(.gray.opacity(0.2)))
    }
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
 PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
 FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
 OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 DEALINGS IN THE SOFTWARE.
 */
