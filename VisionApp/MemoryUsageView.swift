import SwiftUI

struct MemoryUsageView: View {
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  @Environment(SharedAppModel.self) private var sharedAppModel

  var body: some View {
    VStack(spacing: 16) {
      Label("profile_memory_usage_title", systemImage: "memorychip")
        .font(.title2.bold())

      AtlasPagingGraph(model: runtimeAppModel.atlasPagingModel)

      HStack {
        Spacer()
        Button {
          sharedAppModel.purgeAtlas = true
        } label: {
          Label("profile_button_clear_atlas", systemImage: "arrow.counterclockwise")
        }
        .help("Remove cached bricks from the atlas, keeping the lowest-resolution brick.")
        .disabled(runtimeAppModel.activeDataset == nil)
      }
    }
    .padding(20)
    .frame(minWidth: 740, minHeight: 320)
  }
}
