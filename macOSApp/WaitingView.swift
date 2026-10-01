import SwiftUI

struct WaitingView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var sharePlay: SharePlayCoordinator

  var body: some View {
    VStack(spacing: 18) {
      Spacer()

      Image("borgvr")
        .resizable()
        .scaledToFit()
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 8))

      Text(appModel.sharePlayWaitingReason == .datasetSource
        ? "Waiting for Data Source"
        : "Waiting for SharePlay Host")
        .font(.title2.bold())

      Text(appModel.sharePlayWaitingReason == .datasetSource
        ? "BorgVR is waiting for a participant to make the current dataset available."
        : "Waiting for the host to select and open a dataset.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      if appModel.sharePlayWaitingReason == .datasetSource,
         let source = appModel.sharePlayDatasetSource {
        Label {
          Text(
            String(
              format: NSLocalizedString("Trying server: %@", comment: "Currently queried dataset server"),
              source.endpointDescription
            )
          )
        } icon: {
          Image(systemName: "server.rack")
        }
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
      }

      Button {
        sharePlay.leaveGroupActivity()
        appModel.closeDataset(destination: .start)
      } label: {
        Label("Leave SharePlay", systemImage: "rectangle.portrait.and.arrow.right")
      }
      .buttonStyle(.borderedProminent)

      Spacer()
    }
    .padding()
  }
}
