import SwiftUI

// MARK: - WaitingView

/**
 A SwiftUI view that presents the waiting room interface for SharePlay sessions.

 This view displays:
 - The application version.
 - The BorgVR logo.
 - A waiting message instructing the user to wait for the host.
 - A cancel button to leave the group activity.
 - A footer with copyright and link.
 */
struct WaitingView: View {
  /// Shared application model for global app state.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel
  /// Rendering parameters, used here to leave the SharePlay activity.
  @Environment(SharedAppModel.self) private var sharedAppModel

  /// The view’s body.
  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 12) {
          Text("BorgVR Version \(Bundle.main.appVersion).\(Bundle.main.appBuild)")
            .font(.headline)
            .fontWeight(.semibold)

          Image("borgvr")
            .resizable()
            .scaledToFit()
            .frame(
              width: min(180, proxy.size.width * 0.28),
              height: min(180, proxy.size.height * 0.34)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 6)

          Text(runtimeAppModel.sharePlayWaitingReason == .datasetSource
            ? "Waiting for Data Source"
            : "Prepare to be assimilated.")
            .font(.title2)
            .fontWeight(.semibold)

          Text(runtimeAppModel.sharePlayWaitingReason == .datasetSource
            ? "BorgVR is waiting for a participant to make the current dataset available."
            : "Waiting for the host to select and open a dataset.")
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

          if runtimeAppModel.sharePlayWaitingReason == .datasetSource,
             let source = runtimeAppModel.sharePlayDatasetSource {
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

          Spacer(minLength: 4)

          Button {
            sharedAppModel.leaveGroupActivity()
            runtimeAppModel.completeDatasetClose(destination: .datasetSelection)
            runtimeAppModel.navigationState = .start
          } label: {
            Label("Leave SharePlay", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .buttonStyle(.borderedProminent)

          HStack(spacing: 5) {
            Text("© 2024–2026")
            Link("CGVIS Duisburg, Germany", destination: URL(string: "https://www.cgvis.de")!)
          }
          .font(.footnote)
          .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, minHeight: proxy.size.height - 32)
        .padding(16)
      }
    }
  }
}

// MARK: - Preview

#Preview {
  WaitingView()
    .environment(RuntimeAppModel())
    .environment(SharedAppModel())
}

/*
 Copyright (c) 2026 Computer Graphics and Visualization Group, University of Duisburg-
 Essen

 Permission is hereby granted, free of charge, to any person obtaining a copy of this
 software and associated documentation files (the "Software"), to deal in the Software
 without restriction, including without limitation the rights to use, copy, modify,
 merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be included in all copies
 or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
 CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR
 THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
