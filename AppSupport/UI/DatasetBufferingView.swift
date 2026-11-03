import SwiftUI

struct DatasetBufferingView: View {
  var datasetDescription: String? = nil

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Buffering...")
        .font(.headline)
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
