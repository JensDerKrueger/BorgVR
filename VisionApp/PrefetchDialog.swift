import SwiftUI

struct PrefetchDialog: View {
  @Binding var isPresented: Bool
  @Binding var progress: Double
  @Binding var statusText: String
  @Binding var continueExecution: Bool
  @Binding var wasCancelled: Bool

  var body: some View {
    VStack(spacing: 20) {
      Text("Prefetching Dataset")
        .font(.headline)

      Text(statusText)
        .font(.subheadline)
        .multilineTextAlignment(.center)

      ProgressView(value: progress)
        .progressViewStyle(LinearProgressViewStyle())
        .padding()

      ProgressView() // Busy spinner

      Button("Cancel and Resume Later") {
        continueExecution = false
        wasCancelled = true
        isPresented = false
      }
      .padding(.top, 10)
    }
    .padding()
    .frame(width: 300)
  }
}
