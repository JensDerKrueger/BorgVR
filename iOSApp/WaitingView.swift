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
        ? "No Data Source Available"
        : "Waiting for SharePlay Host")
        .font(.title2.bold())

      Text(appModel.sharePlayWaitingReason == .datasetSource
        ? "The current dataset is not available from any known source. BorgVR is waiting for a participant to provide one."
        : "Waiting for the host to select and open a dataset.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      Button {
        sharePlay.leaveGroupActivity()
        appModel.currentState = .start
      } label: {
        Label("Leave SharePlay", systemImage: "rectangle.portrait.and.arrow.right")
      }
      .buttonStyle(.borderedProminent)

      Spacer()
    }
    .padding()
  }
}
