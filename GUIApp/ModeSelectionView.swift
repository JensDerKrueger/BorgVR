import SwiftUI

struct ModeSelectionView: View {

  @Environment(RuntimeAppModel.self) private var runtimeAppModel

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss

  @State private var showingAbout = false

  var body: some View {
    VStack(spacing: 20) {
      // Large title text
      Text("BorgVR Dataset Companion Application - Version \(Bundle.main.appVersion).\(Bundle.main.appBuild)")
        .font(.largeTitle)
        .bold()
        .frame(minWidth: 680, minHeight: 40)

      Image("borgvr")
        .resizable()
        .scaledToFit()
        .frame(width: 400, height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 10)

      Spacer()
      
      Text("Please choose an option below")
        .font(.title2)

      Spacer()

      HStack {
        Button {
          runtimeAppModel.currentState = .importData
        } label: {
          Label("Import a Dataset", systemImage: "tray.and.arrow.down")
        }
        Button {
          runtimeAppModel.currentState = .serveData
        } label: {
          Label("Dataset Server", systemImage: "server.rack")
        }
        Button {
          runtimeAppModel.currentState = .settings
        } label: {
          Label("Settings", systemImage: "gearshape")
        }

        Spacer()

        Button {
          showingAbout = true
        } label: {
          Label("About", systemImage: "info.circle")
        }
        .sheet(isPresented: $showingAbout) {
          InfoView()
        }

        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle")
          //Label("Close", systemImage: "xmark.circle")
        }
      }

      HStack(spacing: 5) {
        Text("© 2024-2025")
        Link("CGVIS Duisburg, Germany", destination: URL(string: "https://www.cgvis.de")!)
      }
      .padding()
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
