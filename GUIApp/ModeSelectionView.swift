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
          Label("Information", systemImage: "info.circle")
        }
        .sheet(isPresented: $showingAbout) {
          InfoView()
        }

        Button {
          dismiss()
        } label: {
          Label("Close", systemImage: "xmark.circle")
        }


      }

      // Footer with copyright and external link
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

