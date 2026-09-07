import SwiftUI

struct PerformanceGraphView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    VStack(spacing: 16) {
      Text("performance_title")
        .font(.title2)
        .bold()

      PerformanceGraph(model: appModel.performanceModel)
    }
    .padding(16)
    .frame(minWidth: 720, minHeight: 300)
  }
}

