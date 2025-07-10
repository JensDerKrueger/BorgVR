import Foundation
import Metal
import SwiftUI
import UniformTypeIdentifiers

/**
 Extensions for TransferFunction1D that provide various drawing methods
 for visualizing transfer functions in a GraphicsContext.
 */
extension TransferFunction1D {

  /**
   Draws colored curves for each channel (red, green, blue, white) based on the
   transfer function data within the specified rectangle.

   - Parameters:
   - context: The GraphicsContext to draw in.
   - rect: The CGRect area where the curves will be drawn.
   */
  func drawCurves(in context: GraphicsContext, rect: CGRect) {
    let width = rect.width
    let height = rect.height
    let count = data.count
    guard count > 1 else { return }

    let xSpacing = width / CGFloat(count - 1)

    var redPath = Path()
    var greenPath = Path()
    var bluePath = Path()
    var whitePath = Path()

    let dashStyle: [CGFloat] = [3, 4]
    for i in 0..<count {
      let x = CGFloat(i) * xSpacing + rect.minX
      let values = data[i]

      // Map each UInt8 (0...255) to a y coordinate in the rect.
      let redY   = rect.maxY - (CGFloat(values.x) / 255.0 * height)
      let greenY = rect.maxY - (CGFloat(values.y) / 255.0 * height)
      let blueY  = rect.maxY - (CGFloat(values.z) / 255.0 * height)
      let whiteY = rect.maxY - (CGFloat(values.w) / 255.0 * height)

      let redPoint = CGPoint(x: x, y: redY)
      let greenPoint = CGPoint(x: x, y: greenY)
      let bluePoint = CGPoint(x: x, y: blueY)
      let whitePoint = CGPoint(x: x, y: whiteY)

      if i == 0 {
        redPath.move(to: redPoint)
        greenPath.move(to: greenPoint)
        bluePath.move(to: bluePoint)
        whitePath.move(to: whitePoint)
      } else {
        redPath.addLine(to: redPoint)
        greenPath.addLine(to: greenPoint)
        bluePath.addLine(to: bluePoint)
        whitePath.addLine(to: whitePoint)
      }
    }

    context.stroke(redPath,
                   with: .color(.red),
                   style: StrokeStyle(lineWidth: 2, dash: dashStyle, dashPhase: 0))
    context.stroke(greenPath,
                   with: .color(.green),
                   style: StrokeStyle(lineWidth: 2, dash: dashStyle, dashPhase: 1))
    context.stroke(bluePath,
                   with: .color(.blue),
                   style: StrokeStyle(lineWidth: 2, dash: dashStyle, dashPhase: 2))
    context.stroke(whitePath,
                   with: .color(.white),
                   style: StrokeStyle(lineWidth: 2, dash: dashStyle, dashPhase: 3))
  }

