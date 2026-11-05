import Foundation
import Combine
import AppKit
import SwiftUI
@testable import BorgVR

private final class ProgressSource: DatasetStreamingProgressSource {
  var localRatio: Double
  var isCachingLocally = true

  init(_ ratio: Double) { localRatio = ratio }
}

@main
struct DatasetStreamingProgressTests {
  @MainActor
  static func main() async throws {
    let progress = DatasetStreamingProgress()
    precondition(!progress.isStreaming)
    precondition(progress.fractionRemaining == 0)
    for (input, expected) in [(Double.nan, 0.0), (.infinity, 0), (-1, 0), (2, 1), (0.5, 0.5)] {
      precondition(DatasetStreamingProgress.normalizedFraction(input) == expected)
    }

    let first = ProgressSource(0.25)
    progress.trackProgress(of: first)
    precondition(progress.isStreaming && progress.fractionRemaining == 0.75)
    var updates = 0
    let observation = progress.objectWillChange.sink { updates += 1 }
    progress.refresh()
    precondition(updates == 0, "Unchanged progress must not redraw the UI")
    first.localRatio = 0.6
    try await waitUntil { progress.fractionCompleted == 0.6 }
    precondition(progress.fractionRemaining == 0.4)

    let replacement = ProgressSource(0.1)
    progress.trackProgress(of: replacement)
    first.localRatio = 1
    progress.refresh()
    precondition(progress.fractionCompleted == 0.1, "Old sources must not update a replacement")
    replacement.localRatio = 1
    try await waitUntil { !progress.isStreaming }
    precondition(progress.fractionRemaining == 0)

    let uncached = ProgressSource(0)
    uncached.isCachingLocally = false
    progress.trackProgress(of: uncached)
    precondition(progress.isStreaming && progress.fractionRemaining == 1)
    progress.track(nil)
    precondition(!progress.isStreaming)

    var transient: ProgressSource? = ProgressSource(0.2)
    weak let weakSource = transient
    progress.trackProgress(of: transient)
    transient = nil
    precondition(weakSource == nil, "The UI must not retain an unused dataset")
    progress.refresh()
    precondition(!progress.isStreaming)
    for (fraction, expectedWidth) in [(1.0, 200), (0.75, 150), (0.25, 50), (0, 0)] {
      let renderer = ImageRenderer(content: FractionProgressLine(fraction: fraction).frame(width: 200))
      renderer.scale = 1
      guard let image = renderer.cgImage else { fatalError("Progress line did not render") }
      let bitmap = NSBitmapImageRep(cgImage: image)
      precondition(image.width == 200 && image.height == 2)
      let filledWidth = (0..<200).filter { (bitmap.colorAt(x: $0, y: 0)?.alphaComponent ?? 0) > 0.5 }.count
      precondition(filledWidth == expectedWidth, "Progress line must shrink with the remaining fraction")
      for x in 0..<200 {
        let filled = (bitmap.colorAt(x: x, y: 0)?.alphaComponent ?? 0) > 0.5
        precondition(filled == (x >= 200 - expectedWidth), "Progress line must disappear from left to right")
      }
    }
    withExtendedLifetime(observation) {}
    print("Dataset streaming progress, polling, replacement and completion tests passed")
  }

  @MainActor
  private static func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<30 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    preconditionFailure("Streaming progress did not update")
  }
}
