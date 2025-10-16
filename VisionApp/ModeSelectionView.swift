import SwiftUI

/**
 A view that presents the mode selection interface for the BorgVR application.

 This view displays the current application version, an image, descriptive text about BorgVR,
 and provides options to either import a dataset or open an existing one. It also includes footer
 copyright information and a link to the CGVIS Duisburg website.
 */
struct ModeSelectionView: View {

  /// The shared application model, providing access to the application state.
  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  /// An environment value that provides a closure to open new windows.
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 20) {
      // App version
      Text("BorgVR Version \(Bundle.main.appVersion).\(Bundle.main.appBuild)")
        .font(.largeTitle)
        .bold()

      // App logo image
      Image("borgvr")
        .resizable()
        .scaledToFit()
        .frame(width: 400, height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 10)

      // Description
      VStack(alignment: .leading, spacing: 10) {
        Text("Welcome to the BorgVR application.")
          .font(.title2)
          .bold()

        Text("""
              BorgVR is a **Bricked Out-of-Core, Ray-Guided Volume Rendering Application** designed for **Virtual and Augmented Reality** on the **Apple Vision Pro** platform. It has been built from the ground up to be fully optimized for Vision Pro, leveraging **Swift** and **Metal** for high-performance rendering. BorgVR is an **open-source** project, making it accessible for further development and collaboration.
              """)

        Text("""
              This application is part of an **ongoing research project**, exploring advanced techniques in volume rendering. Our work has been published in the following papers:
              """)

        VStack(alignment: .leading, spacing: 6) {
          Link("**Investigating the Apple Vision Pro Spatial Computing Platform for GPU-Based Volume Visualization**",
               destination: URL(string: "https://ieeexplore.ieee.org/document/10771092")!)
          .font(.headline)
          .foregroundColor(.blue)

          Text("Presented at **IEEE Visualization 2024**.")

          Link("**An Investigation of the Apple Vision Pro for Out-of-Core Ray-Guided Volume Rendering with BorgVR**",
               destination: URL(string: "https://www.cgvis.de/publications.shtml#2025")!)
          .font(.headline)
          .foregroundColor(.blue)

          Text("Presented at **VMV 2025**.")
        }

        Text("""
              While the original study introduced the core technology, BorgVR now represents a **more sophisticated volume renderer**, integrating **Ray-Guided Volume Rendering** along with the latest advancements introduced in **visionOS 1.3 and beyond**.
              """)
      }
      .font(.body)
      .multilineTextAlignment(.leading)
      .padding()

      Spacer()

      // Main action buttons
      HStack {
        ShareLink(
          item: BorgVRActivity(),
          preview: SharePreview("BorgVR Live Collaboration")
        ).hidden()

        Button("Open a Dataset") {
          runtimeAppModel.currentState = .selectData
        }
        .padding()
        .buttonStyle(.borderedProminent)

        Button("Import a Dataset") {
          runtimeAppModel.currentState = .importData
        }
        .padding()
        .buttonStyle(.borderedProminent)

        Button("Configure Settings") {
          runtimeAppModel.currentState = .settings
        }
        .padding()
        .buttonStyle(.borderedProminent)
      }

      // Footer
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