  /**
   Draws a grid in the specified rectangle.

   Vertical and horizontal grid lines are drawn at regular intervals.

   - Parameters:
   - context: The GraphicsContext to draw the grid.
   - rect: The rectangle in which to draw the grid.
   */
  func drawGrid(in context: GraphicsContext, rect: CGRect) {
    let gridSpacing: CGFloat = 20.0
    var gridPath = Path()

    // Draw vertical grid lines.
    for x in stride(from: rect.minX, through: rect.maxX, by: gridSpacing) {
      gridPath.move(to: CGPoint(x: x, y: rect.minY))
      gridPath.addLine(to: CGPoint(x: x, y: rect.maxY))
    }

    // Draw horizontal grid lines.
    for y in stride(from: rect.minY, through: rect.maxY, by: gridSpacing) {
      gridPath.move(to: CGPoint(x: rect.minX, y: y))
      gridPath.addLine(to: CGPoint(x: rect.maxX, y: y))
    }

    context.stroke(gridPath,
                   with: .color(.gray),
                   style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
  }

  /**
   Computes optimized gradient stops from the transfer function data.

   Only adds a gradient stop if the value has changed from the last stop and limits
   the total number of stops to at most maxStops.

   - Parameter maxStops: The maximum number of gradient stops to include (default is 40).
   - Returns: An array of Gradient.Stop values representing the transfer function.
   */
  private func optimizedGradientStops(maxStops: Int = 40) -> [Gradient.Stop] {
    guard data.count > 1 else { return [] }

    var stops: [Gradient.Stop] = []
    let totalCount = data.count
    let step = max(1, totalCount / maxStops)

    // Always add the first stop.
    let first = data[0]
    let firstColor = Color(
      red: Double(first.x) / 255.0,
      green: Double(first.y) / 255.0,
      blue: Double(first.z) / 255.0,
      opacity: Double(first.w) / 255.0)
    stops.append(Gradient.Stop(color: firstColor, location: 0))

    var lastStopValue = first
    // Iterate through data with the chosen step.
    for index in stride(from: 1, to: totalCount - 1, by: step) {
      let current = data[index]
      if current != lastStopValue {
        let location = Double(index) / Double(totalCount - 1)
        let currentColor = Color(
          red: Double(current.x) / 255.0,
          green: Double(current.y) / 255.0,
          blue: Double(current.z) / 255.0,
          opacity: Double(current.w) / 255.0)
        stops.append(Gradient.Stop(color: currentColor, location: location))
        lastStopValue = current
      }
    }

    // Always add the final stop.
    let last = data[totalCount - 1]
    let lastColor = Color(
      red: Double(last.x) / 255.0,
      green: Double(last.y) / 255.0,
      blue: Double(last.z) / 255.0,
      opacity: Double(last.w) / 255.0)
    stops.append(Gradient.Stop(color: lastColor, location: 1))

    return stops
  }

  /**
   Draws a ribbon using a linear gradient computed from the transfer function data.

   The gradient is computed from optimized gradient stops and fills the specified rectangle.

   - Parameters:
   - context: The GraphicsContext to draw the ribbon.
   - rect: The rectangle to fill with the gradient.
   - maxStops: The maximum number of gradient stops to use (default is 40).
   */
  func drawRibbon(in context: GraphicsContext, rect: CGRect, maxStops: Int = 40) {
    guard data.count > 1 else { return }
    let stops = optimizedGradientStops(maxStops: maxStops)
    let gradient = Gradient(stops: stops)

    context.fill(
      Path(rect),
      with: .linearGradient(
        gradient,
        startPoint: CGPoint(x: rect.minX, y: rect.minY),
        endPoint: CGPoint(x: rect.maxX, y: rect.minY)
      )
    )
  }

  /**
   Draws a checkerboard pattern in the specified rectangle.

   The checkerboard is drawn using cells of the specified size. Alternate cells are filled
   with different shades of gray.

   - Parameters:
   - context: The GraphicsContext in which to draw.
   - rect: The CGRect area where the checkerboard will be drawn.
   - cellSize: The size of each square cell (default is 10 points).
   */
  func drawCheckerboard(in context: GraphicsContext, rect: CGRect, cellSize: CGFloat = 10) {
    guard cellSize > 0 else { return }

    let columns = Int(ceil(rect.width / cellSize))
    let rows = Int(ceil(rect.height / cellSize))

    var lightPath = Path()
    var darkPath = Path()

    for row in 0..<rows {
      for col in 0..<columns {
        let x = rect.minX + CGFloat(col) * cellSize
        let y = rect.minY + CGFloat(row) * cellSize

        let alignedX = x.rounded(.down)
        let alignedY = y.rounded(.down)

        let cellRect = CGRect(x: alignedX, y: alignedY,
                              width: cellSize, height: cellSize)
        let isLight = (row + col) % 2 == 0

        if isLight {
          lightPath.addRect(cellRect)
        } else {
          darkPath.addRect(cellRect)
        }
      }
    }

    context.fill(lightPath, with: .color(Color(white: 0.8)))
    context.fill(darkPath, with: .color(Color(white: 0.6)))
  }
}

extension UTType {
  static var transferFunction: UTType {
    UTType(exportedAs: "de.cgvis.transferfunction1d")
  }
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
