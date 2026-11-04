import SwiftUI

protocol DatasetStreamingProgressSource: AnyObject {
  var localRatio: Double { get }
  var isCachingLocally: Bool { get }
}

extension BORGVRRemoteData: DatasetStreamingProgressSource {
  var isCachingLocally: Bool { sourceType == .cachingRemote }
}

@MainActor
final class DatasetStreamingProgress: ObservableObject {
  @Published private(set) var fractionCompleted = 1.0
  var isStreaming: Bool { fractionCompleted < 1 }
  var fractionRemaining: Double { 1 - fractionCompleted }

  private weak var source: (any DatasetStreamingProgressSource)?
  private var pollingTask: Task<Void, Never>?

  deinit { pollingTask?.cancel() }

  func track(_ dataset: BORGVRDatasetProtocol?) {
    trackProgress(of: dataset as? DatasetStreamingProgressSource)
  }

  func trackProgress(of source: (any DatasetStreamingProgressSource)?) {
    pollingTask?.cancel()
    pollingTask = nil
    self.source = source
    refresh()
    guard source?.isCachingLocally == true, isStreaming else { return }

    // Read only the cached-brick counter, independently of rendering and paging.
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) }
        catch { return }
        guard let self else { return }
        self.refresh()
        if !self.isStreaming { return }
      }
    }
  }

  func refresh() {
    let fraction = Self.normalizedFraction(source?.localRatio ?? 1)
    if fraction != fractionCompleted { fractionCompleted = fraction }
  }

  static func normalizedFraction(_ fraction: Double) -> Double {
    fraction.isFinite ? min(1, max(0, fraction)) : 0
  }

  var statusText: String {
    let percent = (fractionCompleted * 100).rounded(.down) / 100
    return String(format: NSLocalizedString("Streaming... %@ available locally", comment: ""),
      percent.formatted(.percent.precision(.fractionLength(0))))
  }
}

struct DatasetStreamingStatusView: View {
  @ObservedObject var progress: DatasetStreamingProgress

  var body: some View {
    if progress.isStreaming {
      Text(verbatim: progress.statusText)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct DatasetStreamingProgressLine: View {
  @ObservedObject var progress: DatasetStreamingProgress

  var body: some View {
    if progress.isStreaming {
      FractionProgressLine(fraction: progress.fractionRemaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.statusText)
        .help(progress.statusText)
    }
  }
}
