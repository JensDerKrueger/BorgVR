import SwiftUI

struct PerformanceGraphView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var selectedTab = Tab.frameTiming

  private enum Tab { case frameTiming, paging }

  var body: some View {
    VStack(spacing: 16) {
      Picker("Performance view", selection: $selectedTab) {
        Text("FPS / ms").tag(Tab.frameTiming)
        Text("Paging / Atlas").tag(Tab.paging)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 300)

      switch selectedTab {
        case .frameTiming:
          PerformanceGraph(model: appModel.performanceModel)
        case .paging:
          AtlasPagingGraph(model: appModel.atlasPagingModel)
          HStack {
            Spacer()
            Button {
              appModel.renderAtlasPurgeHandler?()
            } label: {
              Label("Clear Atlas", systemImage: "arrow.counterclockwise")
            }
            .help("Remove cached bricks from the atlas, keeping the lowest-resolution brick.")
            .disabled(!appModel.rendererHasActiveDataset)
          }
      }
    }
    .padding(16)
    .frame(minWidth: 720, minHeight: 340)
  }
}

