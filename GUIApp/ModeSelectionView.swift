import SwiftUI

struct ModeSelectionView: View {

  @Environment(AppModel.self) private var appModel

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

      // Description text section
      VStack(alignment: .leading, spacing: 10) {
        Text("Welcome to the BorgVR Dataset Companion Application.")
          .font(.title2)
          .bold()

        Text("""
                BorgVR is a **Bricked Out-of-Core, Ray-Guided Volume Rendering Application** designed for **Virtual and Augmented Reality** on the **Apple Vision Pro** platform. It has been built from the ground up to be fully optimized for Vision Pro, leveraging **Swift** and **Metal** for high-performance rendering. BorgVR is an **open-source** project, making it accessible for further development and collaboration.
                """)

        Text("""
                This application is part of an **ongoing research project**, exploring advanced techniques in volume rendering. Our work has been published in a **short paper** titled:
                """)

        // Link to the IEEE paper
        Link("**Investigating the Apple Vision Pro Spatial Computing Platform for GPU-Based Volume Visualization**",
             destination: URL(string: "https://ieeexplore.ieee.org/document/10771092")!)
        .font(.headline)
        .foregroundColor(.blue)

        Text("""
                presented at **IEEE Visualization 2024**. While the original study introduced the core technology, BorgVR now represents a **more sophisticated volume renderer**, integrating **Ray-Guided Volume Rendering** along with the latest advancements introduced in **visionOS 1.3 and beyond**.
                """)
      }
      .font(.body)
      .multilineTextAlignment(.leading)
      .padding()
      .frame(minWidth: 600, minHeight: 300)

      Spacer()

      HStack {
        Button("Import a Dataset") {
          appModel.currentState = .importData
        }
        Button("Dataset Server") {
          appModel.currentState = .serveData
        }
        Button("Settings") {
          appModel.currentState = .settings
        }
      }

      // Footer with copyright and external link
      HStack(spacing: 5) {
        Text("© 2024-2025")
        Link("CGVIS Duisburg, Germany", destination: URL(string: "https://www.cgvis.de")!)
      }
      .font(.footnote)
      .foregroundColor(.gray)
    }
    .padding()
  }
}
