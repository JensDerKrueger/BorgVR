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

      Text("Waiting for SharePlay Host")
        .font(.title2.bold())

      Text("Waiting for the host to select and open a dataset.")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)

      Button {
        sharePlay.leaveGroupActivity()
        appModel.currentState = .start
      } label: {
        Label("Cancel", systemImage: "xmark")
      }
      .buttonStyle(.borderedProminent)

      Spacer()
    }
    .padding()
  }
}
