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

  @State private var showingAbout = false

  var body: some View {
    VStack() {
      HStack {
        VStack() {
          Text("BorgVR")
            .font(.largeTitle)
            .bold()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
          Text("Version \(Bundle.main.appVersion).\(Bundle.main.appBuild)")
            .font(.title)
            .bold()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

          Spacer()

          Text("Please choose an option below")
            .font(.title2)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Spacer()

        VStack() {
          Image("borgvr")
            .resizable()
            .scaledToFit()
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 10)
            .padding()
          Spacer()
        }
      }

      Spacer()

      // Main action buttons
      HStack {
        Button {
          runtimeAppModel.currentState = .selectData
        } label: {
          Label("Open Dataset", systemImage: "folder")
        }
        .padding()
        .buttonStyle(.borderedProminent)

        Button {
          runtimeAppModel.currentState = .importData
        } label: {
          Label("Import Dataset", systemImage: "tray.and.arrow.down")
        }
        .padding()
        .buttonStyle(.borderedProminent)

        Button {
          runtimeAppModel.currentState = .settings
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .padding()
        .buttonStyle(.borderedProminent)

        ShareLink(
          item: BorgVRActivity(),
          preview: SharePreview("BorgVR Live Collaboration")
        ).hidden()

        Button {
          showingAbout = true
        } label: {
          Label("About", systemImage: "info.circle")
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
      .padding()
    }
    .padding()
    .sheet(isPresented: $showingAbout) {
      InfoView()
      .frame(
        minWidth: 900,
        minHeight: 300
      )

    }
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
