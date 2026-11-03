import SwiftUI

enum DatasetBufferingPhase: Sendable {
  case loadingData
  case preparingRenderer
  case renderingFirstFrame

  var title: LocalizedStringKey {
    switch self {
      case .loadingData: "Buffering..."
      case .preparingRenderer: "Preparing renderer..."
      case .renderingFirstFrame: "Rendering first frame..."
    }
  }

  var explanation: LocalizedStringKey {
    switch self {
      case .loadingData: "Loading the initial volume data and preparing the atlas."
      case .preparingRenderer: "Preparing rendering resources and shaders."
      case .renderingFirstFrame: "The view will open as soon as the first volume frame is ready."
    }
  }
}

struct DatasetBufferingView: View {
  var datasetDescription: String? = nil
  var phase: DatasetBufferingPhase = .loadingData

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(phase.title)
        .font(.headline)
      Text(phase.explanation)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let datasetDescription, !datasetDescription.isEmpty {
        Text(verbatim: datasetDescription)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .multilineTextAlignment(.center)
    .padding(24)
    .frame(maxWidth: 360)
  }
}
