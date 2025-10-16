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
    VStack(spacing: 10) {
      // Display the application version (major.minor).
      Text("BorgVR Version \(Bundle.main.appVersion).\(Bundle.main.appBuild)")
        .font(.extraLargeTitle)
        .bold()

      // Display the BorgVR logo.
      Image("borgvr")
        .resizable()
        .scaledToFit()
        .frame(width: 400, height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 10)

      // Waiting message header.
      Text("Prepare to be assimilated.")
        .font(.extraLargeTitle2)
        .bold()

      // Waiting instruction text.
      Text("Waiting for the host to select and open a dataset.")
        .font(.largeTitle)
        .bold()

      Spacer()

      // Cancel button row.
      HStack {
        Button("Cancel") {
          // Leave the SharePlay group activity and return to start screen.
          sharedAppModel.leaveGroupActivity()
          runtimeAppModel.currentState = .start
        }
        .padding()
        .buttonStyle(.borderedProminent)
      }

      // Footer with copyright and link.
      HStack(spacing: 5) {
        Text("© 2024–2025")
        Link("CGVIS Duisburg, Germany", destination: URL(string: "https://www.cgvis.de")!)
      }
      .font(.footnote)
      .foregroundColor(.gray)
    }
    .padding()
  }
}

// MARK: - Preview

#Preview {
  WaitingView()
    .environment(RuntimeAppModel())
    .environment(SharedAppModel())
}

/*
 Copyright (c) 2025 Computer Graphics and Visualization Group, University of Duisburg-
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
